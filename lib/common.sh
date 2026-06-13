#!/usr/bin/env bash
# Shared helpers for deploy-cli. Sourced, never run directly.
# No sudo anywhere: binaries land in ~/.local/bin, services are systemd --user.

set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITES_DIR="$KIT_ROOT/sites"
SECRETS_DIR="$KIT_ROOT/secrets"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_cyn=$'\e[36m'; c_dim=$'\e[2m'; c_off=$'\e[0m'
log()  { printf '%s==>%s %s\n' "$c_cyn" "$c_off" "$*"; }
ok()   { printf '%s ✓%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s ! %s %s\n' "$c_ylw" "$c_off" "$*" >&2; }
die()  { printf '%s ✗ %s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

# systemctl --user that works in non-login shells (cron, ssh, Actions jobs)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
uctl() { systemctl --user "$@"; }

list_sites() { ls -1 "$SITES_DIR" 2>/dev/null; }

# Load a site's declarative config into the current shell.
load_site() {
  local name="$1"
  local conf="$SITES_DIR/$name/site.conf"
  [ -f "$conf" ] || die "unknown site '$name' (no $conf)"
  SITE_NAME=""; REPO=""; BRANCH="main"; SRC_DIR=""; NEEDS_MONGO=0; NEEDS_NODE=1
  NEEDS_CLOUDFLARED=1; TUNNEL_MODE="none"; TUNNEL_NAME=""; TUNNEL_HOSTNAME=""
  RUNNER_LABEL=""; SEED_CMD=""; declare -ga SERVICES=(); declare -ga SECRET_FILES=()
  # shellcheck disable=SC1090
  source "$conf"
  SITE_DIR="$SITES_DIR/$name"
}

enable_linger() {
  if ! loginctl show-user "$(id -un)" 2>/dev/null | grep -q 'Linger=yes'; then
    loginctl enable-linger "$(id -un)" 2>/dev/null \
      && ok "linger enabled (services survive logout/reboot)" \
      || warn "could not enable linger; services won't auto-start on reboot"
  fi
}

# ---- dependency installers (user-space) -------------------------------------
arch_tag() { case "$(uname -m)" in x86_64) echo amd64;; aarch64|arm64) echo arm64;; *) echo amd64;; esac; }

ensure_node() {
  command -v node >/dev/null && return 0
  warn "node not found — installing via nvm (user-space)"
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] || curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh" && nvm install --lts && nvm alias default 'lts/*'
}

ensure_cloudflared() {
  command -v "$BIN_DIR/cloudflared" >/dev/null && return 0
  log "installing cloudflared ($(arch_tag))"
  mkdir -p "$BIN_DIR"
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$(arch_tag)" -o "$BIN_DIR/cloudflared"
  chmod +x "$BIN_DIR/cloudflared"; ok "cloudflared $("$BIN_DIR/cloudflared" --version 2>&1 | awk '{print $3}')"
}

ensure_mongod() {
  command -v "$BIN_DIR/mongod" >/dev/null && return 0
  log "installing MongoDB (user-space tarball)"
  mkdir -p "$BIN_DIR" "$HOME/mongodb-dl"
  local ver="7.0.16" got=""
  for d in rhel90 rhel93 rhel80 ubuntu2204 ubuntu2004; do
    local url="https://fastdl.mongodb.org/linux/mongodb-linux-x86_64-$d-$ver.tgz"
    if curl -fsI "$url" >/dev/null 2>&1; then
      curl -fsSL "$url" -o "$HOME/mongodb-dl/mongo.tgz" && got="$url" && break
    fi
  done
  [ -n "$got" ] || die "no MongoDB tarball matched this OS — install mongod manually"
  tar xzf "$HOME/mongodb-dl/mongo.tgz" -C "$HOME/mongodb-dl" && rm -f "$HOME/mongodb-dl/mongo.tgz"
  ln -sf "$(ls -d "$HOME"/mongodb-dl/mongodb-linux-*/bin/mongod | head -1)" "$BIN_DIR/mongod"
  mkdir -p "$HOME/mongodb-data" "$HOME/mongodb-logs"
  ok "mongod $("$BIN_DIR/mongod" --version | head -1 | awk '{print $3}')"
}

