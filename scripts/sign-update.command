#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/modules
./scripts/swiftc.command -parse-as-library -swift-version 5 -D CAPSLINK_TESTING \
  -module-cache-path "$PWD/.build/modules" slock.swift UpdateInstaller.swift \
  scripts/sign-update.swift -o .build/sign-update
.build/sign-update "$@"
