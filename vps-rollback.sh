#!/usr/bin/env bash
# Points a site's `current` symlink back at an earlier release. Runs AS THE
# SITE'S LINUX USER on the host:
#   bash ~/htdocs/<domain>/.deploy/vps-rollback.sh <domain> [release-id]
# Without a release id it goes to the newest release older than the live one.
#
# Code only: migrations already applied stay applied. That is safe only while
# every migration is additive (expand first, remove columns in a later release
# once no live code reads them). For a migration that broke the old code,
# restore the pre-deploy dump from shared/backups instead.
set -euo pipefail

DOMAIN="${1:?usage: vps-rollback.sh <domain> [release-id]}"
TARGET_REL="${2:-}"
PHP_BIN="${PHP_BIN:-$(command -v php8.3 || command -v php || echo /usr/bin/php)}"

SITE_DIR="$HOME/htdocs/$DOMAIN"
RELEASES="$SITE_DIR/releases"
CURRENT="$SITE_DIR/current"

LIVE="$(basename "$(readlink -f "$CURRENT")")"

if [ -z "$TARGET_REL" ]; then
    # Release ids start with a UTC timestamp, so a name sort is a time sort.
    TARGET_REL="$(ls -1 "$RELEASES" | sort | awk -v live="$LIVE" '$0 < live' | tail -n 1)"
fi

if [ -z "$TARGET_REL" ] || [ ! -d "$RELEASES/$TARGET_REL" ]; then
    echo "FATAL: no release to roll back to (live: $LIVE, requested: ${2:-previous})." >&2
    ls -1 "$RELEASES" >&2
    exit 1
fi
if [ "$TARGET_REL" = "$LIVE" ]; then
    echo "FATAL: $TARGET_REL is already live." >&2
    exit 1
fi

echo "rolling back $DOMAIN: $LIVE → $TARGET_REL"
ln -sfn "$RELEASES/$TARGET_REL" "$CURRENT.tmp"
mv -Tf "$CURRENT.tmp" "$CURRENT"

# Workers hold the newer code in memory until told to restart.
"$PHP_BIN" "$CURRENT/artisan" queue:restart || true
for svc in "php8.3-fpm" "php8.3-fpm@$USER" "php-fpm"; do
    sudo -n systemctl reload "$svc" >/dev/null 2>&1 && { echo "reloaded $svc"; break; }
done
sudo -n varnishadm "ban req.url ~ ^/" >/dev/null 2>&1 || true

echo "current → $RELEASES/$TARGET_REL"
