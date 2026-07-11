# matrix-stack

Self-hosted Matrix homeserver + bridges on a single Debian 13 LXC, behind Cloudflare Tunnel.

## Prerequisites on the Linux workstation

- SSH key at `~/.ssh/id_rsa` (must have access to `root@YOUR_PROXMOX_IP`)
- `rsync` (`sudo apt install rsync` if missing)

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
                                                                              → MAS:8080 (login/logout/refresh)
```

- No ports exposed to internet — cloudflared tunnel only
- Matrix LXC: `YOUR_LXC_IP` (key-only SSH via `~/.ssh/id_rsa`)
- Domain: `matrix.example.com`
- Auth: delegated to MAS (Matrix Authentication Service), which federates to Authentik — see below

## Matrix Authentication Service (MAS) — Authentik SSO

Set `MAS_ENABLED=true` (+ `MAS_PUBLIC_URL`, `MAS_SYNAPSE_SECRET`, `MAS_AUTHENTIK_CLIENT_ID/SECRET`,
`MAS_UPSTREAM_ULID` in `.env`) to delegate Synapse auth to MAS with Authentik as the upstream OIDC
provider. `render-configs.sh` then:
- Adds `matrix_authentication_service: {enabled, endpoint: http://mas:8080/, secret}` to
  `homeserver.yaml`.
- Renders `mas/config.yaml` from `mas/config.yaml.tmpl` (**skip-if-exists** — see the note in
  `render-configs.sh` §7b: MAS's signing keys/encryption secret live in this file and must NOT be
  regenerated on every render, or every session/token breaks. Generate once:
  `docker run --rm ghcr.io/element-hq/matrix-authentication-service:1.20.0 config generate`,
  paste the `secrets:` block into `mas/config.yaml`, then let the template fill in the rest).
- Routes `/_matrix/client/(v3|r0|unstable)/(login|logout|refresh|login/sso/redirect|login/sso/redirect/[^/]+)`
  to MAS in the Caddyfile (must come *before* the generic `/_matrix/*` → synapse handler), adds the
  `org.matrix.msc2965.authentication` block to the static `/.well-known/matrix/client` responder,
  and adds a second Caddy site block for `MAS_PUBLIC_URL` (public-only, no LAN/HAProxy route needed
  — cloudflared ingress + DNS route only). **When a second site is added, the `:{CADDY_PORT}` site
  needs explicit `{ }` braces** — Caddy can't otherwise tell where one site's directives end and
  the next site's hostname begins; without it, reload fails with
  `unrecognized directive: mas.bb-bbb.com`.
  **`login/sso/redirect` was missing from this list at first (found 2026-07-10)** — Synapse still
  advertises `m.login.sso` (with `delegated_oidc_compatibility: true`) for older clients, and Element
  uses this legacy endpoint for its "Continue with SSO" button rather than the modern MSC2965
  discovery flow. Without it in the regex, the request fell through to Synapse directly, which no
  longer implements it under MAS delegation (`M_UNRECOGNIZED`) — confirmed MAS itself handles the
  path correctly when hit directly, so this was purely a routing gap, not a MAS/Synapse bug.
  **The `mas.bb-bbb.com` site block itself was on the wrong listener (found + fixed same day):** it
  had no port, so with `auto_https off` it defaulted to a listener nothing actually connects to —
  HAProxy/cloudflared both forward to `{CADDY_PORT}` (8080), matching the main site's explicit
  binding, so every `mas.bb-bbb.com` request landed on the main site's catch-all (proxying to
  Synapse) instead. The address must be `http://mas.bb-bbb.com:{CADDY_PORT}` — explicit port so it
  joins the *same* Caddy server as the main site, **and** explicit `http://` scheme so Caddy doesn't
  infer a TLS connection policy for that server just because a real hostname is now part of it (a
  bare `:{CADDY_PORT}` address never triggers this; give it a hostname without a scheme and it does,
  even with `auto_https off` globally — confirmed by inspecting Caddy's own admin API config, which
  showed a `tls_connection_policies` entry appear on the merged server that broke both `mas.` and
  `matrix.` — a regression from the first fix attempt, caught before it reached a real request).
