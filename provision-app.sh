#!/usr/bin/env bash
# One-time bootstrap of a new demo app on the Hostinger Cloud Startup host.
# Idempotent — safe to re-run.
#
# Usage:
#   provision-app.sh APP DOMAIN
# Example:
#   provision-app.sh serveeta serveeta.codenzia.com
#
# After this completes:
#   1. Seed apps/shared/.env from .env.example (APP_KEY, DB_CONNECTION=sqlite,
#      DB_DATABASE=<absolute path to apps/shared/database.sqlite>, etc.)
#   2. In hPanel → Advanced → Cron Jobs, add the two cron lines printed below.
#   3. Append the repo's deploy public key to ~/.ssh/authorized_keys.
#   4. First deploy from GitHub Actions, or via /console route.
#
# Notes:
#   - Hostinger Cloud Startup pins the doc root at public_html/. Don't try
#     to repoint it; this flow accepts that and uses public_html as the
#     live Laravel root with a top-level .htaccess that rewrites into
#     /public/.
#   - SQLite by default. apps/shared/database.sqlite is created here and
#     symlinked into public_html/database/ by the release activator.
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 APP DOMAIN" >&2
    exit 1
fi

APP="$1"
DOMAIN="$2"
DOMAIN_DIR="$HOME/domains/$DOMAIN"
APPS="$DOMAIN_DIR/apps"
SHARED="$APPS/shared"
LOG_DIR="$HOME/logs/$APP"
RUNTIME_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -d "$DOMAIN_DIR" ]; then
    echo "FATAL: $DOMAIN_DIR does not exist. Create the subdomain in hPanel first." >&2
    exit 1
fi

mkdir -p "$APPS/releases"
mkdir -p "$SHARED"
mkdir -p "$SHARED/storage/app/public"
mkdir -p "$SHARED/storage/framework/cache/data"
mkdir -p "$SHARED/storage/framework/sessions"
mkdir -p "$SHARED/storage/framework/testing"
mkdir -p "$SHARED/storage/framework/views"
mkdir -p "$SHARED/storage/logs"
mkdir -p "$LOG_DIR"
mkdir -p "$DOMAIN_DIR/public_html"

if [ ! -f "$SHARED/database.sqlite" ]; then
    touch "$SHARED/database.sqlite"
    chmod 664 "$SHARED/database.sqlite"
    echo "created SQLite DB at $SHARED/database.sqlite"
fi

if [ ! -f "$SHARED/.env" ]; then
    touch "$SHARED/.env"
    chmod 600 "$SHARED/.env"
    echo "NOTE: $SHARED/.env is empty — seed it before first deploy."
fi

if [ -f "$RUNTIME_DIR/deploy.sh" ]; then
    install -m 0750 "$RUNTIME_DIR/deploy.sh" "$APPS/deploy.sh"
else
    echo "WARNING: $RUNTIME_DIR/deploy.sh not found; you must place apps/deploy.sh manually." >&2
fi

if [ -f "$RUNTIME_DIR/.htaccess.public_html" ]; then
    install -m 0644 "$RUNTIME_DIR/.htaccess.public_html" "$APPS/.htaccess.public_html"
else
    echo "WARNING: $RUNTIME_DIR/.htaccess.public_html not found; top-level rewrite will not auto-install on first deploy." >&2
fi

PHP_BIN="$(command -v php8.3 || command -v php || echo /usr/bin/php)"

cat <<EOF

== provision-app.sh complete for $APP ($DOMAIN) ==

Directories:
  $APPS/releases/                       (CI rsyncs staged releases here)
  $DOMAIN_DIR/public_html/              (live doc root — managed by deploy.sh)
  $SHARED/.env                          $( [ -s "$SHARED/.env" ] && echo "(seeded)" || echo "(EMPTY — seed before first deploy)" )
  $SHARED/storage/                      (Laravel storage tree)
  $SHARED/database.sqlite               (SQLite DB; symlinked into public_html/database/ by deploy.sh)
  $LOG_DIR/                             (scheduler + worker logs)

Detected PHP binary: $PHP_BIN

== Put these absolute paths in $SHARED/.env ==

  DB_CONNECTION=sqlite
  DB_DATABASE=$SHARED/database.sqlite

== Add these cron lines in hPanel → Advanced → Cron Jobs ==

  # Scheduler
  * * * * * cd $DOMAIN_DIR/public_html && $PHP_BIN artisan schedule:run >> $LOG_DIR/schedule.log 2>&1

  # Queue worker (cron-loop pattern; --stop-when-empty + --max-time keeps a fresh process each minute)
  * * * * * cd $DOMAIN_DIR/public_html && $PHP_BIN artisan queue:work database --stop-when-empty --max-time=55 --tries=3 --sleep=1 >> $LOG_DIR/worker.log 2>&1

== Next steps ==
  1. Seed $SHARED/.env (APP_KEY, APP_ENV=demo, APP_URL=https://$DOMAIN, DB_CONNECTION=sqlite, DB_DATABASE=<absolute path above>, CONSOLE_USER/PASSWORD)
  2. Append repo deploy public key to ~/.ssh/authorized_keys
  3. Trigger GitHub Actions deploy (or use /console for first run)
EOF
