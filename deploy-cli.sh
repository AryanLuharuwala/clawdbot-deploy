#!/usr/bin/env bash
# deploy-cli — stand up / manage self-hosted sites on a machine (no sudo).
# Each site is a folder under sites/<name> with a site.conf, unit templates,
# and a deploy.sh. Secrets are AES-encrypted in secrets/<name>.tar.enc.
#
#   ./deploy-cli.sh list
#   ./deploy-cli.sh install <site|all>
#   ./deploy-cli.sh status [site]
#   ./deploy-cli.sh start|stop|restart|logs <site>
#   ./deploy-cli.sh deploy <site>            # rebuild from latest git (what the runner runs)
#   ./deploy-cli.sh secrets gather|seal|unseal <site>
#   ./deploy-cli.sh register-runner <site>
#   ./deploy-cli.sh add-site <name>
#
# Env knobs: GH_TOKEN (clone private repos + register runners),
#            DEPLOY_SECRET_PASS (skip the passphrase prompt),
#            PORT=... TUNNEL_HOSTNAME=... (override site.conf at install time)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

site_services() {  # echo "unit port tmpl" lines
  local s; for s in "${SERVICES[@]}"; do echo "${s//:/ }"; done
}

cmd_list() {
  printf '%-14s %-8s %-22s %s\n' SITE STATUS TUNNEL SERVICES
  local name
  for name in $(list_sites); do
    ( load_site "$name"
      local up=0 tot=0 u
      for u in $(site_services | awk '{print $1}'); do tot=$((tot+1)); uctl is-active --quiet "$u" && up=$((up+1)); done
      local st="$c_dim-$c_off"; [ "$up" -gt 0 ] && st="$c_grn$up/$tot up$c_off"; [ "$up" = 0 ] && st="$c_dim$up/$tot$c_off"
      printf '%-14s %-17s %-22s %s\n' "$name" "$st" "${TUNNEL_HOSTNAME:-none}" "$(site_services | awk '{print $1}' | paste -sd, -)"
    )
  done
}

cmd_status() {
  local name="${1:-}"
  [ -n "$name" ] || { for name in $(list_sites); do cmd_status "$name"; done; return; }
  load_site "$name"; log "$name"
  local u p; while read -r u p _; do
    printf '   %-26s %s\n' "$u" "$(uctl is-active "$u" 2>/dev/null)"
  done < <(site_services)
}

cmd_install() {
  local name="$1"
  [ "$name" = all ] && { local s; for s in $(list_sites); do cmd_install "$s"; done; return; }
  load_site "$name"
  # allow port/tunnel overrides from env
  [ -n "${PORT:-}" ] && APP_PORT="$PORT" || APP_PORT="${APP_PORT:-}"
  [ -n "${TUNNEL_HOSTNAME_OVERRIDE:-}" ] && TUNNEL_HOSTNAME="$TUNNEL_HOSTNAME_OVERRIDE"
  log "installing site: $name  (branch $BRANCH, tunnel ${TUNNEL_HOSTNAME:-none})"

  enable_linger
  [ "$NEEDS_NODE" = 1 ] && ensure_node
  [ "$NEEDS_CLOUDFLARED" = 1 ] && ensure_cloudflared
  [ "$NEEDS_MONGO" = 1 ] && ensure_mongod

  log "fetching code -> $SRC_DIR"
  ensure_repo "$REPO" "$BRANCH" "$SRC_DIR"

  if [ -f "$SECRETS_DIR/$name.tar.enc" ]; then log "restoring secrets"; secrets_unseal "$name"
  else warn "no sealed secrets for $name — app may need env to build/run"; fi

  log "installing systemd units"
  local u p t
  while read -r u t p; do install_unit "$SITE_DIR/units/$t" "$u.service" "$p"; done < <(site_services)
  uctl daemon-reload

  # start infra services (mongo, tunnel) before the app build/health-check
  while read -r u t p; do case "$u" in *mongod*|*cloudflared*) uctl enable --now "$u" >/dev/null 2>&1;; esac; done < <(site_services)

  if [ "$NEEDS_MONGO" = 1 ] && [ -n "$SEED_CMD" ]; then
    log "seeding database (idempotent)"; ( cd "$SRC_DIR" && eval "$SEED_CMD" ) || warn "seed step failed (continuing)"
  fi

  log "build + start app via deploy.sh"
  bash "$SITE_DIR/deploy.sh" || warn "deploy.sh returned non-zero (check health)"
  # make sure every declared unit is enabled
  while read -r u t p; do uctl enable "$u" >/dev/null 2>&1; done < <(site_services)

  ok "$name installed."
  [ -n "$RUNNER_LABEL" ] && warn "auto-deploy: run '$0 register-runner $name' (needs GH_TOKEN) to wire push-to-deploy"
}