- Adds `mas` to `.compose-profiles` (the `mas` service in `docker-compose.yml` is behind a compose
  profile, dormant unless included).

**Migrating existing users:** `mas-cli syn2mas check`/`migrate` (in the MAS image) imports Synapse's
password users (bcrypt hashes, sessions, devices, tokens) into MAS's database — existing clients
keep working, no forced re-login. Requires `passwords.schemes` to include
`{version: 1, algorithm: bcrypt}` (MAS defaults to argon2id only). Requires Synapse stopped during
the real (non-dry-run) migration. Non-destructive validation first: `mas-cli config check`,
`syn2mas check`, `syn2mas migrate --dry-run` (dry-run truncates its own imported data at the end —
safe to run repeatedly). `mas-cli doctor --config mas/config.yaml` is the single best post-cutover
health check (validates well-known, homeserver reachability, legacy login routing — all in one).

**Gotcha — bots/bridges must talk to Caddy, not Synapse, directly.** Anything that logs in via
`m.login.password` against `http://synapse:8008` directly (bypassing Caddy) breaks once MAS is
enabled — Synapse itself returns 404/`M_UNRECOGNIZED` for `/login` under MAS delegation; only
requests that pass through Caddy's `/_matrix/client/.../login` matcher get proxied to MAS.
`translate-bot` and `claude-notify-bot` (`config.json.tmpl`) point `homeserver` at
`http://caddy:8080` (not `http://synapse:8008`) for exactly this reason. `setup.sh`'s sticker-room
provisioning (`_stk_admin_token`, `_admin_token`, `_stk_token` — the three `/login` calls around
lines 370/411/447) uses `http://localhost:8080` (Caddy's published port), not `:8008`, for the same
reason. This applies to ANY future component that logs in with a password.

**Gotcha — `translate-bot`/`claude-notify-bot`/`stickers`' `config.json` has NO skip-if-exists guard
in `render-configs.sh`, unlike the bridge configs.** It's unconditionally re-rendered from
`config.json.tmpl` + `.env` on every run. If you ever hand-patch the *live* `config.json` for one of
these (e.g. to migrate to token-based auth) without ALSO pushing the matching updated `.tmpl` to the
live host, the next `render-configs.sh` run — even one triggered for a completely unrelated fix —
will silently regenerate it from the stale template and revert your change. This crash-looped all 3
bots once already (2026-07-10, `KeyError: 'access_token'` after the template stayed on the old
`password` schema while two later Caddy-only re-renders ran). Always push the `.tmpl` in the same
step as any live `config.json` hand-edit for these three.

**Gotcha — googlechat cannot use encryption under MAS.** googlechat (Python bridge) has no MSC4190
support — its e2ee client calls `GET /_matrix/client/v3/login` directly on `synapse:8008` at
startup (to discover login flows) regardless of `encryption.default`, and crash-loops when that
404s under MAS (mirrors element-hq/matrix-authentication-service#3206). Fix: both
`encryption.allow: false` AND `encryption.default: false` in `bridges/googlechat/config.yaml` (allow
alone is not enough — the crash happens during e2ee client init, before default is even consulted).
All other bridges have `msc4190: true` and are unaffected.

**Post-cutover cleanup (not done automatically):** while `passwords.enabled: true` and
`claims_imports.localpart.on_conflict: add` stay set, existing users can log in with either
password or Authentik SSO, and Authentik logins link to (not replace) the migrated account. Once
every human has logged in via Authentik at least once, consider flipping `on_conflict` to `fail`
(prevents new SSO logins from silently creating duplicate accounts on a localpart mismatch) —
bots must move to token-based auth before disabling passwords entirely.

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
| Backup | `ssh root@YOUR_LXC_IP 'cd /opt/matrix-stack && docker compose exec -T postgres pg_dumpall -U synapse \| gzip > ~/matrix-pg-$(date +%F).sql.gz && tar czf ~/matrix-files-$(date +%F).tgz .env synapse bridges'` (logical dump — crash-consistent; never tar a live `postgres/data`) |
| Stop stack | `ssh root@YOUR_LXC_IP "cd /opt/matrix-stack && docker compose down"` |
| Register a new user | `ssh root@YOUR_LXC_IP "cd /opt/matrix-stack && ./setup.sh register-user"` |

## Bridge disconnects / re-login

Bridges that use browser session auth (Messenger, Discord) **will be revoked periodically** — this
is inherent, not a misconfiguration. Auto-refresh from the server is intentionally not done:
a Playwright headless sidecar was built and removed because Facebook blocks headless logins from
datacenter IPs, and Discord ToS invalidates user tokens. Re-auth always comes from your real browser.

### Discord — `4004 Authentication failed` / silent no messages

Symptom: `close 4004: Authentication failed` / `Got logged out from Discord due to invalid token`
in logs; bridge appears up but delivers nothing (no gateway activity after the 4004).

**Re-login (preferred — QR, no token handling):**
```text
DM @discordbot:matrix.example.com → send: login-qr
```
Then **Discord phone app → Settings → Scan QR Code** and scan the image the bot posts.
Verify: `docker logs --tail 10 matrix-stack-mautrix-discord-1` → expect `Connected to Discord`.

Backfill is configured (`bridge.backfill.forward_limits.missed: -1` in the live config), so on
reconnect the bridge **refills every message missed during the outage** — no manual catch-up.

Fallback (token): private browser → Discord web → F12 → Network → copy `Authorization` header →
DM the bot `login-token user <token>`. Use a private window so closing it won't revoke the token.

**You no longer have to notice this yourself:** `scripts/discord-health.sh` (cron `*/10`) pings you
via the claude-notify-bot the moment the bridge logs out or stops — see *Monitoring* below.

Ref: https://docs.mau.fi/bridges/go/discord/authentication.html

### Messenger — `connect failure: 400` / `IRIS_DOMAIN subscribe PERMISSION DENIED`

Symptom: repeated `Unknown connect failure: <failure location="odn" reason="400"/>` and
`WarthogPermissionDeniedException` in logs; messages stop arriving. The bridge's CAT-refresh loop
cannot recover a revoked session.

```bash
# 1. Restart
ssh -i ~/.ssh/id_rsa root@YOUR_LXC_IP 'cd /opt/matrix-stack && docker compose restart mautrix-meta-fb'
# 2. DM @messengerbot:matrix.example.com → send: login-cookie
#    Follow the cURL prompt (copy the GraphQL request as cURL from a logged-in Facebook tab in
#    DevTools → Network → right-click any messenger.com/api/graphql request → Copy as cURL)
# 3. Close the browser tab WITHOUT logging out of Facebook (logout invalidates the session)
# 4. Verify: docker compose logs --tail 10 mautrix-meta-fb → expect message upserts, no 400 errors
```

Ref: https://etke.cc/help/bridges/mautrix-meta-messenger/

### WUD / updates

WUD is healthy (hourly cron). Calver bridges (meta, telegram, signal, etc.) auto-update.
Discord (`mautrix-discord`) is pinned at latest v0.7.6 (`wud.watch: false` / semver).
Image versions are **not** the cause of these disconnects.

### Monitoring — Discord disconnect alerts

`scripts/discord-health.sh` runs from root cron every 10 min on the LXC:

```cron
*/10 * * * * /opt/matrix-stack/scripts/discord-health.sh
```

It POSTs the claude-notify-bot webhook (→ encrypted Matrix DM) once per outage if the bridge
container is down or the logs show a `4004`/`4003`/auth failure in the last 15 min, and clears the
one-shot flag (`/run/discord-bridge-down`) when it next sees `Connected to Discord`. Reuses
`CLAUDE_NOTIFY_WEBHOOK_TOKEN` from `.env`; no extra service. Generalise to other bridges by adding
their container name + auth-failure pattern.

### Host: weekly reboot (reduce reconnect churn)

The LXC's `auto-update` (vendored `noloader/auto-update`) ran daily at 04:10 and rebooted on every
apt change — a daily cold reconnect that flagged Discord and tripped a startup DNS race. Switched to
**weekly** (Mondays) via a systemd drop-in *on the host* (not deploy.sh-managed):

```bash
mkdir -p /etc/systemd/system/auto-update.timer.d
printf '[Timer]\nOnCalendar=\nOnCalendar=Mon *-*-* 04:10:00\n' \
  > /etc/systemd/system/auto-update.timer.d/override.conf
systemctl daemon-reload && systemctl restart auto-update.timer
```

## Bring each bridge online (after deploy)

1. Log in to [Element](https://app.element.io) as `@admin:matrix.example.com`
2. DM `@whatsappbot:matrix.example.com` → send `login qr` → scan QR from WhatsApp mobile
3. DM `@telegrambot:matrix.example.com` → send `login` → enter phone + OTP
4. DM `@signalbot:matrix.example.com` → send `link` → scan from Signal mobile (Linked Devices)
5. DM `@discordbot:matrix.example.com` → send `login-qr` → scan from Discord mobile (Settings → Scan QR Code)
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

## Multi-user bridges & double puppeting

Every bridgev2 ("megabridge") config grants `"matrix.bb-bbb.com": user` in its `permissions:`
block — any local Matrix user can log their own account into any bridge (their own
WhatsApp/Telegram/Signal/etc.), get their own portals, and double-puppet as themselves. The
`"*"` wildcard default is `block` (fixed 2026-07-10 — `setup.sh`'s bridge-config generator used
to translate the bridge's own default `relaybot` value to `"*": relay`, which is the opposite of
per-user separation: it would let unauthenticated/unmatched senders talk through the bridge bot
as a shared relay identity instead of requiring their own login). `relay.enabled` stays `false`
everywhere.

**Double puppeting** uses a single shared `doublepuppet` appservice `as_token`
(`synapse/appservices/doublepuppet-registration.yaml`), referenced by each bridge as
`double_puppet.secrets: { matrix.bb-bbb.com: as_token:<TOKEN> }` (the "modern"/bridgev2 method —
works for whatsapp, telegram, signal, slack, gmessages, twitter, meta-fb, meta-ig, linkedin).

**discord and googlechat are legacy-format bridges and CANNOT use that method.** They only
support `login_shared_secret_map: { matrix.bb-bbb.com: <secret> }`, which authenticates via the
**`matrix-synapse-shared-secret-auth` Synapse password_provider module** — a completely
different mechanism, and that module **is not installed** in this stack (confirmed: no
`password_providers:` block in `homeserver.yaml`, module not importable in the synapse
container). Wiring the doublepuppet as_token into `login_shared_secret_map` (as `setup.sh` used
to do, and as this session initially tried) does NOT work — it just produces repeated
`Failed to login with shared secret: M_FORBIDDEN` on every bridge restart. `setup.sh` leaves
`login_shared_secret_map` empty for these two bridges now; double-puppeting for discord/
googlechat requires either installing that module (own Synapse password-provider, needs a
custom-built Synapse image or a sidecar) or per-user manual `login-matrix` (paste an access
token). Bridging itself is unaffected — only the "sent as you" cosmetic ghost styling.

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

**Note:** WUD may not flag this update if the registry config is wrong. The correct config
requires `WUD_REGISTRY_GITLAB_MAUDEV_URL=https://dock.mau.dev` (registry host) **and**
`WUD_REGISTRY_GITLAB_MAUDEV_AUTHURL=https://mau.dev` (JWT auth host). Without `_AUTHURL`,
WUD logs `Unsupported Registry unknown` for all mautrix images every cron and never checks tags.
The tag regex `^v0\.\d{4}\.\d+$` already matches patch releases like `v0.2605.1`.
