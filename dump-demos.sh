#!/usr/bin/env bash
# Nightly backup of all demo SQLite databases on the Hostinger Cloud Startup
# host. Keeps the last 7 dumps per app. Designed for a single hPanel cron:
#
#   30 3 * * * /home/<user>/codenzia/deploy-runtime/dump-demos.sh
#
# Walks every ~/domains/*/apps/shared/database.sqlite, gzips it into
# ~/backups/demos/<app>/<app>-<timestamp>.sqlite.gz, and prunes anything
# beyond the last 7 per app.
set -euo pipefail

BACKUP_ROOT="$HOME/backups/demos"
KEEP_PER_APP=7
DATE="$(date -u +%Y%m%dT%H%MZ)"
mkdir -p "$BACKUP_ROOT"

shopt -s nullglob
for db in "$HOME"/domains/*/apps/shared/database.sqlite; do
    [ -s "$db" ] || continue
    domain_dir="$(dirname "$(dirname "$(dirname "$db")")")"
    domain="$(basename "$domain_dir")"
    app="${domain%%.*}"

    out_dir="$BACKUP_ROOT/$app"
    mkdir -p "$out_dir"
    out_file="$out_dir/${app}-${DATE}.sqlite.gz"

    if command -v sqlite3 >/dev/null 2>&1; then
        tmp="$(mktemp)"
        if sqlite3 "$db" ".backup '$tmp'" && gzip -9 -c "$tmp" > "$out_file"; then
            rm -f "$tmp"
            echo "dumped $app -> $out_file ($(stat -c%s "$out_file" 2>/dev/null || stat -f%z "$out_file") bytes)"
        else
            rm -f "$tmp"
            echo "FAILED to dump $app" >&2
            rm -f "$out_file"
            continue
        fi
    elif gzip -9 -c "$db" > "$out_file"; then
        echo "dumped $app -> $out_file ($(stat -c%s "$out_file" 2>/dev/null || stat -f%z "$out_file") bytes)"
    else
        echo "FAILED to dump $app" >&2
        rm -f "$out_file"
        continue
    fi

    ls -1t "$out_dir"/*.sqlite.gz 2>/dev/null | tail -n +$((KEEP_PER_APP + 1)) | xargs -r rm -f
done
