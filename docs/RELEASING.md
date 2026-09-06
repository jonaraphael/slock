# Publishing a release

Pushing a stable version tag runs the [release workflow](../.github/workflows/release.yml).
It checks that the tag matches `SlockConfig.appVersion` and
`CFBundleShortVersionString`, runs the tests, builds both architectures, and
verifies the bundle. Since v0.2.9, it prepares a **draft**; signing and publication
finish locally so the private update-signing key never leaves the signing Mac.
The README download button follows GitHub's latest public stable release.

1. Update `SlockConfig.appVersion` in `slock.swift` and `CFBundleShortVersionString`
   in `Resources/Info.plist`, and increment `CFBundleVersion`.
2. Add release notes at `docs/releases/vMAJOR.MINOR.PATCH.md`.
3. Commit and push, then tag that commit and push the tag:

```sh
git tag -a v0.3.0 -m "Release v0.3.0"  # use the new version
git push origin v0.3.0
```

4. Wait for the Release run to succeed, then complete publication from the clean
   checkout of that tag on the signing Mac:

```sh
./scripts/publish-release.command v0.3.0
```

The publish script checks the tag and CI status, rebuilds the app locally,
exercises its installer helper against a disposable app, signs and verifies
`slock-update.json`, reconstructs and checks the signed app, and
uploads `slock.app.zip`, `SHA256SUMS`, and `slock-update.json` together before
making the draft public. It refuses to overwrite an already published release.
No secret is uploaded to GitHub or stored in GitHub Actions.

The dedicated Ed25519 signing key is stored in the private, Git-ignored
`.release-signing/update.key` file and must match `SlockUpdatePublicKey` in
`Resources/Info.plist`. Keep a secure backup. Do not regenerate it for each
release: installed apps trust the existing public key. This update-package
signature does not involve Keychain access. For local package verification
after a build, run:

```sh
./scripts/sign-update.command dist/slock.app dist/slock-update.json
```

The private key is never passed in command-line arguments, printed, or included
in release assets. Signing fails if the key does not match the app. The native
update format accepts only the app's fixed set of regular files and checks the
publisher signature before staging any of them.

If CI fails, the draft stays unpublished. Fix the problem and rerun the workflow.
If the workflow itself needs a fix, push it to `main` and use **Run workflow** with
the existing tag, or run:

```sh
gh workflow run release.yml --ref main -f tag=v0.3.0
```

A rerun leaves already published releases unchanged. Tags older than v0.2.9 retain
the previous automatic publication path. Public releases from v0.3.0 require
Developer ID Application signing and are not notarized; see
[SECURITY.md](../SECURITY.md). Versions 0.2.6–0.2.8 need one
manual app replacement to receive the restored native updater.

## macOS code signing and privacy permissions

The Ed25519 update signature authenticates downloads to slock. macOS privacy
permissions use the app's code-signing identity separately. Ad-hoc signatures
have a designated requirement based on code hashes, so changing the app can
invalidate existing Accessibility, Input Monitoring, or Microphone approvals.
Keeping the bundle identifier and installation path alone does not fix this.
See Apple's [code-signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

For public releases, install a **Developer ID Application** certificate and its
private key in the signing Mac's Keychain, then use the same developer identity
for every release. Creating this certificate requires Apple Developer Program
membership. List available identities with:

```sh
security find-identity -v -p codesigning
```

Save that identity's fingerprint in the private, Git-ignored
`.release-signing/codesign-identity` file once. Both local builds and future
releases will reuse it. For example, replacing the placeholder with the
fingerprint shown above:

```sh
printf '%s\n' 'YOUR_CERTIFICATE_FINGERPRINT' > .release-signing/codesign-identity
./scripts/publish-release.command vMAJOR.MINOR.PATCH
```

`SLOCK_CODESIGN_IDENTITY` can override the saved identity for a particular
build. `build.command` signs the app before ZIP creation and update-package
signing. A signing or timestamp failure stops publication. The publish script
requires a Developer ID Application signature and refuses ad-hoc, development,
and App Store signatures. CI can still validate ad-hoc draft builds; the local
publish step replaces those draft assets with the certificate-signed ones.
Without either setting, ordinary local builds remain ad-hoc, with a warning.
The code-signing private key stays in Keychain and is separate from
`.release-signing/update.key`.

Moving to a new Mac does not require a new identity. Preserve both signing keys
using the [encrypted migration backup and restoration steps](MIGRATING_SIGNING.md).

Keep `com.jonaraphael.CapsLink` as the bundle identifier. Expect that migrating
from ad-hoc builds may require one final approval on each Mac. Later releases
with compatible designated requirements should retain those grants. Verify an
actual upgrade between two certificate-signed versions on a Mac with existing
keyboard and microphone approvals before claiming permission persistence.
Switching between development, ad-hoc, and release identities can prompt again.

This option adds certificate signing and a secure timestamp. It does not enable
the hardened runtime or submit the app for notarization; those are separate
distribution steps. Public releases before v0.3.0 remain ad-hoc signed.
