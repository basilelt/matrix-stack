#!/usr/bin/env bash
set -euo pipefail

cat >/usr/local/bin/signal-release-watch <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd /opt/matrix-stack
grep -qE 'mautrix/signal:[0-9a-f]{40}-amd64' docker-compose.yml || { systemctl disable signal-release-watch.timer; exit 0; }
for v in v0.2612.0 v0.2611.0; do
  docker manifest inspect "dock.mau.dev/mautrix/signal:$v" >/dev/null 2>&1 || continue
  sed -i -E "s#(mautrix/signal:)[0-9a-f]{40}-amd64#\1$v#" docker-compose.yml
  COMPOSE_PROFILES="$(cat .compose-profiles)" docker compose up -d mautrix-signal
  echo "switched mautrix-signal to $v"
  systemctl disable signal-release-watch.timer
  exit 0
done
echo "no release yet"
EOF
chmod +x /usr/local/bin/signal-release-watch

cat >/etc/systemd/system/signal-release-watch.service <<'EOF'
[Unit]
Description=Move mautrix-signal from interim main build to first calver release
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/signal-release-watch
EOF

cat >/etc/systemd/system/signal-release-watch.timer <<'EOF'
[Unit]
Description=Check for mautrix-signal release every 6h

[Timer]
OnCalendar=*-*-* 00/6:17:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now signal-release-watch.timer
