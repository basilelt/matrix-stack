#!/usr/bin/env python3
"""matrix-sticker-bot (E2EE) — watches stickers room for .wastickers uploads, auto-imports."""
import asyncio
import base64
import importlib.util
import json
import logging
import secrets
import tempfile
from pathlib import Path
from typing import Optional

import httpx
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from nio import (
    AsyncClient, AsyncClientConfig, LoginResponse,
    RoomMessageFile, RoomEncryptedFile, MegolmEvent, DownloadError,
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


def _b64(b: bytes) -> str:
    return base64.b64encode(b).decode().rstrip("=")


def _canonical_json(obj: dict) -> bytes:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()


def _sign_key(key: Ed25519PrivateKey, obj: dict) -> str:
    stripped = {k: v for k, v in obj.items() if k not in ("signatures", "unsigned")}
    return _b64(key.sign(_canonical_json(stripped)))


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
            display_name = Path(body).stem
            result = await asyncio.get_event_loop().run_in_executor(
                None, import_pack, self.cfg, token, tmp_path, display_name
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

    async def _setup_cross_signing(self) -> None:
        try:
            keys_file = STORE_DIR / "cross_signing_keys.json"
            if keys_file.exists():
                saved = json.loads(keys_file.read_text())
                msk_seed = bytes.fromhex(saved["msk"])
                ssk_seed = bytes.fromhex(saved["ssk"])
            else:
                msk_seed = secrets.token_bytes(32)
                ssk_seed = secrets.token_bytes(32)
                keys_file.write_text(json.dumps({"msk": msk_seed.hex(), "ssk": ssk_seed.hex()}))
                LOG.info("Generated new cross-signing seeds")

            msk = Ed25519PrivateKey.from_private_bytes(msk_seed)
            ssk = Ed25519PrivateKey.from_private_bytes(ssk_seed)
            raw, enc = PublicFormat.Raw, Encoding.Raw
            msk_pub = _b64(msk.public_key().public_bytes(enc, raw))
            ssk_pub = _b64(ssk.public_key().public_bytes(enc, raw))
            msk_key_id = f"ed25519:{msk_pub}"
            ssk_key_id = f"ed25519:{ssk_pub}"
            user_id = self.client.user_id
            device_id = self.client.device_id
            hdrs = {"Authorization": f"Bearer {self.client.access_token}"}

            async with httpx.AsyncClient() as http:
                r = await http.post(f"{self.hs}/_matrix/client/v3/keys/query",
                                    json={"device_keys": {user_id: []}}, headers=hdrs)
                keys_resp = r.json()

                server_msk = keys_resp.get("master_keys", {}).get(user_id, {}).get("keys", {})
                if msk_pub not in server_msk.values():
                    LOG.info("Uploading cross-signing keys")
                    msk_obj = {"keys": {msk_key_id: msk_pub}, "usage": ["master"], "user_id": user_id}
                    msk_obj["signatures"] = {user_id: {msk_key_id: _sign_key(msk, msk_obj)}}
                    ssk_obj = {"keys": {ssk_key_id: ssk_pub}, "usage": ["self_signing"], "user_id": user_id}
                    ssk_obj["signatures"] = {user_id: {msk_key_id: _sign_key(msk, ssk_obj)}}
                    payload = {"master_key": msk_obj, "self_signing_key": ssk_obj}
                    upload_url = f"{self.hs}/_matrix/client/v3/keys/device_signing/upload"

                    r = await http.post(upload_url, json=payload, headers=hdrs)
                    if r.status_code == 401:
                        uiaa = r.json()
                        auth_payload = {**payload, "auth": {
                            "type": "m.login.password",
                            "identifier": {"type": "m.id.user", "user": self.cfg["stickers_user"]},
                            "password": self.cfg["stickers_password"],
                            "session": uiaa.get("session", ""),
                        }}
                        r = await http.post(upload_url, json=auth_payload, headers=hdrs)
                        if r.status_code != 200:
                            LOG.error("Cross-signing upload failed %d: %s", r.status_code, r.text)
                            return
                    elif r.status_code != 200:
                        LOG.error("Cross-signing upload failed %d: %s", r.status_code, r.text)
                        return
                    LOG.info("Cross-signing keys uploaded")

                    r = await http.post(f"{self.hs}/_matrix/client/v3/keys/query",
                                        json={"device_keys": {user_id: []}}, headers=hdrs)
                    keys_resp = r.json()

                device_key = keys_resp.get("device_keys", {}).get(user_id, {}).get(device_id)
                if not device_key:
                    LOG.warning("Own device key not found — skipping device signing")
                    return
                if ssk_key_id in device_key.get("signatures", {}).get(user_id, {}):
                    LOG.info("Device already signed by SSK")
                    return

                LOG.info("Signing device %s with SSK", device_id)
                sigs = {k: dict(v) for k, v in device_key.get("signatures", {}).items()}
                sigs.setdefault(user_id, {})[ssk_key_id] = _sign_key(ssk, device_key)
                signed_device = {**device_key, "signatures": sigs}
                r = await http.post(f"{self.hs}/_matrix/client/v3/keys/signatures/upload",
                                    json={user_id: {device_id: signed_device}}, headers=hdrs)
                if r.status_code != 200:
                    LOG.error("signatures/upload failed %d: %s", r.status_code, r.text)
                    return
                LOG.info("Device %s signed by SSK — cross-signing complete", device_id)

        except Exception:
            LOG.exception("Cross-signing setup failed — continuing without it")

    async def _catchup_initial_timeline(self, sync_resp) -> None:
        """Process file events from the initial sync timeline (handles offline period)."""
        try:
            room_data = sync_resp.rooms.join.get(self.room_id)
            if not room_data:
                return
            for event in room_data.timeline.events:
                if isinstance(event, (RoomMessageFile, RoomEncryptedFile)):
                    content = event.source.get("content", {})
                    file_info = content.get("file")
                    mxc = file_info["url"] if file_info else event.url
                    asyncio.create_task(self._process(event.event_id, event.body, mxc, file_info))
                elif isinstance(event, MegolmEvent):
                    LOG.warning("Undecryptable event %s in catchup — re-send the file to import it", event.event_id)
        except Exception as exc:
            LOG.warning("Could not process initial timeline: %s", exc)

    async def start(self) -> None:
        await self._login()
        # Initial sync to populate room state, then trust devices
        sync_resp = await self.client.sync(timeout=10_000, full_state=True)
        self._trust_room_devices()
        await self._setup_cross_signing()
        await self._catchup_initial_timeline(sync_resp)

        self.client.add_event_callback(self._on_file, RoomMessageFile)
        self.client.add_event_callback(self._on_file, RoomEncryptedFile)
        self.client.add_event_callback(self._on_megolm, MegolmEvent)

        LOG.info("Watching room %s (E2EE)", self.room_id)
        await self.client.sync_forever(timeout=30_000, full_state=True)


async def main() -> None:
    cfg = load_config()
    bot = StickerBot(cfg)
    await bot.start()


if __name__ == "__main__":
    asyncio.run(main())
