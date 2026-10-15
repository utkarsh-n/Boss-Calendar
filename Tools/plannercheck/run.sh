#!/bin/zsh
# Planner invariant harness: compiles BossCore + main.swift for macOS and runs it (< 2 s).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${TMPDIR:-/tmp}/boss-plannercheck"
swiftc -O -swift-version 6 -o "$OUT" "$HERE"/../../BossCore/*.swift "$HERE/main.swift"
"$OUT" "$@"
