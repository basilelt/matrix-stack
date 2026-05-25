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

    # ── 8. Start postgres; create per-bridge DBs ─────────────────────────────
    cd "$SCRIPT_DIR"
    docker compose up -d postgres

    log "Waiting for postgres to be healthy..."
    WAITED=0
    until docker compose ps postgres 2>/dev/null | grep -q "healthy"; do
      if [[ "$WAITED" -ge 120 ]]; then
        die "postgres did not become healthy after 120 seconds — check logs: docker compose logs postgres"
      fi
      sleep 2
      (( WAITED += 2 ))
    done
    ok "postgres is healthy"

    for b in whatsapp telegram signal discord slack gmessages twitter googlechat linkedin meta-fb meta-ig; do
      # Strip hyphens for valid postgres DB name (meta-fb → metafb)
      db_slug="${b//-/}"
      docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
        -c "CREATE DATABASE ${POSTGRES_DB}_${db_slug};" 2>/dev/null || true
    done

    # ── 9. Generate bridge registrations BEFORE Synapse starts ───────────────
    # homeserver.yaml references appservices/*.yaml, so they must exist first.
    # mautrix v2 (megabridge) bridges: auto-generate default config, patch fields, then register.
    mkdir -p "$SCRIPT_DIR/synapse/appservices"
    for b in whatsapp telegram signal discord slack gmessages twitter googlechat linkedin meta-fb meta-ig; do
      # Convert slug to env-var key: meta-fb → ENABLE_BRIDGE_META_FB
      flag_var="ENABLE_BRIDGE_$(echo "${b}" | tr '[:lower:]-' '[:upper:]_')"
      [[ "${!flag_var:-false}" == "true" ]] || continue

      db_slug="${b//-/}"   # strip hyphens for postgres DB name
      svc="mautrix-${b}"  # docker compose service name

      if [[ ! -f "$SCRIPT_DIR/bridges/${b}/registration.yaml" ]]; then
        log "Bootstrapping ${svc} config..."
        mkdir -p "$SCRIPT_DIR/bridges/${b}"
        bridge_cfg="$SCRIPT_DIR/bridges/${b}/config.yaml"

        case "$b" in
          linkedin|googlechat)
            # Python bridges: rely on template rendered by render-configs.sh
            if [[ ! -f "$bridge_cfg" ]]; then
              warn "No config for ${b} — run render-configs.sh first, then re-run setup.sh"
              continue
            fi
            ;;
          *)
            # Go megabridge: auto-generate default config, then patch
            rm -f "$bridge_cfg"
            docker compose run --rm "$svc" 2>&1 | grep -v "^$" || true

            if [[ ! -f "$bridge_cfg" ]]; then
              warn "Config auto-generation failed for ${b} — skipping"
              continue
            fi

            # Generic patches
            # Note: DB URI sed must strip any trailing quote that auto-gen leaves: sslmode=disable"
            sed -i \
              -e "s|address: http://example.localhost:8008|address: http://synapse:8008|" \
              -e "s|    domain: example.com|    domain: ${MATRIX_DOMAIN}|" \
              -e "s|uri: .*sslmode=disable.*|uri: postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres/${POSTGRES_DB}_${db_slug}?sslmode=disable|" \
              -e "s|    hostname: 127.0.0.1|    hostname: 0.0.0.0|" \
              -e "s|address: http://localhost:\([0-9]*\)|address: http://${svc}:\1|" \
              -e "s|\"example.com\": user|\"${MATRIX_DOMAIN}\": user|" \
              -e "s|\"@admin:example.com\": admin|\"@${SYNAPSE_ADMIN_USER}:${MATRIX_DOMAIN}\": admin|" \
              -e "s|\"\\*\": relaybot|\"*\": relay|" \
              -e "s|\": full\"|\": user\"|" \
              -e "s|^    allow: false$|    allow: true|" \
              -e "s|^    default: false$|    default: true|" \
              "$bridge_cfg"
            # Fix username template from Python-era format to mautrix-go {{.}} style
            sed -i -E "s|username_template: ([a-z_]+)_\{[a-z_]+\}|username_template: \"\1_{{.}}\"|" "$bridge_cfg"

            # Enable E2EE, backfill, avatars, full sync
            python3 - "$bridge_cfg" <<'PY'
import sys, re, secrets as _sec

path = sys.argv[1]
content = open(path).read()

# E2EE: allow, default, self_sign, msc4190, pickle_key rotation, allow_key_sharing
in_enc = False; enc_indent = None; lines = content.split('\n'); out = []
enc_keys_seen = set()

def flush_missing(enc_indent, enc_keys_seen, out):
    ins = ' ' * (enc_indent + 4)
    if 'self_sign' not in enc_keys_seen:
        out.append(f'{ins}self_sign: true')
    if 'msc4190' not in enc_keys_seen:
        out.append(f'{ins}msc4190: true')

