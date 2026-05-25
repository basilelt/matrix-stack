#!/usr/bin/env python3
"""matrix-sticker-bot (E2EE) — watches stickers room for .wastickers uploads, auto-imports."""
import asyncio
import importlib.util
import json
import logging
import tempfile
from pathlib import Path
from typing import Optional

from nio import (
    AsyncClient, AsyncClientConfig, LoginResponse,
    RoomMessageFile, MegolmEvent, DownloadError,
    OlmUnverifiedDeviceError,
)
from nio.crypto import decrypt_attachment

# Load import.py helpers via importlib (module name 'import' is a Python keyword)
_spec = importlib.util.spec_from_file_location("importer", Path(__file__).parent / "import.py")
_importer = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_importer)
load_config = _importer.load_config
import_pack = _importer.import_pack

LOG = logging.getLogger("sticker-bot")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s — %(message)s")

STORE_DIR = Path("/app/data/store")
SEEN_FILE = Path("/app/data/seen.json")
SEEN_MAX = 500
DEVICE_ID = "STICKERBOT01"


def _load_seen() -> set:
    if SEEN_FILE.exists():
        return set(json.loads(SEEN_FILE.read_text()))
    return set()


def _save_seen(seen: set) -> None:
    SEEN_FILE.write_text(json.dumps(list(seen)[-SEEN_MAX:]))


class StickerBot:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.hs = cfg["homeserver_url"].rstrip("/")
        self.room_id = cfg["stickers_room_id"]
        self.seen = _load_seen()
        STORE_DIR.mkdir(parents=True, exist_ok=True)

        domain = self.hs.split("//")[-1]
        self.client = AsyncClient(
            self.hs,
            f"@{cfg['stickers_user']}:{domain}",
            device_id=DEVICE_ID,
            store_path=str(STORE_DIR),
            config=AsyncClientConfig(
                encryption_enabled=True,
                store_sync_tokens=True,
                max_limit_exceeded=0,
                max_timeouts=0,
            ),
        )

    async def _login(self) -> None:
        resp = await self.client.login(self.cfg["stickers_password"], device_name="sticker-bot")
        if not isinstance(resp, LoginResponse):
            raise RuntimeError(f"Login failed: {resp}")
        self.client.load_store()
        if self.client.should_upload_keys:
            await self.client.keys_upload()
        if self.client.should_query_keys:
            await self.client.keys_query()
        LOG.info("Logged in as %s (device %s)", self.client.user_id, DEVICE_ID)

    def _trust_room_devices(self) -> None:
        room = self.client.rooms.get(self.room_id)
        if not room:
            return
        for user_id in room.users:
            try:
                for device in self.client.device_store.active_user_devices(user_id):
                    if not device.verified and not device.blacklisted:
                        self.client.verify_device(device)
                        LOG.debug("Trusted device %s for %s", device.device_id, user_id)
            except Exception:
                pass

    async def _react(self, event_id: str, key: str) -> None:
        content = {"m.relates_to": {"rel_type": "m.annotation", "event_id": event_id, "key": key}}
        for _ in range(3):
            try:
                await self.client.room_send(self.room_id, "m.reaction", content)
                return
            except OlmUnverifiedDeviceError as e:
                self.client.verify_device(e.device)
            except Exception as exc:
                LOG.warning("react failed: %s", exc)
                return

    async def _send_message(self, body: str) -> None:
        content = {"msgtype": "m.text", "body": body}
        for _ in range(3):
            try:
                await self.client.room_send(self.room_id, "m.room.message", content)
                return
            except OlmUnverifiedDeviceError as e:
                self.client.verify_device(e.device)
            except Exception as exc:
                LOG.warning("send_message failed: %s", exc)
                return

    async def _process(self, event_id: str, body: str, mxc: str,
                       file_info: Optional[dict]) -> None:
        if not body.lower().endswith(".wastickers"):
            return
        if event_id in self.seen:
            return
        self.seen.add(event_id)
        _save_seen(self.seen)

        LOG.info("Processing upload: %s (%s)", body, event_id)
        try:
            resp = await self.client.download(mxc)
            if isinstance(resp, DownloadError):
                raise RuntimeError(f"Download error: {resp.message}")

            data = resp.body
            if file_info:
                data = decrypt_attachment(
                    data,
                    file_info["key"]["k"],
                    file_info["hashes"]["sha256"],
                    file_info["iv"],
                )

            with tempfile.NamedTemporaryFile(suffix=".wastickers", delete=False) as tmp:
                tmp.write(data)
                tmp_path = Path(tmp.name)

            token = self.client.access_token
            result = await asyncio.get_event_loop().run_in_executor(
                None, import_pack, self.cfg, token, tmp_path
            )
            tmp_path.unlink(missing_ok=True)

            await self._react(event_id, "✅")
            if result is not None:
                pack_id, pack_title, n = result
                await self._send_message(
                    f"Imported '{pack_title}' ({n} stickers) — pack id {pack_id}"
                )
            else:
                await self._send_message(f"Imported {body}")

        except Exception as exc:
            LOG.exception("Failed to import %s", body)
            try:
                await self._react(event_id, "❌")
                await self._send_message(f"Import failed: {exc}")
            except Exception:
                pass

    async def _on_file(self, room, event: RoomMessageFile) -> None:
        if room.room_id != self.room_id or event.sender == self.client.user_id:
            return
        content = event.source.get("content", {})
        file_info = content.get("file")
        mxc = file_info["url"] if file_info else event.url
        asyncio.create_task(self._process(event.event_id, event.body, mxc, file_info))

    async def _on_megolm(self, room, event: MegolmEvent) -> None:
        if room.room_id == self.room_id:
            LOG.warning("Undecryptable event %s — missing Megolm session key", event.event_id)

    async def start(self) -> None:
        await self._login()
        # Initial sync to populate room state, then trust devices
        await self.client.sync(timeout=10_000, full_state=True)
        self._trust_room_devices()

        self.client.add_event_callback(self._on_file, RoomMessageFile)
        self.client.add_event_callback(self._on_megolm, MegolmEvent)

        LOG.info("Watching room %s (E2EE)", self.room_id)
        await self.client.sync_forever(timeout=30_000, full_state=True)


async def main() -> None:
    cfg = load_config()
    bot = StickerBot(cfg)
    await bot.start()


if __name__ == "__main__":
    asyncio.run(main())
