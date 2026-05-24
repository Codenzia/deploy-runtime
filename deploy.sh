#!/usr/bin/env bash
# Release activator. Runs on the Hostinger Cloud Startup host after CI has
# rsynced the new release into apps/releases/$REL. Reads its config from env:
#   APP          short app name, e.g. serveeta
#   DOMAIN       full subdomain, e.g. serveeta.codenzia.com
#   REL          release id (timestamp-sha), e.g. 20260518T120000Z-abc1234
#   FRESH        "true" to migrate:fresh + reseed, default "false"
#   MODE         "release" (default) → APP_DEBUG=false, APP_ENV=production
#                "debug"              → APP_DEBUG=true,  APP_ENV=local
#   MIGRATE      "true" to one-shot move existing public_html state (real .env,
#                SQLite DB, storage uploads) into apps/shared/ before the
#                deploy proceeds. Use on first CI deploy of an app that was
#                previously deployed manually (FTP, /console, etc.).
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
MIGRATE="${MIGRATE:-false}"
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

# Pre-deploy snapshot — always take a tarball of public_html before any
# rsync touches it, in case the drift guard below misses something or
# content surfaces that the operator didn't expect. Kept in
# ~/backups/<app>/pre-deploy-<stamp>.tar.gz; retain last 3 to bound disk.
PREDEPLOY_TARBALL=""
if [ -d "$PUB" ] && [ -n "$(ls -A "$PUB" 2>/dev/null)" ]; then
    BACKUP_DIR="$HOME/backups/$APP"
    mkdir -p "$BACKUP_DIR"
    STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
    PREDEPLOY_TARBALL="$BACKUP_DIR/pre-deploy-${STAMP}.tar.gz"
    if tar -czf "$PREDEPLOY_TARBALL" -C "$DOMAIN_DIR" public_html 2>/dev/null; then
        SIZE="$(du -sh "$PREDEPLOY_TARBALL" 2>/dev/null | cut -f1)"
        echo "pre-deploy snapshot: $PREDEPLOY_TARBALL ($SIZE)"
        ls -1t "$BACKUP_DIR"/pre-deploy-*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f
    else
        echo "pre-deploy snapshot SKIPPED (tar failed)" >&2
        PREDEPLOY_TARBALL=""
    fi
fi

# Drift detection — refuse to overwrite real state in public_html that
# would be destroyed by the rsync + symlink re-bind below. Operator opts
# into one-shot migration by setting MIGRATE=true.
DRIFT=()

if [ -f "$PUB/.env" ] && [ ! -L "$PUB/.env" ] && grep -q '^APP_KEY=' "$PUB/.env" 2>/dev/null; then
    DRIFT+=("$PUB/.env  (real file with APP_KEY)")
fi

if [ -f "$PUB/database/database.sqlite" ] && [ ! -L "$PUB/database/database.sqlite" ]; then
    DB_BYTES="$(stat -c%s "$PUB/database/database.sqlite" 2>/dev/null || echo 0)"
    if [ "$DB_BYTES" -gt 0 ]; then
        DRIFT+=("$PUB/database/database.sqlite  ($DB_BYTES bytes)")
    fi
fi

if [ -d "$PUB/storage" ] && [ ! -L "$PUB/storage" ]; then
    STORAGE_FILES="$(find "$PUB/storage/app" -type f 2>/dev/null | wc -l)"
    if [ "$STORAGE_FILES" -gt 0 ]; then
        DRIFT+=("$PUB/storage  (real dir, $STORAGE_FILES files under storage/app/)")
    fi
fi

