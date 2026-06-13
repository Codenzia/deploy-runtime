# VPS Deploy Runbook (Hostinger KVM / CloudPanel)

Atomic-release CI/CD for Laravel apps on the Codenzia Hostinger KVM VPS
(`31.97.78.215`, CloudPanel). Parallel to the Cloud Startup pipeline
(`laravel-cloud-deploy.yml`) — use this one for VPS-hosted sites.

**Pieces**
- `vps-deploy.yml` — reusable GitHub Actions workflow (build + ship + activate).
- `vps-provision.sh` — one-time per-site host bootstrap (atomic layout, `--adopt`).
- `vps-deploy.sh` — release activator (symlink shared, migrate, atomic swap, prune).

The workflow uploads `vps-provision.sh` + `vps-deploy.sh` to the host on every
run, so improving them here improves every app's next deploy — nothing to copy
by hand.

---

## Onboard a NEW app in ~5 minutes

Each app needs just **two files** in its own repo:

**1. `deploy/targets.json`** — maps logical targets to CloudPanel sites:
```json
{
  "production": { "site_user": "myapp",      "domain": "myapp.com" },
  "demo":       { "site_user": "myapp-demo", "domain": "demo.myapp.com", "seeder": "DemoSeeder" }
}
```
Optional per-target keys: `seeder` (default `DatabaseSeeder`), `db` (`sqlite`
default | `mysql`).

**2. `.github/workflows/deploy-vps.yml`** — copy task-off's caller, change
`app_name`, the `target` choice options, and `siblings` if used.

Then the per-site host prep below, set repo secrets, and Run workflow.

---

## Per-site host prep (one-time)

### A. CloudPanel UI (no CLI)
1. **Create the site** → records the Linux user + `/home/<user>/htdocs/<domain>/`.
2. After the first deploy auto-provisions, **set the site's doc root (vhost
   root) to** `/home/<user>/htdocs/<domain>/current/public`.
3. **Enable Let's Encrypt** for the domain.
4. (MySQL targets only) **create a DB + user**; put the credentials in
   `shared/.env` (`DB_HOST=127.0.0.1`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`).

### B. SSH access for the deploy
Append the deploy public key to **each site user's** `authorized_keys`
(one `VPS_SSH_KEY`, authorized on every site user):
```bash
sudo -u <site-user> mkdir -p /home/<site-user>/.ssh
echo "<deploy-public-key>" | sudo tee -a /home/<site-user>/.ssh/authorized_keys
sudo chown -R <site-user>:<site-user> /home/<site-user>/.ssh
sudo chmod 700 /home/<site-user>/.ssh && sudo chmod 600 /home/<site-user>/.ssh/authorized_keys
```

### C. Queue worker (supervisor — root, one-time on the box)
```bash
sudo apt install -y supervisor && sudo systemctl enable --now supervisor
```
Then per app (`/etc/supervisor/conf.d/<app>-worker.conf`):
```ini
[program:<app>-worker]
command=php8.3 /home/<site-user>/htdocs/<domain>/current/artisan queue:work --sleep=1 --tries=3 --max-time=3600
user=<site-user>
numprocs=1
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/home/<site-user>/htdocs/<domain>/shared/storage/logs/worker.log
```
`sudo supervisorctl reread && sudo supervisorctl update`. The deploy calls
`php artisan queue:restart`, which supervisor-managed workers honour.

### D. Scheduler (cron — as the site user)
```cron
* * * * * cd /home/<site-user>/htdocs/<domain>/current && php8.3 artisan schedule:run >> ../shared/storage/logs/schedule.log 2>&1
```

### E. (Optional) let deploys reload php-fpm + flush Varnish
The deploy runs as the unprivileged site user. Without this it relies on
opcache realpath invalidation (works, but a reload is cleaner). Grant
passwordless sudo for just those two commands (`/etc/sudoers.d/<site-user>-deploy`):
```
<site-user> ALL=(root) NOPASSWD: /usr/bin/systemctl reload php8.3-fpm, /usr/bin/varnishadm ban req.url ~ ^/
```

---

## Repo secrets (set per repo — Free org plan doesn't propagate org secrets)
```bash
gh secret set VPS_HOST     -R Codenzia/<repo> --body "31.97.78.215"
gh secret set VPS_PORT     -R Codenzia/<repo> --body "22"
gh secret set VPS_SSH_KEY  -R Codenzia/<repo> < deploy_key            # private key
gh secret set CODENZIA_PAT -R Codenzia/<repo> --body "<PAT repo scope>"
```

---

## Running a deploy
GitHub → repo → Actions → **Deploy (VPS)** → Run workflow:
- **target**: production / demo / … (mapped via `deploy/targets.json`)
- **db**: `sqlite` (default) or `mysql`
- **fresh**: `true` only to wipe + reseed (DESTRUCTIVE; auto-backs up first)
- **adopt**: `true` on the very first deploy over an existing non-atomic site

> Deploys are **manual only** (`workflow_dispatch`). Per policy, never add a
> push/schedule trigger to a user-facing host, and never fire a deploy on the
> user's behalf — they click Run workflow.

---

## Data migration

**Same engine (automatic, safe).** `--adopt` on first deploy backs up the old
site and carries its real `.env`, SQLite DB, and `storage/app` uploads into
`shared/`. Every deploy runs `migrate --force` (non-destructive — never drops
rows). Existing data is preserved.

**Cross-engine (sqlite ↔ mysql, deliberate one-time step).** The deploy-time
`db` toggle only changes which connection the app *uses* — it does **not** copy
data. To actually move data between engines, run the `db:transfer` artisan
command once (ships in task-off; copy to any app):
```bash
# on the host, inside current/, with both connections configured in .env
php8.3 artisan db:transfer --from=sqlite --to=mysql
```
Always take a backup first (`shared/backups/` already holds pre-deploy snapshots).

---

## Rollback
Releases are kept (last 5) under `htdocs/<domain>/releases/`. Repoint `current`:
```bash
ssh <site-user>@31.97.78.215
cd ~/htdocs/<domain>
ln -sfn "releases/<previous-stamp>" current.tmp && mv -Tf current.tmp current
php8.3 current/artisan optimize:clear && php8.3 current/artisan config:cache
```
(If the rollback target predates a destructive migration, restore the matching
DB snapshot from `shared/backups/` too.)
