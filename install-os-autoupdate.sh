#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_root

# Idempotency: skip if timer is already enabled
if systemctl is-enabled --quiet auto-update.timer 2>/dev/null; then
    ok "auto-update.timer is already enabled — nothing to do"
    exit 0
fi

# Ensure git is available
command -v git >/dev/null 2>&1 || die "git is not installed; run: apt-get install -y git"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

log "Cloning noloader/auto-update..."
git clone --depth 1 https://github.com/noloader/auto-update.git "$TMP/auto-update"

log "Running install.sh..."
(cd "$TMP/auto-update" && ./install.sh)

log "Enabling auto-update.timer..."
systemctl enable --now auto-update.timer

ok "auto-update installed and timer enabled"

log "Timer status:"
systemctl status auto-update.timer --no-pager | head -n 8 || true
