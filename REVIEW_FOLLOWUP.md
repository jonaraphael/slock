# Follow-up bug review — 2026-09-04

This review covers the protocol, pairing/PTT controller, keyboard ownership and
recovery, audio lifecycle, and build/test scripts. The concurrent nickname and
pairing-history feature was preserved and included in integration validation.

## Confirmed bugs fixed

| Finding | Fix |
| --- | --- |
| Evicting a wire session forgot its replay history while keeping the same receiver challenge, allowing recorded HELLOs and commands to become valid again. | Give each cached peer session a fresh local challenge. Eviction requires a fresh handshake. Keep protocol-2 compatibility. |
| An invalid command from an unknown sender could evict a legitimate session before being rejected. | Reject unknown non-HELLO commands before reserving cache space; protect paired and pending identities on outbound handshakes too. |
| A PTT menu action could accept or reject a different invitation from the one shown. | Bind the displayed invitation ID to the action and check it before microphone permission or consent changes. |
| Lost messages during concurrent PTT invitations could prevent agreement from converging. | Persist and retry the chosen agreement until acknowledged; ignore late competing invitations while an agreement is active. |
| A lost rejection could make a declined PTT invitation reappear. | Remember the declined ID and repeat the rejection when it is retried. |
| Deferred key presses could survive tap disable or reach a new capture session, relatching the outgoing hold. | Invalidate queued events on release and teardown while preserving valid event order. |
| Recovery journals were passed to hidutil before validation, including through the emergency-exit path. | Validate and canonicalize first; never configure emergency cleanup with malformed or unrelated properties. |
| A failed journal save could still allow keyboard remapping. | Require successful persistence before taking ownership. |
| Duplicate readback entries could hide a missing mapping, and partially parsed input could discard mappings. | Compare complete mapping multisets and reject incomplete arrays, duplicate fields, and partial numeric tokens. |
| Failed startup rollback could leave Caps remapped without a tap and lose the previous logical lock state on stop or retry. | Retain interception until mapping recovery succeeds; track owed logical-state restoration separately from active capture. |
| Delayed audio errors could stop a later talk. | Bind error delivery to the audio generation and controller talk ID. |
| Playback kept its engine and audio hardware running after drain, PTT disable, or unpair. | Stop the engine after drain and immediate stop; restart on the next talk. |
| An input-device configuration change could stop the engine but leave the app showing Transmitting. | Detect interrupted capture and report a generation-scoped error so the controller stops the talk. |
| Diagnostics omitted the application/audio error. | Include the current app error. |
| Concurrent test runs compiled and executed the same output path. | Snapshot sources into a unique temporary directory and run each independent test entry point there. |

## Validation

The original source passed all 31 baseline regressions with normal macOS codec
access. Focused tests reproduced the cache-eviction replay and unknown-command
eviction failures before the SecureWire fix.

The expanded suite uses temporary identities, fake keyboard commands, fake relay
connections, and fake controller audio devices. Native Opus is tested with
synthetic silent PCM. Controller tests exercise pairing approval, held-key relay,
PTT collisions and playback drain, disconnect cleanup, stale permission/menu
actions, lost rejection messages, and stale audio errors. Wire tests include an
independent original protocol-2 peer fixture.

Final combined tests passed: **51/51 regressions and 7/7 nickname tests**. Shell
syntax, bundle plist, and whitespace checks also passed. Native Opus requires
normal macOS service access; the restricted sandbox's codec failure was not
counted as a pass.

Validated source SHA-256:
`044bb09d5eb9806c52cfa71e5ea6919077350798372e491cb6c34d53708f6588`.

The universal release build passed for **arm64 and x86_64**, with macOS **13.0**
minimum deployment verified for both slices. Strict code-signature verification
passed. The ZIP contains the executable, Info.plist, signature, and license notices.
Artifacts are `dist/slock.app` and `dist/slock.app.zip` (ignored by Git).

Release executable SHA-256:
`459f6a8ed9b72575ad751b51ce97872f285db6064a2efe110bce2d06a8de4ade`.
ZIP SHA-256:
`a1e661cb29705914141ab77b3860e3014525d03424ade43dd289d6f819c89dbf`.

Hardware typing, LEDs, actual microphone/output device changes, and two physical
Macs remain manual checks. This review does not install or restart the app;
installation is coordinated separately with the other task. These checks do not
establish that every possible bug has been found.
