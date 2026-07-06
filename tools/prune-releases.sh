#!/bin/bash
# Keep only the 2 most recent releases per app (plus whatever `current` symlink points at)
# and delete older ones. Each release carries a full vendor/ tree (~30k inodes), so
# pruning saves big inode budget. Safe to re-run.

set -e

KEEP=2
saved_inodes=0

for dom_dir in ~/domains/*/; do
  rel_dir="${dom_dir}apps/releases"
  if [ ! -d "$rel_dir" ]; then continue; fi
  dom="$(basename "$dom_dir")"

  # which release does `current` link to? never delete it.
  current_target=""
  if [ -L "${dom_dir}apps/current" ]; then
    current_target="$(readlink "${dom_dir}apps/current" | sed 's|.*/||')"
  fi

  # list releases newest-first as a newline-separated string (no temp file —
  # the host's inode quota is so tight even mktemp fails)
  releases=$(ls -1t "$rel_dir" 2>/dev/null)
  count=$(echo "$releases" | grep -c .)
  if [ "$count" -le "$KEEP" ]; then
    printf "%-32s %d releases (no prune)\n" "$dom" "$count"
    continue
  fi

  kept=0; deleted=0
  echo "$releases" | while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    target="$rel_dir/$rel"
    if [ "$rel" = "$current_target" ] || [ "$kept" -lt "$KEEP" ]; then
      kept=$((kept+1))
      continue
    fi
    rm -rf "$target"
    deleted=$((deleted+1))
    echo "  pruned $dom/$rel"
  done
  printf "%-32s scanned=%d  kept_min=%d\n" "$dom" "$count" "$KEEP"
done

echo ""
echo "Approx inodes freed: $saved_inodes"
