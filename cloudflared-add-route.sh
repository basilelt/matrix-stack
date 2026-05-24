#!/usr/bin/env bash
# cloudflared-add-route.sh
# Adds matrix.example.com → http://YOUR_PROXMOX_IP0:8080 to the cloudflared tunnel config
# running inside the cloudflared LXC on Proxmox, then restarts the service.
#
# Usage:
#   bash cloudflared-add-route.sh
#   SSH_KEY=~/.ssh/other_key bash cloudflared-add-route.sh
#
# Requirements (on the Mac running this script):
#   - ssh access to root@YOUR_PROXMOX_IP via SSH key
#   - scp available (bundled with openssh)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
PROXMOX="root@YOUR_PROXMOX_IP"
MATRIX_HOST="matrix.example.com"
MATRIX_BACKEND="http://YOUR_PROXMOX_IP0:8080"

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[cloudflared-add-route] $*"; }
die()  { echo "[cloudflared-add-route] ERROR: $*" >&2; exit 1; }

# Run a command on the Proxmox host over SSH.
# SC2029: arguments intentionally expand on the client side before passing to ssh.
# shellcheck disable=SC2029
run_on_proxmox() {
    ssh "${SSH_OPTS[@]}" "$PROXMOX" "$@"
}

# Run a command inside the LXC via pct exec
run_in_lxc() {
    local lxc_id="$1"; shift
    run_on_proxmox "pct exec $lxc_id -- bash -c '$*'"
}

# ---------------------------------------------------------------------------
# STEP 1: Find the cloudflared LXC
# ---------------------------------------------------------------------------
log "Detecting cloudflared LXC on Proxmox..."

# Parse running container IDs safely (skip header, match 'running' in status column)
RUNNING_IDS=$(run_on_proxmox "pct list" | awk 'NR>1 && $2=="running" {print $1}')

if [[ -z "$RUNNING_IDS" ]]; then
    die "No running LXC containers found on Proxmox."
fi

LXC_ID=""
for id in $RUNNING_IDS; do
    # Wrap the probe: which exits nonzero when not found — don't let set -e kill us
    if run_on_proxmox "pct exec $id -- which cloudflared" >/dev/null 2>&1; then
        LXC_ID="$id"
        log "Found cloudflared in LXC $LXC_ID"
        break
    fi
done

if [[ -z "$LXC_ID" ]]; then
    die "cloudflared binary not found in any running LXC. Containers checked: $RUNNING_IDS"
fi

# ---------------------------------------------------------------------------
# STEP 2: Find the config file
# ---------------------------------------------------------------------------
log "Locating cloudflared config file in LXC $LXC_ID..."

CANDIDATE_PATHS=(
    /etc/cloudflared/config.yml
    /etc/cloudflared/config.yaml
    /root/.cloudflared/config.yml
    /root/.cloudflared/config.yaml
)

CONFIG_PATH=""
for candidate in "${CANDIDATE_PATHS[@]}"; do
    if run_on_proxmox "pct exec $LXC_ID -- test -f $candidate" 2>/dev/null; then
        CONFIG_PATH="$candidate"
        log "Config found at: $CONFIG_PATH"
        break
    fi
done

if [[ -z "$CONFIG_PATH" ]]; then
    log "Common paths not found, trying find..."
    CONFIG_PATH=$(run_on_proxmox "pct exec $LXC_ID -- bash -c 'find /etc /root -name \"config.y*ml\" 2>/dev/null | head -1'" 2>/dev/null || true)
fi

if [[ -z "$CONFIG_PATH" ]]; then
    die "cloudflared config file not found in LXC $LXC_ID"
fi

# ---------------------------------------------------------------------------
# STEP 3: Backup the config
# ---------------------------------------------------------------------------
BACKUP_SUFFIX="bak.$(date +%Y%m%d_%H%M%S)"
log "Backing up config to ${CONFIG_PATH}.${BACKUP_SUFFIX}..."
run_on_proxmox "pct exec $LXC_ID -- cp $CONFIG_PATH ${CONFIG_PATH}.${BACKUP_SUFFIX}"

