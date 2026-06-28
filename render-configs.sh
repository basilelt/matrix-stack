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
"${SCRIPT_DIR}/postgres/data" \
  "${SCRIPT_DIR}/stickers/web/packs" \
  "${SCRIPT_DIR}/stickers/data" \
  "${SCRIPT_DIR}/stickers/input" \
  "${SCRIPT_DIR}/bridges/whatsapp/data" \
  "${SCRIPT_DIR}/bridges/telegram/data" \
  "${SCRIPT_DIR}/bridges/signal/data" \
  "${SCRIPT_DIR}/bridges/discord/data" \
  "${SCRIPT_DIR}/bridges/slack/data" \
  "${SCRIPT_DIR}/bridges/gmessages/data" \
  "${SCRIPT_DIR}/bridges/twitter/data" \
  "${SCRIPT_DIR}/bridges/googlechat/data" \
  "${SCRIPT_DIR}/bridges/linkedin/data" \
  "${SCRIPT_DIR}/bridges/meta-fb/data" \
  "${SCRIPT_DIR}/bridges/meta-ig/data"
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
    handle /.well-known/matrix/server {{
        header Content-Type application/json
        respond `{{"m.server":"{matrix_domain}:443"}}` 200
    }}
    handle /.well-known/matrix/client {{
        header Content-Type application/json
        header Access-Control-Allow-Origin *
        respond `{{"m.homeserver":{{"base_url":"https://{matrix_domain}"}},"m.identity_server":{{"base_url":"https://vector.im"}}}}` 200
    }}
    handle /.well-known/matrix/mautrix {{
        header Content-Type application/json
        header Access-Control-Allow-Origin *
        respond `{{"fi.mau.bridges":["https://{matrix_domain}/bridge/discord","https://{matrix_domain}/bridge/gmessages","https://{matrix_domain}/bridge/googlechat","https://{matrix_domain}/bridge/linkedin","https://{matrix_domain}/bridge/meta-fb","https://{matrix_domain}/bridge/meta-ig","https://{matrix_domain}/bridge/signal","https://{matrix_domain}/bridge/slack","https://{matrix_domain}/bridge/telegram","https://{matrix_domain}/bridge/twitter","https://{matrix_domain}/bridge/whatsapp"]}}` 200
    }}
    handle_path /bridge/discord/* {{
        reverse_proxy mautrix-discord:29334
    }}
    handle_path /bridge/gmessages/* {{
        reverse_proxy mautrix-gmessages:29336
    }}
    handle_path /bridge/googlechat/* {{
        reverse_proxy mautrix-googlechat:29338
    }}
    handle_path /bridge/linkedin/* {{
        reverse_proxy mautrix-linkedin:29341
    }}
    handle_path /bridge/meta-fb/* {{
        reverse_proxy mautrix-meta-fb:29340
    }}
    handle_path /bridge/meta-ig/* {{
        reverse_proxy mautrix-meta-ig:29341
    }}
    handle_path /bridge/signal/* {{
        reverse_proxy mautrix-signal:29328
    }}
    handle_path /bridge/slack/* {{
        reverse_proxy mautrix-slack:29335
    }}
    handle_path /bridge/telegram/* {{
        reverse_proxy mautrix-telegram:29317
    }}
    handle_path /bridge/twitter/* {{
        reverse_proxy mautrix-twitter:29337
    }}
    handle_path /bridge/whatsapp/* {{
        reverse_proxy mautrix-whatsapp:29318
    }}
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
    handle_path /stickerpicker/* {{
        root * /srv/stickerpicker
        file_server
    }}
    handle {{
        respond "Matrix server. Use a Matrix client like Element." 200
    }}
""").format(caddy_port=caddy_port, matrix_domain=os.environ.get("PUBLIC_DOMAIN", os.environ.get("MATRIX_DOMAIN", "example.com")))

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
bridges = ["whatsapp", "telegram", "signal", "discord", "slack", "gmessages", "twitter", "googlechat", "linkedin", "meta-fb", "meta-ig"]
appservice_files = []
# Always include doublepuppet appservice if it exists
dp_reg = os.path.join(script_dir, "synapse", "appservices", "doublepuppet-registration.yaml")
if os.path.exists(dp_reg):
    appservice_files.append("/data/appservices/doublepuppet-registration.yaml")
for bridge in bridges:
    key = f"ENABLE_BRIDGE_{bridge.upper().replace('-', '_')}"
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
    "signing_key_path": f"/data/{matrix_domain}.signing.key",
    "trusted_key_servers": [{"server_name": "matrix.org"}],
    "suppress_key_server_warning": True,
    "experimental_features": {"msc2716_enabled": True, "msc4190_enabled": True},
    "rc_joins": {
        "local": {"per_second": 100, "burst_count": 500},
        "remote": {"per_second": 10, "burst_count": 100},
    },
    "rc_message": {"per_second": 100, "burst_count": 500},
    "rc_invites": {
        "per_room": {"per_second": 100, "burst_count": 500},
        "per_user": {"per_second": 100, "burst_count": 500},
    },
    "rc_login": {
        "address": {"per_second": 100, "burst_count": 500},
        "account": {"per_second": 100, "burst_count": 500},
        "failed_attempts": {"per_second": 100, "burst_count": 500},
    },
    "auto_accept_invites": {
        "enabled": True,
        "only_for_direct_messages": False,
        "only_from_local_users": True,
    },
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
BRIDGES=(whatsapp telegram signal discord slack gmessages twitter googlechat linkedin meta-fb meta-ig)

for bridge in "${BRIDGES[@]}"; do
  # Convert bridge slug to env-var-safe uppercase: meta-fb → META_FB
  env_key="ENABLE_BRIDGE_$(echo "${bridge}" | tr '[:lower:]-' '[:upper:]_')"
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
# 6. Render translate-bot/config.json from template
###############################################################################

# Extract bridge as_tokens from registration files so the translate-bot config
# can use them to invite itself via the bridge bot on behalf of the appservice.
declare -A _bridge_token_map=(
  [whatsapp]=BRIDGE_TOKEN_WHATSAPP
  [telegram]=BRIDGE_TOKEN_TELEGRAM
  [signal]=BRIDGE_TOKEN_SIGNAL
  [discord]=BRIDGE_TOKEN_DISCORD
  [slack]=BRIDGE_TOKEN_SLACK
  [gmessages]=BRIDGE_TOKEN_GMESSAGES
  [twitter]=BRIDGE_TOKEN_TWITTER
  [googlechat]=BRIDGE_TOKEN_GOOGLECHAT
  [linkedin]=BRIDGE_TOKEN_LINKEDIN
  [meta-fb]=BRIDGE_TOKEN_META_FB
  [meta-ig]=BRIDGE_TOKEN_META_IG
)
for _b in "${!_bridge_token_map[@]}"; do
  _reg="${SCRIPT_DIR}/synapse/appservices/${_b}-registration.yaml"
  _var="${_bridge_token_map[$_b]}"
  if [[ -f "$_reg" ]] && [[ -z "${!_var:-}" ]]; then
    _tok="$(grep '^as_token:' "$_reg" | awk '{print $2}')"
    [[ -n "$_tok" ]] && export "${_var}=${_tok}"
  fi
done
unset _b _reg _var _tok

log "Rendering translate-bot/config.json..."
TRANSLATE_BOT_TMPL="${SCRIPT_DIR}/translate-bot/config.json.tmpl"
TRANSLATE_BOT_OUT="${SCRIPT_DIR}/translate-bot/config.json"

if [[ "${ENABLE_TRANSLATE_BOT:-false}" != "true" ]]; then
  log "  translate-bot disabled (ENABLE_TRANSLATE_BOT != true) — skipping."
elif [[ ! -f "${TRANSLATE_BOT_TMPL}" ]]; then
  warn "translate-bot/config.json.tmpl not found — skipping."
else
  TMPL_PATH="${TRANSLATE_BOT_TMPL}" OUT_PATH="${TRANSLATE_BOT_OUT}" \
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
  ok "translate-bot/config.json rendered."
fi

###############################################################################
# 8. Render claude-notify-bot/config.json from template
###############################################################################

log "Rendering claude-notify-bot/config.json..."
CLAUDE_NOTIFY_TMPL="${SCRIPT_DIR}/claude-notify-bot/config.json.tmpl"
CLAUDE_NOTIFY_OUT="${SCRIPT_DIR}/claude-notify-bot/config.json"

if [[ "${ENABLE_CLAUDE_NOTIFY:-false}" != "true" ]]; then
  log "  claude-notify-bot disabled (ENABLE_CLAUDE_NOTIFY != true) — skipping."
elif [[ ! -f "${CLAUDE_NOTIFY_TMPL}" ]]; then
  warn "claude-notify-bot/config.json.tmpl not found — skipping."
else
  TMPL_PATH="${CLAUDE_NOTIFY_TMPL}" OUT_PATH="${CLAUDE_NOTIFY_OUT}" \
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
  ok "claude-notify-bot/config.json rendered."
fi

###############################################################################
# 9. Render cookie-refresher/config.json from template
###############################################################################

log "Rendering cookie-refresher/config.json..."
COOKIE_REFRESHER_TMPL="${SCRIPT_DIR}/cookie-refresher/config.json.tmpl"
COOKIE_REFRESHER_OUT="${SCRIPT_DIR}/cookie-refresher/config.json"

if [[ "${ENABLE_COOKIE_REFRESHER:-false}" != "true" ]]; then
  log "  cookie-refresher disabled (ENABLE_COOKIE_REFRESHER != true) — skipping."
elif [[ ! -f "${COOKIE_REFRESHER_TMPL}" ]]; then
  warn "cookie-refresher/config.json.tmpl not found — skipping."
else
  TMPL_PATH="${COOKIE_REFRESHER_TMPL}" OUT_PATH="${COOKIE_REFRESHER_OUT}" \
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
  ok "cookie-refresher/config.json rendered."
fi

###############################################################################
# 9b. Render stickers/config.json from template
###############################################################################

log "Rendering stickers/config.json..."
STICKERS_TMPL="${SCRIPT_DIR}/stickers/config.json.tmpl"
STICKERS_OUT="${SCRIPT_DIR}/stickers/config.json"

if [[ "${ENABLE_STICKERS:-false}" != "true" ]]; then
  log "  stickers disabled (ENABLE_STICKERS != true) — skipping."
elif [[ ! -f "${STICKERS_TMPL}" ]]; then
  warn "stickers/config.json.tmpl not found — skipping."
else
  TMPL_PATH="${STICKERS_TMPL}" OUT_PATH="${STICKERS_OUT}" \
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
  ok "stickers/config.json rendered."
fi

###############################################################################
# 9. Compute and write COMPOSE_PROFILES
###############################################################################

log "Computing Docker Compose profiles..."
PROFILES=()

for bridge in "${BRIDGES[@]}"; do
  env_key="ENABLE_BRIDGE_$(echo "${bridge}" | tr '[:lower:]-' '[:upper:]_')"
  bridge_enabled="${!env_key:-false}"
  if [[ "${bridge_enabled}" == "true" ]]; then
    PROFILES+=("${bridge}")
  fi
done

if [[ "${ENABLE_TRANSLATE_BOT:-false}" == "true" ]]; then
  PROFILES+=("translate")
fi

if [[ "${ENABLE_COOKIE_REFRESHER:-false}" == "true" ]]; then
  PROFILES+=("cookie-refresher")
fi

if [[ "${ENABLE_CLAUDE_NOTIFY:-false}" == "true" ]]; then
  PROFILES+=("claude-notify")
fi

if [[ "${ENABLE_STICKERS:-false}" == "true" ]]; then
  PROFILES+=("stickers")
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

ok "render-configs.sh complete."
