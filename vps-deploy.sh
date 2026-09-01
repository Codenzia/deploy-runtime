#!/usr/bin/env bash
# Atomic-release activator for the Codenzia Hostinger KVM VPS (CloudPanel).
# Runs AS THE SITE'S LINUX USER after CI has rsynced a new release into
# htdocs/<domain>/releases/$REL. Reads its config from env:
#   APP      short app name, e.g. task-off
#   DOMAIN   full domain, e.g. task-off.com
#   REL      release id (timestamp-sha)
#   DB       "sqlite" (default) or "mysql" — sets DB_CONNECTION in shared/.env
#   FRESH    "true" to migrate:fresh + reseed (default "false")
#   SEEDER   seeder class for FRESH path (default "DatabaseSeeder")
#   ALWAYS_SEED  "true" to also run the (idempotent) seeder on the NORMAL
#                (non-FRESH) path every deploy (default "false")
#   SYNC_SUPERADMIN  "true" (default) to sync super-admin creds from env via
#                    `superadmin:ensure --from-env`; soft-fails on older apps
#   MODE     "release" (default; APP_ENV=production, APP_DEBUG=false)
#            "debug"   (APP_ENV=local, APP_DEBUG=true)
#   PHP_BIN  php binary (default: php8.3 || php)
#
# Unlike Hostinger Cloud Startup, this host ALLOWS exec()/symlink(), so we
# use real symlinks + `php artisan storage:link`, and swap an atomic
# `current` symlink instead of rsyncing over a pinned public_html.
#
# php-fpm reload + Varnish flush need privileges the unprivileged site user
# usually lacks; we attempt them via passwordless sudo and fall back to
# opcache realpath invalidation (the symlink swap changes realpaths, so
# opcache picks up the new release). See VPS-DEPLOY-RUNBOOK.md for the
# optional sudoers entry that makes the reload + flush real.
set -euo pipefail

: "${APP:?APP is required}"
: "${DOMAIN:?DOMAIN is required}"
: "${REL:?REL is required}"
DB="${DB:-sqlite}"
FRESH="${FRESH:-false}"
SEEDER="${SEEDER:-DatabaseSeeder}"
ALWAYS_SEED="${ALWAYS_SEED:-false}"
SYNC_SUPERADMIN="${SYNC_SUPERADMIN:-true}"
MODE="${MODE:-release}"
PHP_BIN="${PHP_BIN:-$(command -v php8.3 || command -v php || echo /usr/bin/php)}"

SITE_DIR="$HOME/htdocs/$DOMAIN"
RELEASES="$SITE_DIR/releases"
SHARED="$SITE_DIR/shared"
CURRENT="$SITE_DIR/current"
R="$RELEASES/$REL"
ENV_FILE="$SHARED/.env"
DB_FILE="$SHARED/database.sqlite"
BACKUPS="$SHARED/backups"

if [ ! -d "$R" ]; then
    echo "FATAL: release directory $R does not exist" >&2
    exit 1
fi
if [ ! -f "$ENV_FILE" ]; then
    echo "FATAL: $ENV_FILE not seeded; run vps-provision.sh first" >&2
    exit 1
fi
if [ ! -d "$SHARED/storage" ]; then
    echo "FATAL: $SHARED/storage missing; run vps-provision.sh first" >&2
    exit 1
fi

# --- Bind shared state into the new release -------------------------------
ln -sfn "$ENV_FILE" "$R/.env"

rm -rf "$R/storage"
ln -sfn "$SHARED/storage" "$R/storage"

mkdir -p "$R/database"
if [ "$DB" = "sqlite" ]; then
    [ -f "$DB_FILE" ] || { touch "$DB_FILE"; chmod 664 "$DB_FILE"; }
    rm -f "$R/database/database.sqlite"
    ln -sfn "$DB_FILE" "$R/database/database.sqlite"
fi

# public/storage → shared/storage/app/public (exec()/symlink() allowed here).
ln -sfn "$SHARED/storage/app/public" "$R/public/storage"