# ---------------------------------------------------------------------------
# STEP 4: Check for existing entry (idempotency)
# ---------------------------------------------------------------------------
log "Checking for existing ingress entry for $MATRIX_HOST..."
ALREADY_EXISTS=false
if run_on_proxmox "pct exec $LXC_ID -- grep -q $MATRIX_HOST $CONFIG_PATH" 2>/dev/null; then
    ALREADY_EXISTS=true
    log "Entry for $MATRIX_HOST already exists in config. Skipping YAML edit."
fi

# ---------------------------------------------------------------------------
# STEP 5: Add ingress rule via Python (safe YAML manipulation)
# ---------------------------------------------------------------------------
if [[ "$ALREADY_EXISTS" == "false" ]]; then
    log "Adding ingress rule for $MATRIX_HOST → $MATRIX_BACKEND..."

    # Trap to clean up local temp files on exit (covers both normal and error paths)
    LOCAL_INSTALL=""
    LOCAL_PY=""
    cleanup_temps() {
        [[ -n "$LOCAL_INSTALL" ]] && rm -f "$LOCAL_INSTALL"
        [[ -n "$LOCAL_PY" ]]      && rm -f "$LOCAL_PY"
    }
    trap cleanup_temps EXIT

    # Ensure PyYAML is available in the LXC (minimal containers may lack it)
    log "Ensuring python3-yaml is available in LXC $LXC_ID..."
    LOCAL_INSTALL=$(mktemp /tmp/install-pyyaml.XXXXXX.sh)
    PROXMOX_INSTALL="/tmp/install-pyyaml.sh"
    cat > "$LOCAL_INSTALL" << 'INSTALLEOF'
#!/bin/sh
python3 -c "import yaml" 2>/dev/null && exit 0
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -q python3-yaml
elif command -v apk >/dev/null 2>&1; then
    apk add --quiet py3-yaml
else
    echo "Cannot install python3-yaml: no apt-get or apk found" >&2
    exit 1
fi
INSTALLEOF
    scp "${SSH_OPTS[@]}" "$LOCAL_INSTALL" "$PROXMOX:$PROXMOX_INSTALL"
    run_on_proxmox "pct push $LXC_ID $PROXMOX_INSTALL /tmp/install-pyyaml.sh"
    run_on_proxmox "pct exec $LXC_ID -- bash /tmp/install-pyyaml.sh"
    rm -f "$LOCAL_INSTALL"
    run_on_proxmox "rm -f $PROXMOX_INSTALL"
    run_on_proxmox "pct exec $LXC_ID -- rm -f /tmp/install-pyyaml.sh"

    # Write the Python script to a local temp file, scp to Proxmox, push into LXC, execute.
    LOCAL_PY=$(mktemp /tmp/add-cloudflared-route.XXXXXX.py)
    PROXMOX_PY="/tmp/add-cloudflared-route.py"
    LXC_PY="/tmp/add-cloudflared-route.py"

    cat > "$LOCAL_PY" << PYEOF
import sys
import yaml

config_path = sys.argv[1]
new_hostname = sys.argv[2]
new_service  = sys.argv[3]

with open(config_path, 'r') as f:
    cfg = yaml.safe_load(f)

ingress = cfg.get('ingress', [])

# Find the catch-all: an entry that has 'service' but no 'hostname'
catchall_idx = None
for i, entry in enumerate(ingress):
    if 'hostname' not in entry:
        catchall_idx = i
        break

if catchall_idx is None:
    print("WARNING: no catch-all entry found; appending new entry at end.", file=sys.stderr)
    ingress.append({'hostname': new_hostname, 'service': new_service})
else:
    ingress.insert(catchall_idx, {'hostname': new_hostname, 'service': new_service})

cfg['ingress'] = ingress

with open(config_path, 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)

