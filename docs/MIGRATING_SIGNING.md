# Move release signing to another Mac

Slock's signing identity belongs to the Apple developer team, not to a Mac.
The RSA key is portable; it is not bound to the Secure Enclave or a hardware ID.
Use the same Developer ID Application certificate and private key on the new
Mac, retain the `com.jonaraphael.CapsLink` bundle identifier, and retain the
separate Ed25519 update-signing key. A computer change alone does not change
the app's identity.

## Save the migration backup before retiring the old Mac

The signing setup's migration backup is an AES-256 encrypted
`slock-signing-backup.dmg` in the private, Git-ignored
`.release-signing/migration-backup/` directory. Its password is chosen locally
and kept separately from the backup.
The disk image contains:

- `Developer ID Application.p12`: the certificate and private key, also protected
  by the recovery password.
- `DeveloperIDG2CA.cer`: Apple's public intermediate certificate.
- `release-signing/update.key`: the existing Ed25519 key trusted by installed apps.
- `release-signing/codesign-identity`: the certificate fingerprint used by builds.
- `slock-source.zip`: a snapshot of the source and release configuration at backup
  time, including local changes that might not have been pushed yet.
- `README.txt`: restoration instructions and the source revision.

Copy the encrypted disk image to storage you can access after the move. Save
the recovery password in your password manager, separately from the disk image.
Neither the disk image nor the password is uploaded automatically. A backup
left only on the old Mac will not help if that Mac is unavailable.

## Restore on the new Mac

1. Install Xcode or the Xcode Command Line Tools and clone the current repository.
   If the signing changes have not been pushed, overlay the included source
   snapshot onto that checkout and review and commit the restored changes.
2. Open the encrypted disk image and enter its recovery password.
3. Double-click `Developer ID Application.p12`, import it into your login Keychain,
   and use the same recovery password when prompted. Import `DeveloperIDG2CA.cer`
   as well if the intermediate is missing. Do not change certificate trust settings.
4. Copy the backup's `release-signing/update.key` and `codesign-identity` into
   the checkout's `.release-signing/` directory. Do not replace a different key
   without investigating: existing apps trust the original update public key.
   Keep the directory at mode `0700` and `update.key` at `0600`.
5. Run `security find-identity -v -p codesigning` to confirm that the Developer ID
   Application identity is available, then run `SLOCK_REQUIRE_DEVELOPER_ID=1
   ./build.command`. Allow Apple's `codesign` tool to access the imported key
   if Keychain asks.
6. Run `./scripts/sign-update.command dist/slock.app dist/slock-update.json`.
   It checks that the Ed25519 key matches the public key embedded in Slock and
   verifies the reconstructed update before it writes the package.

The release scripts read the saved fingerprint from the checkout; no absolute
path to the old Mac or old user's home directory is part of that configuration.
Use the normal [publishing steps](RELEASING.md) after verification succeeds.

Keep this backup after the migration and update it when renewing the Developer
ID certificate. Do not regenerate the Ed25519 update key when moving computers.