for line in lines:
    s = line.lstrip(); indent = len(line) - len(s)
    if s.startswith('encryption:'):
        in_enc = True; enc_indent = indent; enc_keys_seen = set()
    elif in_enc and s and not s.startswith('#') and indent <= enc_indent:
        flush_missing(enc_indent, enc_keys_seen, out)
        in_enc = False
    if in_enc:
        m = re.match(r'\s+(\w+):', line)
        if m: enc_keys_seen.add(m.group(1))
        if re.match(r'\s+allow: false', line): line = line.replace('allow: false', 'allow: true')
        if re.match(r'\s+default: false', line): line = line.replace('default: false', 'default: true')
        if re.match(r'\s+self_sign: false', line): line = line.replace('self_sign: false', 'self_sign: true')
        if re.match(r'\s+msc4190: false', line): line = line.replace('msc4190: false', 'msc4190: true')
        if re.match(r'\s+allow_key_sharing: false', line): line = line.replace('allow_key_sharing: false', 'allow_key_sharing: true')
        if re.match(r'\s+pickle_key: mautrix\.bridge\.e2ee\s*$', line):
            line = line.replace('pickle_key: mautrix.bridge.e2ee', f'pickle_key: {_sec.token_hex(32)}')
    out.append(line)
if in_enc:
    flush_missing(enc_indent, enc_keys_seen, out)
content = '\n'.join(out)

# Backfill
content = content.replace('    enabled: false\n    # Maximum number of messages',
                           '    enabled: true\n    # Maximum number of messages')
content = re.sub(r'max_initial_messages: \d+', 'max_initial_messages: 500', content, count=1)
content = re.sub(r'max_catchup_messages: \d+', 'max_catchup_messages: 5000', content, count=1)

# Avatars / profile info
for old, new in [
    ('contact_avatars: false', 'contact_avatars: true'),
    ('use_contact_avatars: false', 'use_contact_avatars: true'),
    ('contact_names: false', 'contact_names: true'),
    ('phone_numbers_in_profile: false', 'phone_numbers_in_profile: true'),
    ('ghost_extra_profile_info: false', 'ghost_extra_profile_info: true'),
    ('login_sync_limit: 15', 'login_sync_limit: -1'),
    ('forward_backfill: false', 'forward_backfill: true'),
    ('backward_backfill: false', 'backward_backfill: true'),
    ('sync_direct_chat_list: false', 'sync_direct_chat_list: true'),
    ('enable_webhook_avatars: false', 'enable_webhook_avatars: true'),
]:
    content = content.replace(old, new)

open(path, 'w').write(content)
PY

            # Bridge-specific patches
            case "$b" in
              meta-fb)
                sed -i \
                  -e "s|^    id: meta$|    id: meta-fb|" \
                  -e "s|bot_username: metabot|bot_username: messengerbot|" \
                  "$bridge_cfg"
                ;;
              meta-ig)
                sed -i \
                  -e "s|^    id: meta$|    id: meta-ig|" \
                  -e "s|bot_username: metabot|bot_username: instagrambot|" \
                  -e "s|mode: messenger|mode: instagram|" \
                  "$bridge_cfg"
                ;;
            esac

            log "Config patched for ${b}"
            ;;
        esac

        # Generate registration
        log "Generating registration for ${svc}..."
        case "$b" in
          meta-fb|meta-ig)
            docker compose run --rm --entrypoint "/usr/bin/mautrix-meta" "$svc" \
              -g -c /data/config.yaml -r /data/registration.yaml 2>&1 \
              || warn "Registration gen failed for ${b}"
            ;;
          linkedin|googlechat)
            # Python bridges: use container's default entrypoint
            docker compose run --rm "$svc" \
              -g -c /data/config.yaml -r /data/registration.yaml 2>&1 \
              || warn "Registration gen failed for ${b}"
            ;;
          *)
            docker compose run --rm --entrypoint "/usr/bin/mautrix-${b}" "$svc" \
              -g -c /data/config.yaml -r /data/registration.yaml 2>&1 \
              || warn "Registration gen failed for ${b}"
            ;;
        esac
      fi

      if [[ -f "$SCRIPT_DIR/bridges/${b}/registration.yaml" ]]; then
        cp -f "$SCRIPT_DIR/bridges/${b}/registration.yaml" \
              "$SCRIPT_DIR/synapse/appservices/${b}-registration.yaml"
      else
        warn "No registration.yaml for ${b} — skipping appservice registration"
      fi
    done

    # ── 9b. Doublepuppet appservice registration + wire secrets into bridge configs
    dp_reg="$SCRIPT_DIR/synapse/appservices/doublepuppet-registration.yaml"
    if [[ ! -f "$dp_reg" ]]; then
      [[ -n "${DOUBLE_PUPPET_SECRET:-}" ]] || DOUBLE_PUPPET_SECRET="$(openssl rand -hex 32)"
      cat > "$dp_reg" <<DPREG
id: doublepuppet
url: null
as_token: ${DOUBLE_PUPPET_SECRET}
hs_token: $(openssl rand -hex 32)
sender_localpart: doublepuppet_$(openssl rand -hex 6)
namespaces:
  users:
    - regex: '@.*:${MATRIX_DOMAIN}'
      exclusive: false
  rooms: []
  aliases: []
