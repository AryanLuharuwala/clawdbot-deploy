#!/bin/bash
# Build + (re)start BitforBytes. Run by deploy-cli install AND by the GitHub
# self-hosted runner on every push to main. Idempotent; keeps the tunnel up.
set -uo pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
SRC="$HOME/verilog-src"

echo "==> pull latest (origin/main)"
git -C "$SRC" fetch origin main --quiet && git -C "$SRC" reset --hard origin/main
SHA="$(git -C "$SRC" rev-parse --short HEAD)"; echo "    $SHA"

echo "==> restore live preview config + env (reset reverts tracked files)"
[ -f "$HOME/bitforbytes-vite.config.ts" ] && cp "$HOME/bitforbytes-vite.config.ts" "$SRC/frontend/vite.config.ts"
[ -f "$HOME/backend.env" ] && cp "$HOME/backend.env" "$SRC/backend/.env"

echo "==> build frontend"
cd "$SRC/frontend" && npm install --no-audit --no-fund --silent && npm run build || { echo "build FAILED"; exit 1; }
[ -f dist/index.html ] || { echo "no dist/index.html"; exit 1; }

echo "==> backend deps + restart services (tunnel stays up)"
( cd "$SRC/backend" && npm install --no-audit --no-fund --silent ) || true
systemctl --user restart verilog-backend verilog-frontend
systemctl --user start verilog-cloudflared 2>/dev/null || true

echo "==> health check (localhost frontend)"
for i in $(seq 1 30); do
  [ "$(curl -s -m 8 -o /dev/null -w '%{http_code}' http://localhost:5173)" = 200 ] && { echo "LIVE :5173 ($SHA)"; exit 0; }
  sleep 4
done
echo "not healthy yet — systemctl --user status verilog-frontend"; exit 1
