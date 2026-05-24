#!/usr/bin/env bash
# proxmox-create-lxc.sh — Create and configure a Debian 13 LXC for Matrix homeserver
# Usage (called from deploy.sh on Mac):
#   ssh root@YOUR_PROXMOX_IP bash -s -- "$VMID" "$PUBKEY" < proxmox-create-lxc.sh
# Args:
#   $1 = VMID (optional; auto-detected with pct nextid if empty)
#   $2 = PUBKEY (required; full pubkey string content)

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo "[$(date '+%H:%M:%S')] $*" >&2
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
VMID="${1:-}"
# Accept pubkey from $2 or from the PUBKEY environment variable (deploy.sh uses the latter)
PUBKEY="${2:-${PUBKEY:-}}"

[[ -z "$PUBKEY" ]] && die "PUBKEY required: pass as \$2 or set PUBKEY env var before calling this script"

if [[ -z "$VMID" ]]; then
    # pct nextid not available on all Proxmox versions; compute from existing IDs
    local_max="$(pct list 2>/dev/null | awk 'NR>1 {print $1}' | sort -n | tail -1 || true)"
    VMID=$(( ${local_max:-100} + 1 ))
    log "Auto-selected VMID: $VMID (next after $local_max)"
fi

# Validate VMID is a positive integer
[[ "$VMID" =~ ^[0-9]+$ ]] || die "VMID must be a positive integer, got: $VMID"

log "Using VMID: $VMID"

# ---------------------------------------------------------------------------
# Debian 13 template
# ---------------------------------------------------------------------------
STORAGE="local"

ensure_template() {
    log "Checking for Debian 13 template on $STORAGE..."
    local existing
    existing="$(pveam list "$STORAGE" 2>/dev/null | awk '{print $1}' | grep "debian-13-standard" | head -1 || true)"

    if [[ -n "$existing" ]]; then
        log "Template already present: $existing"
        # stdout is captured by caller; must print only the template ID
        printf '%s\n' "$existing"
        return 0
    fi

    log "Template not found locally. Updating pveam index..."
    pveam update || die "pveam update failed"

    local available
    available="$(pveam available | awk '{print $2}' | grep "debian-13-standard" | head -1 || true)"
    [[ -z "$available" ]] && die "No debian-13-standard template found in pveam available"

    log "Downloading template: $available"
    pveam download "$STORAGE" "$available" || die "pveam download failed for $available"

    local downloaded
    downloaded="$(pveam list "$STORAGE" 2>/dev/null | awk '{print $1}' | grep "debian-13-standard" | head -1 || true)"
    [[ -z "$downloaded" ]] && die "Template download appeared to succeed but not found in pveam list"
    printf '%s\n' "$downloaded"
}

# ---------------------------------------------------------------------------
# Idempotency: check if container already exists
# ---------------------------------------------------------------------------
CONTAINER_EXISTS=0
if pct list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$VMID"; then
    log "Container $VMID already exists — skipping creation, will ensure SSH config."
    CONTAINER_EXISTS=1
fi

# ---------------------------------------------------------------------------
# Create LXC (only if it doesn't exist)
# ---------------------------------------------------------------------------
if [[ "$CONTAINER_EXISTS" -eq 0 ]]; then
    TEMPLATE_ID="$(ensure_template)"

    log "Creating LXC container $VMID..."
    pct create "$VMID" "$TEMPLATE_ID" \
        --arch amd64 \
        --ostype debian \
        --hostname matrix-stack \
        --memory 6144 \
        --cpulimit 4 \
        --cores 4 \
        --rootfs local-lvm:40 \
        --net0 name=eth0,bridge=vmbr0,ip=YOUR_LXC_IP/24,gw=YOUR_GATEWAY_IP \
        --nameserver 1.1.1.1 \
        --searchdomain local \
        --unprivileged 1 \
        --features nesting=1,keyctl=1 \
        --onboot 1 \
        || die "pct create failed"

    log "Container $VMID created."