# --- Apply DB engine + MODE to shared/.env (persists across releases) -----
case "$DB" in
    sqlite)
        echo "DB=sqlite → DB_CONNECTION=sqlite, DB_DATABASE=$DB_FILE"
        if grep -q '^DB_CONNECTION=' "$ENV_FILE"; then
            sed -i "s|^DB_CONNECTION=.*|DB_CONNECTION=sqlite|" "$ENV_FILE"
        else
            echo "DB_CONNECTION=sqlite" >> "$ENV_FILE"
        fi
        if grep -q '^DB_DATABASE=' "$ENV_FILE"; then
            sed -i "s|^DB_DATABASE=.*|DB_DATABASE=$DB_FILE|" "$ENV_FILE"
        else
            echo "DB_DATABASE=$DB_FILE" >> "$ENV_FILE"
        fi
        ;;
    mysql)
        echo "DB=mysql → DB_CONNECTION=mysql (expects DB_HOST/DATABASE/USERNAME/PASSWORD already in shared/.env)"
        if grep -q '^DB_CONNECTION=' "$ENV_FILE"; then
            sed -i "s|^DB_CONNECTION=.*|DB_CONNECTION=mysql|" "$ENV_FILE"
        else
            echo "DB_CONNECTION=mysql" >> "$ENV_FILE"
        fi
        if ! grep -q '^DB_DATABASE=.\+' "$ENV_FILE" || grep -q "^DB_DATABASE=$DB_FILE" "$ENV_FILE"; then
            echo "WARN: DB=mysql but shared/.env has no MySQL DB_DATABASE — migrations will fail until you" >&2
            echo "      fill DB_HOST/DB_DATABASE/DB_USERNAME/DB_PASSWORD (create the DB in CloudPanel UI)." >&2
        fi
        ;;
    pgsql)
        # PostgreSQL isn't a CloudPanel-managed engine — install it on the box
        # (apt install postgresql php8.3-pgsql) and create the role + DB once,
        # then put the credentials in shared/.env. See VPS-DEPLOY-RUNBOOK.md.
        echo "DB=pgsql → DB_CONNECTION=pgsql (expects DB_HOST/PORT/DATABASE/USERNAME/PASSWORD already in shared/.env)"
        if grep -q '^DB_CONNECTION=' "$ENV_FILE"; then
            sed -i "s|^DB_CONNECTION=.*|DB_CONNECTION=pgsql|" "$ENV_FILE"
        else
            echo "DB_CONNECTION=pgsql" >> "$ENV_FILE"
        fi
        if ! grep -q '^DB_DATABASE=.\+' "$ENV_FILE" || grep -q "^DB_DATABASE=$DB_FILE" "$ENV_FILE"; then
            echo "WARN: DB=pgsql but shared/.env has no PostgreSQL DB_DATABASE — migrations will fail until you" >&2
            echo "      fill DB_HOST/DB_PORT/DB_DATABASE/DB_USERNAME/DB_PASSWORD (create the role + DB on the host)." >&2
        fi
        ;;
    *)
        echo "FATAL: unknown DB='$DB' (expected 'sqlite', 'mysql' or 'pgsql')" >&2
        exit 1
        ;;
esac

case "$MODE" in
    debug)
        echo "MODE=debug → APP_ENV=local APP_DEBUG=true"
        sed -i 's/^APP_DEBUG=.*/APP_DEBUG=true/' "$ENV_FILE"
        sed -i 's/^APP_ENV=.*/APP_ENV=local/'    "$ENV_FILE"
        ;;
    demo)
        # Public demo running fake integration drivers (e.g. DARI's fake Sanad
        # auth). NOT production — so apps that fail-closed on fake-driver-in-
        # production still boot — but APP_DEBUG stays off so no stack traces leak.
        echo "MODE=demo → APP_ENV=demo APP_DEBUG=false"
        sed -i 's/^APP_DEBUG=.*/APP_DEBUG=false/' "$ENV_FILE"
        sed -i 's/^APP_ENV=.*/APP_ENV=demo/'      "$ENV_FILE"
        ;;
    release|"")
        echo "MODE=release → APP_ENV=production APP_DEBUG=false"
        sed -i 's/^APP_DEBUG=.*/APP_DEBUG=false/'  "$ENV_FILE"
        sed -i 's/^APP_ENV=.*/APP_ENV=production/'  "$ENV_FILE"
        ;;
    *)
        echo "FATAL: unknown MODE='$MODE' (expected 'release', 'demo' or 'debug')" >&2
        exit 1
        ;;
