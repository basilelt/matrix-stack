#!/usr/bin/env python3
"""
Matrix Translate + Transcribe Bot

React with a flag emoji on any text message to translate it.
React with 🎙️ on any audio/voice message to transcribe it via Whisper.

For messages sent before the bot joined: the bot requests the Megolm session
key from the bridge and automatically retries for up to 120s (8×15s). No need
to react again — the bot will process the message once the key arrives.
"""
import asyncio
import base64
import json
import logging
import os
import secrets
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from collections import OrderedDict, defaultdict
from pathlib import Path
from typing import Optional

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

import httpx
from nio import (
    AsyncClient,
    AsyncClientConfig,
    DownloadError,
    Event,
    InviteMemberEvent,
    LoginResponse,
    MatrixRoom,
    MegolmEvent,
    ReactionEvent,
    RoomEncryptedAudio,
    RoomEncryptedVideo,
    RoomGetEventError,
    RoomMessageAudio,
    RoomMessageText,
    RoomMessageVideo,
)
from nio.exceptions import OlmUnverifiedDeviceError

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
)
log = logging.getLogger("translate-bot")
log.setLevel(logging.DEBUG)

FLAG_TO_LANG: dict[str, str] = {
    "🇫🇷": "fr",
    "🇬🇧": "en", "🇺🇸": "en",
    "🇪🇸": "es", "🇦🇷": "es",
    "🇩🇪": "de",
    "🇵🇹": "pt", "🇧🇷": "pt",
    "🇮🇹": "it",
    "🇯🇵": "ja",
    "🇨🇳": "zh",
    "🇷🇺": "ru",
    "🇸🇦": "ar",
    "🇳🇱": "nl",
    "🇹🇷": "tr",
    "🇰🇷": "ko",
    "🇵🇱": "pl",
    "🇺🇦": "uk",
    "🇸🇪": "sv",
}
STT_EMOJIS = {"🎙️", "🎙", "🎤", "🎤️"}  # studio mic + plain mic, with/without variation selector
MAX_CACHED_EVENTS_PER_ROOM = 500
MAX_DONE = 1000  # max completed-operation dedup entries


def _b64(b: bytes) -> str:
    return base64.b64encode(b).decode().rstrip("=")


def _canonical_json(obj: dict) -> bytes:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")


def _sign_key(key: Ed25519PrivateKey, obj: dict) -> str:
    stripped = {k: v for k, v in obj.items() if k not in ("signatures", "unsigned")}
    return _b64(key.sign(_canonical_json(stripped)))
KEY_WAIT_SECONDS = 10  # max wait for key to arrive after request


def load_config() -> dict:
    path = os.environ.get("CONFIG_PATH", "/app/config.json")
    with open(path) as f:
        return json.load(f)


async def call_libretranslate(
    text: str, target: str, lt_url: str, source: str = "auto"
) -> Optional[str]:
    try:
        async with httpx.AsyncClient(timeout=30) as c:
            r = await c.post(
                f"{lt_url}/translate",
                json={"q": text, "source": source, "target": target, "format": "text"},
            )
            r.raise_for_status()
            return r.json().get("translatedText")
    except Exception as e:
        log.warning(f"LibreTranslate error: {e}")
        return None


def _run_whisper(audio_path: str, model_name: str, models_dir: str) -> Optional[str]:
    from faster_whisper import WhisperModel
    model = WhisperModel(
        model_name, device="cpu", compute_type="int8", download_root=models_dir
    )
    segments, _ = model.transcribe(audio_path, beam_size=5)
    return " ".join(s.text for s in segments).strip() or None


def _as_megolm(event) -> Optional["MegolmEvent"]:
    """Coerce RoomEncrypted* variants to MegolmEvent so nio crypto ops work."""
    if isinstance(event, MegolmEvent):
        return event
    if hasattr(event, "source"):
        try:
            me = MegolmEvent.from_dict(event.source)
            if isinstance(me, MegolmEvent):
                return me
        except Exception as e:
            log.debug(f"_as_megolm re-parse failed: {e}")
    return None


