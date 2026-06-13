#!/usr/bin/env bash
# One-time bootstrap of a Laravel app on the Codenzia Hostinger KVM VPS
# (CloudPanel). Run AS THE SITE'S LINUX USER (the deploy SSHes in as that
# user, so $HOME == /home/<site-user>). Idempotent — safe to re-run.
#
# Usage:
#   vps-provision.sh APP DOMAIN [--adopt]
# Example:
#   vps-provision.sh task-off task-off.com --adopt
#
# CloudPanel layout: the site lives at /home/<site-user>/htdocs/<domain>/.
# This converts that directory to an atomic-release structure:
#
#   htdocs/<domain>/
#     releases/<rel>/            (CI rsyncs each build here)
#     shared/.env                (real env, symlinked into every release)
#     shared/storage/            (persists across releases)
#     shared/database.sqlite     (SQLite DB, default engine)
#     shared/backups/            (pre-fresh + adopt snapshots)
#     current -> releases/<rel>  (atomic symlink; vhost doc root = current/public)
#
# AFTER this runs, do the one-time root + CloudPanel steps in
# VPS-DEPLOY-RUNBOOK.md (set doc root to current/public, TLS, supervisor,
# optional sudoers for php-fpm reload + Varnish flush), then seed shared/.env.
#
# --adopt: a previous (non-atomic) deployment already has files dumped
# directly in htdocs/<domain>/. Back them up, carry the real .env / SQLite
# DB / storage uploads into shared/, and move the rest aside so the new
# current/public doc root serves cleanly. One-shot; safe to omit on a
# brand-new empty site.
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 APP DOMAIN [--adopt]" >&2
    exit 1
fi

APP="$1"
DOMAIN="$2"
ADOPT="false"
[ "${3:-}" = "--adopt" ] && ADOPT="true"

SITE_DIR="$HOME/htdocs/$DOMAIN"
RELEASES="$SITE_DIR/releases"
SHARED="$SITE_DIR/shared"
DB_FILE="$SHARED/database.sqlite"
ENV_FILE="$SHARED/.env"
BACKUPS="$SHARED/backups"

if [ ! -d "$SITE_DIR" ]; then
    echo "FATAL: $SITE_DIR does not exist." >&2
    echo "       Create the site in the CloudPanel UI first (this also creates" >&2
    echo "       the Linux user + htdocs/<domain> directory)." >&2
    exit 1
fi

# --- Adopt an existing non-atomic deployment ------------------------------
# Detect real state sitting directly in the site dir (not our managed
# releases/ shared/ current). If found and --adopt was passed, snapshot
# everything, carry the durable bits into shared/, and tuck the old tree
# into shared/backups/pre-atomic-<stamp>/ so doc-root=current/public wins.
LOOSE_COUNT="$(find "$SITE_DIR" -maxdepth 1 -mindepth 1 \
    ! -name releases ! -name shared ! -name current 2>/dev/null | wc -l)"

if [ "$LOOSE_COUNT" -gt 0 ]; then
    if [ "$ADOPT" != "true" ]; then
        echo "================================================================"
        echo "NOTICE: $SITE_DIR already contains files from a previous deploy."
        echo "================================================================"
        echo "  $LOOSE_COUNT top-level entries found (excluding releases/ shared/ current)."
        echo ""
        echo "Re-run with --adopt to back them up and carry .env / database /"
        echo "storage into shared/ before converting to atomic releases:"
        echo "    $0 $APP $DOMAIN --adopt"
        echo ""
        echo "(Provisioning will still create releases/ shared/ alongside the"
        echo " old files, but the old tree is left exactly as-is.)"
    fi
fi

mkdir -p "$RELEASES"
mkdir -p "$SHARED"
mkdir -p "$BACKUPS"
mkdir -p "$SHARED/storage/app/public"
mkdir -p "$SHARED/storage/framework/cache/data"
mkdir -p "$SHARED/storage/framework/sessions"
mkdir -p "$SHARED/storage/framework/testing"
mkdir -p "$SHARED/storage/framework/views"
mkdir -p "$SHARED/storage/logs"