print(f"Inserted: hostname={new_hostname} service={new_service} (before index {catchall_idx})")
PYEOF

    # scp the script to Proxmox
    scp "${SSH_OPTS[@]}" "$LOCAL_PY" "$PROXMOX:$PROXMOX_PY"

    # Push the script from Proxmox into the LXC
    run_on_proxmox "pct push $LXC_ID $PROXMOX_PY $LXC_PY"

    # Execute inside the LXC
    run_on_proxmox "pct exec $LXC_ID -- python3 $LXC_PY $CONFIG_PATH $MATRIX_HOST $MATRIX_BACKEND"

    # Clean up temp files
    rm -f "$LOCAL_PY"
    run_on_proxmox "rm -f $PROXMOX_PY"
    run_on_proxmox "pct exec $LXC_ID -- rm -f $LXC_PY"

    log "Ingress rule added successfully."
fi

# ---------------------------------------------------------------------------
# STEP 6: Register DNS route
# ---------------------------------------------------------------------------
log "Registering DNS route for $MATRIX_HOST..."

# Extract tunnel ID from the config (avoids needing cert.pem for tunnel list).
# Use sed rather than awk to avoid $N positional-param expansion issues in double-quoted strings.
TUNNEL_ID=$(run_on_proxmox "pct exec $LXC_ID -- sed -n 's/^tunnel: //p' $CONFIG_PATH" 2>/dev/null || true)

if [[ -z "$TUNNEL_ID" ]]; then
    die "Could not extract tunnel ID from $CONFIG_PATH. Check the 'tunnel:' field."
fi

log "Tunnel ID: $TUNNEL_ID"

# Route dns may report "already exists" — treat that as success
# shellcheck disable=SC2016
DNS_RESULT=$(run_on_proxmox "pct exec $LXC_ID -- cloudflared tunnel route dns $TUNNEL_ID $MATRIX_HOST 2>&1" || true)
if echo "$DNS_RESULT" | grep -qi "already exists\|already added\|Overwriting"; then
    log "DNS route already registered (or will be overwritten)."
elif echo "$DNS_RESULT" | grep -qi "error\|failed"; then
    log "WARNING: DNS route command returned: $DNS_RESULT"
else
    log "DNS route registered: $DNS_RESULT"
fi

# ---------------------------------------------------------------------------
# STEP 7: Restart cloudflared
# ---------------------------------------------------------------------------
log "Restarting cloudflared service in LXC $LXC_ID..."

RESTARTED=false
# Note: avoid single quotes inside restart_cmd — they break when interpolated into
# "bash -c '$restart_cmd'", producing unbalanced quotes. Use double-quoted glob instead.
for restart_cmd in \
    "systemctl restart cloudflared" \
    "systemctl restart cloudflared@\\*" \
    "service cloudflared restart"; do
    if run_on_proxmox "pct exec $LXC_ID -- bash -c '$restart_cmd'" 2>/dev/null; then
        log "Service restarted via: $restart_cmd"
        RESTARTED=true
        break
    fi
done

if [[ "$RESTARTED" == "false" ]]; then
    log "WARNING: Could not restart cloudflared via systemctl or service. Restart it manually."
fi

# Print service status
log "Service status:"
run_on_proxmox "pct exec $LXC_ID -- bash -c 'systemctl is-active cloudflared 2>/dev/null || systemctl is-active cloudflared@* 2>/dev/null || echo unknown'" || true

# ---------------------------------------------------------------------------
# STEP 8: Summary
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "  Route added: $MATRIX_HOST → $MATRIX_BACKEND"
echo "  LXC ID:      $LXC_ID"
echo "  Config:      $CONFIG_PATH"
echo "  Backup:      ${CONFIG_PATH}.${BACKUP_SUFFIX}"
echo "=========================================="
echo ""
echo "Verify with:"
echo "  curl -s https://$MATRIX_HOST/_matrix/client/versions | python3 -m json.tool"
