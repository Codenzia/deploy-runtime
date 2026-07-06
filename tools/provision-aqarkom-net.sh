#!/bin/bash
# Provision aqarkom.net (aqarkom-pro tier) — runs once, seeds .env if missing.
set -e

APP=aqarkom-net
DOM=aqarkom.net
SHARED=~/domains/$DOM/apps/shared

~/codenzia/deploy-runtime/provision-app.sh $APP $DOM > /dev/null

if [ -s "$SHARED/.env" ] && grep -q "^APP_KEY=base64:" "$SHARED/.env"; then
  echo "($SHARED/.env already seeded — kept)"
else
  APP_KEY="base64:$(openssl rand -base64 32)"
  CPW=$(openssl rand -base64 18 | tr -d "+/=" | head -c 24)
  cat > "$SHARED/.env" <<INNER
APP_NAME="Aqarkom"
APP_ENV=production
APP_KEY=$APP_KEY
APP_DEBUG=false
APP_URL=https://$DOM

LOG_CHANNEL=daily
LOG_LEVEL=warning

DB_CONNECTION=sqlite
DB_DATABASE=/home/u396571706/domains/$DOM/apps/shared/database.sqlite

CACHE_DRIVER=file
SESSION_DRIVER=file
QUEUE_CONNECTION=database

CONSOLE_USER=admin
CONSOLE_PASSWORD=$CPW
INNER
  chmod 600 "$SHARED/.env"
  echo "Seeded $SHARED/.env  (CONSOLE_PASSWORD=$CPW)"
fi
