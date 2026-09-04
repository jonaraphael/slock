#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/tests .build/modules
./scripts/swiftc.command -parse-as-library -swift-version 5 -D CAPSLINK_TESTING \
  -module-cache-path "$PWD/.build/modules" "$@" \
  slock.swift Tests/RegressionTests.swift -o .build/tests/regressions
.build/tests/regressions
