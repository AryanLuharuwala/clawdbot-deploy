# deploy-cli — portable self-hosted site deployer

Stand up one or more web apps on any Linux box **without sudo** — binaries land in
`~/.local/bin`, everything runs as `systemd --user` services (with linger, so they
survive reboot), and code auto-deploys via GitHub self-hosted runners.

Currently ships two sites:

| Site | URL | Stack | Port | DB | Tunnel |
|------|-----|-------|------|----|--------|
| `bitforbytes` | bitforbytes.in | Vite+React + Express | 5173 / 3000 | — | named (`madhur`) |
| `pollys` | pollys.food | Next.js 16 | 3100 | local MongoDB | token connector |

## Move everything to a new machine

```bash
git clone https://github.com/AryanLuharuwala/clawdbot-deploy.git
cd clawdbot-deploy
export GH_TOKEN=ghp_xxx            # a PAT with repo + workflow (+ admin to register runners)
./deploy-cli.sh install all       # prompts once for the secrets passphrase
./deploy-cli.sh register-runner bitforbytes
./deploy-cli.sh register-runner pollys
```

That downloads cloudflared + mongod, clones+builds both apps, decrypts and places
all secrets, installs+starts every service, and (optionally) registers the
push-to-deploy runners. ~3 minutes.

> **DNS / tunnels are account-side.** Named tunnels carry their own creds in the
> secrets bundle, so they "just work". The `pollys` token connector also works
> as-is, but its hostname→service routing lives in the Cloudflare dashboard.
> If you move to a brand-new domain/account you'll re-point DNS there.

## Everyday commands

```bash
./deploy-cli.sh list                 # sites + how many services are up
./deploy-cli.sh status pollys        # per-service state
./deploy-cli.sh deploy pollys        # rebuild from latest git (same as the runner)
./deploy-cli.sh restart bitforbytes
./deploy-cli.sh logs pollys
```

## Changing ports / tunnels

Edit `sites/<name>/site.conf` (`APP_PORT`, `BACKEND_PORT`, `TUNNEL_*`) and re-run
`install`, or override at install time:

```bash
PORT=3200 ./deploy-cli.sh install pollys
```

For a named tunnel, edit the `config.yml` inside that site's secrets bundle
(`secrets <site>` round-trip below).

## Secrets (AES-256, one passphrase you keep)

Plaintext never enters git. Only `secrets/<site>.tar.enc` is committed.

```bash
./deploy-cli.sh secrets gather pollys   # copy this box's live secret files into secrets/plain/pollys
./deploy-cli.sh secrets seal   pollys   # encrypt -> secrets/pollys.tar.enc (prompts passphrase)
./deploy-cli.sh secrets unseal pollys   # decrypt + place files (install does this for you)
```

## Add a new site

```bash
./deploy-cli.sh add-site mysite
# edit sites/mysite/{site.conf, units/*.tmpl, deploy.sh}, then:
./deploy-cli.sh secrets gather mysite && ./deploy-cli.sh secrets seal mysite
./deploy-cli.sh install mysite
```

A site is just: `site.conf` (declares repo/branch/ports/tunnel/services/secrets),
`units/*.service.tmpl` (systemd templates with `@HOME@`/`@PORT@`/`@BIN@`), and a
`deploy.sh` (build + restart, shared by install and the runner).