esac

cd "$R"

# --- Migrate / reseed -----------------------------------------------------
mkdir -p "$BACKUPS"
backup_db() {
    local stamp; stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    if [ "$DB" = "sqlite" ] && [ -s "$DB_FILE" ]; then
        gzip -c "$DB_FILE" > "$BACKUPS/pre-$1-$stamp.sqlite.gz"
        echo "  backup → $BACKUPS/pre-$1-$stamp.sqlite.gz"
    elif [ "$DB" = "mysql" ]; then
        # Best-effort logical dump using the app's own .env credentials.
        local host db user pass
        host="$(grep -E '^DB_HOST=' "$ENV_FILE" | cut -d= -f2-)"
        db="$(grep -E '^DB_DATABASE=' "$ENV_FILE" | cut -d= -f2-)"
        user="$(grep -E '^DB_USERNAME=' "$ENV_FILE" | cut -d= -f2-)"
        pass="$(grep -E '^DB_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)"
        if command -v mysqldump >/dev/null 2>&1 && [ -n "$db" ]; then
            MYSQL_PWD="$pass" mysqldump -h"${host:-127.0.0.1}" -u"$user" "$db" 2>/dev/null \
                | gzip -c > "$BACKUPS/pre-$1-$stamp.sql.gz" \
                && echo "  backup → $BACKUPS/pre-$1-$stamp.sql.gz" \
                || echo "  WARN: mysqldump backup failed (check credentials)"
        fi
    elif [ "$DB" = "pgsql" ]; then
        # Best-effort logical dump using the app's own .env credentials.
        local host port db user pass
        host="$(grep -E '^DB_HOST=' "$ENV_FILE" | cut -d= -f2-)"
        port="$(grep -E '^DB_PORT=' "$ENV_FILE" | cut -d= -f2-)"
        db="$(grep -E '^DB_DATABASE=' "$ENV_FILE" | cut -d= -f2-)"
        user="$(grep -E '^DB_USERNAME=' "$ENV_FILE" | cut -d= -f2-)"
        pass="$(grep -E '^DB_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)"
        if command -v pg_dump >/dev/null 2>&1 && [ -n "$db" ]; then
            PGPASSWORD="$pass" pg_dump -h "${host:-127.0.0.1}" -p "${port:-5432}" -U "$user" "$db" 2>/dev/null \
                | gzip -c > "$BACKUPS/pre-$1-$stamp.sql.gz" \
                && echo "  backup → $BACKUPS/pre-$1-$stamp.sql.gz" \
                || echo "  WARN: pg_dump backup failed (check credentials)"
        fi
    fi
    ls -1t "$BACKUPS"/pre-"$1"-* 2>/dev/null | tail -n +6 | xargs -r rm -f
}

if [ "$FRESH" = "true" ]; then
    echo "FRESH=true → backup then migrate:fresh + db:seed --class=$SEEDER"
    backup_db fresh
    "$PHP_BIN" artisan migrate:fresh --force
    "$PHP_BIN" artisan db:seed --class="$SEEDER" --force
else
    backup_db deploy
    "$PHP_BIN" artisan migrate --force
    # Opt-in: re-run the (idempotent) seeder on every deploy. For our own
    # single-source-of-truth sites whose content lives in the seeder, this
    # keeps prod in sync with the committed catalogue without a destructive
    # FRESH. Off by default so customer/stateful apps are never reseeded.
    if [ "$ALWAYS_SEED" = "true" ]; then
        echo "ALWAYS_SEED=true → db:seed --class=$SEEDER --force (idempotent, non-destructive)"
        "$PHP_BIN" artisan db:seed --class="$SEEDER" --force
    fi
