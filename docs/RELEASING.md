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
git tag -a v0.2.9 -m "Release v0.2.9"  # use the new version
git push origin v0.2.9
```

4. Wait for the Release run to succeed, then complete publication from the clean
   checkout of that tag on the signing Mac:

```sh
./scripts/publish-release.command v0.2.9
```

The publish script checks the tag and CI status, rebuilds the app locally, signs
and verifies `slock-update.json`, reconstructs and checks the signed app, and
uploads `slock.app.zip`, `SHA256SUMS`, and `slock-update.json` together before
making the draft public. It refuses to overwrite an already published release.
No secret is uploaded to GitHub or stored in GitHub Actions.

The dedicated Ed25519 signing key is stored in the private, Git-ignored
`.release-signing/update.key` file and must match `SlockUpdatePublicKey` in
`Resources/Info.plist`. Keep a secure backup. Do not regenerate it for each
release: installed apps trust the existing public key. No Keychain access is
involved. For local package verification after a build, run:

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
gh workflow run release.yml --ref main -f tag=v0.2.9
```

A rerun leaves already published releases unchanged. Tags older than v0.2.9 retain
the previous automatic publication path. Builds remain ad-hoc signed and are not
notarized; see [SECURITY.md](../SECURITY.md). Versions 0.2.6–0.2.8 need one manual
app replacement to receive the restored native updater.
