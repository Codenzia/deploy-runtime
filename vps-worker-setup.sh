#!/usr/bin/env bash
# One-time (per app) root setup of the queue worker (supervisor) + Laravel
# scheduler cron for a Codenzia VPS site. Run AS ROOT. Idempotent — safe to
# re-run (e.g. to point the worker at a new PHP binary).
#
# This is intentionally NOT part of vps-deploy.sh: the deploy activator runs as
# the unprivileged site user, and installing packages / writing /etc/supervisor
# / systemctl all need root. Provisioning like this belongs to a one-time root
# step, not a per-deploy (or web-panel) action. The deploy pipeline ships this
# script to the host at htdocs/<domain>/.deploy/ so you only run one line.
#
# Usage:
#   sudo bash vps-worker-setup.sh APP DOMAIN SITE_USER [PHP_BIN]
# Example:
#   sudo bash vps-worker-setup.sh dari dari.codenzia.com codenzia-dari php8.3
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "FATAL: run as root (sudo bash $0 ...)" >&2
    exit 1
fi
if [ $# -lt 3 ]; then
    echo "Usage: $0 APP DOMAIN SITE_USER [PHP_BIN]" >&2
    exit 1
fi

APP="$1"
DOMAIN="$2"
SITE_USER="$3"
PHP_BIN="${4:-php8.3}"
SITE_DIR="/home/$SITE_USER/htdocs/$DOMAIN"
LOG_DIR="$SITE_DIR/shared/storage/logs"

if [ ! -e "$SITE_DIR/current" ]; then
    echo "FATAL: $SITE_DIR/current not found — run a deploy first, then this." >&2
    exit 1
fi

# cron and supervisor run with a minimal PATH, where a bare `php` can resolve to
# a different version than the one the site was built for. Pin the absolute
# binary, and refuse one that cannot reach the site's database driver.
PHP_ABS="$(command -v "$PHP_BIN" 2>/dev/null || true)"
if [ -z "$PHP_ABS" ]; then
    echo "FATAL: PHP binary '$PHP_BIN' not found on this host." >&2
    exit 1
fi
PHP_BIN="$PHP_ABS"
DB_DRIVER="$(grep -E '^DB_CONNECTION=' "$SITE_DIR/shared/.env" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\042\047' || true)"
if [ "$DB_DRIVER" = "pgsql" ] && ! "$PHP_BIN" -m 2>/dev/null | grep -qx 'pdo_pgsql'; then
    echo "FATAL: $PHP_BIN has no pdo_pgsql, but $DOMAIN uses PostgreSQL. Install the extension for this PHP version first." >&2
    exit 1
fi

# 1. supervisor — install once per box (no-op if already present).
if ! command -v supervisorctl >/dev/null 2>&1; then
    echo "→ installing supervisor"
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        echo "  waiting for another apt/dpkg to release the lock…"; sleep 5
    done
    apt-get update -y
    apt-get install -y supervisor
fi
systemctl enable --now supervisor

# 2. per-app worker program. command points at current/ (the atomic symlink),
#    so it always runs the live release; queue:restart picks up new code.
CONF="/etc/supervisor/conf.d/${APP}-worker.conf"
cat > "$CONF" <<EOF
[program:${APP}-worker]
command=${PHP_BIN} ${SITE_DIR}/current/artisan queue:work --sleep=1 --tries=3 --max-time=3600
user=${SITE_USER}
numprocs=1
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=${LOG_DIR}/worker.log
stopwaitsecs=3600
EOF
echo "→ wrote $CONF"

mkdir -p "$LOG_DIR"
chown "$SITE_USER:$SITE_USER" "$LOG_DIR" 2>/dev/null || true

supervisorctl reread
supervisorctl update
supervisorctl restart "${APP}-worker" 2>/dev/null || supervisorctl start "${APP}-worker" 2>/dev/null || true

# 3. Laravel scheduler cron for the site user (idempotent).
CRON_LINE="* * * * * cd ${SITE_DIR}/current && ${PHP_BIN} artisan schedule:run >> ${SITE_DIR}/shared/storage/logs/schedule.log 2>&1"
if crontab -u "$SITE_USER" -l 2>/dev/null | grep -Fxq "$CRON_LINE"; then
    echo "→ scheduler cron already present for $SITE_USER"
else
    # Any older scheduler line (another PHP binary, another path) is replaced,
    # not kept beside the new one. `crontab -l` exits 1 when the user has no
    # crontab yet; under set -e that aborted the subshell before the echo, so
    # an EMPTY crontab was installed and the script died here.
    { crontab -u "$SITE_USER" -l 2>/dev/null | grep -Fv "artisan schedule:run" || true; echo "$CRON_LINE"; } | crontab -u "$SITE_USER" -
    echo "→ installed scheduler cron for $SITE_USER: $CRON_LINE"
fi

echo
echo "== done: queue worker + scheduler for $APP ($DOMAIN) =="
supervisorctl status "${APP}-worker" || true
