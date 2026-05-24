#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export SCRIPT_DIR
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

CMD="${1:-up}"

case "$CMD" in
  up)
    # ── 1. Require root ──────────────────────────────────────────────────────
    require_root

    # ── 2. APT prerequisites ─────────────────────────────────────────────────
    log "Installing apt prerequisites"
    apt-get update -qq
    apt-get install -y ca-certificates curl gnupg python3 jq openssl git

    # ── 3. Docker install (idempotent) ───────────────────────────────────────
    if ! command -v docker &>/dev/null; then
      log "Installing Docker CE from official repo (trixie channel)"
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian trixie stable" \
        > /etc/apt/sources.list.d/docker.list
      apt-get update -qq
      apt-get install -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
      systemctl enable --now docker
    fi
    # Docker daemon may take a moment to start after fresh install
    DOCKER_RETRIES=0
    until docker info >/dev/null 2>&1; do
      if [[ "$DOCKER_RETRIES" -ge 10 ]]; then
        die "Docker won't start after 10s — check LXC features (nesting=1,keyctl=1)"
      fi
      sleep 1
      (( DOCKER_RETRIES++ ))
    done

    # ── 4. .env bootstrap ────────────────────────────────────────────────────
    if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
      cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env" && chmod 600 "$SCRIPT_DIR/.env"
      ok "Created .env from template"
      echo ""
      echo "IMPORTANT: Edit /opt/matrix-stack/.env before re-running:"
      echo "  - Set MATRIX_DOMAIN, PUBLIC_DOMAIN"
      echo "  - Generate secrets: openssl rand -hex 32"
      echo "  - Set TELEGRAM_API_ID + TELEGRAM_API_HASH if using Telegram bridge"
      echo "  - Flip ENABLE_BRIDGE_* flags"
      echo ""
      echo "Then re-run: ./setup.sh"
      exit 0
    fi
    chmod 600 "$SCRIPT_DIR/.env"
    load_env

    # ── 5. OS auto-update ────────────────────────────────────────────────────
    if [[ "${INSTALL_OS_AUTOUPDATE:-false}" == "true" ]]; then
      "$SCRIPT_DIR/install-os-autoupdate.sh"
    fi

    # ── 6. NVIDIA Container Toolkit (stt-gpu only) ───────────────────────────
    if [[ "${STT_GPU:-false}" == "true" ]]; then
      if ! command -v nvidia-smi &>/dev/null; then
        die "nvidia-smi not found — install NVIDIA drivers and enable GPU passthrough in the LXC config, then re-run"
      fi

      # Use dpkg-query for reliable installed-only check (excludes rc state)
      if ! dpkg-query -W -f='${Status}' nvidia-container-toolkit 2>/dev/null | grep -q "install ok installed"; then
        log "Installing NVIDIA Container Toolkit"
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
          | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -sSL \
          https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
          | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
          > /etc/apt/sources.list.d/nvidia-container-toolkit.list
        apt-get update -qq
        apt-get install -y nvidia-container-toolkit
      fi

      nvidia-ctk runtime configure --runtime=docker
      systemctl restart docker
      log "Running GPU smoke test..."
      docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi \
        || die "GPU smoke test failed — check LXC GPU passthrough and NVIDIA driver compatibility"
    fi

    # ── 7. Render configs; read active profiles ──────────────────────────────
    "$SCRIPT_DIR/render-configs.sh"
    PROFILES=$(cat "$SCRIPT_DIR/.compose-profiles")
    export COMPOSE_PROFILES="$PROFILES"
    log "Active profiles: $PROFILES"

    # ── 8. First-run: postgres + synapse ─────────────────────────────────────
    cd "$SCRIPT_DIR"
    docker compose up -d postgres

    log "Waiting for postgres to be healthy..."
    WAITED=0
    until docker compose ps postgres 2>/dev/null | grep -q "healthy"; do
      if [[ "$WAITED" -ge 60 ]]; then
        die "postgres did not become healthy after 60 seconds — check logs: docker compose logs postgres"
      fi
      sleep 1
      (( WAITED++ ))
    done
    ok "postgres is healthy"

    # Generate Synapse signing key (idempotent)
    docker compose run --rm synapse generate || true

    docker compose up -d synapse caddy

    log "Waiting for Synapse to be ready..."
    WAITED=0
    until curl -sf http://localhost:8008/_matrix/client/versions >/dev/null 2>&1; do
      if [[ "$WAITED" -ge 60 ]]; then
        die "Synapse did not become ready after 60 seconds — check logs: docker compose logs synapse"
      fi
      sleep 1
      (( WAITED++ ))
    done
    ok "Synapse is ready"

    # ── 9. Per-bridge Postgres DBs (idempotent) ──────────────────────────────
    for b in whatsapp telegram signal discord meta; do
      docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
        -c "CREATE DATABASE ${POSTGRES_DB}_${b};" 2>/dev/null || true
    done

    # ── 10. Register admin user (idempotent) ─────────────────────────────────
    docker compose exec -T synapse register_new_matrix_user \
      -u "$SYNAPSE_ADMIN_USER" -p "$SYNAPSE_ADMIN_PASSWORD" -a \
      -k "$SYNAPSE_REGISTRATION_SHARED_SECRET" http://localhost:8008 2>/dev/null || true

    # ── 11. Register STT bot user (if enabled) ───────────────────────────────
    if [[ "${ENABLE_STT_BOT:-false}" == "true" ]]; then
      docker compose exec -T synapse register_new_matrix_user \
        -u "$STT_BOT_USER_LOCALPART" -p "$STT_BOT_PASSWORD" --no-admin \
        -k "$SYNAPSE_REGISTRATION_SHARED_SECRET" http://localhost:8008 2>/dev/null || true
    fi

    # ── 12. Per-bridge: generate registration.yaml ───────────────────────────
    mkdir -p "$SCRIPT_DIR/synapse/appservices"
    for b in whatsapp telegram signal discord meta; do
      flag_var="ENABLE_BRIDGE_${b^^}"
      if [[ "${!flag_var:-false}" == "true" ]]; then
        if [[ ! -f "$SCRIPT_DIR/bridges/${b}/registration.yaml" ]]; then
          log "Generating registration for mautrix-${b}..."
          docker compose run --rm "mautrix-${b}" \
            -g -c /data/config.yaml -r /data/registration.yaml \
            || warn "Registration gen failed for ${b} — bridge may not work"
        fi
        if [[ -f "$SCRIPT_DIR/bridges/${b}/registration.yaml" ]]; then
          cp -f "$SCRIPT_DIR/bridges/${b}/registration.yaml" \
                "$SCRIPT_DIR/synapse/appservices/${b}-registration.yaml"
        else
          warn "No registration.yaml for ${b} — skipping appservice registration"
        fi
      fi
    done

    # ── 13. Restart Synapse to load appservices ──────────────────────────────
    docker compose restart synapse
    sleep 5

    # ── 14. Build GPU image if needed ────────────────────────────────────────
    if [[ "$PROFILES" == *"stt-gpu"* ]]; then
      log "Building GPU image (this may take a while)..."
      docker compose build matrix-stt-bot-gpu
    fi

    # ── 15. Bring everything up ───────────────────────────────────────────────
    docker compose up -d
    ok "Stack is up."
    echo ""
    echo "Matrix homeserver:  https://${PUBLIC_DOMAIN:-$MATRIX_DOMAIN}"
    echo "Admin user:         @${SYNAPSE_ADMIN_USER}:${MATRIX_DOMAIN}"
    echo ""
    echo "Next steps:"
    echo "  1. Log in via Element: https://app.element.io"
    echo "  2. DM each bridge bot to link accounts (see README.md)"
    if [[ "${ENABLE_STT_BOT:-false}" == "true" ]]; then
      echo "  3. Invite @${STT_BOT_USER_LOCALPART:-stt-bot}:${MATRIX_DOMAIN} into rooms"
      echo "  4. Update STT_BOT_ROOM_ID in .env, re-run ./setup.sh"
    fi
    ;;

  rebuild-gpu)
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    export SCRIPT_DIR
    load_env
    cd "$SCRIPT_DIR"
    PROFILES=$(cat "$SCRIPT_DIR/.compose-profiles" 2>/dev/null || echo "")
    export COMPOSE_PROFILES="$PROFILES"
    docker compose build matrix-stt-bot-gpu --no-cache
    docker compose up -d matrix-stt-bot-gpu
    ok "GPU image rebuilt and restarted."
    ;;

  register-user)
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    export SCRIPT_DIR
    load_env
    cd "$SCRIPT_DIR"
    read -rp "Username: " USERNAME
    read -rs -p "Password: " PASSWORD
    echo
    read -rp "Admin? [y/N]: " IS_ADMIN
    ADMIN_FLAG="--no-admin"
    # shellcheck disable=SC2015
    [[ "$IS_ADMIN" =~ ^[Yy]$ ]] && ADMIN_FLAG="-a" || true
    # shellcheck disable=SC2086
    docker compose exec -T synapse register_new_matrix_user \
      -u "$USERNAME" -p "$PASSWORD" $ADMIN_FLAG \
      -k "$SYNAPSE_REGISTRATION_SHARED_SECRET" http://localhost:8008
    ;;

  *)
    die "Unknown subcommand: $CMD"
    ;;
esac