DPREG
      log "Created doublepuppet appservice registration"
    fi

    dp_token="$(grep '^as_token:' "$dp_reg" | awk '{print $2}')"
    for b in whatsapp telegram signal discord slack gmessages twitter googlechat linkedin meta-fb meta-ig; do
      bridge_cfg="$SCRIPT_DIR/bridges/${b}/config.yaml"
      [[ -f "$bridge_cfg" ]] || continue
      python3 - "$bridge_cfg" "$MATRIX_DOMAIN" "$dp_token" <<'DPPY'
import sys, re

path, domain, token = sys.argv[1], sys.argv[2], sys.argv[3]
content = open(path).read()

# Modern format: double_puppet:\n    secrets:\n (empty block → add entry)
pat_modern = re.compile(r'(^double_puppet:\n(?:    [^\n]*\n)*?    secrets:\n)(    [^\n]*\n)*', re.M)
def inject_modern(m):
    block = m.group(0)
    if f'{domain}:' in block:
        return block  # already wired
    indent = '        '
    return block + f'{indent}{domain}: as_token:{token}\n'
new = pat_modern.sub(inject_modern, content)

# Old format: login_shared_secret_map: {} → wire under bridge:
pat_old = re.compile(r'(    login_shared_secret_map:) \{\}')
if pat_old.search(new) and f'login_shared_secret_map:' not in new.replace('    login_shared_secret_map: {}', ''):
    new = pat_old.sub(f'\\1\n        {domain}: {token}', new)

if new != content:
    open(path, 'w').write(new)
    print(f'  Wired double_puppet for {path}')
DPPY
    done

    # ── 10. Re-render configs with appservice paths now that registrations exist
    "$SCRIPT_DIR/render-configs.sh"

    # ── 11. Start Synapse + Caddy ─────────────────────────────────────────────
    # Generate signing key (idempotent, must run before synapse service starts)
    docker compose run --rm synapse generate || true

    docker compose up -d synapse caddy

    log "Waiting for Synapse to be ready..."
    WAITED=0
    until curl -sf http://localhost:8008/_matrix/client/versions >/dev/null 2>&1; do
      if [[ "$WAITED" -ge 90 ]]; then
        die "Synapse did not become ready after 90 seconds — check logs: docker compose logs synapse"
      fi
      sleep 2
      (( WAITED += 2 ))
    done
    ok "Synapse is ready"

    # ── 12. Register admin user (idempotent) ─────────────────────────────────
    docker compose exec -T synapse register_new_matrix_user \
      -u "$SYNAPSE_ADMIN_USER" -p "$SYNAPSE_ADMIN_PASSWORD" -a \
      -k "$SYNAPSE_REGISTRATION_SHARED_SECRET" http://localhost:8008 2>/dev/null || true

    # ── 13. Register STT bot user (if enabled) ───────────────────────────────
    if [[ "${ENABLE_STT_BOT:-false}" == "true" ]]; then
      docker compose exec -T synapse register_new_matrix_user \
        -u "$STT_BOT_USER_LOCALPART" -p "$STT_BOT_PASSWORD" --no-admin \
        -k "$SYNAPSE_REGISTRATION_SHARED_SECRET" http://localhost:8008 2>/dev/null || true
    fi

    # ── 14. Register translate-bot user + build image (if enabled) ───────────
    if [[ "${ENABLE_TRANSLATE_BOT:-false}" == "true" ]]; then
      docker compose exec -T synapse register_new_matrix_user \
        -u "$TRANSLATE_BOT_USER_LOCALPART" -p "$TRANSLATE_BOT_PASSWORD" --no-admin \
        -k "$SYNAPSE_REGISTRATION_SHARED_SECRET" http://localhost:8008 2>/dev/null || true
      log "Building translate-bot image (this may take a while)..."
      docker compose build matrix-translate-bot
    fi

    # ── 14b. Register claude-notify-bot user + build image (if enabled) ─────────
    if [[ "${ENABLE_CLAUDE_NOTIFY:-false}" == "true" ]]; then
      docker compose exec -T synapse register_new_matrix_user \
        -u "${CLAUDE_NOTIFY_USER_LOCALPART:-claude-notify}" -p "$CLAUDE_NOTIFY_PASSWORD" --no-admin \
        -k "$SYNAPSE_REGISTRATION_SHARED_SECRET" http://localhost:8008 2>/dev/null || true
      log "Building claude-notify-bot image..."
      docker compose build claude-notify-bot
    fi

    # ── 15a. Register cookie-refresher user + build image (if enabled) ──────────
    if [[ "${ENABLE_COOKIE_REFRESHER:-false}" == "true" ]]; then
      docker compose exec -T synapse register_new_matrix_user \
        -u "cookie-refresher" -p "${COOKIE_REFRESHER_PASSWORD}" --no-admin \
        -k "$SYNAPSE_REGISTRATION_SHARED_SECRET" http://localhost:8008 2>/dev/null || true
      log "Building cookie-refresher image (Playwright, may take a while)..."
      docker compose build cookie-refresher
    fi

    # ── 15. Build GPU image if needed ────────────────────────────────────────
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
