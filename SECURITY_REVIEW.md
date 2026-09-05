# Public-release security review — 2026-09-05

## Result

The actionable code findings below are patched in the v0.2.6 source.
Public distribution still carries the explicit prototype limits in
[SECURITY.md](SECURITY.md): an unauthenticated testing relay, ad-hoc distribution
without notarization, and a protocol without forward secrecy. These are material
launch constraints, not problems solved by making the repository public.
The initial review did not change the published download. The fixes are included
in the v0.2.6 release source.

## Scope and method

Reviewed the application source, crypto envelope and replay/session rules, MQTT
framing and message dispatch, pairing/profile flows, PTT permission and audio
lifecycles, keyboard mapping recovery, filesystem storage, update/download code,
bundle resources, shell scripts, GitHub Actions and tracked documentation.
There are no third-party package dependencies to resolve; the native Opus codec
and other frameworks are provided by macOS. Their internals were not audited.

Scanned all 99 unique historical file blobs reachable from local refs across 18
commits for common credential signatures, private-key blocks, embedded credential
URLs, credential assignments and sensitive filenames. No matches were found.
This was a pattern-based scan, not proof that arbitrary secrets are absent. No
secret values or file contents were sent to an external scanning service.

GitHub metadata confirmed the repository was already public. Secret scanning and
push protection were already enabled, with no open secret-scanning alerts.
Private vulnerability reporting was disabled; it was enabled and read back as
`enabled: true`. Actions defaults to read-only tokens and cannot approve pull
requests. The existing release workflow pins checkout to a commit, disables
persisted checkout credentials and restricts releases to validated stable tags.
The main branch has no branch protection; requiring reviewed PRs and passing
checks remains a maintainer governance choice before broad distribution.

## Findings and patches

| Severity | Finding | Patch |
| --- | --- | --- |
| High | The in-app installer treated a release-hosted checksum and an ad-hoc signature as sufficient verification of executable code. Neither authenticates the publisher; its archive path listing also did not establish link safety before extraction. | Removed the complete archive extraction, app replacement and command-line installer helper. “Download Update…” now opens only the validated stable-tag page on the fixed GitHub repository. A future self-installer needs independent publisher authentication. |
| High | Re-pairing an already connected peer cleared PTT consent but could leave its microphone capture running. | Re-pairing and acceptance stop audio and revoke the current agreement through the normal consent path. Regression reproduced the active microphone after consent was cleared. |
| Medium | Queued authenticated packets could restart audio after transport loss; pausing left remote playback running and accepted new voice starts. | Ignore messages while disconnected; stop playback on pause and require active capture, consent and connection before accepting voice. Validate talk identifier payload lengths. Both bugs were reproduced by regression tests before the patch. |
| Medium | Identity and lock operations followed filesystem links; key loading read an entire file before checking its size. Lock descriptors could also survive exec. | Use a user-owned `0700` directory, directory-relative `O_NOFOLLOW` descriptors, regular-file/owner/hard-link checks, `0600` permissions and `O_CLOEXEC`. Read only a verified 32-byte identity and create new files exclusively. |
| Medium | The MQTT client ID was derived from a publicly visible inbox ID, allowing another client to predict it and force a duplicate-ID disconnect. | Generate an independent random MQTT client ID per process. This removes the predictable-ID attack; a public broker can still deny service. |
| Medium | Unsolicited requests could retrieve the recipient's nickname. New requests could also displace the request being reviewed. | Disclose the recipient's profile only after local acceptance or local initiation. Once a peer/request is selected, ignore other senders before decryption. Explicitly rejecting or initiating a new request selects another peer. |
| Medium | Public-relay traffic could drive expensive key agreement and repeated outbound negotiations on the main queue without a processing-rate limit. | Apply a bounded token budget before decryption, with a smaller stranger allowance; ignore unrelated identities once a peer is selected. Only new confirmed sessions force negotiation retries. Unchanged profiles no longer rewrite preferences. |
| Medium | Pairing instructions relied on a 40-bit display fingerprint. | Display 128 bits of SHA-256 and instruct users to compare the whole fingerprint or pairing code. Routing and protocol-2 compatibility remain unchanged. |
| Low | Release metadata used an unbounded data task, and developer credential files had no ignore rules. | Limit metadata while streaming and by declared length, bound resource time, decline redirects, disable cookies/cache, validate tag-derived links, and ignore common key/credential files. |

Added a read-only PR/main CI workflow that runs regression and security tests.
The build now snapshots the Swift source so both architecture slices compile the
same bytes while another local task edits the working tree. Concurrent changes
to the peer availability indicator and its documentation were preserved.

## Verification

The final complete run passed **119/119 tests**: 89 application regressions, 8 light
timing tests, 7 nickname tests, 8 security tests and 7 update tests. HTTP transport
tests cover both declared and streamed oversized responses and valid metadata.
The universal release build passed for **arm64 and x86_64**, with minimum macOS
**13.0** verified in both slices. Deep/strict code-signature verification, ZIP
integrity and contents, shell syntax, workflow YAML parsing, bundle plist and
`git diff --check` all passed. The signature remains ad-hoc; verification is an
integrity check, not proof of publisher identity.

Artifacts are `dist/slock.app` and `dist/slock.app.zip` (ignored by Git).
SHA-256 values for the original audit snapshot (before the v0.2.6 version bump;
these are not checksums for the published v0.2.6 release):

| File | SHA-256 |
| --- | --- |
| `slock.swift` | `9d09423a1739de47dc36ac2e615c43fbf09a00278122bd5e4139602acc27d2bd` |
| Universal executable | `e88bcc2c59f9eab28db3790beed2f8aa2e5390bfcfe9dd1fc106b540f0752938` |
| App ZIP | `541d0fa2b5fc16f53ccdd9bbb23abb620cb1df948c1e1f1f4bc1300d81181b43` |

Security coverage includes symbolic links, hard links, FIFOs, unchanged rejected
targets, private-directory migration, descriptor inheritance, oversized identities,
128-bit fingerprints, message budgets, identity-independent MQTT IDs, consent
revocation, paused/disconnected voice delivery and unsolicited nickname queries.
Existing tamper, replay, receiver restart, cache eviction and legacy protocol-2
interoperability tests remain in the suite.

The normal macOS service environment was used for synthetic Opus tests. The
restricted sandbox's codec and icon conversion failures were not counted as
passes. No tests captured the user's keyboard or microphone or connected to the
public relay. The audit did not install, restart or publish the app; the subsequent v0.2.6
release is a separate publication step.