# ---- systemd unit rendering --------------------------------------------------
# Render a *.tmpl, substituting @HOME@ / @PORT@ / @BIN@ etc, into ~/.config/systemd/user
install_unit() {
  local tmpl="$1" unit="$2" port="${3:-}"
  mkdir -p "$UNIT_DIR"
  sed -e "s#@HOME@#$HOME#g" -e "s#@BIN@#$BIN_DIR#g" -e "s#@PORT@#$port#g" \
      "$tmpl" > "$UNIT_DIR/$unit"
}

# ---- secrets (openssl AES-256, one passphrase) -------------------------------
# Bundle layout in the repo: secrets/<site>.tar.enc  (encrypted tar of files)
SECRET_PASS=""
prompt_pass() {
  [ -n "$SECRET_PASS" ] && return 0
  if [ -n "${DEPLOY_SECRET_PASS:-}" ]; then SECRET_PASS="$DEPLOY_SECRET_PASS"; return 0; fi
  read -rs -p "Secrets passphrase: " SECRET_PASS; echo
  [ -n "$SECRET_PASS" ] || die "empty passphrase"
}

# gather live secret files (defined per-site) into a staging dir
secrets_gather() {
  local name="$1"; load_site "$name"
  local stage="$SECRETS_DIR/plain/$name"; rm -rf "$stage"; mkdir -p "$stage"
  local entry src dst
  for entry in "${SECRET_FILES[@]}"; do
    src="${entry%%::*}"; dst="${entry##*::}"   # entry = "<bundle-rel>::<live-path>"
    src="$(eval echo "$src")"; dst="$(eval echo "$dst")"
    if [ -f "$dst" ]; then mkdir -p "$stage/$(dirname "$src")"; cp -a "$dst" "$stage/$src"; ok "gathered $src"
    else warn "missing live secret: $dst (skip)"; fi
  done
  log "staged at $stage — now run: $0 secrets seal $name"
}

secrets_seal() {
  local name="$1"; prompt_pass
  local stage="$SECRETS_DIR/plain/$name"
  [ -d "$stage" ] || die "nothing staged for $name — run 'secrets gather $name' first"
  ( cd "$stage" && tar cz . ) | openssl enc -aes-256-cbc -pbkdf2 -salt -pass pass:"$SECRET_PASS" \
      -out "$SECRETS_DIR/$name.tar.enc"
  ok "sealed -> secrets/$name.tar.enc  (commit this; plaintext stays gitignored)"
}

secrets_unseal() {
  local name="$1"; load_site "$name"; prompt_pass
  local enc="$SECRETS_DIR/$name.tar.enc"
  [ -f "$enc" ] || die "no sealed secrets for $name ($enc)"
  local tmp; tmp="$(mktemp -d)"
  openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:"$SECRET_PASS" -in "$enc" | tar xz -C "$tmp" \
      || die "decryption failed (wrong passphrase?)"
  local entry src dst
  for entry in "${SECRET_FILES[@]}"; do
    src="${entry%%::*}"; dst="${entry##*::}"
    src="$(eval echo "$src")"; dst="$(eval echo "$dst")"
    if [ -f "$tmp/$src" ]; then mkdir -p "$(dirname "$dst")"; cp -a "$tmp/$src" "$dst"; chmod 600 "$dst" 2>/dev/null||true; ok "placed $dst"
    else warn "bundle missing $src"; fi
  done
  rm -rf "$tmp"
}

# ---- git clone/update with PAT (for private repos) ---------------------------
ensure_repo() {
  local repo="$1" branch="$2" dir="$3"
  if [ -n "${GH_TOKEN:-}" ]; then
    git config --global credential.helper store
    umask 077; printf 'https://x-access-token:%s@github.com\n' "$GH_TOKEN" > "$HOME/.git-credentials"
  fi
  if [ -d "$dir/.git" ]; then git -C "$dir" fetch origin "$branch" --quiet && git -C "$dir" reset --hard "origin/$branch" >/dev/null
  else git clone --quiet "$repo" "$dir"; fi
  git -C "$dir" checkout -q "$branch" 2>/dev/null || true
}