cmd_deploy() { local name="$1"; load_site "$name"; bash "$SITE_DIR/deploy.sh"; }

cmd_svc() {  # start/stop/restart/logs
  local action="$1" name="$2"; load_site "$name"
  local u; for u in $(site_services | awk '{print $1}'); do
    case "$action" in
      logs) echo "── $u ──"; uctl --no-pager -n 15 status "$u" 2>/dev/null | tail -16;;
      *) uctl "$action" "$u" && ok "$action $u";;
    esac
  done
}

cmd_register_runner() {
  local name="$1"; load_site "$name"
  [ -n "$RUNNER_LABEL" ] || die "$name has no RUNNER_LABEL"
  [ -n "${GH_TOKEN:-}" ] || die "set GH_TOKEN (needs repo admin) to register a runner"
  local owner_repo; owner_repo="$(echo "$REPO" | sed -E 's#https://github.com/##; s#\.git$##')"
  log "registering runner for $owner_repo (label $RUNNER_LABEL)"
  local rt; rt="$(curl -s -X POST -H "Authorization: token $GH_TOKEN" \
      "https://api.github.com/repos/$owner_repo/actions/runners/registration-token" \
      | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')"
  [ -n "$rt" ] || die "could not mint registration token (need admin on $owner_repo)"
  local rdir="$HOME/actions-runner-$name"; mkdir -p "$rdir"; cd "$rdir"
  if [ ! -f ./config.sh ]; then
    local rv; rv="$(curl -s https://api.github.com/repos/actions/runner/releases/latest | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p')"
    curl -fsSL -o r.tgz "https://github.com/actions/runner/releases/download/v$rv/actions-runner-linux-x64-$rv.tar.gz"
    tar xzf r.tgz && rm -f r.tgz
  fi
  ./config.sh --url "https://github.com/$owner_repo" --token "$rt" --name "$(hostname)-$name" \
      --labels "$RUNNER_LABEL" --unattended --replace >/dev/null
  install_unit "$HERE/lib/runner.service.tmpl" "runner-$name.service" ""
  sed -i "s#@RDIR@#$rdir#g" "$UNIT_DIR/runner-$name.service"
  uctl daemon-reload && uctl enable --now "runner-$name" && ok "runner online for $name"
}

cmd_secrets() {
  local sub="$1" name="${2:-}" targets t
  [ -n "$name" ] || die "secrets: gather|seal|unseal <site|all>"
  if [ "$name" = all ]; then targets="$(list_sites)"; else targets="$name"; fi
  for t in $targets; do
    case "$sub" in
      gather) secrets_gather "$t";;
      seal)   secrets_seal "$t";;     # prompt_pass caches the passphrase across the loop
      unseal) secrets_unseal "$t";;
      *) die "secrets: gather|seal|unseal <site|all>";;
    esac
  done
}

cmd_add_site() {
  local name="$1"; local d="$SITES_DIR/$name"
  [ -e "$d" ] && die "$name already exists"
  mkdir -p "$d/units"; cp "$SITES_DIR/.template/site.conf" "$d/site.conf" 2>/dev/null \
     || warn "see sites/pollys for an example to copy"
  ok "scaffolded sites/$name — edit site.conf, add units/ + deploy.sh"
}

main() {
  local cmd="${1:-list}"; shift || true
  case "$cmd" in
    list)             cmd_list "$@";;
    status)           cmd_status "$@";;
    install)          [ $# -ge 1 ] || die "usage: install <site|all>"; cmd_install "$@";;
    deploy)           [ $# -ge 1 ] || die "usage: deploy <site>"; cmd_deploy "$@";;
    start|stop|restart|logs) [ $# -ge 1 ] || die "usage: $cmd <site>"; cmd_svc "$cmd" "$@";;
    register-runner)  [ $# -ge 1 ] || die "usage: register-runner <site>"; cmd_register_runner "$@";;
    secrets)          [ $# -ge 1 ] || die "usage: secrets gather|seal|unseal <site>"; cmd_secrets "$@";;
    add-site)         [ $# -ge 1 ] || die "usage: add-site <name>"; cmd_add_site "$@";;
    -h|--help|help)   sed -n '2,20p' "$0";;
    *) die "unknown command '$cmd' (try: list)";;
  esac
}
main "$@"