if [ "${#DRIFT[@]}" -gt 0 ]; then
    if [ "$MIGRATE" != "true" ]; then
        {
            echo ""
            echo "================================================================"
            echo "FATAL: public_html has state that would be destroyed on deploy"
            echo "================================================================"
            for item in "${DRIFT[@]}"; do
                echo "  - $item"
            done
            echo ""
            if [ -n "$PREDEPLOY_TARBALL" ]; then
                echo "Pre-deploy snapshot already taken: $PREDEPLOY_TARBALL"
                echo ""
            fi
            echo "To migrate this state into apps/shared/ and proceed, re-run the"
            echo "workflow with the 'migrate' input checked (MIGRATE=true). Migration"
            echo "is one-shot: once state lives in apps/shared/, future deploys find"
            echo "symlinks in place and proceed normally."
        } >&2
        exit 1
    fi

    # MIGRATE=true: move real public_html state into apps/shared/ where
    # the symlink re-bind below will find it. Per-item refuse if shared
    # already holds content for that piece (avoid silent reconciliation).
    echo "MIGRATE=true → moving public_html state into apps/shared/"

    if [ -f "$PUB/.env" ] && [ ! -L "$PUB/.env" ] && grep -q '^APP_KEY=' "$PUB/.env" 2>/dev/null; then
        if [ -s "$ENV_FILE" ] && grep -q '^APP_KEY=' "$ENV_FILE" 2>/dev/null; then
            echo "FATAL: $PUB/.env and $ENV_FILE both have APP_KEY — reconcile manually." >&2
            exit 1
        fi
        mv "$PUB/.env" "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        echo "  migrated $PUB/.env → $ENV_FILE"
    fi

    if [ -f "$PUB/database/database.sqlite" ] && [ ! -L "$PUB/database/database.sqlite" ]; then
        DB_BYTES="$(stat -c%s "$PUB/database/database.sqlite" 2>/dev/null || echo 0)"
        if [ "$DB_BYTES" -gt 0 ]; then
            EXISTING_DB_BYTES="$(stat -c%s "$DB_FILE" 2>/dev/null || echo 0)"
            if [ "$EXISTING_DB_BYTES" -gt 0 ]; then
                echo "FATAL: $PUB/database/database.sqlite and $DB_FILE both have content — reconcile manually." >&2
                exit 1
            fi
            mv "$PUB/database/database.sqlite" "$DB_FILE"
            echo "  migrated $PUB/database/database.sqlite → $DB_FILE"
        fi
    fi

    if [ -d "$PUB/storage" ] && [ ! -L "$PUB/storage" ]; then
        STORAGE_FILES="$(find "$PUB/storage/app" -type f 2>/dev/null | wc -l)"
        if [ "$STORAGE_FILES" -gt 0 ]; then
            rsync -a --remove-source-files "$PUB/storage/" "$SHARED/storage/"
            find "$PUB/storage" -depth -type d -empty -delete 2>/dev/null || true
            echo "  migrated $PUB/storage → $SHARED/storage  ($STORAGE_FILES files)"
        fi
    fi
fi

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
            # Pre-FRESH backup: gzipped copy of the SQLite file before we drop
            # tables. Lives next to the nightly dumps in ~/backups/demos/<app>/;
            # keep the last 5 pre-fresh snapshots so accidental wipes are
            # recoverable for ~5 deploys, then auto-prune.
            if [ -f "$DB_FILE" ] && [ -s "$DB_FILE" ]; then
                BACKUP_DIR="$HOME/backups/demos/$APP"
                mkdir -p "$BACKUP_DIR"
                STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
                BACKUP_FILE="$BACKUP_DIR/pre-fresh-${STAMP}.sqlite.gz"
                gzip -c "$DB_FILE" > "$BACKUP_FILE"
                echo "pre-FRESH backup written: $BACKUP_FILE ($(stat -c%s "$BACKUP_FILE" 2>/dev/null || stat -f%z "$BACKUP_FILE") bytes)"
                # Retain only the 5 most recent pre-fresh snapshots.
                ls -1t "$BACKUP_DIR"/pre-fresh-*.sqlite.gz 2>/dev/null | tail -n +6 | xargs -r rm -f
            else
                echo "pre-FRESH backup skipped: $DB_FILE is empty or missing"
            fi
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

# Wipe every cache (config / route / view / event / compiled) before
# rebuilding. apps/shared/storage/framework/views/ persists across
# releases by design (it's part of shared/), so stale compiled blade
# files for stuff like `App\Filament\pages\...` (older case-sensitivity
# bug that has since been fixed in source) survive without this. The
# subsequent *:cache commands then write fresh files.
"$PHP_BIN" artisan optimize:clear

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
