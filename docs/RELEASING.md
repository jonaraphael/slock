# Publishing a release

Pushing a stable version tag such as `v0.2.6` runs the
[release workflow](../.github/workflows/release.yml). It checks that the tag
matches `SlockConfig.appVersion` and `CFBundleShortVersionString`, runs the tests,
builds both architectures, and verifies the bundle before publishing a GitHub
release with `slock.app.zip` and `SHA256SUMS`. The README download button follows
GitHub's latest stable release; pushing a commit to `main` alone does not change
the download.

1. Update `SlockConfig.appVersion` in `slock.swift` and `CFBundleShortVersionString`
   in `Resources/Info.plist`, and increment `CFBundleVersion`.
2. Optionally add release notes at `docs/releases/vMAJOR.MINOR.PATCH.md`;
   otherwise GitHub generates them.
3. Commit and push, then tag that commit and push the tag:

```sh
git tag -a v0.2.6 -m "Release v0.2.6"  # use the new version
git push origin v0.2.6
```

Monitor the Release run in GitHub Actions. If it fails, any draft stays
unpublished; rerunning the workflow can finish the draft. If the workflow itself
needs a fix, push the fix to `main`, then use **Run workflow** on `main` and enter
the existing tag, or run:

```sh
gh workflow run release.yml --ref main -f tag=v0.2.6
```

This uses the updated workflow to rebuild the original tagged source. A rerun
leaves an already published release unchanged. Release automation uses the
repository's built-in GitHub token and needs no extra secret. Builds remain
ad-hoc signed and are not notarized; see [SECURITY.md](../SECURITY.md).
