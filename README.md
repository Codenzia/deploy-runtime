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
