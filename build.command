#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# Keep the same certificate identity across installed builds so macOS can
# recognize updates when evaluating saved privacy grants. Ad-hoc signing ties
# those grants to a particular build's code hashes instead.
if [[ ${SLOCK_CODESIGN_IDENTITY+x} ]]; then
  signing_identity=$SLOCK_CODESIGN_IDENTITY
elif [[ -f .release-signing/codesign-identity ]]; then
  signing_identity=$(cat .release-signing/codesign-identity)
else
  signing_identity=-
fi
[[ -n "$signing_identity" ]] || { echo 'The configured code-signing identity is empty.' >&2; exit 1; }
if [[ ${SLOCK_REQUIRE_DEVELOPER_ID:-0} == 1 && "$signing_identity" == - ]]; then
  echo 'Publication requires Developer ID Application signing. Configure .release-signing/codesign-identity first.' >&2
  exit 1
fi
signing_args=(--force --sign "$signing_identity" --identifier com.jonaraphael.CapsLink)
if [[ "$signing_identity" == - ]]; then
  echo 'Ad-hoc signing: macOS privacy permissions may need approval after each update.' >&2
  echo 'Set SLOCK_CODESIGN_IDENTITY to use a persistent code-signing certificate.' >&2
else
  signing_args+=(--timestamp)
fi
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
/usr/bin/codesign "${signing_args[@]}" "$app"
/usr/bin/codesign --verify --strict "$app"
if [[ ${SLOCK_REQUIRE_DEVELOPER_ID:-0} == 1 ]]; then
  /usr/bin/codesign --verify --strict -R='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$app"
fi
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$build_dir/slock.app.zip"
rm -rf dist/slock.app
mv "$app" dist/slock.app
mv "$build_dir/slock.app.zip" dist/slock.app.zip
echo "Built dist/slock.app and dist/slock.app.zip (${architectures[*]})"
