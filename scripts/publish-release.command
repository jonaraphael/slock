#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
tag=${1:?Usage: publish-release.command vMAJOR.MINOR.PATCH}
[[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
revision=$(git rev-parse HEAD)
[[ "$revision" == "$(git rev-parse "$tag^{commit}")" ]] || { echo 'Check out the tagged release first.' >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo 'Release signing requires a clean checkout.' >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
[[ "v$version" == "$tag" ]]
[[ "$(gh release view "$tag" --json isDraft --jq .isDraft)" == true ]] || { echo 'Only a draft can be published.' >&2; exit 1; }
run=$(gh run list --commit "$revision" --workflow release.yml --limit 1 --json status,conclusion \
  --jq '.[0] | .status + "/" + .conclusion')
[[ "$run" == completed/success ]] || { echo 'Wait for successful release checks before signing.' >&2; exit 1; }
SLOCK_REQUIRE_DEVELOPER_ID=1 CAPSLINK_ARCHS='arm64 x86_64' ./build.command
./scripts/test-update-helper.command
./scripts/sign-update.command dist/slock.app dist/slock-update.json
(cd dist && shasum -a 256 slock.app.zip > SHA256SUMS)
[[ "$revision" == "$(git rev-parse HEAD)" && -z "$(git status --porcelain)" ]] || {
  echo 'The checkout changed during the release build.' >&2; exit 1;
}
# Only public artifacts leave this Mac. The private signing key stays local.
gh release upload "$tag" dist/slock.app.zip dist/SHA256SUMS dist/slock-update.json --clobber
gh release edit "$tag" --draft=false --latest
gh release view "$tag" --json url --jq .url
