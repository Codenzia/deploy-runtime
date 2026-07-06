#!/bin/bash
# Swap codenzia.com from WordPress to Laravel (CodenziaWebsite).
# - Archives current public_html to public_html-wordpress-backup/ (DOESN'T touch old.codenzia.com)
# - Runs provision-app.sh so apps/shared/ exists
# - Seeds the .env with APP_KEY + CONSOLE password (only if missing)

set -e

DOMAIN=codenzia.com
APP=codenzia-website
SHARED=~/domains/$DOMAIN/apps/shared

# 1. Sanity-check old.codenzia.com is still its OWN public_html (not a symlink to codenzia.com).
if [ -L ~/domains/old.codenzia.com/public_html ]; then
  echo "ERROR: old.codenzia.com/public_html is a symlink — aborting to protect the mirror."
  ls -l ~/domains/old.codenzia.com/public_html
  exit 1
fi

# 2. Archive current WP docroot (idempotent — keeps oldest backup).
PH=~/domains/$DOMAIN/public_html
BK=~/domains/$DOMAIN/public_html-wordpress-backup
if [ -d "$PH" ] && [ ! -L "$PH" ] && [ ! -d "$BK" ]; then
  echo "Archiving $PH -> $BK"
  mv "$PH" "$BK"
fi

# 3. Provision Laravel layout
~/codenzia/deploy-runtime/provision-app.sh $APP $DOMAIN > /dev/null

# 4. Seed .env if not already
if [ -s "$SHARED/.env" ] && grep -q "^APP_KEY=base64:" "$SHARED/.env"; then
  echo "($SHARED/.env already seeded — kept)"
else
  APP_KEY="base64:$(openssl rand -base64 32)"
  CPW=$(openssl rand -base64 18 | tr -d "+/=" | head -c 24)
  cat > "$SHARED/.env" <<INNER
APP_NAME="Codenzia"
APP_ENV=production
APP_KEY=$APP_KEY
APP_DEBUG=false
APP_URL=https://$DOMAIN

LOG_CHANNEL=daily
LOG_LEVEL=warning

DB_CONNECTION=sqlite
DB_DATABASE=/home/u396571706/domains/$DOMAIN/apps/shared/database.sqlite

CACHE_DRIVER=file
SESSION_DRIVER=file
QUEUE_CONNECTION=database

CONSOLE_USER=admin
CONSOLE_PASSWORD=$CPW
INNER
  chmod 600 "$SHARED/.env"
  echo "Seeded $SHARED/.env  (CONSOLE_PASSWORD=$CPW)"
fi

echo ""
echo "Done. codenzia.com is now ready for CodenziaWebsite deploy."
echo "Old WP files preserved at $BK (delete later if you want)."
echo "old.codenzia.com untouched and still serving the WP mirror."