fi

# --- Sync super-admin credentials from env --------------------------------
# Apply SUPER_ADMIN_EMAIL/PASSWORD (config) to the protected account so the
# owner can always log in. Soft-fail: apps on older laravel-superadmin
# versions (no --from-env flag) or without the package deploy fine.
# SYNC_SUPERADMIN=false lets an app opt out entirely.
if [ "$SYNC_SUPERADMIN" = "true" ]; then
    "$PHP_BIN" artisan superadmin:ensure --from-env --no-interaction || echo "superadmin sync skipped (command/flag unavailable)"
fi

# --- Rebuild caches -------------------------------------------------------
"$PHP_BIN" artisan optimize:clear
"$PHP_BIN" artisan config:cache
"$PHP_BIN" artisan route:cache
"$PHP_BIN" artisan view:cache
"$PHP_BIN" artisan event:cache
"$PHP_BIN" artisan filament:cache-components || true
"$PHP_BIN" artisan filament:assets || true

# --- Atomic swap ----------------------------------------------------------
# ln -s to a temp name then `mv -T` is an atomic rename of the symlink, so
# there's no window where `current` is missing.
ln -sfn "$R" "$CURRENT.tmp"
mv -Tf "$CURRENT.tmp" "$CURRENT"
echo "current → $R"

# --- Restart workers + invalidate opcache + flush Varnish -----------------
# queue:restart signals running workers (supervisor restarts them).
"$PHP_BIN" artisan queue:restart || true

# Reload php-fpm so opcache picks up the new realpaths immediately. Needs
# privilege; attempt passwordless sudo, otherwise rely on opcache realpath
# invalidation from the symlink swap. (See runbook for the sudoers entry.)
RELOADED="false"
for svc in "php8.3-fpm" "php8.3-fpm@$USER" "php-fpm"; do
    if sudo -n systemctl reload "$svc" >/dev/null 2>&1; then
        echo "reloaded $svc"; RELOADED="true"; break
    fi
done
[ "$RELOADED" = "true" ] || echo "php-fpm reload skipped (no passwordless sudo); relying on opcache realpath invalidation"

# Flush Varnish so anonymous public pages don't serve the old release.
if sudo -n varnishadm "ban req.url ~ ^/" >/dev/null 2>&1; then
    echo "flushed Varnish cache"
else
    echo "Varnish flush skipped (no passwordless sudo / varnishadm)"
fi

# --- Queue worker health (guard: a site with no worker drops async jobs) --
# Async work (notifications, etc.) silently piles up if no `queue:work` worker
# runs. The worker is a supervisor program installed once by vps-worker-setup.sh
# (needs root) and is deliberately NOT part of this unprivileged deploy — so we
# DETECT it every deploy and warn loudly (log + GitHub ::warning:: annotation),
# and optionally auto-install it when a NOPASSWD sudoers grant opts in. This is
# the guard for the dari.codenzia.com class of bug: scheduler cron present,
# queue worker never started, notification jobs stuck.
SITE_USER="$(id -un)"
WORKER_SCRIPT="$SITE_DIR/.deploy/vps-worker-setup.sh"
WORKER_SETUP_CMD="sudo bash $WORKER_SCRIPT $APP $DOMAIN $SITE_USER $PHP_BIN"
HEALTH_FILE="$SITE_DIR/.deploy/health.env"

QUEUE_CONNECTION="$(grep -E '^QUEUE_CONNECTION=' "$ENV_FILE" | head -n1 | cut -d= -f2- | tr -d '\042\047' | xargs || true)"
QUEUE_CONNECTION="${QUEUE_CONNECTION:-sync}"

worker_running() {
    pgrep -f "$CURRENT/artisan queue:work" >/dev/null 2>&1 \
        || pgrep -f "htdocs/$DOMAIN/current/artisan queue:work" >/dev/null 2>&1
}

