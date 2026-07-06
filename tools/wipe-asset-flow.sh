#!/bin/bash
# Wipe asset-flow's deployed state to free Hostinger inodes (~160k freed).
# Keeps the domain shell (Hostinger created it) so it can be re-deployed later.

set -e

D=~/domains/asset-flow.codenzia.com

if [ ! -d "$D" ]; then
  echo "asset-flow domain dir not present — nothing to wipe."
  exit 0
fi

echo "Before:  $(find "$D" 2>/dev/null | wc -l) inodes under $D"

# Remove the app tree (releases + shared + current symlink) and the docroot.
rm -rf "$D/apps" "$D/public_html"

# Re-create empty public_html so Hostinger's nginx doesn't 502 if someone hits it.
mkdir -p "$D/public_html"

echo "After:   $(find "$D" 2>/dev/null | wc -l) inodes under $D"
echo ""
echo "Account inodes now:"
quota -s 2>/dev/null | tail -2 || df -i ~ | tail -2