fi

# ---------------------------------------------------------------------------
# Append Docker-required LXC config (idempotent: only if lines not present)
# ---------------------------------------------------------------------------
LXC_CONF="/etc/pve/lxc/${VMID}.conf"
[[ -f "$LXC_CONF" ]] || die "LXC config file not found: $LXC_CONF"

log "Ensuring Docker-required LXC config in $LXC_CONF..."

append_if_missing() {
    local line="$1"
    local file="$2"
    if ! grep -qxF "$line" "$file"; then
        echo "$line" >> "$file"
        log "  Added: $line"
    else
        log "  Already present: $line"
    fi
}

append_if_missing "lxc.apparmor.profile: unconfined"   "$LXC_CONF"
append_if_missing "lxc.cap.drop:"                       "$LXC_CONF"
append_if_missing "lxc.cgroup2.devices.allow: a"        "$LXC_CONF"
append_if_missing "lxc.mount.auto: proc:rw sys:rw"      "$LXC_CONF"

# ---------------------------------------------------------------------------
# Start the container (config is now applied before first start)
# ---------------------------------------------------------------------------
CURRENT_STATUS="$(pct status "$VMID" | awk '{print $2}')"
if [[ "$CURRENT_STATUS" == "running" ]]; then
    log "Container $VMID is already running."
elif [[ "$CURRENT_STATUS" == "stopped" ]]; then
    log "Starting container $VMID..."
    pct start "$VMID" || die "pct start $VMID failed"
else
    die "Container $VMID is in unexpected state: $CURRENT_STATUS"
fi

# ---------------------------------------------------------------------------
# Wait for container to be running (max 30s)
# ---------------------------------------------------------------------------
log "Waiting for container $VMID to reach running state..."
WAITED=0
while ! pct status "$VMID" 2>/dev/null | grep -q "running"; do
    if [[ "$WAITED" -ge 30 ]]; then
        die "Container $VMID did not reach running state after 30 seconds"
    fi
    sleep 1
    (( WAITED++ ))
done
log "Container $VMID is running."

# ---------------------------------------------------------------------------
# Install openssh-server inside the LXC
# ---------------------------------------------------------------------------
log "Installing openssh-server in container $VMID..."
pct exec "$VMID" -- bash -c 'apt-get update -qq && apt-get install -y -qq openssh-server' \
    || die "Failed to install openssh-server in container $VMID"

# ---------------------------------------------------------------------------
# SSH hardening inside the LXC
# ---------------------------------------------------------------------------
log "Configuring SSH in container $VMID..."

# Setup authorized_keys — pass PUBKEY as positional arg to avoid quoting issues
pct exec "$VMID" -- bash -c '
    set -euo pipefail
    PUBKEY="$1"
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    if ! grep -qxF "$PUBKEY" /root/.ssh/authorized_keys 2>/dev/null; then
        echo "$PUBKEY" >> /root/.ssh/authorized_keys
    fi
    chmod 600 /root/.ssh/authorized_keys
' _ "$PUBKEY" || die "Failed to configure authorized_keys"

# Write sshd_config atomically
pct exec "$VMID" -- bash -c '
    set -euo pipefail
    cat > /tmp/sshd_config_new <<'"'"'SSHD_EOF'"'"'
# Managed by proxmox-create-lxc.sh — do not edit manually
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
AuthorizedKeysFile .ssh/authorized_keys
SSHD_EOF
    mv /tmp/sshd_config_new /etc/ssh/sshd_config
    chmod 644 /etc/ssh/sshd_config
' || die "Failed to write sshd_config"

# Lock root password, enable and restart SSH
pct exec "$VMID" -- bash -c '
    set -euo pipefail
    passwd -l root
    systemctl enable ssh
    systemctl restart ssh
' || die "Failed to lock password / restart SSH"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log "LXC $VMID ready. SSH: ssh root@YOUR_LXC_IP (key-only)"