if [ "$ADOPT" = "true" ] && [ "$LOOSE_COUNT" -gt 0 ]; then
    STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
    ADOPT_DIR="$BACKUPS/pre-atomic-$STAMP"
    mkdir -p "$ADOPT_DIR"
    echo "--adopt → snapshotting existing tree into $ADOPT_DIR"

    # Carry the real .env (only if shared/.env not already seeded).
    if [ -f "$SITE_DIR/.env" ] && grep -q '^APP_KEY=' "$SITE_DIR/.env" 2>/dev/null; then
        if [ -s "$ENV_FILE" ] && grep -q '^APP_KEY=' "$ENV_FILE" 2>/dev/null; then
            echo "  WARN: shared/.env already has APP_KEY — keeping it; old .env saved to backup only."
        else
            cp -p "$SITE_DIR/.env" "$ENV_FILE"
            chmod 600 "$ENV_FILE"
            echo "  adopted .env → shared/.env"
        fi
    fi

    # Carry the SQLite DB (default engine) if present and non-empty.
    for cand in "$SITE_DIR/database/database.sqlite" "$SITE_DIR/database.sqlite"; do
        if [ -f "$cand" ] && [ -s "$cand" ]; then
            if [ -s "$DB_FILE" ]; then
                echo "  WARN: shared/database.sqlite already has data — old DB saved to backup only."
            else
                cp -p "$cand" "$DB_FILE"
                echo "  adopted $(basename "$cand") → shared/database.sqlite"
            fi
            break
        fi
    done

    # Carry uploaded files (storage/app) into shared/storage.
    if [ -d "$SITE_DIR/storage/app" ]; then
        rsync -a "$SITE_DIR/storage/app/" "$SHARED/storage/app/" 2>/dev/null || true
        echo "  adopted storage/app → shared/storage/app"
    fi

    # Move the entire old tree (everything except our managed dirs) into the
    # snapshot dir so the new current/public doc root serves cleanly.
    find "$SITE_DIR" -maxdepth 1 -mindepth 1 \
        ! -name releases ! -name shared ! -name current \
        -exec mv -t "$ADOPT_DIR" {} + 2>/dev/null || true
    echo "  moved old tree → $ADOPT_DIR (delete it once the new release is verified)"
fi

if [ ! -f "$DB_FILE" ]; then
    touch "$DB_FILE"
    chmod 664 "$DB_FILE"
    echo "created SQLite DB at $DB_FILE"
fi

if [ ! -f "$ENV_FILE" ]; then
    touch "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    cat >> "$ENV_FILE" <<'SEED'
# Seed me before first deploy. Minimum:
#   APP_NAME, APP_KEY (php artisan key:generate --show), APP_ENV, APP_URL
# SQLite (default): DB_CONNECTION + absolute DB_DATABASE printed below.
# MySQL (if you flip db=mysql at deploy time): fill DB_HOST/DATABASE/USERNAME/PASSWORD
#   from the credentials you created in the CloudPanel Databases UI.
# Branding: CODENZIA_BRANDING=false  # uncomment to hide "Powered by Codenzia"
SEED
    echo "NOTE: $ENV_FILE created with hints only — seed it before first deploy."
fi

PHP_BIN="$(command -v php8.3 || command -v php || echo /usr/bin/php)"

cat <<EOF

== vps-provision.sh complete for $APP ($DOMAIN) ==

Layout:
  $RELEASES/                  (CI rsyncs staged releases here)
  $SHARED/.env                $( [ -s "$ENV_FILE" ] && grep -q '^APP_KEY=' "$ENV_FILE" && echo "(seeded)" || echo "(SEED before first deploy)" )
  $SHARED/storage/            (Laravel storage tree)
  $DB_FILE   (SQLite DB)
  $SHARED/backups/            (adopt + pre-fresh snapshots)
  $SITE_DIR/current           (atomic symlink → releases/<rel>; created on first deploy)

Detected PHP: $PHP_BIN

== Put these in $ENV_FILE for the SQLite default ==
  DB_CONNECTION=sqlite
  DB_DATABASE=$DB_FILE

== One-time CloudPanel + root steps (see VPS-DEPLOY-RUNBOOK.md) ==
  1. CloudPanel UI → this site → set doc root (vhost root) to:
       $SITE_DIR/current/public
  2. CloudPanel UI → enable Let's Encrypt for $DOMAIN.
  3. (root) apt install -y supervisor; add a worker program for $APP (runbook).
  4. (root, optional) sudoers entry so deploys can reload php-fpm + flush Varnish.
  5. Append the deploy public key to ~/.ssh/authorized_keys for THIS site user.
EOF
