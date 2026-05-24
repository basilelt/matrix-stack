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
Internet → Cloudflare edge (TLS) → cloudflared LXC → YOUR_PROXMOX_IP0:8080 → Caddy → Synapse:8008
```

- No ports exposed to internet — cloudflared tunnel only
- Matrix LXC: `YOUR_PROXMOX_IP0` (key-only SSH via `~/.ssh/id_rsa`)
- Domain: `matrix.example.com`

## Operational cheatsheet

| Action | Command |
|--------|---------|
| Tail all logs | `ssh root@YOUR_PROXMOX_IP0 "cd /opt/matrix-stack && docker compose logs -f"` |
| Tail one service | `ssh root@YOUR_PROXMOX_IP0 "cd /opt/matrix-stack && docker compose logs -f synapse"` |
| Restart service | `ssh root@YOUR_PROXMOX_IP0 "cd /opt/matrix-stack && docker compose restart synapse"` |
| Apply .env changes | `ssh root@YOUR_PROXMOX_IP0` then: `cd /opt/matrix-stack && ./setup.sh` |
| Force container updates | `ssh root@YOUR_PROXMOX_IP0 "docker exec watchtower /watchtower --run-once"` |
| Force OS updates | `ssh root@YOUR_PROXMOX_IP0 "systemctl start auto-update.service"` |
| Add SSH pubkey | `ssh root@YOUR_PROXMOX_IP0 "echo 'ssh-ed25519 AAAA...' >> /root/.ssh/authorized_keys"` |
| Backup | `ssh root@YOUR_PROXMOX_IP0 "cd /opt/matrix-stack && tar czf ~/backup.tgz .env synapse bridges stt-bot postgres/data"` |
| Stop stack | `ssh root@YOUR_PROXMOX_IP0 "cd /opt/matrix-stack && docker compose down"` |
| Rebuild GPU image | `ssh root@YOUR_PROXMOX_IP0 "cd /opt/matrix-stack && ./setup.sh rebuild-gpu"` |
| Register a new user | `ssh root@YOUR_PROXMOX_IP0 "cd /opt/matrix-stack && ./setup.sh register-user"` |

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

## Verification checklist

- [ ] `curl -s https://matrix.example.com/_matrix/client/versions | python3 -m json.tool` → JSON with `versions`
- [ ] Element login as `@admin:matrix.example.com` works
- [ ] Each bridge bot responds to `help` in DM
- [ ] `ssh root@YOUR_PROXMOX_IP0 "systemctl list-timers | grep auto-update"`
- [ ] `ssh root@YOUR_PROXMOX_IP0 "docker logs watchtower"`
