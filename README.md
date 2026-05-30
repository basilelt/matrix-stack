# matrix-stack

Self-hosted Matrix homeserver + bridges on a single Debian 13 LXC, behind Cloudflare Tunnel.

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
| Force container updates | `ssh root@YOUR_LXC_IP "cd /opt/matrix-stack && docker compose restart wud"` |
| Force OS updates | `ssh root@YOUR_LXC_IP "systemctl start auto-update.service"` |
| Add SSH pubkey | `ssh root@YOUR_LXC_IP "echo 'ssh-ed25519 AAAA...' >> /root/.ssh/authorized_keys"` |
| Backup | `ssh root@YOUR_LXC_IP "cd /opt/matrix-stack && tar czf ~/backup.tgz .env synapse bridges postgres/data"` |
| Stop stack | `ssh root@YOUR_LXC_IP "cd /opt/matrix-stack && docker compose down"` |
| Register a new user | `ssh root@YOUR_LXC_IP "cd /opt/matrix-stack && ./setup.sh register-user"` |

## Bring each bridge online (after deploy)

1. Log in to [Element](https://app.element.io) as `@admin:matrix.example.com`
2. DM `@whatsappbot:matrix.example.com` → send `login qr` → scan QR from WhatsApp mobile
3. DM `@telegrambot:matrix.example.com` → send `login` → enter phone + OTP
4. DM `@signalbot:matrix.example.com` → send `link` → scan from Signal mobile (Linked Devices)
5. DM `@discordbot:matrix.example.com` → send `login-token user <token>`
6. DM `@slackbot:matrix.example.com` → send `login` → follow OAuth flow
7. DM `@gmessagesbot:matrix.example.com` → send `login` → follow QR pairing flow
8. DM `@twitterbot:matrix.example.com` → send `login` → enter credentials
9. DM `@linkedinbot:matrix.example.com` → send `login` → follow cookie login flow
10. DM `@messengerbot:matrix.example.com` → send `login-cookie` with Facebook session cookies
11. DM `@instagrambot:matrix.example.com` → send `login-cookie` with Instagram session cookies

## Telegram bridge note

`TELEGRAM_API_ID` and `TELEGRAM_API_HASH` in `.env` must be set before enabling the Telegram bridge. Get them from [my.telegram.org/apps](https://my.telegram.org/apps) — register a "personal use" app.

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

## Claude notify bot

Receives a webhook POST and forwards it as an encrypted Matrix message. Intended for alerting from Claude Code or CI.

1. In `.env`: set `ENABLE_CLAUDE_NOTIFY=true`, fill `CLAUDE_NOTIFY_WEBHOOK_TOKEN` (`openssl rand -hex 32`), set `CLAUDE_NOTIFY_ROOM_ID` to the target room ID.
2. Run `./setup.sh` on the LXC.
3. Wire the Cloudflare tunnel to forward `https://notify.example.com` → `http://YOUR_LXC_IP:8095` — the bot only listens on `127.0.0.1:8095` and **must** sit behind the tunnel; it is not safe to expose directly.

Send a notification:
```bash
curl -s -X POST https://notify.example.com/notify \
  -H "Authorization: Bearer <CLAUDE_NOTIFY_WEBHOOK_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"message": "Deploy finished"}'
```

## Verification checklist

- [ ] `curl -s https://matrix.example.com/_matrix/client/versions | python3 -m json.tool` → JSON with `versions`
- [ ] Element login as `@admin:matrix.example.com` works
- [ ] Each bridge bot responds to `help` in DM
- [ ] `ssh root@YOUR_LXC_IP "systemctl list-timers | grep auto-update"`
- [ ] `ssh root@YOUR_LXC_IP "cd /opt/matrix-stack && docker compose logs wud"`

## Gotchas / Lessons

### Signal bridge: group messages fail — "missing sender key state" (error 80)

**Symptom:** Sending a message from Matrix into a Signal group fails. The bridge bot
posts:
> ⚠️ Your message may not have been bridged: failed to encrypt group message:
> 80: missing sender key state for distribution ID `<uuid>`

Logs also show `"Reusing existing sender key"` immediately before the error — so the
bridge never regenerates the key.

**Cause:** The bridge (mautrix-signal / signalmeow) re-linked to Signal, which assigned
a new `device_id`. The sender-key tracking table
(`signalmeow_outbound_sender_key_info`) is keyed by `(account_id, group_id)` only —
no device column — so it still points at a `distribution_id` whose
`SenderKeyRecord` was stored under the **old** device id. At encrypt time signalmeow
looks up the own sender key under the **current** device, finds nothing, and fails.
Because the tracking row says "already shared", the bridge loops forever without
regenerating.

**Fix** (run on the LXC, DB = `synapse_signal`):

```bash
# 1. Stop the bridge (prevent in-memory cache from re-writing the row)
docker compose stop mautrix-signal

# 2. Delete the stale outbound sender-key info for the affected group
#    (do NOT touch signalmeow_sender_keys — inbound keys from members live there)
docker compose exec -T postgres psql -U postgres -d synapse_signal -c "
  DELETE FROM signalmeow_outbound_sender_key_info
  WHERE account_id = '<your-aci-uuid>'
    AND group_id = '<group-id-from-logs>';
"

# 3. Restart the bridge — it will generate a fresh distribution_id on the next send
docker compose start mautrix-signal
```

**Verify:** Send a real message into the group from Matrix, then check:
```bash
docker compose logs --tail=60 mautrix-signal | grep -iE "sender key|distribut|encrypt|error"
```
A **new** `distribution_id` (≠ the old one) should appear, SenderKeyDistributionMessages
go out to members, and the message delivers without error.

**Escalation** (only if regeneration still doesn't happen): also delete the orphaned
own `SenderKeyRecord`:
```sql
DELETE FROM signalmeow_sender_keys
WHERE account_id = '<aci-uuid>'
  AND sender_uuid = '<aci-uuid>'
  AND distribution_id = '<old-distribution-id>';
```
Then restart and retest.

### Instagram bridge: TRANSIENT_DISCONNECT / "failed to send sync tasks: timeout waiting for response"

**Symptom:** The Instagram bridge shows **TRANSIENT_DISCONNECT** in mautrix-manager and loops
in the logs:
```
Failed to handle connect ack: "failed to send sync tasks: timeout waiting for response"
Error reading message from socket: "use of closed network connection"
Error in connection, reconnecting   (backoff 2s → 4s → … → 300s)
```
Re-logging with fresh cookies does not help. The Facebook bridge (same image) continues to work.

**Cause:** Meta changed the Instagram app ID in the MQTT layer. The old bridge image has the
stale hardcoded ID — MQTT connects but sync tasks receive no ack → timeout → socket closed →
TRANSIENT_DISCONNECT loop. Because FB uses a different app ID, it is unaffected.

**Fix:** Bump the `mautrix/meta` image to the patch release that contains the corrected app ID
(v26.05.1 = `v0.2605.1`). Then pull and recreate the two meta services:

```bash
cd /opt/matrix-stack
# 1. Edit docker-compose.yml: change both meta lines to the new tag, e.g. v0.2605.1
# 2. Pull + recreate (session cookies persist in the bridge volume — no re-login needed)
docker compose pull mautrix-meta-fb mautrix-meta-ig
docker compose up -d mautrix-meta-fb mautrix-meta-ig
```

**Verify:** Watch logs for ≥5 min — the `failed to send sync tasks` → `reconnecting` loop must
be **absent**, and a successful connected/sync line must appear:
```bash
docker compose logs -f --since 1m mautrix-meta-ig 2>&1 | grep -iE "connect|sync|error"
```
Send a test IG DM from Matrix and confirm delivery both ways.

**Note:** WUD may not flag this update because its calver transform only tracks `YYMM` and
ignores `.N` patch releases. Check `mautrix/meta` releases manually after a Meta outage.
