#!/bin/bash
# Bulk provision + .env seed for 14 Codenzia apps on Hostinger.
# Invoked remotely via: ssh ... 'bash -s' < provision-all-apps.sh

PROVISION=~/codenzia/deploy-runtime/provision-app.sh

declare -A APPS=(
  [bmp]="bmp.codenzia.com"
  [larafilcommerce]="ecom.codenzia.com"
  [gamephoria]="gamephoria.codenzia.com"
  [larafilpos]="pos.codenzia.com"
  [larapress]="press.codenzia.com"
  [plugins-demo]="plugins-demo.codenzia.com"
  [asset-flow]="asset-flow.codenzia.com"
  [swiftdelivery]="swiftdelivery.codenzia.com"
  [snapcar]="snapcar.codenzia.com"
  [taskira]="taskira.codenzia.com"
  [dropflow]="dropflow.codenzia.com"
  [tajir-express]="tajirexpress.codenzia.com"
  [wikibanknotes]="wikibanknotes.codenzia.com"
  [mos]="mos.codenzia.com"
)

declare -A NAMES=(
  [bmp]="BuyMyProducts" [larafilcommerce]="LaraFilCommerce" [gamephoria]="Gamephoria"
  [larafilpos]="LarafilPos" [larapress]="LaraPress" [plugins-demo]="PluginsDemo"
  [asset-flow]="AssetFlow" [swiftdelivery]="SwiftDelivery" [snapcar]="SnapCar"
  [taskira]="Taskira" [dropflow]="DropFlow" [tajir-express]="TajirExpress"
  [wikibanknotes]="WikiBankNotes" [mos]="MyOwnStore"
)

echo ""
printf '%-20s %-32s %s\n' "app" "domain" "console"
printf '%-20s %-32s %s\n' "---" "------" "-------"

for app in "${!APPS[@]}"; do
  dom="${APPS[$app]}"
  if [ ! -d "$HOME/domains/$dom" ]; then
    found=$(ls "$HOME/domains/" 2>/dev/null | grep -i "^${dom}$" | head -1)
    if [ -n "$found" ]; then dom="$found"; fi
  fi
  if [ ! -d "$HOME/domains/$dom" ]; then
    printf '%-20s %-32s MISSING (create subdomain in hPanel)\n' "$app" "$dom"
    continue
  fi
  $PROVISION "$app" "$dom" > /dev/null 2>&1
  ENV_FILE=~/domains/$dom/apps/shared/.env
  if [ -s "$ENV_FILE" ] && grep -q "^APP_KEY=base64:" "$ENV_FILE" 2>/dev/null; then
    printf '%-20s %-32s (already seeded - kept existing)\n' "$app" "$dom"
    continue
  fi
  APP_KEY="base64:$(openssl rand -base64 32)"
  CPW=$(openssl rand -base64 18 | tr -d "+/=" | head -c 24)
  cat > "$ENV_FILE" <<INNER
APP_NAME="${NAMES[$app]}"
APP_ENV=demo
APP_KEY=$APP_KEY
APP_DEBUG=false
APP_URL=https://$dom

LOG_CHANNEL=daily
LOG_LEVEL=warning

DB_CONNECTION=sqlite
DB_DATABASE=/home/u396571706/domains/$dom/apps/shared/database.sqlite

CACHE_DRIVER=file
SESSION_DRIVER=file
QUEUE_CONNECTION=database

CONSOLE_USER=admin
CONSOLE_PASSWORD=$CPW
INNER
  chmod 600 "$ENV_FILE"
  printf '%-20s %-32s %s\n' "$app" "$dom" "$CPW"
done
