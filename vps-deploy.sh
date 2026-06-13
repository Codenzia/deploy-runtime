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
    *)
        echo "FATAL: unknown DB='$DB' (expected 'sqlite' or 'mysql')" >&2
        exit 1
        ;;
esac

case "$MODE" in
    debug)
        echo "MODE=debug → APP_ENV=local APP_DEBUG=true"
        sed -i 's/^APP_DEBUG=.*/APP_DEBUG=true/' "$ENV_FILE"
        sed -i 's/^APP_ENV=.*/APP_ENV=local/'    "$ENV_FILE"
        ;;
    release|"")
        echo "MODE=release → APP_ENV=production APP_DEBUG=false"
        sed -i 's/^APP_DEBUG=.*/APP_DEBUG=false/'  "$ENV_FILE"
        sed -i 's/^APP_ENV=.*/APP_ENV=production/'  "$ENV_FILE"
        ;;
    *)
        echo "FATAL: unknown MODE='$MODE' (expected 'release' or 'debug')" >&2
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

# --- Prune old releases (keep last 5) -------------------------------------
ls -1dt "$RELEASES"/*/ 2>/dev/null | tail -n +6 | xargs -r rm -rf
echo "vps-deploy.sh: activated $APP @ $REL"