def _try_decrypt(client: AsyncClient, event: MegolmEvent, room_id: str):
    """Attempt to decrypt a MegolmEvent using stored sessions. Returns event or None."""
    session_id = getattr(event, "session_id", "?")
    sender_key = getattr(event, "sender_key", "?")
    log.debug(f"_try_decrypt: session_id={session_id} sender_key={sender_key[:16] if sender_key != '?' else '?'}…")

    if hasattr(client, "decrypt_event"):
        try:
            decrypted = client.decrypt_event(event)
            if decrypted is not None:
                log.debug(f"_try_decrypt: client.decrypt_event succeeded → {type(decrypted).__name__}")
                return decrypted
        except Exception as e:
            log.debug(f"_try_decrypt: client.decrypt_event failed: {e}")

    if hasattr(client, "olm") and client.olm:
        try:
            decrypted, _ = client.olm.decrypt_event(event)
            log.debug(f"_try_decrypt: olm.decrypt_event succeeded → {type(decrypted).__name__}")
            return decrypted
        except Exception as e:
            log.debug(f"_try_decrypt: olm.decrypt_event failed: {e}")

    log.debug(f"_try_decrypt: all methods failed for session {session_id}")
    return None


class TranslateBot:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.lt_url: str = cfg.get("libretranslate_url", "http://libretranslate:5000")
        self.whisper_model: str = cfg.get("whisper_model", "base")
        self.models_dir: str = cfg.get("models_dir", "/app/models")

        store_path = cfg.get("store_path", "/app/store")
        Path(store_path).mkdir(parents=True, exist_ok=True)
        Path(self.models_dir).mkdir(parents=True, exist_ok=True)

        self.client = AsyncClient(
            cfg["homeserver"],
            cfg["user_id"],
            device_id=cfg.get("device_id", "TRANSLATEBOT01"),
            store_path=store_path,
            config=AsyncClientConfig(
                encryption_enabled=True,
                store_sync_tokens=True,
                max_limit_exceeded=0,
                max_timeouts=0,
            ),
        )

        # {room_id: {event_id: {"body": str, "msgtype": str, "mxc": str|None}}}
        self._cache: dict[str, dict] = defaultdict(dict)
        # {room_id: {event_id: MegolmEvent}} — awaiting key
        self._pending: dict[str, dict] = defaultdict(dict)
        # (room_id, target_id) currently being retried in background
        self._processing: set = set()
        # completed operations: ("stt"|"tr", room_id, target_id[, lang]) → True
        # prevents bridge-echo duplicates where the same logical reaction arrives
        # as two distinct events (e.g. Element native + WA puppet echo)
        self._done: OrderedDict = OrderedDict()

    def _cache_put(self, room_id, event_id, body, msgtype, mxc=None, file=None):
        room_cache = self._cache[room_id]
        room_cache[event_id] = {"body": body, "msgtype": msgtype, "mxc": mxc, "file": file}
        if len(room_cache) > MAX_CACHED_EVENTS_PER_ROOM:
            del room_cache[next(iter(room_cache))]

    @staticmethod
    def _extract_media_url(event) -> tuple[Optional[str], Optional[dict]]:
        """Return (plain_mxc, file_info) from an audio/video event."""
        content = event.source.get("content", {}) if hasattr(event, "source") else {}
        plain_url = getattr(event, "url", None) or content.get("url")
        file_info = content.get("file")  # present only for encrypted media
        if file_info:
            return file_info.get("url"), file_info
        return plain_url, None

    async def start(self):
        resp = await self.client.login(
            password=self.cfg["password"],
            device_name="translate-bot",
        )
        if not isinstance(resp, LoginResponse):
            log.error(f"Login failed: {resp}")
            return
        log.info(f"Logged in as {self.cfg['user_id']}")

        if self.client.should_upload_keys:
            await self.client.keys_upload()

        await self._setup_cross_signing()

        # Trust all devices in already-joined rooms
        if self.client.should_query_keys:
            await self.client.keys_query()
        for room_id in self.client.rooms:
            self._trust_room_devices(room_id)

        self.client.add_event_callback(self._on_invite, InviteMemberEvent)
        self.client.add_event_callback(self._on_text, RoomMessageText)
        self.client.add_event_callback(self._on_audio, RoomMessageAudio)
        self.client.add_event_callback(self._on_audio, RoomEncryptedAudio)
        self.client.add_event_callback(self._on_video, RoomMessageVideo)
        self.client.add_event_callback(self._on_video, RoomEncryptedVideo)
        self.client.add_event_callback(self._on_megolm, MegolmEvent)
        self.client.add_event_callback(self._on_reaction, ReactionEvent)

        log.info("Sync loop started.")
        if self.cfg.get("admin_user") and self.cfg.get("bridge_bots"):
            asyncio.create_task(self._room_scan_loop())
        await self.client.sync_forever(timeout=30_000, full_state=True)

    async def _setup_cross_signing(self):
        try:
            store_path = Path(self.cfg.get("store_path", "/app/store"))
            keys_file = store_path / "cross_signing_keys.json"

            if keys_file.exists():
                saved = json.loads(keys_file.read_text())
                msk_seed = bytes.fromhex(saved["msk"])
                ssk_seed = bytes.fromhex(saved["ssk"])
            else:
                msk_seed = secrets.token_bytes(32)
                ssk_seed = secrets.token_bytes(32)
                keys_file.write_text(json.dumps({"msk": msk_seed.hex(), "ssk": ssk_seed.hex()}))
                log.info("Generated new cross-signing seeds")

            msk = Ed25519PrivateKey.from_private_bytes(msk_seed)
            ssk = Ed25519PrivateKey.from_private_bytes(ssk_seed)
            raw = PublicFormat.Raw
            enc = Encoding.Raw
            msk_pub = _b64(msk.public_key().public_bytes(enc, raw))
            ssk_pub = _b64(ssk.public_key().public_bytes(enc, raw))
            msk_key_id = f"ed25519:{msk_pub}"
            ssk_key_id = f"ed25519:{ssk_pub}"
            user_id = self.cfg["user_id"]
            device_id = self.client.device_id
            hs = self.cfg["homeserver"]
            hdrs = {"Authorization": f"Bearer {self.client.access_token}"}

            async with httpx.AsyncClient() as http:
                r = await http.post(f"{hs}/_matrix/client/v3/keys/query",
                                    json={"device_keys": {user_id: []}}, headers=hdrs)
                keys_resp = r.json()

                server_msk = keys_resp.get("master_keys", {}).get(user_id, {}).get("keys", {})
                if msk_pub not in server_msk.values():
                    log.info("Uploading cross-signing keys")
                    msk_obj = {"keys": {msk_key_id: msk_pub}, "usage": ["master"], "user_id": user_id}
                    msk_obj["signatures"] = {user_id: {msk_key_id: _sign_key(msk, msk_obj)}}
                    ssk_obj = {"keys": {ssk_key_id: ssk_pub}, "usage": ["self_signing"], "user_id": user_id}
                    ssk_obj["signatures"] = {user_id: {msk_key_id: _sign_key(msk, ssk_obj)}}
                    payload = {"master_key": msk_obj, "self_signing_key": ssk_obj}
                    upload_url = f"{hs}/_matrix/client/v3/keys/device_signing/upload"

                    r = await http.post(upload_url, json=payload, headers=hdrs)
                    if r.status_code == 401:
                        uiaa = r.json()
                        auth_payload = {**payload, "auth": {
                            "type": "m.login.password",
                            "identifier": {"type": "m.id.user", "user": user_id},
                            "password": self.cfg["password"],
                            "session": uiaa.get("session", ""),
                        }}
                        r = await http.post(upload_url, json=auth_payload, headers=hdrs)
                        if r.status_code != 200:
                            log.error("Cross-signing upload failed %d: %s", r.status_code, r.text)
                            return
                    elif r.status_code != 200:
                        log.error("Cross-signing upload failed %d: %s", r.status_code, r.text)
                        return
                    log.info("Cross-signing keys uploaded")

                    r = await http.post(f"{hs}/_matrix/client/v3/keys/query",
                                        json={"device_keys": {user_id: []}}, headers=hdrs)
                    keys_resp = r.json()

                device_key = keys_resp.get("device_keys", {}).get(user_id, {}).get(device_id)
                if not device_key:
                    log.warning("Own device key not found — skipping device signing")
                    return

                if ssk_key_id in device_key.get("signatures", {}).get(user_id, {}):
                    log.info("Device already signed by SSK")
                    return

                log.info("Signing device %s with SSK", device_id)
                device_sig = _sign_key(ssk, device_key)
                signed_device = dict(device_key)
                sigs = {k: dict(v) for k, v in signed_device.get("signatures", {}).items()}
                sigs.setdefault(user_id, {})[ssk_key_id] = device_sig
                signed_device["signatures"] = sigs

                r = await http.post(f"{hs}/_matrix/client/v3/keys/signatures/upload",
                                    json={user_id: {device_id: signed_device}}, headers=hdrs)
                if r.status_code != 200:
                    log.error("signatures/upload failed %d: %s", r.status_code, r.text)
                    return
                log.info("Device %s signed by SSK — cross-signing complete", device_id)

        except Exception:
            log.exception("Cross-signing setup failed — continuing without it")

    def _admin_api(self, method: str, path: str, body=None, token: str = None) -> dict:
        url = self.cfg["homeserver"] + path
        data = json.dumps(body).encode() if body else None
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            return json.loads(e.read())
        except Exception as e:
            return {"error": str(e)}

    async def _room_scan_loop(self):
        """Periodically find bridge rooms the bot isn't in and self-invite."""
        interval = self.cfg.get("room_scan_interval", 300)
        bridge_bots = set(self.cfg.get("bridge_bots", []))
        bot_id = self.cfg["user_id"]

        while True:
            try:
                await asyncio.sleep(5)
                loop = asyncio.get_event_loop()
                await loop.run_in_executor(None, self._scan_and_invite, bridge_bots, bot_id)
            except Exception as e:
                log.exception(f"_room_scan_loop error: {e}")
            await asyncio.sleep(interval)

    def _scan_and_invite(self, bridge_bots: set, bot_id: str):
        # Get admin token
        resp = self._admin_api("POST", "/_matrix/client/v3/login", {
            "type": "m.login.password",
            "identifier": {"type": "m.id.user", "user": self.cfg["admin_user"]},
            "password": self.cfg["admin_password"],
        })
        admin_token = resp.get("access_token")
        if not admin_token:
            log.warning(f"Room scan: admin login failed: {resp.get('error')}")
            return



        # Paginate all rooms
        rooms = []
        from_tok = None
        while True:
            path = "/_synapse/admin/v1/rooms?limit=100"
            if from_tok:
                path += f"&from={from_tok}"
            r = self._admin_api("GET", path, token=admin_token)
            rooms.extend(r.get("rooms", []))
            from_tok = r.get("next_batch")
            if not from_tok:
                break

        invited = 0
        for room in rooms:
            rid = room["room_id"]
            enc_rid = urllib.parse.quote(rid, safe="")
            members = self._admin_api("GET", f"/_synapse/admin/v1/rooms/{enc_rid}/members", token=admin_token)
            member_ids = set(members.get("members", []))
            if not bridge_bots.intersection(member_ids):
                continue
            if bot_id in member_ids:
                continue
            import time
            bridge_tokens = self.cfg.get("bridge_tokens", {})
            present_bots = bridge_bots.intersection(member_ids)
            # Find a bridge bot token we can use to invite
            invite_token = None
            invite_as_bot = None
            for b in present_bots:
                if b in bridge_tokens:
                    invite_token = bridge_tokens[b]
                    invite_as_bot = b
                    break
            if not invite_token:
                # No bridge bot token — use Synapse admin force-join to avoid
                # M_FORBIDDEN when admin user is not a room member
                for attempt in range(5):
                    r = self._admin_api(
                        "POST",
                        f"/_synapse/admin/v1/join/{enc_rid}",
                        {"user_id": bot_id},
                        token=admin_token,
                    )
                    if r.get("errcode") == "M_LIMIT_EXCEEDED":
                        time.sleep(r.get("retry_after_ms", 3000) / 1000.0 + 0.5)
                        continue
                    break
                if not r.get("errcode"):
                    log.info(f"Room scan: force-joined {room.get('name', rid)}")
                    invited += 1
                else:
                    log.debug(f"Room scan: join error {room.get('name', rid)}: {r.get('errcode')}: {r.get('error')}")
                time.sleep(0.5)
                continue
            # Bridge bot token available — use regular invite
            invite_url = f"/_matrix/client/v3/rooms/{enc_rid}/invite"
            enc_bot = urllib.parse.quote(invite_as_bot, safe="")
            invite_url += f"?user_id={enc_bot}"
            for attempt in range(5):
                r = self._admin_api("POST", invite_url, {"user_id": bot_id}, token=invite_token)
                if r.get("errcode") == "M_LIMIT_EXCEEDED":
                    time.sleep(r.get("retry_after_ms", 3000) / 1000.0 + 0.5)
                    continue
                break
            if not r.get("errcode"):
                log.info(f"Room scan: joined {room.get('name', rid)}")
                invited += 1
            else:
                log.debug(f"Room scan: invite error {room.get('name', rid)}: {r.get('errcode')}: {r.get('error')}, trying admin force-join")
                for attempt in range(5):
                    r2 = self._admin_api(
                        "POST",
                        f"/_synapse/admin/v1/join/{enc_rid}",
                        {"user_id": bot_id},
                        token=admin_token,
                    )
                    if r2.get("errcode") == "M_LIMIT_EXCEEDED":
                        time.sleep(r2.get("retry_after_ms", 3000) / 1000.0 + 0.5)
                        continue
                    break
                if not r2.get("errcode"):
                    log.info(f"Room scan: force-joined {room.get('name', rid)} (bridge invite failed)")
                    invited += 1
                else:
                    log.debug(f"Room scan: join error {room.get('name', rid)}: {r2.get('errcode')}: {r2.get('error')}")
            time.sleep(0.5)

        if invited:
            log.info(f"Room scan: invited bot to {invited} new room(s)")
        else:
            log.debug("Room scan: no new rooms found")

    async def _on_invite(self, room: MatrixRoom, event: InviteMemberEvent):
        if event.state_key == self.cfg["user_id"]:
            await self.client.join(room.room_id)
            log.info(f"Joined {room.room_id}")
            if self.client.should_query_keys:
                await self.client.keys_query()
            self._trust_room_devices(room.room_id)

    async def _on_text(self, room: MatrixRoom, event: RoomMessageText):
        if event.sender == self.cfg["user_id"]:
            return
        self._cache_put(room.room_id, event.event_id, event.body, "m.text")
        # Resolve any pending reaction that was waiting for this event
        self._pending[room.room_id].pop(event.event_id, None)

    async def _on_audio(self, room: MatrixRoom, event: RoomMessageAudio):
        if event.sender == self.cfg["user_id"]:
            return
        mxc, file_info = self._extract_media_url(event)
        self._cache_put(room.room_id, event.event_id,
                        event.body or "voice message", "m.audio", mxc, file_info)
        self._pending[room.room_id].pop(event.event_id, None)

    async def _on_video(self, room: MatrixRoom, event: RoomMessageVideo):
        if event.sender == self.cfg["user_id"]:
            return
        mxc, file_info = self._extract_media_url(event)
        self._cache_put(room.room_id, event.event_id,
                        event.body or "video message", "m.audio", mxc, file_info)
        self._pending[room.room_id].pop(event.event_id, None)

    async def _request_key_targeted(self, room: MatrixRoom, event: MegolmEvent):
        """Send m.room_key_request to the real device that encrypted the message.

        nio's request_room_key() sends to self.user_id (the bot), which is wrong
        for bridged rooms: the ghost user @whatsapp_XXX has no E2EE devices.
        The actual Megolm session belongs to the bridge bot device (e.g. @whatsappbot/SAFPLMUFGL).
        We find that device by matching event.sender_key (curve25519) against the device store.
        """
        sender_key = getattr(event, "sender_key", None)
        target_user = None
        target_device_id = None

        if sender_key:
            for user_id in list(room.users.keys()):
                try:
                    for device in self.client.device_store.active_user_devices(user_id):
                        if device.keys.get("curve25519") == sender_key:
                            target_user = user_id
                            target_device_id = device.device_id
                            break
                except Exception:
                    continue
                if target_user:
                    break

        if target_user and target_user != event.sender:
            log.info(
                f"Key request → {target_user}/{target_device_id} "
                f"(real owner of sender_key {sender_key[:16] if sender_key else '?'}…)"
            )
            try:
                msg = event.as_key_request(
                    user_id=target_user,
                    requesting_device_id=self.client.device_id,
                    device_id=target_device_id,
                )
                await self.client.to_device(msg)
                return
            except Exception as e:
                log.debug(f"Targeted key request failed: {e}")

        # Fallback: standard nio request (goes to self.user_id — rarely works for bridges)
        try:
            await self.client.request_room_key(event)
        except Exception as e:
            log.debug(f"Standard key request failed: {e}")

    async def _on_megolm(self, room: MatrixRoom, event: MegolmEvent):
        """Undecryptable event — try decrypt, then request the session key."""
        if event.sender == self.cfg["user_id"]:
            return
        # Try immediate decrypt (key may already be in store)
        decrypted = _try_decrypt(self.client, event, room.room_id)
        if decrypted is not None:
            self._cache_from_decrypted(room.room_id, event.event_id, decrypted)
            return
        # Store raw event for potential retry
        self._pending[room.room_id][event.event_id] = (room, event)
        await self._request_key_targeted(room, event)
        log.info(f"Key requested for session {event.session_id} in {room.room_id}")

    async def _on_reaction(self, room: MatrixRoom, event: ReactionEvent):
        try:
            await self._handle_reaction(room, event)
        except Exception as e:
            log.exception(f"Unhandled error in _on_reaction: {e}")

    async def _handle_reaction(self, room: MatrixRoom, event: ReactionEvent):
        log.info(f"_on_reaction called: sender={event.sender} type={type(event).__name__}")
        if event.sender == self.cfg["user_id"]:
            return

        # nio 0.25+ exposes these directly on ReactionEvent
        try:
            emoji: str = event.key or ""
            target_id: str = event.reacts_to or ""
        except AttributeError:
            # fallback for unexpected event shape
            try:
                relates_to = event.source.get("content", {}).get("m.relates_to", {})
                emoji = relates_to.get("key", "")
                target_id = relates_to.get("event_id", "")
            except Exception as e:
                log.warning(f"Could not parse reaction content: {e} | source={getattr(event, 'source', None)}")
                return

        if not emoji or not target_id:
            log.debug(f"Empty emoji or target_id: {emoji!r} {target_id!r}")
            return

        is_flag = emoji in FLAG_TO_LANG
        is_stt = emoji in STT_EMOJIS
        log.info(f"Reaction from {event.sender}: {emoji!r} → target {target_id} | flag={is_flag} stt={is_stt}")
        if not is_flag and not is_stt:
            return

        # Redact the trigger reaction so it doesn't get bridged to WhatsApp/Signal
        try:
            await self.client.room_redact(room.room_id, event.event_id, reason="bot trigger")
        except Exception as e:
            log.debug(f"Could not redact trigger reaction: {e}")

        # Try cache first
        cached = self._cache.get(room.room_id, {}).get(target_id)

        # Not in cache — fetch the event and try to decrypt it
        if cached is None:
            cached = await self._fetch_and_cache(room, target_id)

        if cached is None:
            proc_key = (room.room_id, target_id)
            if proc_key in self._processing:
                await self._reply(room.room_id, target_id, "⏳ Already fetching key, please wait…")
                return
            self._processing.add(proc_key)
            asyncio.create_task(
                self._retry_after_key(room, target_id, is_stt, FLAG_TO_LANG.get(emoji), target_id)
            )
            await self._reply(room.room_id, target_id, "⏳ Fetching decryption key from bridge, processing automatically…")
            return

        if is_stt:
            await self._do_stt(room.room_id, target_id, cached)
        else:
            await self._do_translate(room.room_id, target_id, cached, FLAG_TO_LANG[emoji])

    async def _fetch_and_cache(self, room: MatrixRoom, event_id: str) -> Optional[dict]:
        """Fetch an event from the server, decrypt if needed, cache and return it."""
        resp = await self.client.room_get_event(room.room_id, event_id)
        if isinstance(resp, RoomGetEventError):
            log.warning(f"Could not fetch event {event_id}: {resp}")
            return None

        ev = resp.event

        if isinstance(ev, (RoomMessageAudio, RoomEncryptedAudio)):
            mxc, file_info = self._extract_media_url(ev)
            entry = {"body": ev.body or "voice message", "msgtype": "m.audio",
                     "mxc": mxc, "file": file_info}
            self._cache_put(room.room_id, event_id, **entry)
            return entry

        if isinstance(ev, (RoomMessageVideo, RoomEncryptedVideo)):
            mxc, file_info = self._extract_media_url(ev)
            entry = {"body": ev.body or "video message", "msgtype": "m.audio",
                     "mxc": mxc, "file": file_info}
            self._cache_put(room.room_id, event_id, **entry)
            return entry

        if isinstance(ev, RoomMessageText):
            entry = {"body": ev.body, "msgtype": "m.text", "mxc": None, "file": None}
            self._cache_put(room.room_id, event_id, **entry)
            return entry

        # Handle any encrypted event type — MegolmEvent OR RoomEncrypted* variants
        # (nio 0.25 returns RoomEncryptedAudio/Video etc. from room_get_event)
        if isinstance(ev, MegolmEvent) or hasattr(ev, "session_id"):
            log.info(f"_fetch_and_cache: encrypted {type(ev).__name__} session_id={getattr(ev, 'session_id', '?')}")
            megolm_ev = _as_megolm(ev)
            if megolm_ev is not None:
                decrypted = _try_decrypt(self.client, megolm_ev, room.room_id)
                if decrypted is not None:
                    return self._cache_from_decrypted(room.room_id, event_id, decrypted)
                await self._request_key_targeted(room, megolm_ev)
                log.info(f"Key requested for {event_id} in {room.room_id}")

        return None

    async def _retry_after_key(
        self, room: MatrixRoom, target_id: str, is_stt: bool, lang: Optional[str], reply_to: str
    ):
        """Background task: wait for sync cycles to deliver the key, then process."""
        proc_key = (room.room_id, target_id)
        log.info(f"_retry_after_key started for {target_id} stt={is_stt}")
        try:
            for attempt in range(8):
                await asyncio.sleep(15)  # let sync run; key should arrive within 1-4 cycles (up to 120s)
                log.info(f"_retry_after_key attempt {attempt+1} for {target_id}")
                cached = self._cache.get(room.room_id, {}).get(target_id)
                if cached is None:
                    resp = await self.client.room_get_event(room.room_id, target_id)
                    if not isinstance(resp, RoomGetEventError):
                        ev = resp.event
                        log.info(f"_retry attempt {attempt+1}: got {type(ev).__name__} session_id={getattr(ev, 'session_id', '?')} for {target_id}")
                        if isinstance(ev, MegolmEvent) or hasattr(ev, "session_id"):
                            megolm_ev = _as_megolm(ev)
                            if megolm_ev is not None:
                                decrypted = _try_decrypt(self.client, megolm_ev, room.room_id)
                                if decrypted:
                                    cached = self._cache_from_decrypted(room.room_id, target_id, decrypted)
                                else:
                                    await self._request_key_targeted(room, megolm_ev)
                        else:
                            cached = await self._fetch_and_cache(room, target_id)
                if cached is not None:
                    log.info(f"Key received after {(attempt+1)*15}s for {target_id}")
                    if is_stt:
                        await self._do_stt(room.room_id, reply_to, cached)
                    else:
                        await self._do_translate(room.room_id, reply_to, cached, lang)
                    return
            await self._reply(room.room_id, reply_to, "❌ Bridge did not share decryption key after 120s.")
        except Exception as e:
            log.exception(f"_retry_after_key failed: {e}")
        finally:
            self._processing.discard(proc_key)

    def _cache_from_decrypted(self, room_id: str, event_id: str, decrypted) -> Optional[dict]:
        if isinstance(decrypted, (RoomMessageAudio, RoomMessageVideo)):
            mxc, file_info = self._extract_media_url(decrypted)
            entry = {"body": decrypted.body or "media", "msgtype": "m.audio",
                     "mxc": mxc, "file": file_info}
            self._cache_put(room_id, event_id, **entry)
            return entry
        if isinstance(decrypted, RoomMessageText):
            entry = {"body": decrypted.body, "msgtype": "m.text", "mxc": None, "file": None}
            self._cache_put(room_id, event_id, **entry)
            return entry
        return None

    def _done_mark(self, key: tuple):
        self._done[key] = True
        if len(self._done) > MAX_DONE:
            self._done.popitem(last=False)

    async def _do_translate(self, room_id: str, target_id: str, cached: dict, lang: str):
        key = ("tr", room_id, target_id, lang)
        if key in self._done:
            log.info(f"_do_translate: duplicate suppressed for {target_id} lang={lang}")
            return
        if cached["msgtype"] not in ("m.text", "m.notice", "m.emote"):
            await self._reply(room_id, target_id, "❌ Can only translate text messages.")
            return
        log.info(f"Translating → {lang}: {cached['body'][:60]!r}")
        result = await call_libretranslate(cached["body"], lang, self.lt_url)
        if result:
            await self._reply(room_id, target_id, f"🌐 {result}")
            self._done_mark(key)
        else:
            await self._reply(room_id, target_id, "❌ Translation failed — LibreTranslate unreachable?")

    async def _do_stt(self, room_id: str, target_id: str, cached: dict):
        key = ("stt", room_id, target_id)
        if key in self._done:
            log.info(f"_do_stt: duplicate suppressed for {target_id}")
            return
        if cached["msgtype"] != "m.audio":
            await self._reply(room_id, target_id, "❌ Not an audio message.")
            return

        file_info = cached.get("file")
        mxc = cached.get("mxc")
        if not mxc:
            await self._reply(room_id, target_id, "❌ No media URL found.")
            return

        log.info(f"Downloading audio {mxc}…")
        resp = await self.client.download(mxc)
        if isinstance(resp, DownloadError):
            await self._reply(room_id, target_id, "❌ Could not download audio.")
            return

        audio_bytes = resp.body
        if file_info:
            # Encrypted attachment — nio.crypto.decrypt_attachment takes raw base64 strings
            try:
                from nio.crypto import decrypt_attachment
                audio_bytes = decrypt_attachment(
                    audio_bytes,
                    file_info["key"]["k"],
                    file_info["hashes"]["sha256"],
                    file_info["iv"],
                )
            except Exception as e:
                log.warning(f"Attachment decryption failed: {e}")
                await self._reply(room_id, target_id, "❌ Could not decrypt audio attachment.")
                return

        with tempfile.NamedTemporaryFile(suffix=".ogg", delete=False) as f:
            f.write(audio_bytes)
            tmp = f.name

        try:
            loop = asyncio.get_event_loop()
            text = await loop.run_in_executor(
                None, _run_whisper, tmp, self.whisper_model, self.models_dir
            )
            await self._reply(
                room_id, target_id,
                f"📝 {text}" if text else "❌ Could not transcribe audio."
            )
            if text:
                self._done_mark(key)
        finally:
            os.unlink(tmp)

    def _trust_room_devices(self, room_id: str):
        """Mark all unverified (non-blacklisted) devices in a room as verified."""
        room = self.client.rooms.get(room_id)
        if not room:
            return
        for user_id in room.users:
            try:
                for device in self.client.device_store.active_user_devices(user_id):
                    if not device.verified and not device.blacklisted:
                        self.client.verify_device(device)
                        log.debug(f"Trusted device {device.device_id} for {user_id}")
            except Exception:
                pass

    async def _reply(self, room_id: str, reply_to_id: str, text: str):
        content = {
            "msgtype": "m.notice",
            "body": text,
            "m.relates_to": {"m.in_reply_to": {"event_id": reply_to_id}},
        }
        for attempt in range(3):
            try:
                await self.client.room_send(room_id, message_type="m.room.message", content=content)
                return
            except OlmUnverifiedDeviceError as e:
                log.warning(f"Unverified device {e.device} — trusting and retrying (attempt {attempt+1})")
                try:
                    self.client.verify_device(e.device)
                except Exception:
                    self._trust_room_devices(room_id)
            except Exception as e:
                log.error(f"room_send failed: {e}")
                return


async def main():
    cfg = load_config()
    bot = TranslateBot(cfg)
    await bot.start()


if __name__ == "__main__":
    asyncio.run(main())
