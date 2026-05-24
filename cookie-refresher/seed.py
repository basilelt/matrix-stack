#!/usr/bin/env python3
"""Seed credentials for the cookie-refresher vault.

Usage (inside the container or with COOKIE_REFRESHER_KEY set):
  python3 seed.py <bridge>      # add/update credentials for <bridge>
  python3 seed.py --list        # list which bridges have credentials stored
  python3 seed.py --remove <bridge>  # delete credentials for a bridge

Supported bridges: twitter, slack, meta-fb, meta-ig, linkedin
"""
import getpass
import json
import os
import sys
from pathlib import Path

from cryptography.fernet import Fernet


def get_fernet() -> Fernet:
    key = os.environ.get("COOKIE_REFRESHER_KEY", "").strip()
    if not key:
        sys.exit("ERROR: COOKIE_REFRESHER_KEY env var not set")
    return Fernet(key.encode())


def load(path: Path, fernet: Fernet) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(fernet.decrypt(path.read_bytes()))
    except Exception as e:
        sys.exit(f"ERROR: Could not decrypt {path}: {e}")


def save(path: Path, fernet: Fernet, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(fernet.encrypt(json.dumps(data).encode()))
    print(f"Saved to {path}")


SECRETS_PATH = Path(os.environ.get("SECRETS_PATH", "/app/data/secrets.enc"))

BRIDGE_FIELDS = {
    "twitter":  [("username", False), ("password", True)],
    "slack":    [("email", False), ("password", True), ("workspace_url", False), ("totp_secret", True)],
    "meta-fb":  [("email", False), ("password", True), ("totp_secret", True)],
    "meta-ig":  [("username", False), ("password", True), ("totp_secret", True)],
    "linkedin": [("email", False), ("password", True), ("totp_secret", True)],
}


def prompt_fields(bridge: str) -> dict:
    fields = BRIDGE_FIELDS.get(bridge)
    if not fields:
        sys.exit(f"Unknown bridge: {bridge}. Valid: {', '.join(BRIDGE_FIELDS)}")
    creds = {}
    print(f"\nEnter credentials for {bridge}:")
    print("(Leave blank to skip optional fields)\n")
    for field, secret in fields:
        optional = field == "totp_secret" or (bridge == "slack" and field == "workspace_url")
        label = f"  {field}{'  (optional)' if optional else ''}: "
        if secret:
            val = getpass.getpass(label)
        else:
            val = input(label).strip()
        if val:
            creds[field] = val
        elif not optional:
            sys.exit(f"ERROR: {field} is required")
    return creds


def main():
    args = sys.argv[1:]
    fernet = get_fernet()
    secrets = load(SECRETS_PATH, fernet)

    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return

    if args[0] == "--list":
        if not secrets:
            print("No credentials stored.")
        else:
            print("Bridges with stored credentials:")
            for b in secrets:
                print(f"  {b}")
        return

    if args[0] == "--remove":
        if len(args) < 2:
            sys.exit("Usage: seed.py --remove <bridge>")
        bridge = args[1]
        if bridge in secrets:
            del secrets[bridge]
            save(SECRETS_PATH, fernet, secrets)
            print(f"Removed credentials for {bridge}")
        else:
            print(f"No credentials found for {bridge}")
        return

    bridge = args[0]
    creds = prompt_fields(bridge)
    secrets[bridge] = creds
    save(SECRETS_PATH, fernet, secrets)
    print(f"\nCredentials stored for {bridge}.")
    print("Enable auto-refresh in config.json by setting \"enabled\": true for this bridge,")
    print("then restart the cookie-refresher container.")


if __name__ == "__main__":
    main()
