#!/bin/sh
# Dustpan A1 survey — how much disk do developer caches really hold?
# https://github.com/contactdharsan-blip/Dustpan
#
# READ-ONLY. This script only runs `du`/`find` and prints a summary for you
# to eyeball and (only if you choose) paste into the survey thread. It sends
# nothing anywhere, and it is short on purpose so you can audit every line.
#
# Context: vendors claim "50-100 GB reclaimable" on dev machines. Before we
# build features on that claim, we are measuring it. (PRD assumption A1.)

set -eu

measure() { # label path
  if [ -e "$2" ]; then
    kb=$(du -sk "$2" 2>/dev/null | cut -f1) || kb=0
    printf "%-28s %8.1f GB\n" "$1" "$(echo "$kb" | awk '{print $1/1048576}')"
    total_kb=$((total_kb + kb))
  else
    printf "%-28s %10s\n" "$1" "—"
  fi
}

total_kb=0
echo "Dustpan dev-cache survey (read-only) — $(sw_vers -productVersion), $(uname -m)"
echo "--------------------------------------------"
measure "Xcode DerivedData"        "$HOME/Library/Developer/Xcode/DerivedData"
measure "Xcode Archives"           "$HOME/Library/Developer/Xcode/Archives"
measure "iOS DeviceSupport"        "$HOME/Library/Developer/Xcode/iOS DeviceSupport"
measure "CoreSimulator Devices"    "$HOME/Library/Developer/CoreSimulator/Devices"
measure "CoreSimulator Caches"     "$HOME/Library/Developer/CoreSimulator/Caches"
measure "npm cache (~/.npm)"       "$HOME/.npm"
measure "pnpm store"               "$HOME/Library/pnpm/store"
measure "yarn cache"               "$HOME/Library/Caches/Yarn"
measure "cargo (~/.cargo)"         "$HOME/.cargo/registry"
measure "uv cache"                 "$HOME/Library/Caches/uv"
measure "bun cache"                "$HOME/.bun/install/cache"
measure "deno cache"               "$HOME/Library/Caches/deno"
measure "Homebrew cache"           "$HOME/Library/Caches/Homebrew"
measure "pip cache"                "$HOME/Library/Caches/pip"
measure "gradle (~/.gradle)"       "$HOME/.gradle/caches"
measure "CocoaPods cache"          "$HOME/Library/Caches/CocoaPods"
measure "Docker.raw"               "$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"

# node_modules: bounded search of common project roots, depth 4, so the
# script stays fast and predictable. Adjust roots if your code lives elsewhere.
nm_kb=0
for root in "$HOME/Developer" "$HOME/Projects" "$HOME/Code" "$HOME/src" "$HOME/dev"; do
  [ -d "$root" ] || continue
  for d in $(find "$root" -maxdepth 4 -type d -name node_modules -prune 2>/dev/null); do
    kb=$(du -sk "$d" 2>/dev/null | cut -f1) || kb=0
    nm_kb=$((nm_kb + kb))
  done
done
printf "%-28s %8.1f GB  (depth-4 search of ~/Developer,Projects,Code,src,dev)\n" \
  "node_modules (bounded)" "$(echo "$nm_kb" | awk '{print $1/1048576}')"
total_kb=$((total_kb + nm_kb))

echo "--------------------------------------------"
printf "%-28s %8.1f GB\n" "TOTAL measured" "$(echo "$total_kb" | awk '{print $1/1048576}')"
echo
echo "Paste the block above (nothing is sent automatically). Locations that"
echo "print '—' don't exist on your machine — that's data too."
