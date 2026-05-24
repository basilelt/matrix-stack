#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
PROXMOX="root@YOUR_PROXMOX_IP"
MATRIX_LXC="root@YOUR_PROXMOX_IP0"
MATRIX_DIR="/opt/matrix-stack"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

px() { ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$PROXMOX" "$@"; }
mx() { ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$MATRIX_LXC" "$@"; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

preflight() {
  [[ -f "$SSH_KEY" ]]     || { echo "ERROR: $SSH_KEY not found."; exit 1; }
  [[ -f "$SSH_KEY.pub" ]] || { echo "ERROR: $SSH_KEY.pub not found."; exit 1; }
  command -v rsync >/dev/null || { echo "ERROR: rsync not found. Install with: brew install rsync"; exit 1; }
}

# ---------------------------------------------------------------------------
# Flow: create LXC on Proxmox
# ---------------------------------------------------------------------------

do_create_lxc() {
  local pubkey b64
  pubkey=$(cat "$SSH_KEY.pub")
  # base64-encode the pubkey so it survives SSH quoting; prepend an export
  # assignment before the script so PUBKEY is available when the script runs.
  b64=$(printf '%s' "$pubkey" | base64 | tr -d '\n')

  echo "Creating LXC on Proxmox..."
  {
    printf 'export PUBKEY=$(printf "%%s" "%s" | base64 -d)\n' "$b64"
    cat "$SCRIPT_DIR/proxmox-create-lxc.sh"
  } | px "bash"

  echo "Waiting for LXC SSH..."
  local attempts=0
  while ! ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=3 \
              -o StrictHostKeyChecking=no "$MATRIX_LXC" true 2>/dev/null; do
    if [[ "$attempts" -ge 60 ]]; then
      echo "ERROR: LXC not reachable after 120s. Check YOUR_PROXMOX_IP0."
      exit 1
    fi
    sleep 2
    (( attempts++ ))
  done
  echo "LXC is reachable via SSH."
}

# ---------------------------------------------------------------------------
# Flow: rsync + first-run setup (creates .env then pauses)
# ---------------------------------------------------------------------------

do_deploy() {
  echo "Syncing files to LXC..."
  rsync -av --exclude '.git' --exclude '.DS_Store' \
    -e "ssh -i '$SSH_KEY' -o StrictHostKeyChecking=no" \
    "$SCRIPT_DIR/" "$MATRIX_LXC:$MATRIX_DIR/"

  mx "chmod +x $MATRIX_DIR/setup.sh $MATRIX_DIR/render-configs.sh $MATRIX_DIR/install-os-autoupdate.sh"

  echo "Running setup.sh (first run — will create .env and pause)..."
  local out
  # || true: setup.sh exits 0 after creating .env, but capture the output regardless
  out=$(mx "cd $MATRIX_DIR && ./setup.sh" 2>&1 | tee /dev/stderr) || true

  if grep -qE "Edit /opt/matrix-stack/\.env|re-run \./setup\.sh" <<<"$out"; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "PAUSED: Edit the .env file on the LXC:"
    echo ""
    echo "  ssh root@YOUR_PROXMOX_IP0"
    echo "  nano /opt/matrix-stack/.env"
    echo ""
    echo "Set POSTGRES_PASSWORD, SYNAPSE_REGISTRATION_SHARED_SECRET,"
    echo "SYNAPSE_ADMIN_PASSWORD, STT_BOT_PASSWORD (all: openssl rand -hex 32)"
    echo "Set TELEGRAM_API_ID + TELEGRAM_API_HASH if enabling Telegram bridge."
    echo "Flip ENABLE_BRIDGE_* flags as desired."
    echo ""
    echo "Then run: ./deploy.sh resume"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 0
  fi
}

# ---------------------------------------------------------------------------
# Flow: re-sync (excluding .env) + full setup
# ---------------------------------------------------------------------------

do_resume() {
  echo "Re-syncing files to LXC (preserving .env)..."
  rsync -av --exclude '.git' --exclude '.env' --exclude '.DS_Store' \
    -e "ssh -i '$SSH_KEY' -o StrictHostKeyChecking=no" \
    "$SCRIPT_DIR/" "$MATRIX_LXC:$MATRIX_DIR/"

  echo "Running setup.sh (full setup)..."
  mx "cd $MATRIX_DIR && ./setup.sh"
}

# ---------------------------------------------------------------------------
# Flow: cloudflared route + completion banner
# ---------------------------------------------------------------------------

do_cloudflared() {
  "$SCRIPT_DIR/cloudflared-add-route.sh"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "DEPLOY COMPLETE"
  echo ""
  echo "Matrix homeserver: https://matrix.example.com"
  echo "Admin login: @admin:matrix.example.com"
  echo ""
  echo "Verify:"
  echo "  curl -s https://matrix.example.com/_matrix/client/versions | python3 -m json.tool"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

CMD="${1:-full}"

case "$CMD" in
  full)
    preflight
    do_create_lxc
    do_deploy
    # do_deploy calls exit 0 if .env was just created and setup paused.
    # If we reach here, setup.sh ran to completion on the first run
    # (e.g. .env already existed from a previous partial run).
    do_cloudflared
    ;;
  deploy)
    preflight
    do_deploy
    ;;
  resume)
    preflight
    do_resume
    do_cloudflared
    ;;
  cloudflared)
    preflight
    do_cloudflared
    ;;
  *)
    echo "Usage: $0 [full|deploy|resume|cloudflared]"
    exit 1
    ;;
esac
