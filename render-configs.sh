#!/usr/bin/env bash
# render-configs.sh — Main config renderer for the matrix-stack.
# Run from /opt/matrix-stack/ after copying .env.
# Usage: bash render-configs.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

load_env
require_root

###############################################################################
# 1. Create directory structure
###############################################################################

log "Creating directory structure..."
mkdir -p \
  "${SCRIPT_DIR}/caddy/data" \
  "${SCRIPT_DIR}/synapse/appservices" \
  "${SCRIPT_DIR}/synapse/media_store" \
  "${SCRIPT_DIR}/stt-bot/data/db" \
  "${SCRIPT_DIR}/stt-bot/data/models" \
  "${SCRIPT_DIR}/postgres/data" \
  "${SCRIPT_DIR}/bridges/whatsapp/data" \
  "${SCRIPT_DIR}/bridges/telegram/data" \
  "${SCRIPT_DIR}/bridges/signal/data" \
  "${SCRIPT_DIR}/bridges/discord/data" \
  "${SCRIPT_DIR}/bridges/meta/data"
ok "Directories created."

###############################################################################
# 2. Render caddy/Caddyfile
###############################################################################

log "Rendering caddy/Caddyfile..."
python3 - <<'PY'
import os, textwrap

caddy_port = os.environ.get("CADDY_PORT", "8080")

# Caddy uses its own {placeholder} syntax — NOT shell/Python variables.
# We use a regular string and only substitute caddy_port via Python.
content = textwrap.dedent("""\
    {{
        auto_https off
    }}
    :{caddy_port}
    handle /_matrix/* {{
        reverse_proxy synapse:8008 {{
            header_up X-Forwarded-For {{remote_host}}
            header_up X-Forwarded-Proto https
        }}
    }}
    handle /_synapse/client/* {{
        reverse_proxy synapse:8008 {{
            header_up X-Forwarded-For {{remote_host}}
            header_up X-Forwarded-Proto https
        }}
    }}
    handle {{
        respond "Matrix server. Use a Matrix client like Element." 200
    }}
""").format(caddy_port=caddy_port)

out_path = os.path.join(os.environ.get("SCRIPT_DIR", "."), "caddy", "Caddyfile")
with open(out_path, "w") as f:
    f.write(content)
print(f"  Written: {out_path}")
PY
ok "caddy/Caddyfile rendered."

###############################################################################
# 3. Render synapse/homeserver.yaml
###############################################################################

log "Rendering synapse/homeserver.yaml..."
python3 - <<'PY'
import json, os

env = os.environ

matrix_domain   = env["MATRIX_DOMAIN"]
public_domain   = env["PUBLIC_DOMAIN"]
postgres_user   = env["POSTGRES_USER"]
postgres_pass   = env["POSTGRES_PASSWORD"]
postgres_db     = env["POSTGRES_DB"]
reg_secret      = env["SYNAPSE_REGISTRATION_SHARED_SECRET"]
allow_reg_str   = env.get("ALLOW_REGISTRATION", "false").strip().lower()
allow_reg       = allow_reg_str == "true"
fed_enabled_str = env.get("FEDERATION_ENABLED", "false").strip().lower()
fed_enabled     = fed_enabled_str == "true"
script_dir      = env.get("SCRIPT_DIR", ".")

# Build list of enabled bridge appservice config files.
# Only include files that already exist on disk — allows a two-phase startup
# where registrations are generated first, then homeserver.yaml is re-rendered.
import os
bridges = ["whatsapp", "telegram", "signal", "discord", "meta"]
appservice_files = []
for bridge in bridges:
    key = f"ENABLE_BRIDGE_{bridge.upper()}"
    if env.get(key, "false").strip().lower() == "true":
        reg_path = os.path.join(script_dir, "synapse", "appservices", f"{bridge}-registration.yaml")
        if os.path.exists(reg_path):
            appservice_files.append(f"/data/appservices/{bridge}-registration.yaml")

cfg = {
    "server_name": matrix_domain,
    "public_baseurl": f"https://{public_domain}/",
    "x_forwarded": True,
    "listeners": [
        {
            "port": 8008,
            "bind_addresses": ["0.0.0.0"],
            "tls": False,
            "type": "http",
            "resources": [
                {
                    "names": ["client", "federation"],
                    "compress": False,
                }
            ],
        }
    ],
    "database": {
        "name": "psycopg2",
        "args": {
            "user": postgres_user,
            "password": postgres_pass,
            "database": postgres_db,
            "host": "postgres",
            "cp_min": 5,
            "cp_max": 10,
        },
    },
    "registration_shared_secret": reg_secret,
    "enable_registration": allow_reg,
    "allow_public_rooms_over_federation": False,
    "federation_domain_whitelist": [] if not fed_enabled else None,
    "media_store_path": "/data/media_store",
    "log_config": "/data/log.config",
    "app_service_config_files": appservice_files,
    "report_stats": False,
    "signing_key_path": "/data/matrix.example.com.signing.key",
    "trusted_key_servers": [{"server_name": "matrix.org"}],
    "suppress_key_server_warning": True,
}

# Remove None values (e.g. federation_domain_whitelist when federation enabled)
cfg = {k: v for k, v in cfg.items() if v is not None}

out_path = os.path.join(script_dir, "synapse", "homeserver.yaml")
with open(out_path, "w") as f:
    # JSON is valid YAML — Synapse parses it fine.
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(f"  Written: {out_path}")
PY
ok "synapse/homeserver.yaml rendered."

###############################################################################
# 4. Render synapse/log.config
###############################################################################

log "Rendering synapse/log.config..."
python3 - <<'PY'
import json, os

