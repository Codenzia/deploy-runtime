#!/usr/bin/env bash
# Release activator. Runs on the Hostinger Cloud Startup host after CI has
# rsynced the new release into apps/releases/$REL. Reads its config from env:
#   APP          short app name, e.g. serveeta
#   DOMAIN       full subdomain, e.g. serveeta.codenzia.com
#   REL          release id (timestamp-sha), e.g. 20260518T120000Z-abc1234
#   FRESH        "true" to migrate:fresh + reseed, default "false"
#   MODE         "release" (default) → APP_DEBUG=false, APP_ENV=production
#                "debug"              → APP_DEBUG=true,  APP_ENV=local
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
MODE="${MODE:-release}"
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

# Apply MODE (release|debug) by rewriting the shared .env. Done in-place so
# the keys are preserved across deploys (rsync excludes /.env). Caches are
# rebuilt below, so changes take effect on the next request.
case "$MODE" in
    debug)
        echo "MODE=debug → APP_DEBUG=true APP_ENV=local LOG_LEVEL=debug"
        sed -i 's/^APP_DEBUG=.*/APP_DEBUG=true/'   "$ENV_FILE"
        sed -i 's/^APP_ENV=.*/APP_ENV=local/'      "$ENV_FILE"
        if grep -q '^LOG_LEVEL=' "$ENV_FILE"; then
            sed -i 's/^LOG_LEVEL=.*/LOG_LEVEL=debug/' "$ENV_FILE"
        else
            echo 'LOG_LEVEL=debug' >> "$ENV_FILE"
        fi
        ;;
    release|"")
        echo "MODE=release → APP_DEBUG=false APP_ENV=production LOG_LEVEL=error"
        sed -i 's/^APP_DEBUG=.*/APP_DEBUG=false/'    "$ENV_FILE"
        sed -i 's/^APP_ENV=.*/APP_ENV=production/'   "$ENV_FILE"
        if grep -q '^LOG_LEVEL=' "$ENV_FILE"; then
            sed -i 's/^LOG_LEVEL=.*/LOG_LEVEL=error/' "$ENV_FILE"
        else
            echo 'LOG_LEVEL=error' >> "$ENV_FILE"
        fi
        ;;
    *)
        echo "FATAL: unknown MODE='$MODE' (expected 'release' or 'debug')" >&2
        exit 1
        ;;
esac

if [ "$FRESH" = "true" ]; then
    # Demo-host guard: migrate:fresh is destructive (drops all tables).
    # Allow it only on Codenzia-controlled demo subdomains; refuse on any
    # other host (e.g. when an app gets promoted to a customer URL later).
    # If a future operator legitimately needs to reset a non-demo host,
    # they can do it manually via /console or extend the allowlist below.
    case "$DOMAIN" in
        *.codenzia.com)
            echo "FRESH=true on demo host '$DOMAIN' → migrate:fresh + db:seed --class=$DEMO_SEEDER"
            "$PHP_BIN" artisan migrate:fresh --force
            "$PHP_BIN" artisan db:seed --class="$DEMO_SEEDER" --force
            ;;
        *)
            echo "FATAL: FRESH=true refused — '$DOMAIN' is not a Codenzia demo host." >&2
            echo "       migrate:fresh would drop every table. If you really meant this," >&2
            echo "       run it manually via /console after weighing the data loss." >&2
            exit 1
            ;;
    esac
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
