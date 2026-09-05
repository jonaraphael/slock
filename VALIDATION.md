# Validation — 2026-09-04

Environment: Intel macOS 14.8.9 (23J631), Apple Swift 6.0.3, macOS 15.2 SDK,
with a macOS 13 deployment target.

## Automated checks

- **31/31 regression tests passed**, including actual native Opus encoding and
  decoding of synthetic silent PCM. The first decoded frame can be shorter due to
  codec priming; subsequent frames retained the expected 320-sample cadence.
- Tests cover sliced byte buffers, fragmented/coalesced MQTT input, input size
  limits, authenticated encryption, both sides restarting, replay and tampering,
  PTT consent/revocation, simultaneous invitations, pairing persistence, keyboard
  recovery failures, empty mappings, repeated cleanup, identity protection,
  single-instance locking, and subprocess pipe draining.
- Caps Lock regressions cover silently ignored remap/restore commands, clearing
  and restoring a preexisting lock state, rollback when clearing fails, native
  Caps Lock event suppression with other modifiers preserved, forcing the lock
  off for remapped F18 presses, and independent LED success/failure without a
  logical-lock fallback.
- Menu icon state tests cover the hollow, outgoing, and notification tail states,
  including outgoing activity taking priority over a pending notification.
- Permission regressions cover one prompt across repeated activation and
  relaunch, silent migration of existing installs, and quiet capture restart
  after permission is restored.
- A modifier-only event tap is rejected before key mappings or the recovery
  journal are changed. The actual event mask is checked because macOS can
  silently remove key-down and key-up access from a successfully created tap.
- Test keyboard commands and preferences are in-memory doubles. Tests do not
  install an event tap, remap keys, change LEDs, register a login item, contact the
  broker, or request microphone access.
- Shell syntax and bundle property-list validation passed.

- **Universal release build passed** for `arm64` and `x86_64`.
- Mach-O inspection confirms macOS **13.0** minimum deployment for both slices.
- `codesign --verify --strict` passed, and the ZIP contains the executable,
  Info.plist, signature resources, MIT license, and third-party notice.
- Outputs: `dist/slock.app` and `dist/slock.app.zip` (ignored by Git).
- Dit's native menu-bar artwork was rendered and visually inspected at 18 pt
  and enlarged size, covering hollow, yellow-green outgoing, and red notification
  states. It uses nearly the full 18-point height without clipping. Monochrome
  states are AppKit templates; colored states use an adaptive semantic body color.

## Local environment considerations

This machine's Command Line Tools installation contains duplicate `SwiftBridging`
module definitions left by an upgrade. `scripts/swiftc.command` detects that exact
condition and creates an ignored compiler VFS overlay under `.build/toolchain`.
It does not alter the installed SDK or toolchain. Standard installations pass
straight through to `xcrun`'s Swift compiler.

The agent's restricted execution sandbox cannot create the native Opus encoder.
The full regression executable was therefore also run with normal macOS service
access and passed all 31 tests. No microphone or speakers were used. A sandbox
codec failure must not be represented as a passing audio test.

## Still requires manual validation

The user completed the local typing, LED, and capture-disable smoke checks on
this Mac. Afterward, `hidutil` reported `(null)`, matching the saved mapping
baseline. The specific keyboard type and LED observations were not recorded.
The checks below still describe the broader validation matrix.

After the rename to slock, the installed app was rebuilt, signature-checked,
and relaunched from `~/Applications/slock.app`. All 20 regression tests passed
again. The identity file's inode, modification time, size, and permissions were
unchanged. Capture is disabled and the current mapping is empty (`()`), equivalent
to the original `(null)` baseline. Quitting the legacy app had reinstated a stale
Caps-to-F18 entry; that single entry was verified and removed before relaunch.

During the subsequent Caps Lock bug investigation, capture was requested but the
live mapping was empty. The fix removes the logical-lock LED fallback, verifies
mapping writes and the initial lock reset, and distinguishes requested capture
from active capture in the menu. The cursor badge and physical LED behavior need
a fresh typing check with this build; automated event tests do not verify those
visible hardware effects.

The fixed universal build was installed and relaunched successfully. Its runtime
log reports `requested=1 active=0 trusted=0`; macOS currently denies the rebuilt
app Accessibility access, and `hidutil` confirms the mapping remains empty.
Accessibility settings were opened for the user to renew the grant before the
physical key test. Capture is not represented as active in this state.

The subsequent one-time permission prompt update was also installed and
relaunched. The existing installation persisted `CapsLink.didRequestAccessibility=1`
without issuing another prompt. Runtime status still reports missing
Accessibility access; activation waits quietly for the user to grant it.

The Dit mascot update was built for both architectures, signature-verified,
installed, and relaunched from `~/Applications/slock.app`. The app and repository
are still named slock; only the firefly is called Dit. The current keyboard
mapping remains empty.

Version 0.2.2 makes the rotated Dit fill the menu-bar height, gives its tail
hollow/yellow-green/red states, and forces the local Caps Lock state and LED back
to the peer-driven state on every captured press. Version 0.2.1 added explicit
permission recovery actions without repeating the automatic system prompt. No persistent
code-signing identity is installed on this Mac, so ad-hoc rebuilds have cdhash
designated requirements and can invalidate prior Accessibility entries. The
installed builds can need a renewed user grant before their physical capture test.

The user subsequently granted Accessibility for the installed 0.2.2 binary, but
its event tap still had mask 4096 (modifier changes only), despite requesting
7168 (key-down, key-up, and modifier changes). TCC logs explicitly rejected the
Input Monitoring record because it contained an older build's code requirement.
Resetting only `ListenEvent` for `com.jonaraphael.CapsLink` and restarting the
unchanged app restored mask 7168. The user then confirmed that holding Caps Lock
lights Dit's tail while the local LED stays off, and releasing restores the
hollow tail. The new event-mask validation has passed regression tests in source;
the working installed 0.2.2 binary was retained to preserve its permission grant.

- Accessibility/Input Monitoring prompts and the signed app's permission identity.
- Built-in and external keyboard interception, absence of the Caps Lock cursor
  indicator, independent LED self-test, and no local LED latch after a press.
- Normal quit, SIGINT/SIGTERM, crash recovery, and restoring mappings on real hardware.
- Pairing and reconnecting two Macs through the relay, including network loss during a hold.
- Real microphone/speaker audio, simultaneous PTT holds, device changes, and sleep/wake.
- Login-item registration and launch from `/Applications`.
- Execution on Apple Silicon and on the other supported macOS versions.

The app is ad-hoc signed and has not been notarized.
