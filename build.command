#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/modules dist
build_dir=$(mktemp -d "$PWD/.build/package.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
# Compile both architectures from the same bytes even if the working tree is
# edited during a local build (the regression runner uses the same approach).
cp slock.swift "$build_dir/slock.swift"
cp UpdateInstaller.swift "$build_dir/UpdateInstaller.swift"
app="$build_dir/slock.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
./scripts/swiftc.command -swift-version 5 -module-cache-path "$PWD/.build/modules" \
  scripts/generate-app-icon.swift -o "$build_dir/generate-app-icon"
"$build_dir/generate-app-icon" docs/images/firefly.svg "$build_dir/AppIcon.iconset"
/usr/bin/iconutil -c icns "$build_dir/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
read -r -a architectures <<< "${CAPSLINK_ARCHS:-arm64 x86_64}"
slices=()
for architecture in "${architectures[@]}"; do
  case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;; esac
  ./scripts/swiftc.command -parse-as-library -swift-version 5 -O \
    -target "$architecture-apple-macos13.0" -module-cache-path "$PWD/.build/modules" \
    "$@" "$build_dir/slock.swift" "$build_dir/UpdateInstaller.swift" -o "$build_dir/slock-$architecture"
  slices+=("$build_dir/slock-$architecture")
done
xcrun lipo -create "${slices[@]}" -output "$app/Contents/MacOS/slock"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - --identifier com.jonaraphael.CapsLink "$app"
/usr/bin/codesign --verify --strict "$app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$build_dir/slock.app.zip"
rm -rf dist/slock.app
mv "$app" dist/slock.app
mv "$build_dir/slock.app.zip" dist/slock.app.zip
echo "Built dist/slock.app and dist/slock.app.zip (${architectures[*]})"
