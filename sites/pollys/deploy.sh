#!/bin/bash
# Build + (re)start the pollys web app. Run by deploy-cli install AND by the
# GitHub self-hosted runner on every push to master. Idempotent.
set -uo pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
SRC="$HOME/dosa-src"

echo "==> pull latest (origin/master)"
git -C "$SRC" fetch origin master --quiet && git -C "$SRC" reset --hard origin/master
SHA="$(git -C "$SRC" rev-parse --short HEAD)"; echo "    $SHA"

echo "==> restore env (.env.local is gitignored)"
[ -f "$HOME/pollys.env.local" ] && cp "$HOME/pollys.env.local" "$SRC/.env.local"

echo "==> install + build"
cd "$SRC" && npm install --no-audit --no-fund --silent && npm run build || { echo "build FAILED"; exit 1; }

echo "==> restart web (systemd --user)"
systemctl --user restart pollys-web
systemctl --user start mongod pollys-cloudflared 2>/dev/null || true

echo "==> health check (localhost)"
PORT="$(systemctl --user show -p Environment pollys-web 2>/dev/null | grep -o 'PORT=[0-9]*' | cut -d= -f2)"; PORT="${PORT:-3100}"
for i in $(seq 1 30); do
  [ "$(curl -s -m 8 -o /dev/null -w '%{http_code}' "http://localhost:$PORT")" = 200 ] && { echo "LIVE :$PORT ($SHA)"; exit 0; }
  sleep 4
done
echo "not healthy yet — systemctl --user status pollys-web"; exit 1