script_dir = os.environ.get("SCRIPT_DIR", ".")

# JSON is valid YAML; Synapse accepts it for log.config too.
log_cfg = {
    "version": 1,
    "formatters": {
        "precise": {
            "format": "%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s"
        }
    },
    "handlers": {
        "console": {
            "class": "logging.StreamHandler",
            "formatter": "precise",
        }
    },
    "loggers": {
        "synapse.storage.SQL": {
            "level": "WARNING",
        }
    },
    "root": {
        "level": "INFO",
        "handlers": ["console"],
    },
    "disable_existing_loggers": False,
}

out_path = os.path.join(script_dir, "synapse", "log.config")
with open(out_path, "w") as f:
    json.dump(log_cfg, f, indent=2)
    f.write("\n")
print(f"  Written: {out_path}")
PY
ok "synapse/log.config rendered."

###############################################################################
# 5. Render bridge configs from templates
###############################################################################

log "Rendering bridge configs..."
BRIDGES=(whatsapp telegram signal discord meta)

for bridge in "${BRIDGES[@]}"; do
  env_key="ENABLE_BRIDGE_${bridge^^}"
  bridge_enabled="${!env_key:-false}"

  if [[ "${bridge_enabled}" != "true" ]]; then
    continue
  fi

  tmpl_path="${SCRIPT_DIR}/bridges/${bridge}/config.yaml.tmpl"
  out_path="${SCRIPT_DIR}/bridges/${bridge}/config.yaml"

  # Skip rendering if config.yaml already exists — it was auto-generated by
  # the megabridge container (v2 format) and must not be overwritten by the
  # legacy v0.x template.
  if [[ -f "${out_path}" ]]; then
    log "  Bridge '${bridge}' config already exists — skipping template render."
    continue
  fi

  if [[ ! -f "${tmpl_path}" ]]; then
    warn "Template not found for bridge '${bridge}': ${tmpl_path} — skipping."
    continue
  fi

  log "  Rendering bridge config: ${bridge}"
  SCRIPT_DIR="${SCRIPT_DIR}" TMPL_PATH="${tmpl_path}" OUT_PATH="${out_path}" \
  python3 - <<'PY'
import os, string

tmpl_path = os.environ["TMPL_PATH"]
out_path  = os.environ["OUT_PATH"]

with open(tmpl_path, "r") as f:
    template = string.Template(f.read())

rendered = template.safe_substitute(os.environ)

with open(out_path, "w") as f:
    f.write(rendered)
print(f"  Written: {out_path}")
PY
  ok "  Bridge '${bridge}' config rendered."
done

###############################################################################
# 6. Render stt-bot/config.json from template
###############################################################################

log "Rendering stt-bot/config.json..."
STT_BOT_TMPL="${SCRIPT_DIR}/stt-bot/config.json.tmpl"
STT_BOT_OUT="${SCRIPT_DIR}/stt-bot/config.json"

if [[ "${ENABLE_STT_BOT:-false}" != "true" ]]; then
  log "  stt-bot disabled (ENABLE_STT_BOT != true) — skipping."
elif [[ ! -f "${STT_BOT_TMPL}" ]]; then
  warn "stt-bot/config.json.tmpl not found — skipping."
else
  TMPL_PATH="${STT_BOT_TMPL}" OUT_PATH="${STT_BOT_OUT}" \
  python3 - <<'PY'
import os, string

tmpl_path = os.environ["TMPL_PATH"]
out_path  = os.environ["OUT_PATH"]

with open(tmpl_path, "r") as f:
    template = string.Template(f.read())

rendered = template.safe_substitute(os.environ)

with open(out_path, "w") as f:
    f.write(rendered)
print(f"  Written: {out_path}")
PY
  ok "stt-bot/config.json rendered."
fi

###############################################################################
# 7. Compute and write COMPOSE_PROFILES
###############################################################################

log "Computing Docker Compose profiles..."
PROFILES=()

for bridge in "${BRIDGES[@]}"; do
  env_key="ENABLE_BRIDGE_${bridge^^}"
  bridge_enabled="${!env_key:-false}"
  if [[ "${bridge_enabled}" == "true" ]]; then
    PROFILES+=("${bridge}")
  fi
done

ENABLE_STT_BOT="${ENABLE_STT_BOT:-false}"
STT_GPU="${STT_GPU:-false}"

if [[ "${ENABLE_STT_BOT}" == "true" ]]; then
  if [[ "${STT_GPU}" == "true" ]]; then
    PROFILES+=("stt-gpu")
  else
    PROFILES+=("stt-cpu")
  fi
fi

# Join with commas
COMPOSE_PROFILES_STR=""
for profile in "${PROFILES[@]+"${PROFILES[@]}"}"; do
  if [[ -z "${COMPOSE_PROFILES_STR}" ]]; then
    COMPOSE_PROFILES_STR="${profile}"
  else
    COMPOSE_PROFILES_STR="${COMPOSE_PROFILES_STR},${profile}"
  fi
done

printf '%s\n' "${COMPOSE_PROFILES_STR}" > "${SCRIPT_DIR}/.compose-profiles"
ok "Compose profiles written: ${COMPOSE_PROFILES_STR:-<none>}"

###############################################################################
# 8. Touch stt-bot/element-keys.txt if missing
###############################################################################

if [[ ! -f "${SCRIPT_DIR}/stt-bot/element-keys.txt" ]]; then
  touch "${SCRIPT_DIR}/stt-bot/element-keys.txt"
  log "Touched stt-bot/element-keys.txt"
fi

ok "render-configs.sh complete."
