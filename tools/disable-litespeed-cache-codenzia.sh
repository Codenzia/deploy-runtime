#!/bin/bash
# Disable LiteSpeed full-page cache for codenzia.com — Laravel responses are
# dynamic and shouldn't be cached at the edge. Without this, stale WP HTML
# (cached before the swap) keeps re-appearing.
set -e

PH=~/domains/codenzia.com/public_html
HT="$PH/.htaccess"

# Prepend the bypass rule if it's not already there.
if grep -q "CacheDisable public" "$HT" 2>/dev/null; then
  echo "LiteSpeed bypass already in place — nothing to do."
else
  TMP="$PH/.htaccess.new"
  {
    echo "<IfModule LiteSpeed>"
    echo "    CacheDisable public /"
    echo "</IfModule>"
    echo ""
    cat "$HT" 2>/dev/null || true
  } > "$TMP"
  mv "$TMP" "$HT"
  echo "Prepended LiteSpeed bypass to $HT"
fi
echo ""
echo "Now purge the cached pages in hPanel → Cache Manager → Purge All."
