# lib.sh — shared helpers, source this file (do not execute directly)
# Usage: source "$(dirname "$0")/lib.sh"

log() {
    printf '\033[36m\xe2\x96\xb6 %s\033[0m\n' "$*" >&2
}

ok() {
    printf '\033[32m\xe2\x9c\x93 %s\033[0m\n' "$*"
}

warn() {
    printf '\033[33m! %s\033[0m\n' "$*" >&2
}

die() {
    printf '\033[31m\xe2\x9c\x97 %s\033[0m\n' "$*" >&2
    exit 1
}

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        die "This script must be run as root"
    fi
}

load_env() {
    local env_file="${SCRIPT_DIR:-.}/.env"
    if [[ ! -f "$env_file" ]]; then
        die ".env file not found at $env_file"
    fi
    set -a
    # shellcheck source=.env
    source "$env_file"
    set +a
}

random_secret() {
    openssl rand -hex 32
}
