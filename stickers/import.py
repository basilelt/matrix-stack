#!/usr/bin/env python3
"""
WhatsApp → Matrix sticker importer.

Accepts .wastickers ZIP files or folders of WebP/PNG images.
For each pack:
  - Uploads images to Synapse media repo as @stickers user
  - Writes MSC2545 state event (im.ponies.room_emotes) to the stickers room
  - Writes maunium-compatible JSON manifest to /app/packs/<id>.json

Usage:
  python import.py <path.wastickers>...
  python import.py <image-folder>...
"""
import json
import re
import sys
import zipfile
from io import BytesIO
from pathlib import Path

import httpx
from PIL import Image

CONFIG_PATH = Path("/app/config.json")
DATA_DIR = Path("/app/data")
PACKS_DIR = Path("/app/packs")

STICKER_EXTS = {".webp", ".png", ".jpg", ".jpeg", ".gif"}
SKIP_NAMES = {"metadata.json", "tray_image.png", "tray.png", "tray.webp",
              "tray_image.webp", "tray_animated.webp"}


def load_config() -> dict:
    with open(CONFIG_PATH) as f:
        return json.load(f)


def get_access_token(cfg: dict) -> str:
    token_file = DATA_DIR / "access_token.txt"
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if token_file.exists():
        token = token_file.read_text().strip()
        if token:
            return token
    hs = cfg["homeserver_url"].rstrip("/")
    resp = httpx.post(
        f"{hs}/_matrix/client/v3/login",
        json={
            "type": "m.login.password",
            "identifier": {"type": "m.id.user", "user": cfg["stickers_user"]},
            "password": cfg["stickers_password"],
        },
        timeout=30,
    )
    resp.raise_for_status()
    token = resp.json()["access_token"]
    token_file.write_text(token)
    print(f"  Logged in as @{cfg['stickers_user']}")
    return token


def upload_image(hs: str, token: str, data: bytes, mimetype: str, filename: str) -> str:
    resp = httpx.post(
        f"{hs}/_matrix/media/v3/upload",
        params={"filename": filename},
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": mimetype,
        },
        content=data,
        timeout=120,
    )
    if resp.status_code == 401:
        raise RuntimeError("Token rejected — delete data/access_token.txt and retry")
    resp.raise_for_status()
    return resp.json()["content_uri"]


def image_info(data: bytes, mimetype: str) -> dict:
    info: dict = {"mimetype": mimetype, "size": len(data)}
    try:
        img = Image.open(BytesIO(data))
        info["w"], info["h"] = img.size
    except Exception:
        pass
    return info


def slugify(text: str) -> str:
    text = re.sub(r"[^a-z0-9]+", "-", text.lower())
    return text.strip("-") or "pack"


def ext_to_mime(ext: str) -> str:
    return {"webp": "image/webp", "png": "image/png", "gif": "image/gif",
            "jpg": "image/jpeg", "jpeg": "image/jpeg"}.get(ext.lstrip("."), "image/webp")


def read_wastickers(path: Path, display_name: str = "") -> tuple[str, str, list[tuple[str, bytes, str]]]:
    """Returns (pack_id, pack_title, [(stem, data, mimetype), ...])."""
    with zipfile.ZipFile(path) as zf:
        names = zf.namelist()
        pack_title = display_name or path.stem
        identifier = display_name or path.stem
        if "metadata.json" in names:
            try:
                meta = json.loads(zf.read("metadata.json"))
                pack_title = meta.get("name") or meta.get("title") or path.stem
                identifier = meta.get("identifier") or meta.get("name") or path.stem
            except Exception:
                pass
        pack_id = slugify(identifier)
        stickers = []
        for name in sorted(names):
            if name in SKIP_NAMES or "/" in name:
                continue
            ext = Path(name).suffix.lower()
            if ext not in STICKER_EXTS:
                continue
            stickers.append((Path(name).stem, zf.read(name), ext_to_mime(ext.lstrip("."))))
    return pack_id, pack_title, stickers