# Best-effort pending-job count on the app's default queue connection. Boots
# Laravel via its own bootstrap (NOT `artisan tinker` — laravel/tinker is a
# dev dependency and is absent from the --no-dev production artifact). Soft-fails
# to "?" so a driver without size() never breaks the deploy.
backlog_count() {
    REL_PATH="$R" "$PHP_BIN" -d error_reporting=0 -r '
        $rel = getenv("REL_PATH");
        require $rel."/vendor/autoload.php";
        $app = require $rel."/bootstrap/app.php";
        $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
        try { echo (int) $app->make("queue")->size(); } catch (\Throwable $e) { echo -1; }
    ' 2>/dev/null | grep -oE '[0-9]+' | tail -n1
}

WORKER_STATE="not-required"
BACKLOG="0"
if [ "$QUEUE_CONNECTION" != "sync" ]; then
    # SAMPLED, NOT GLANCED AT. This deploy ran `queue:restart` moments ago, so
    # a HEALTHY worker is mid-respawn right now: it exits on the signal and
    # supervisor has it back inside ~2s. A single pgrep landed exactly in that
    # gap on studio-creator (2026-09-01 00:57:19, between the exit at :18.7 and
    # RUNNING at :20.7) and reported a live worker as missing — which reads as
    # "async jobs will NOT be processed" in the deploy log and, where the
    # NOPASSWD grant exists, triggers a needless reinstall. Poll for up to 15s
    # before calling it missing; a genuinely absent worker costs the deploy
    # those 15 seconds once, a healthy one usually answers on the first try.
    WORKER_STATE="missing"
    for _ in 1 2 3 4 5; do
        if worker_running; then WORKER_STATE="running"; break; fi
        sleep 3
    done
    BACKLOG="$(backlog_count || true)"
    [ -z "$BACKLOG" ] && BACKLOG="?"

    # Optional hands-off setup: only if the site user has a NOPASSWD sudoers
    # grant for the worker-setup script. `sudo -n` never prompts — it either
    # runs immediately or fails fast, so this is safe when no grant exists.
    if [ "$WORKER_STATE" = "missing" ] && [ -f "$WORKER_SCRIPT" ]; then
        SETUP_LOG="$(mktemp 2>/dev/null || echo /tmp/worker-setup.$$.log)"
        if sudo -n bash "$WORKER_SCRIPT" "$APP" "$DOMAIN" "$SITE_USER" "$PHP_BIN" >"$SETUP_LOG" 2>&1; then
            echo "queue worker was missing → auto-installed via NOPASSWD sudo (vps-worker-setup.sh)"
            sed 's/^/  worker-setup: /' "$SETUP_LOG" || true
            worker_running && WORKER_STATE="running" || WORKER_STATE="starting"
        fi
        rm -f "$SETUP_LOG"
    fi
fi

# Persist facts so the CI summary step can read them (single detection source).
{
    echo "QUEUE_CONNECTION=$QUEUE_CONNECTION"
    echo "WORKER_STATE=$WORKER_STATE"
    echo "BACKLOG=$BACKLOG"
    echo "WORKER_SETUP_CMD=$WORKER_SETUP_CMD"
} > "$HEALTH_FILE" 2>/dev/null || true

echo "queue health: connection=$QUEUE_CONNECTION worker=$WORKER_STATE backlog=$BACKLOG"
if [ "$WORKER_STATE" = "missing" ]; then
    echo "::warning::[$APP] No queue:work worker running for $DOMAIN (QUEUE_CONNECTION=$QUEUE_CONNECTION, $BACKLOG job(s) pending). Async jobs will NOT be processed. Run as root on the VPS: $WORKER_SETUP_CMD  (or add the NOPASSWD sudoers opt-in — see VPS-DEPLOY-RUNBOOK.md)."
    echo "WARNING: queue worker MISSING for $DOMAIN — run: $WORKER_SETUP_CMD" >&2
fi

# --- Prune old releases (keep last 5) -------------------------------------
ls -1dt "$RELEASES"/*/ 2>/dev/null | tail -n +6 | xargs -r rm -rf
echo "vps-deploy.sh: activated $APP @ $REL"
