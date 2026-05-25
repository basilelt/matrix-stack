# matrix-stack

Self-hosted Matrix homeserver + bridges + Whisper STT on a single Debian 13 LXC, behind Cloudflare Tunnel.

## Prerequisites on the Mac

- SSH key at `~/.ssh/id_rsa` (must have access to `root@YOUR_PROXMOX_IP`)
- `rsync` (`brew install rsync` if missing)

## Proxmox LXC requirements (handled by deploy.sh)

- Debian 13 standard template on local storage (`pveam update && pveam download local debian-13-standard_*`)
- Features: `nesting=1,keyctl=1`

## Quick start

```bash
./deploy.sh          # creates LXC, deploys, pauses for .env edit
# Edit .env on the LXC (see output for instructions)
./deploy.sh resume   # completes setup + configures cloudflared tunnel
```

## Architecture

```
Internet → Cloudflare edge (TLS) → cloudflared LXC → YOUR_LXC_IP:8080 → Caddy → Synapse:8008
```

- No ports exposed to internet — cloudflared tunnel only
- Matrix LXC: `YOUR_LXC_IP` (key-only SSH via `~/.ssh/id_rsa`)
- Domain: `matrix.example.com`

## Operational cheatsheet

| Action | Command |
|--------|---------|
| Tail all logs | `ssh root@YOUR_LXC_IP "cd /opt/matrix-stack && docker compose logs -f"` |
| Tail one service | `ssh root@YOUR_LXC_IP "cd /opt/matrix-stack && docker compose logs -f synapse"` |
| Restart service | `ssh root@YOUR_LXC_IP "cd /opt/matrix-stack && docker compose restart synapse"` |
| Apply .env changes | `ssh root@YOUR_LXC_IP` then: `cd /opt/matrix-stack && ./setup.sh` |
| Force container updates | `ssh root@YOUR_LXC_IP "docker exec watchtower /watchtower --run-once"` |
| Force OS updates | `ssh root@YOUR_LXC_IP "systemctl start auto-update.service"` |
| Add SSH pubkey | `ssh root@YOUR_LXC_IP "echo 'ssh-ed25519 AAAA...' >> /root/.ssh/authorized_keys"` |
| Backup | `ssh root@YOUR_LXC_IP "cd /opt/matrix-stack && tar czf ~/backup.tgz .env synapse bridges stt-bot postgres/data"` |
| Stop stack | `ssh root@YOUR_LXC_IP "cd /opt/matrix-stack && docker compose down"` |
| Rebuild GPU image | `ssh root@YOUR_LXC_IP "cd /opt/matrix-stack && ./setup.sh rebuild-gpu"` |
| Register a new user | `ssh root@YOUR_LXC_IP "cd /opt/matrix-stack && ./setup.sh register-user"` |

## Bring each bridge online (after deploy)

