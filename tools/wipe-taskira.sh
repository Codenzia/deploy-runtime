#!/bin/bash
# Wipe taskira (task-off) deployed state to free Hostinger inodes.
# Standalone Codenzia/task-off is superseded by task-off-workspace monorepo —
# this taskira.codenzia.com slot is no longer in active use.

set -e

D=~/domains/taskira.codenzia.com

if [ ! -d "$D" ]; then
  echo "taskira domain dir not present — nothing to wipe."
  exit 0
fi

echo "Before:  $(find "$D" 2>/dev/null | wc -l) inodes under $D"

rm -rf "$D/apps" "$D/public_html"
mkdir -p "$D/public_html"

echo "After:   $(find "$D" 2>/dev/null | wc -l) inodes under $D"
