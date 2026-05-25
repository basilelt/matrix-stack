#!/usr/bin/env python3
"""claude-notify-bot — Matrix webhook relay for Claude Code session events."""

import asyncio
import json
import logging
import os
from pathlib import Path

from aiohttp import web
from nio import AsyncClient, AsyncClientConfig, LoginResponse, RoomCreateResponse, RoomPreset

LOG = logging.getLogger("claude-notify-bot")


def _setup_logging():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s — %(message)s",
    )


def _load_config() -> dict:
    path = os.environ.get("CONFIG_PATH", "/app/config.json")
    with open(path) as f:
        return json.load(f)


def _fmt_elapsed(secs: int) -> str:
    if secs < 60:
        return f"{secs}s"
    m, s = divmod(secs, 60)
    return f"{m}m{s:02d}s" if s else f"{m}m"


def _render(data: dict) -> tuple[str, str]:
    """Return (plain_body, html_body)."""
    event   = data.get("event", "stop")
    host    = data.get("host", "?")
    session = data.get("session_name", "")
    cwd     = data.get("cwd_basename", "")
    branch  = data.get("branch", "")
    elapsed = int(data.get("elapsed_seconds", 0))
    msg     = data.get("message", "")

    if event == "stop":
        tp = "✅ Claude done" + (f": {session}" if session else "")
        th = "✅ <b>Claude done</b>" + (f": <i>{session}</i>" if session else "")

        mp, mh = [f"💻 {host}"], [f"💻 <code>{host}</code>"]
        if cwd:
            mp.append(f"📁 {cwd}" + (f" ({branch})" if branch else ""))
            mh.append(f"📁 <code>{cwd}</code>" + (f" (<code>{branch}</code>)" if branch else ""))
        if elapsed:
            e = _fmt_elapsed(elapsed)
            mp.append(f"⏱ {e}"); mh.append(f"⏱ {e}")

        return tp + "\n" + " | ".join(mp), th + "<br>" + " | ".join(mh)

    else:  # notification / waiting
        tp = f"⏸ Claude waiting — {host}"
        th = f"⏸ <b>Claude waiting</b> — <code>{host}</code>"
        mp, mh = [], []
        if cwd:
            mp.append(f"📁 {cwd}"); mh.append(f"📁 <code>{cwd}</code>")
        if msg:
            mp.append(msg); mh.append(f"<i>{msg}</i>")
        sep_p = "\n" + " | ".join(mp) if mp else ""
        sep_h = "<br>" + " | ".join(mh) if mh else ""
        return tp + sep_p, th + sep_h


class NotifyBot:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.room_id: str | None = None
        store = cfg["store_path"]
        Path(store).mkdir(parents=True, exist_ok=True)
        self._room_id_file = Path(store) / "dm_room_id"

        nio_cfg = AsyncClientConfig(store_sync_tokens=True, encryption_enabled=True)
        self.client = AsyncClient(
            cfg["homeserver"],
            cfg["user_id"],
            device_id=cfg["device_id"],
            store_path=store,
            config=nio_cfg,
        )

    async def _login(self):
        resp = await self.client.login(self.cfg["password"], device_name="claude-notify-bot")
        if not isinstance(resp, LoginResponse):
            raise RuntimeError(f"Login failed: {resp}")
        self.client.load_store()
        LOG.info("Logged in as %s device=%s", self.cfg["user_id"], self.client.device_id)

    async def _ensure_dm_room(self):
        # Always sync first to populate client.rooms
        await self.client.sync(timeout=15_000, full_state=True)

        if self._room_id_file.exists():
            self.room_id = self._room_id_file.read_text().strip()
            LOG.info("Restored DM room: %s", self.room_id)
            return

        owner = self.cfg["owner_user"]

        for rid, room in self.client.rooms.items():
            members = list(room.users.keys())
            if len(members) == 2 and owner in members and room.encrypted:
                LOG.info("Found existing encrypted DM: %s", rid)
                self.room_id = rid
                self._room_id_file.write_text(rid)
                return

        LOG.info("Creating encrypted DM room with %s", owner)
        resp = await self.client.room_create(
            is_direct=True,
            invite=[owner],
            preset=RoomPreset.trusted_private_chat,
            initial_state=[{
                "type": "m.room.encryption",
                "content": {"algorithm": "m.megolm.v1.aes-sha2"},
            }],
        )
        if not isinstance(resp, RoomCreateResponse):
            raise RuntimeError(f"Room create failed: {resp}")

        self.room_id = resp.room_id
        self._room_id_file.write_text(resp.room_id)
        LOG.info("Created DM room: %s", self.room_id)

    async def send(self, data: dict):
        if not self.room_id:
            LOG.warning("No DM room, dropping notification")
            return

        body, html = _render(data)
        content = {
            "msgtype": "m.text",
            "body": body,
            "format": "org.matrix.custom.html",
            "formatted_body": html,
        }

        await self.client.sync(timeout=5_000)
        resp = await self.client.room_send(
            self.room_id, "m.room.message", content,
            ignore_unverified_devices=True,
        )
        LOG.info("Sent %s event: %s", data.get("event"), resp)

    async def run(self):
        await self._login()
        await self._ensure_dm_room()
        asyncio.create_task(self.client.sync_forever(timeout=30_000, full_state=False))
        LOG.info("Bot ready — DM room %s", self.room_id)


def _make_app(bot: NotifyBot, token: str) -> web.Application:
    app = web.Application()

    async def handle_notify(req: web.Request) -> web.Response:
        if req.headers.get("Authorization") != f"Bearer {token}":
            return web.json_response({"error": "unauthorized"}, status=401)
        try:
            data = await req.json()
        except Exception:
            return web.json_response({"error": "bad json"}, status=400)
        asyncio.create_task(bot.send(data))
        return web.json_response({"ok": True})

    app.router.add_post("/notify", handle_notify)
    return app


async def main():
    _setup_logging()
    cfg = _load_config()
    bot = NotifyBot(cfg)
    await bot.run()

    app = _make_app(bot, cfg["webhook_token"])
    runner = web.AppRunner(app)
    await runner.setup()
    port = cfg.get("listen_port", 8095)
    await web.TCPSite(runner, "0.0.0.0", port).start()
    LOG.info("Webhook listening on :%d", port)

    await asyncio.Event().wait()


if __name__ == "__main__":
    asyncio.run(main())