1. Log in to [Element](https://app.element.io) as `@admin:matrix.example.com`
2. DM `@whatsappbot:matrix.example.com` → send `login qr` → scan QR from WhatsApp mobile
3. DM `@telegrambot:matrix.example.com` → send `login` → enter phone + OTP
4. DM `@signalbot:matrix.example.com` → send `link` → scan from Signal mobile (Linked Devices)
5. DM `@discordbot:matrix.example.com` → send `login-token user <token>`
6. DM `@metabot:matrix.example.com` → send `login-cookie` with FB/Instagram session cookies

## Telegram bridge note

`TELEGRAM_API_ID` and `TELEGRAM_API_HASH` in `.env` must be set before enabling the Telegram bridge. Get them from [my.telegram.org/apps](https://my.telegram.org/apps) — register a "personal use" app.

## STT bot — invite to rooms

After bridges are linked and portal rooms appear:
1. Invite `@stt-bot:matrix.example.com` into rooms you want transcribed.
2. Edit `STT_BOT_ROOM_ID` in `/opt/matrix-stack/.env`.
3. Run `./setup.sh` on the LXC to re-render the config and restart the bot.

## Stickers

Hybrid setup: **MSC2545 native packs** (FluffyChat picker) + **maunium-style widget** at `/stickerpicker/` (Element Web/Desktop picker). Same images serve both.

### One-time setup

1. In `.env`: set `ENABLE_STICKERS=true`, fill `STICKERS_PASSWORD` (`openssl rand -hex 32`).
2. Run `./setup.sh` on the LXC — registers `@stickers:matrix.example.com` and builds the importer image.
3. In FluffyChat: create a new **unencrypted** room (e.g. `#stickers:matrix.example.com`), keep it invite-only.
4. Invite `@stickers:matrix.example.com` into that room and give them **power level ≥ 50** (room settings → roles).
5. Copy the room ID (e.g. `!abc123:matrix.example.com`) → paste into `STICKERS_ROOM_ID` in `.env`.
6. Run `./setup.sh` again to re-render configs.

### Importing a WhatsApp sticker pack

Open the stickers room in any client, upload your `.wastickers` file as a file attachment — the bot picks it up automatically within a few seconds and reacts ✅ when the pack is live. Repeat for as many packs as you want.

#### Fallback / bulk import (advanced)

If you prefer the CLI path or want to import a folder of WebP/PNG files:

```bash
# copy pack to LXC
scp my-cats.wastickers root@YOUR_LXC_IP:/opt/matrix-stack/stickers/input/

# import (uploads images, writes MSC2545 state event + widget manifest)
ssh root@YOUR_LXC_IP "cd /opt/matrix-stack && \
  docker compose run --rm --no-deps matrix-sticker-importer /input/my-cats.wastickers"

# import a folder of WebP/PNG instead of a ZIP
ssh root@YOUR_LXC_IP "cd /opt/matrix-stack && \
  docker compose run --rm --no-deps matrix-sticker-importer /input/my-folder/"
```

Re-running the same pack updates the state event + manifest in place (idempotent).

### Using stickers in FluffyChat (native MSC2545)

1. Open FluffyChat → Settings → Stickers & Emojis → "Add a sticker room".
2. Enter the stickers room alias (e.g. `#stickers:matrix.example.com`) → subscribe.
3. Packs imported by the importer appear in the sticker picker across all rooms.

### Using stickers in Element Web/Desktop (widget)

The widget is served at `https://matrix.example.com/stickerpicker/`.

To enable the **sticker button** in the Element composer, run this once per account (replace `<userid>` and `<token>`):

```bash
curl -s -X PUT \
  "https://matrix.example.com/_matrix/client/v3/user/<userid>/account_data/m.widgets" \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "stickerpicker": {
      "content": {
        "type": "m.stickerpicker",
        "url": "https://matrix.example.com/stickerpicker/",
        "name": "Stickerpicker",
        "data": {}
      },
      "state_key": "stickerpicker",
      "type": "m.widget",
      "id": "stickerpicker",
      "sender": "<userid>"
    }
  }'
```

Get your access token from Element → Settings → Help & About → Access Token.

### Favorites space

To pin the stickers room (or any other room) inside a Favorites space:

1. Create a private space in FluffyChat (+ → New Space, invite-only, encryption off).
2. Copy the space's room ID (FluffyChat: room info → Internal room ID).
3. Set `FAVORITES_SPACE_ID=!<room-id>:matrix.example.com` in `.env` on the LXC.
4. Re-run `./setup.sh` — it wires `m.space.child` (space → stickers room) and `m.space.parent` (stickers room → space) idempotently.

To add more rooms to the Favorites space later, run this once per room (replace placeholders):
```bash
curl -s -X PUT \
  "https://matrix.example.com/_matrix/client/v3/rooms/<SPACE_ID>/state/m.space.child/<ROOM_ID>" \
  -H "Authorization: Bearer <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{"via":["matrix.example.com"],"suggested":false}'
```

### Where to get .wastickers files

- Export from the **Sticker Maker** or **sticker.ly** Android/iOS app (any pack you have installed).
- Download with a third-party tool like [wa-sticker-exporter](https://github.com/nicolo-ribaudo/wa-sticker-exporter).
- Hand-build a folder of WebP images (max 512×512, ≤30 per pack).

## Verification checklist

- [ ] `curl -s https://matrix.example.com/_matrix/client/versions | python3 -m json.tool` → JSON with `versions`
- [ ] Element login as `@admin:matrix.example.com` works
- [ ] Each bridge bot responds to `help` in DM
- [ ] `ssh root@YOUR_LXC_IP "systemctl list-timers | grep auto-update"`
- [ ] `ssh root@YOUR_LXC_IP "docker logs watchtower"`
