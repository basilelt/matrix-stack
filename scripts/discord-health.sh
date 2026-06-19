#!/usr/bin/env bash
# Alert (once per outage) when the Discord bridge logs out or stops, via the
# claude-notify-bot webhook → encrypted Matrix DM. Run from cron every ~10 min.
# mautrix-discord can't self-recover from a 4004 (revoked user token); this turns
# a silent multi-day outage into an immediate ping. Fix on alert: !discord login-qr
set -euo pipefail

cd /opt/matrix-stack
# shellcheck disable=SC1091
source .env

C=matrix-stack-mautrix-discord-1
STATE=/run/discord-bridge-down

fire() {
  [[ -f "$STATE" ]] && exit 0   # already alerted for this outage
  curl -fsS -X POST "http://127.0.0.1:8095/notify" \
    -H "Authorization: Bearer ${CLAUDE_NOTIFY_WEBHOOK_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "{\"event\":\"notification\",\"host\":\"discord-bridge\",\"message\":\"⚠️ Discord bridge DOWN: $1 — re-login with !discord login-qr\"}" \
    >/dev/null || true
  touch "$STATE"
  exit 0
}

# Container gone
docker ps --format '{{.Names}}' | grep -qx "$C" || fire "container not running"

# Token revoked / auth failure in the last 15 min
if docker logs --since 15m "$C" 2>&1 | grep -qE '4004|4003|Authentication failed|Not authenticated'; then
  fire "auth failed (token revoked)"
fi

# Reconnected (re-login or restart succeeded) → clear the outage flag
if docker logs --since 30m "$C" 2>&1 | grep -q 'We are now connected to Discord'; then
  rm -f "$STATE"
fi