def read_folder(path: Path) -> tuple[str, str, list[tuple[str, bytes, str]]]:
    pack_id = slugify(path.name)
    pack_title = path.name
    stickers = []
    for p in sorted(path.iterdir()):
        if p.suffix.lower() not in STICKER_EXTS:
            continue
        stickers.append((p.stem, p.read_bytes(), ext_to_mime(p.suffix.lstrip("."))))
    return pack_id, pack_title, stickers


def write_manifest(pack_id: str, pack_title: str, stickers: list[dict]) -> None:
    PACKS_DIR.mkdir(parents=True, exist_ok=True)
    manifest = {"title": pack_title, "id": pack_id, "stickers": stickers}
    tmp = PACKS_DIR / f"{pack_id}.tmp"
    tmp.write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    tmp.rename(PACKS_DIR / f"{pack_id}.json")

    index_file = PACKS_DIR / "index.json"
    index: list[str] = json.loads(index_file.read_text()) if index_file.exists() else []
    if pack_id not in index:
        index.append(pack_id)
    tmp = PACKS_DIR / "index.tmp"
    tmp.write_text(json.dumps(index, ensure_ascii=False))
    tmp.rename(index_file)


def put_state_event(hs: str, token: str, room_id: str, pack_id: str,
                    pack_title: str, stickers: list[dict]) -> None:
    images = {
        s["id"]: {
            "url": s["url"],
            "body": s["body"],
            "usage": ["sticker"],
            "info": s["info"],
        }
        for s in stickers
    }
    content = {
        "pack": {"display_name": pack_title, "usage": ["sticker"]},
        "images": images,
    }
    url = f"{hs}/_matrix/client/v3/rooms/{room_id}/state/im.ponies.room_emotes/{pack_id}"
    resp = httpx.put(url, headers={"Authorization": f"Bearer {token}"},
                     json=content, timeout=30)
    if resp.status_code == 403:
        print(f"  WARNING: 403 on state event — ensure @stickers user has power level ≥ 50 in the stickers room")
        print(f"  Manifest written; MSC2545 state event skipped.")
        return
    resp.raise_for_status()
    print(f"  MSC2545 state event written: im.ponies.room_emotes/{pack_id}")


def import_pack(cfg: dict, token: str, path: Path, display_name: str = "") -> None:
    hs = cfg["homeserver_url"].rstrip("/")
    room_id = cfg["stickers_room_id"]

    if path.suffix.lower() == ".wastickers":
        pack_id, pack_title, raw = read_wastickers(path, display_name)
    elif path.is_dir():
        pack_id, pack_title, raw = read_folder(path)
    else:
        print(f"  Skipping {path}: not a .wastickers file or directory")
        return

    if not raw:
        print(f"  No sticker images found in {path}")
        return

    print(f"\nImporting '{pack_title}' (id={pack_id}): {len(raw)} stickers")

    stickers = []
    for i, (stem, data, mimetype) in enumerate(raw):
        ext = mimetype.split("/")[1]
        filename = f"{pack_id}-{slugify(stem)}.{ext}"
        print(f"  [{i + 1}/{len(raw)}] {stem} ...", end=" ", flush=True)
        mxc = upload_image(hs, token, data, mimetype, filename)
        info = image_info(data, mimetype)
        body = stem.replace("-", " ").replace("_", " ")
        stickers.append({
            "id": f"{pack_id}-{slugify(stem)}",
            "body": body,
            "url": mxc,
            "info": info,
        })
        print(f"→ {mxc}")

    write_manifest(pack_id, pack_title, stickers)
    print(f"  Manifest: packs/{pack_id}.json (index updated)")

    if room_id and not room_id.startswith("!placeholder"):
        put_state_event(hs, token, room_id, pack_id, pack_title, stickers)
    else:
        print(f"  Skipping MSC2545 state event: STICKERS_ROOM_ID not set (manifest still written)")

    return pack_id, pack_title, len(stickers)


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] in ("--help", "-h"):
        print("Usage: python import.py <path.wastickers|folder> ...")
        print("       docker compose run --rm matrix-sticker-importer /input/pack.wastickers")
        sys.exit(0)

    cfg = load_config()
    token = get_access_token(cfg)

    for arg in sys.argv[1:]:
        import_pack(cfg, token, Path(arg))

    print("\nDone.")


if __name__ == "__main__":
    main()
