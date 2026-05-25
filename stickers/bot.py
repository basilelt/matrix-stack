#!/usr/bin/env python3
"""matrix-sticker-bot — watches the stickers room for .wastickers uploads and auto-imports them."""
import importlib.util
import json
import logging
import tempfile
import time
from pathlib import Path

import httpx

# Load import.py via importlib (module name 'import' is a Python keyword)
_spec = importlib.util.spec_from_file_location("importer", Path(__file__).parent / "import.py")
_importer = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_importer)

load_config = _importer.load_config
get_access_token = _importer.get_access_token
import_pack = _importer.import_pack

LOG = logging.getLogger("sticker-bot")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s — %(message)s")

SYNC_TOKEN_FILE = Path("/app/data/sync_token.txt")
SEEN_FILE = Path("/app/data/seen.json")
SEEN_MAX = 500


def _load_seen() -> set:
    if SEEN_FILE.exists():
        return set(json.loads(SEEN_FILE.read_text()))
    return set()


def _save_seen(seen: set) -> None:
    lst = list(seen)[-SEEN_MAX:]
    SEEN_FILE.write_text(json.dumps(lst))


def _mxc_to_download_url(hs: str, mxc: str) -> str:
    without_scheme = mxc[len("mxc://"):]
    return f"{hs}/_matrix/media/v3/download/{without_scheme}"


def _send_message(hs: str, token: str, room_id: str, body: str) -> None:
    txn_id = f"bot-{int(time.time() * 1000)}"
    httpx.put(
        f"{hs}/_matrix/client/v3/rooms/{room_id}/send/m.room.message/{txn_id}",
        headers={"Authorization": f"Bearer {token}"},
        json={"msgtype": "m.text", "body": body},
        timeout=30,
    ).raise_for_status()


def _react(hs: str, token: str, room_id: str, event_id: str, key: str) -> None:
    txn_id = f"react-{int(time.time() * 1000)}"
    httpx.put(
        f"{hs}/_matrix/client/v3/rooms/{room_id}/send/m.reaction/{txn_id}",
        headers={"Authorization": f"Bearer {token}"},
        json={"m.relates_to": {"rel_type": "m.annotation", "event_id": event_id, "key": key}},
        timeout=30,
    ).raise_for_status()


def process_event(cfg: dict, token: str, event: dict) -> None:
    content = event.get("content", {})
    if content.get("msgtype") != "m.file":
        return
    body = content.get("body", "")
    if not body.lower().endswith(".wastickers"):
        return

    event_id = event["event_id"]
    hs = cfg["homeserver_url"].rstrip("/")
    room_id = cfg["stickers_room_id"]
    mxc = content.get("url", "")
    if not mxc.startswith("mxc://"):
        LOG.warning("Event %s has no mxc URL — skipping", event_id)
        return

    LOG.info("Processing upload: %s (%s)", body, event_id)

    try:
        resp = httpx.get(
            _mxc_to_download_url(hs, mxc),
            headers={"Authorization": f"Bearer {token}"},
            timeout=120,
            follow_redirects=True,
        )
        resp.raise_for_status()

        with tempfile.NamedTemporaryFile(suffix=".wastickers", delete=False) as tmp:
            tmp.write(resp.content)
            tmp_path = Path(tmp.name)

        result = import_pack(cfg, token, tmp_path)
        tmp_path.unlink(missing_ok=True)

        _react(hs, token, room_id, event_id, "✅")
        if result is not None:
            pack_id, pack_title, n = result
            _send_message(hs, token, room_id,
                          f"Imported '{pack_title}' ({n} stickers) — pack id {pack_id}")
        else:
            _send_message(hs, token, room_id, f"Imported {body}")

    except Exception as exc:
        LOG.exception("Failed to import %s", body)
        try:
            _react(hs, token, room_id, event_id, "❌")
            _send_message(hs, token, room_id, f"Import failed: {exc}")
        except Exception:
            pass


def run() -> None:
    cfg = load_config()
    hs = cfg["homeserver_url"].rstrip("/")
    room_id = cfg["stickers_room_id"]
    token = get_access_token(cfg)

    domain = hs.split("//")[-1]
    stickers_user_id = f"@{cfg['stickers_user']}:{domain}"

    LOG.info("Logged in as %s", stickers_user_id)
    LOG.info("Watching room %s", room_id)

    seen = _load_seen()

    since = None
    if SYNC_TOKEN_FILE.exists():
        since = SYNC_TOKEN_FILE.read_text().strip() or None

    if since is None:
        LOG.info("First run — getting initial sync position (skipping upload backlog)...")
        resp = httpx.get(
            f"{hs}/_matrix/client/v3/sync",
            params={"filter": json.dumps({"room": {"timeline": {"limit": 1}}}), "timeout": 0},
            headers={"Authorization": f"Bearer {token}"},
            timeout=30,
        )
        resp.raise_for_status()
        since = resp.json().get("next_batch")
        if since:
            SYNC_TOKEN_FILE.write_text(since)
            LOG.info("Initial sync token saved — listening for new uploads only.")

    retry_delay = 5
    while True:
        try:
            params: dict = {"timeout": 30000}
            if since:
                params["since"] = since

            resp = httpx.get(
                f"{hs}/_matrix/client/v3/sync",
                params=params,
                headers={"Authorization": f"Bearer {token}"},
                timeout=60,
            )
            resp.raise_for_status()
            data = resp.json()
            retry_delay = 5

            since = data.get("next_batch", since)
            if since:
                SYNC_TOKEN_FILE.write_text(since)

            rooms_join = data.get("rooms", {}).get("join", {})
            room_data = rooms_join.get(room_id, {})
            events = room_data.get("timeline", {}).get("events", [])

            for event in events:
                if event.get("type") != "m.room.message":
                    continue
                if event.get("sender") == stickers_user_id:
                    continue
                event_id = event.get("event_id", "")
                if event_id in seen:
                    continue
                seen.add(event_id)
                try:
                    process_event(cfg, token, event)
                except Exception:
                    LOG.exception("Unhandled error processing event %s", event_id)

            _save_seen(seen)

        except httpx.HTTPStatusError as exc:
            if exc.response.status_code == 401:
                LOG.error("Token rejected — refreshing login")
                Path("/app/data/access_token.txt").unlink(missing_ok=True)
                token = get_access_token(cfg)
            else:
                LOG.warning("HTTP %s from /sync — retrying in %ds", exc.response.status_code, retry_delay)
                time.sleep(retry_delay)
                retry_delay = min(retry_delay * 2, 60)
        except Exception as exc:
            LOG.warning("Sync error: %s — retrying in %ds", exc, retry_delay)
            time.sleep(retry_delay)
            retry_delay = min(retry_delay * 2, 60)


if __name__ == "__main__":
    run()
