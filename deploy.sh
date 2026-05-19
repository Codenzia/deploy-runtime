#!/usr/bin/env bash
# Release activator. Runs on the Hostinger Cloud Startup host after CI has
# rsynced the new release into apps/releases/$REL. Reads its config from env:
#   APP          short app name, e.g. serveeta
#   DOMAIN       full subdomain, e.g. serveeta.codenzia.com
#   REL          release id (timestamp-sha), e.g. 20260518T120000Z-abc1234
#   FRESH        "true" to migrate:fresh + reseed, default "false"
#   DEMO_SEEDER  seeder class for FRESH path, default "DemoSeeder"
#   PHP_BIN      php binary path, default /usr/bin/php (Hostinger uses a single
#                php binary aliased to the version configured per-domain)
#
# Hostinger Cloud Startup pins the doc root at `public_html/`, so this
# activator rsyncs the staged release into public_html/ (overwriting),
# then re-establishes the symlinks from public_html/ into apps/shared/
# for .env, storage, and the SQLite DB. There is no `apps/current`
# symlink in this flow — public_html/ IS the live tree.
set -euo pipefail

: "${APP:?APP is required}"
: "${DOMAIN:?DOMAIN is required}"
: "${REL:?REL is required}"
FRESH="${FRESH:-false}"
DEMO_SEEDER="${DEMO_SEEDER:-DemoSeeder}"
PHP_BIN="${PHP_BIN:-/usr/bin/php}"

DOMAIN_DIR="$HOME/domains/$DOMAIN"
APPS="$DOMAIN_DIR/apps"
PUB="$DOMAIN_DIR/public_html"
R="$APPS/releases/$REL"
LOG_DIR="$HOME/logs/$APP"
SHARED="$APPS/shared"
DB_FILE="$SHARED/database.sqlite"
ENV_FILE="$SHARED/.env"
TOPLEVEL_HTACCESS_SRC="$APPS/.htaccess.public_html"

if [ ! -d "$R" ]; then
    echo "FATAL: release directory $R does not exist" >&2
    exit 1
fi
if [ ! -f "$ENV_FILE" ]; then
    echo "FATAL: $ENV_FILE not seeded; run first-deploy bootstrap" >&2
    exit 1
fi
if [ ! -d "$SHARED/storage" ]; then
    echo "FATAL: $SHARED/storage not seeded; run first-deploy bootstrap" >&2
    exit 1
fi
if [ ! -f "$DB_FILE" ]; then
    echo "creating SQLite file at $DB_FILE"
    touch "$DB_FILE"
    chmod 664 "$DB_FILE"
fi

mkdir -p "$LOG_DIR"
mkdir -p "$PUB"

# Local rsync from staged release into the live doc root. --delete cleans
# stale files; exclusions preserve the top-level .htaccess that rewrites
# into /public/, plus the symlinks managed below.
rsync -a --delete \
    --exclude='/.htaccess' \
    --exclude='/.env' \
    --exclude='/storage' \
    --exclude='/database/database.sqlite' \
    "$R/" "$PUB/"

# Top-level Hostinger rewrite (only install if missing — never overwrite
# an existing one the operator may have customized).
if [ ! -f "$PUB/.htaccess" ] && [ -f "$TOPLEVEL_HTACCESS_SRC" ]; then
    cp "$TOPLEVEL_HTACCESS_SRC" "$PUB/.htaccess"
    echo "installed top-level .htaccess from $TOPLEVEL_HTACCESS_SRC"
fi

# Shared-state symlinks into public_html/.
ln -sfn "$ENV_FILE" "$PUB/.env"

if [ -L "$PUB/storage" ] || [ -d "$PUB/storage" ]; then
    rm -rf "$PUB/storage"
fi
ln -sfn "$SHARED/storage" "$PUB/storage"

mkdir -p "$PUB/database"
if [ -L "$PUB/database/database.sqlite" ] || [ -f "$PUB/database/database.sqlite" ]; then
    rm -f "$PUB/database/database.sqlite"
fi
ln -sfn "$DB_FILE" "$PUB/database/database.sqlite"

cd "$PUB"

# Hostinger disables PHP's symlink() / link() / exec() / shell_exec(), so
# `php artisan storage:link` blows up with "Call to undefined function exec()".
# Build the public/storage symlink directly with bash instead — equivalent
# result, no PHP shell-out needed.
ln -sfn "$SHARED/storage/app/public" "$PUB/public/storage"

if [ "$FRESH" = "true" ]; then
    echo "FRESH=true → migrate:fresh + db:seed --class=$DEMO_SEEDER"
    "$PHP_BIN" artisan migrate:fresh --force
    "$PHP_BIN" artisan db:seed --class="$DEMO_SEEDER" --force
else
    "$PHP_BIN" artisan migrate --force
fi

"$PHP_BIN" artisan config:cache
"$PHP_BIN" artisan route:cache
"$PHP_BIN" artisan view:cache
"$PHP_BIN" artisan event:cache
"$PHP_BIN" artisan filament:cache-components || true
"$PHP_BIN" artisan filament:assets || true

pkill -f "artisan queue:work" 2>/dev/null || true

# Keep last 5 staged releases for inspection / rollback diff.
ls -1dt "$APPS/releases"/* 2>/dev/null | tail -n +6 | xargs -r rm -rf

echo "deploy.sh: activated $APP @ $REL into $PUB"
