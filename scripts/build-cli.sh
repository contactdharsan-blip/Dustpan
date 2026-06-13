#!/usr/bin/env bash
# Build the Dustpan CLI — a feature-parity command-line front-end over the
# Foundation engines. Uses swiftc directly (the repo's harness convention),
# so it needs no Xcode target and stays decoupled from the .xcodeproj.
#
# Output: dist/dustpan (universal arm64+x86_64 unless --thin is passed).
set -euo pipefail

# Repo root resolved from this script's own location — never hardcoded.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$ROOT/Dustpan"
OUT_DIR="$ROOT/dist"
OUT="$OUT_DIR/dustpan"
mkdir -p "$OUT_DIR"

# Engine sources the CLI links against (Foundation-only + CryptoKit/AppKit).
# Views (SwiftUI) are deliberately excluded — the CLI is a pure engine consumer.
ENGINES=(
  "$SRC/SafeDeleteEngine.swift"
  "$SRC/StatsEngine.swift"
  "$SRC/DuplicateEngine.swift"
  "$SRC/LargeFileEngine.swift"
  "$SRC/ClutterEngine.swift"
  "$SRC/UninstallEngine.swift"
  "$SRC/LoginItemsEngine.swift"
  "$SRC/SnapshotEngine.swift"
  "$SRC/DiagnosticsEngine.swift"
  "$SRC/UndoJournal.swift"
)
CLI="$ROOT/cli/main.swift"

for f in "${ENGINES[@]}" "$CLI"; do
  [ -f "$f" ] || { echo "missing source: $f" >&2; exit 1; }
done

ARCH_FLAGS=(-target-cpu generic)
if [ "${1:-}" = "--thin" ]; then
  echo "Building thin (host arch)…"
  swiftc -O -o "$OUT" "${ENGINES[@]}" "$CLI"
else
  echo "Building universal (arm64 + x86_64)…"
  swiftc -O -target arm64-apple-macos13   -o "$OUT.arm64"  "${ENGINES[@]}" "$CLI"
  swiftc -O -target x86_64-apple-macos13  -o "$OUT.x86_64" "${ENGINES[@]}" "$CLI"
  lipo -create -output "$OUT" "$OUT.arm64" "$OUT.x86_64"
  rm -f "$OUT.arm64" "$OUT.x86_64"
fi

echo "Built: $OUT"
file "$OUT"
