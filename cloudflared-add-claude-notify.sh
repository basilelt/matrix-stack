#!/usr/bin/env bash
# Adds claude-notify.example.com → http://YOUR_LXC_IP:8095 to the cloudflared tunnel.
# Run from the Mac after claude-notify-bot is deployed and running.

set -euo pipefail

SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
PROXMOX="root@YOUR_PROXMOX_IP"
NOTIFY_HOST="claude-notify.example.com"
NOTIFY_BACKEND="http://YOUR_LXC_IP:8095"

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes)

log() { echo "[cloudflared-add-claude-notify] $*"; }
die() { echo "[cloudflared-add-claude-notify] ERROR: $*" >&2; exit 1; }

run_on_proxmox() { ssh "${SSH_OPTS[@]}" "$PROXMOX" "$@"; }
run_in_lxc() {
  local lxc_id="$1"; shift
  run_on_proxmox "pct exec $lxc_id -- bash -c '$*'"
}

log "Finding cloudflared LXC..."
CF_LXC=$(run_on_proxmox "pct list" | awk 'NR>1 && $2=="running" {print $1}' | while read -r id; do
  name=$(run_on_proxmox "pct list" | awk -v id="$id" '$1==id{print $NF}')
  if echo "$name" | grep -qi cloudflared; then echo "$id"; break; fi
done)
[[ -z "$CF_LXC" ]] && die "Could not find running cloudflared LXC"
log "Cloudflared LXC: $CF_LXC"

log "Locating tunnel config..."
CF_CONFIG=$(run_in_lxc "$CF_LXC" "find /etc/cloudflared /root/.cloudflared /home -name 'config.yml' 2>/dev/null | head -1")
[[ -z "$CF_CONFIG" ]] && die "Could not find cloudflared config.yml"
log "Config file: $CF_CONFIG"

log "Checking for existing entry..."
if run_in_lxc "$CF_LXC" "grep -q '${NOTIFY_HOST}' '${CF_CONFIG}'" 2>/dev/null; then
  log "Route already exists — nothing to do."
  exit 0
fi

log "Adding ingress rule for ${NOTIFY_HOST}..."
run_in_lxc "$CF_LXC" "
python3 - <<'PY'
import re

with open('${CF_CONFIG}', 'r') as f:
    content = f.read()

new_rule = '''  - hostname: ${NOTIFY_HOST}
    service: ${NOTIFY_BACKEND}
'''

# Insert before the catch-all (last ingress entry without hostname)
content = re.sub(
    r'(ingress:\n(?:.*\n)*?)(  - service:)',
    r'\1' + new_rule + r'\2',
    content,
    count=1,
)

with open('${CF_CONFIG}', 'w') as f:
    f.write(content)
print('Config updated.')
PY
"

log "Restarting cloudflared..."
run_in_lxc "$CF_LXC" "systemctl restart cloudflared"
sleep 3
run_in_lxc "$CF_LXC" "systemctl is-active cloudflared"

log "Done. Test with: curl -sI https://${NOTIFY_HOST}/notify"
