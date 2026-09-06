# Security

slock is an experimental macOS utility. The current build is suitable for public
prototype testing, with the limitations below. It is not a production private
communications service.

## Reporting vulnerabilities

Use [GitHub's private vulnerability reporting](https://github.com/jonaraphael/slock/security/advisories/new)
for exploitable vulnerabilities. Include the affected revision, reproduction
steps, and impact. Do not post private identity keys, microphone recordings,
credentials, or working exploits in a public issue. Ordinary nonsecurity bugs can
use the public issue tracker. Security fixes target the latest source revision;
older binaries are not automatically patched.

## Trust and privacy

- The app uses Accessibility and Input Monitoring to capture Caps Lock/F18. It
  does not store ordinary typed text. Microphone capture requires macOS permission,
  local PTT consent, a paired peer, an active connection, and a held key. Pause,
  disconnect, consent withdrawal and re-pairing stop the relevant audio paths.
- Verify the complete `CL1.…` code or the entire 128-bit fingerprint over a trusted
  channel before accepting. Nicknames, recent-peer suffixes and older versions'
  short display IDs are not proof of identity. Displayed names are stripped of
  control, formatting and bidirectional characters so they cannot reorder or
  hide dialog text. A pairing code is a public key, not a secret invitation
  token; strangers can send pairing requests.
- Key states, nickname messages and Opus audio use X25519, HKDF-SHA256 and
  ChaCha20-Poly1305. Fresh challenges and increasing sequences reject replayed
  commands. A recipient's nickname is disclosed after local acceptance or a
  locally initiated request, not in response to an unsolicited request.
- **There is no forward secrecy.** If either Mac's private identity key is later
  stolen, recorded traffic can be decrypted. This needs a separately designed
  and reviewed ephemeral-key protocol to change; do not use this prototype for
  sensitive conversations.
- `~/Library/Application Support/CapsLink/identity.key` is private (`0600`) in a
  user-owned directory (`0700`). Keep it and its backups private. Do not copy it
  into source control or distribute it in an app bundle. Filesystem checks reject
  links and special files. These permissions do not protect against malware
  running as your own user or an administrator.
- Peer history and PTT settings persist in local macOS preferences. Unpairing
  clears active consent but retains Recent entries. Diagnostics include device
  fingerprints, OS information and activity counters; review them before sharing.

## Public-release limits

1. **Relay:** `wss://test.mosquitto.org:8081/mqtt` is an unauthenticated public
   testing service. Observers see sender public keys, topics, timing and sizes;
   any client can publish to inboxes or disrupt delivery. Client resource limits
   cannot prevent denial of service at the relay. Its operator explicitly advises
   against relying on it for important applications. See the
   [broker's published access rules and caveats](https://test.mosquitto.org/).
   Production deployment requires an operated service with per-user credentials,
   inbox authorization and abuse limits. A shared password embedded in the
   distributable app cannot provide that isolation.
2. **Distribution:** Builds are ad-hoc signed and not notarized. Since v0.2.9,
   the native updater requires an Ed25519 signature from a dedicated update key
   embedded in the installed app. A release-hosted checksum or ad-hoc code
   signature alone is not accepted as publisher identity. The signed package
   contains only six regular files with fixed paths; no archives or downloaded
   installer scripts are extracted or executed. Staging is private and bundle
   integrity is checked before replacement. The updater requires a writable app
   location and never requests administrator or Keychain access.
   The private signing key stays in a private maintainer file on the signing Mac;
   GitHub receives only signed public artifacts. Initial downloads and
   source/signing-account compromise remain trust boundaries. Broad distribution should use
   [Developer ID signing and notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
   Versions 0.2.6–0.2.8 only open GitHub for manual downloads and need one manual
   replacement to receive this updater.
3. **Validation:** Automated tests use fake keyboard/relay/microphone devices and
   synthetic audio. Two physical Macs, actual permissions, sleep/wake and keyboard
   compatibility still require the manual matrix in [ARCHITECTURE.md](ARCHITECTURE.md).

The [public-release review](SECURITY_REVIEW.md) records the audit scope, fixes and
verification. No review can establish that all possible vulnerabilities are absent.
