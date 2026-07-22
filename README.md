# deploy-runtime

Shared deploy assets for Codenzia demo apps published to Hostinger Cloud
subdomains under `codenzia.com`.

Each Laravel demo (serveeta, task-off, plugins-demo, snapcar, aqarkom, …) is
served from `~/domains/<sub>.codenzia.com/public_html/` (Hostinger pins the
doc root there; we don't fight it). The full Laravel project tree lives
directly in `public_html/`; a top-level `.htaccess` rewrites every request
into `public_html/public/` (the Laravel front controller). Per-app shared
state (`.env`, `storage/`, `database.sqlite`) lives in
`~/domains/<sub>/apps/shared/` and is symlinked into `public_html/` by the
release activator. CI rsyncs staged releases into `apps/releases/<stamp>/`
first, then the activator syncs locally into `public_html/`.

## Why not atomic releases via Public-folder repointing?

Hostinger insists on `public_html/` as the doc root, so we adapt: deploys
overwrite in place after a brief local rsync. The trade-off is rollback —
we keep the last 5 staged releases under `apps/releases/` for inspection
and to support a "re-activate previous release" path, but it's not the
zero-downtime symlink swap the Capistrano pattern gives you.

## Contents

- `provision-app.sh APP DOMAIN` — one-time bootstrap on the Cloud Startup
  host: creates `apps/shared/{storage tree, .env, database.sqlite}`,
  drops the activator at `apps/deploy.sh` and the top-level rewrite at
  `apps/.htaccess.public_html`, prints the cron lines to paste into hPanel
  plus the absolute SQLite path to put in `.env`.
- `deploy.sh` — release activator copied into each app's `apps/deploy.sh`.
  Idempotent. Reads `APP`, `DOMAIN`, `REL`, `FRESH`, `DEMO_SEEDER`, `PHP_BIN`
  from env. Local-rsyncs the staged release into `public_html/`, restores
  the shared symlinks, installs the top-level rewrite (only if missing),
  runs migrations + caches, kills the queue worker so the cron-loop picks
  up the new code.
- `.htaccess.public_html` — top-level Hostinger rewrite that routes every
  request into `public_html/public/`. Dropped by `provision-app.sh` into
  `apps/.htaccess.public_html`; auto-installed by `deploy.sh` on first
  deploy (never overwrites an existing one).
- `dump-demos.sh` — nightly `gzip -c` of every demo's `apps/shared/database.sqlite`
  into `~/backups/demos/<app>/`, keeps the last 7.

## Flow

1. CI builds the artifact (composer + npm), rsyncs to
   `apps/releases/<stamp>/` on the host, then SSHes in to run `deploy.sh`.
2. `deploy.sh` local-rsyncs `releases/<stamp>/` → `public_html/` (overwrite
   with `--delete`, excluding the top-level `.htaccess`, `.env`, `storage`,
   and the SQLite DB so the symlinks survive). Re-establishes the symlinks.
   Runs Laravel migrate + cache. Kills the worker.
3. Hostinger cron jobs (added once per app via hPanel) run `schedule:run`
   and the queue cron-loop (`queue:work --stop-when-empty --max-time=55`),
   both `cd ~/domains/<sub>/public_html` so they reference the live tree.

## CloudPanel vhost — REQUIRED for Livewire v4 apps

Applies to the Hostinger **KVM VPS** (CloudPanel), not the Cloud Startup
host above. When you create a new site in the CloudPanel UI for any
Livewire v4 / Filament app, you **must** paste
[`templates/cloudpanel-vhost-laravel.conf`](templates/cloudpanel-vhost-laravel.conf)
into **Sites → &lt;site&gt; → Vhost** (replace `{{server_name}}` with the
domain; leave every other `{{…}}` token untouched).

CloudPanel's stock 443 server serves `*.js` / `*.css` straight off disk and
hard-404s missing files. Livewire v4 and Filament serve their runtime JS/CSS
through **dynamic Laravel routes** (`/livewire/livewire.min.js`,
`/livewire-<hash>/livewire.min.js`, …) that have no file on disk, so nginx
404s them before Laravel is reached — silently breaking every Livewire form
and Filament panel on the site. The template fixes this by adding
`try_files $uri @laravel;` to the static-asset block plus a named
`location @laravel { … }` that proxies the miss back to Laravel.

CloudPanel vhosts are root-owned, so CI cannot patch this automatically. The
`vps-deploy.yml` workflow runs a **non-fatal post-deploy health check** that
loads the homepage, finds the Livewire script tag, and warns in the Actions
log if that script does not return HTTP 200 — a reminder to paste the
template on a site where it's still missing.

## Queue worker — REQUIRED for apps with async jobs

Any app whose `QUEUE_CONNECTION` is not `sync` (notifications, mail, etc.) needs
a supervised `queue:work` worker. That worker is installed **once per site, as
root**, by `vps-worker-setup.sh` (supervisor program + `schedule:run` cron) — it
is deliberately **not** part of `vps-deploy.sh`, which runs as the unprivileged
site user and cannot write `/etc/supervisor` or touch systemd.

Because that step is separate, a freshly provisioned site can end up with a
scheduler cron but no worker, silently stockpiling jobs (this is exactly what
happened to `dari.codenzia.com`). To make that impossible to miss, every deploy
now runs a **queue worker health check** post-activation:

- Detects whether a `queue:work` worker is running for this site.
- If absent and `QUEUE_CONNECTION != sync`: prints a loud `WARNING`, emits a
  GitHub Actions `::warning::` annotation with the exact
  `sudo bash …/vps-worker-setup.sh <app> <domain> <site-user> <php>` command,
  and adds a **Queue worker health** table (worker state + pending-job count) to
  the run summary.
- Never fails the deploy.

**Opt-in hands-off setup:** grant the site user a NOPASSWD sudoers entry for the
worker-setup script and the deploy will auto-install the worker whenever it's
missing (`sudo -n`, idempotent):
```
<site-user> ALL=(root) NOPASSWD: /usr/bin/bash /home/<site-user>/htdocs/<domain>/.deploy/vps-worker-setup.sh *
```
Without it, `sudo -n` fails fast and the deploy just warns — nothing is forced.
See [`VPS-DEPLOY-RUNBOOK.md`](VPS-DEPLOY-RUNBOOK.md) § "Queue worker" for details.
