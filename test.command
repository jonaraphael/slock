#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/tests .build/modules
test_dir=$(mktemp -d "$PWD/.build/tests/run.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
# Compile a consistent copy and give every run its own executable. Concurrent
# repository edits and test runs must not replace a binary being validated.
cp slock.swift "$test_dir/slock.swift"
cp UpdateInstaller.swift "$test_dir/UpdateInstaller.swift"
cp Tests/*.swift "$test_dir/"
suites=()
helpers=()
for source in "$test_dir/"*Tests.swift; do
  if /usr/bin/grep -q '^@main' "$source"; then
    suites+=("$source")
  else
    helpers+=("$source")
  fi
done
for suite in "${suites[@]}"; do
  sources=("$test_dir/slock.swift" "$test_dir/UpdateInstaller.swift" "$suite")
  if [[ ${#helpers[@]} -gt 0 ]]; then sources+=("${helpers[@]}"); fi
  ./scripts/swiftc.command -parse-as-library -swift-version 5 -D CAPSLINK_TESTING \
    -module-cache-path "$PWD/.build/modules" "$@" \
    "${sources[@]}" -o "$test_dir/regressions"
  "$test_dir/regressions"
done
