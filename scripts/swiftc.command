#!/bin/bash
set -euo pipefail
compiler=$(xcrun --find swiftc)
include_dir="$(dirname "$compiler")/../include/swift"
flags=()

# Some in-place Command Line Tools upgrades leave both definitions behind.
# Hide only the obsolete duplicate through a temporary compiler VFS overlay;
# never modify the installed toolchain. Healthy toolchains need no workaround.
if [[ -f "$include_dir/module.modulemap" && -f "$include_dir/bridging.modulemap" ]] &&
   /usr/bin/grep -q 'module SwiftBridging' "$include_dir/module.modulemap" &&
   /usr/bin/grep -q 'module SwiftBridging' "$include_dir/bridging.modulemap"; then
  scratch="$(cd "$(dirname "$0")/.." && pwd)/.build/toolchain"
  mkdir -p "$scratch"
  /usr/bin/python3 - "$scratch" "$include_dir/module.modulemap" <<'PY'
import json
import pathlib
import sys
scratch = pathlib.Path(sys.argv[1])
empty = scratch / "empty.modulemap"
if not empty.exists():
    empty.write_text("")
overlay = scratch / "overlay.json"
contents = json.dumps({
    "version": 0,
    "case-sensitive": False,
    "roots": [{"type": "file", "name": str(pathlib.Path(sys.argv[2]).resolve()),
               "external-contents": str(empty)}],
})
if not overlay.exists() or overlay.read_text() != contents:
    overlay.write_text(contents)
PY
  flags=(-vfsoverlay "$scratch/overlay.json")
fi
if [[ ${#flags[@]} -gt 0 ]]; then
  xcrun swiftc "${flags[@]}" "$@"
else
  xcrun swiftc "$@"
fi
