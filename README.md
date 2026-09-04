# slock test kit

This repository contains the slock prototype source and design documents.

slock was previously called CapsLink. The app retains its existing bundle
identifier, preference keys, identity directory, and wire identifiers so renaming
does not reset settings or pairing. The app and executable are now named `slock`.

slock is a menu-bar-only macOS prototype intended to link two Caps Lock keys and LEDs over the Internet. Holding Caps Lock lights the paired Mac's Caps Lock LED. After an explicit PTT invitation is accepted, the same hold also sends end-to-end encrypted, 12 kbit/s Opus voice.

## What is included

- `slock.swift` — the complete application in one source file.
- `build.command`, `scripts/swiftc.command`, and `Resources/Info.plist` — compile, package, and ad-hoc sign the app.
- `test.command` and `Tests/RegressionTests.swift` — regression tests without keyboard capture or microphone access.
- `ARCHITECTURE.md` — plan, state machine, protocol, pseudocode, and test plan.
- `VALIDATION.md` — verification results and remaining hardware checks.
- `REVIEW.md` — findings and implemented fixes.
- `LICENSE` — the repository's MIT license.
- `THIRD_PARTY_NOTICES.md` — attribution for the imported Opus conversion pattern.

There is no Xcode project and no package dependency.

## Build on a Mac

Requirements:

- macOS 13 or newer;
- Xcode or Xcode Command Line Tools;
- Internet access during operation, not during compilation.

In Terminal:

```bash
cd /path/to/slock
chmod +x build.command
./build.command
```

The script builds both `arm64` and `x86_64`, combines the slices, ad-hoc signs the app, and creates:

```text
dist/slock.app
dist/slock.app.zip
```

Both slices must compile successfully. To build only one architecture, use
`CAPSLINK_ARCHS=arm64 ./build.command` (or `x86_64`). Build artifacts are ignored by Git.
Run `./test.command` for the regression suite. Both scripts accept additional
`swiftc` arguments, such as a custom SDK or module-cache path.

Version 0.2 uses wire protocol 2. Upgrade both Macs together; version 0.1 cannot
communicate with version 0.2. Existing pairing keys remain usable, but PTT must be
enabled again after upgrading from 0.1.

## Install and first launch

On each Mac:

1. Unzip `slock.app.zip`.
2. Move `slock.app` to `/Applications` before opening it. This keeps the Accessibility grant and login item tied to a stable path.
3. Control-click the app and choose **Open**. The build is ad-hoc signed, not notarized.
4. Approve the macOS Accessibility request. slock does not install the Caps→F18 mapping until the event tap is trusted.
5. Look for the Caps Lock-shaped item in the menu bar.

slock attempts to register itself as a login item on first launch. macOS may require approval under **System Settings → General → Login Items**. The menu has a **Launch at Login** toggle and reports when approval is pending.

## Pair two Macs

1. On Mac A, choose **Copy Pairing Code**.
2. Send that code to Mac B over your existing trusted channel.
3. On Mac B, choose **Pair Using Code…** and paste it.
4. Compare the request's ID with **This Mac** in Mac B's menu over your trusted channel. On Mac A, choose **Accept Pair Request from …** only if the IDs match.
5. Both menus should report the peer as connected within a few seconds.

Now press and hold Caps Lock on A. B's Caps Lock LED should follow the hold duration, shifted by network latency, then turn off. Repeat in the other direction.

## Enable push-to-talk

1. One tester chooses **Invite Peer to Enable PTT** and grants microphone permission.
2. The other tester chooses **Accept PTT Invitation** and grants microphone permission.
3. Hold Caps Lock to talk; release to stop.

PTT is half-duplex. If both people press at almost exactly the same time, both apps use the same public-key tie-break, so one side becomes transmitter and the other receiver.

Audio is native Opus at 16 kHz mono, 20 ms frames, 12 kbit/s. Three packets are batched per encrypted relay message, and the receiver prebuffers about 120 ms.

## Network and privacy model

The test build connects to:

```text
wss://test.mosquitto.org:8081/mqtt
```

That is a public testing broker. It is not an account system and should not be treated as production infrastructure. Anyone can observe topic names, timing, and ciphertext sizes. Message contents and audio are encrypted end to end with X25519, HKDF-SHA256, and ChaCha20-Poly1305.

For a production build, change `SlockConfig.brokerURL` to a broker you operate, then add authentication. The rest of the client protocol can remain unchanged.

## Keyboard behavior and cleanup

While **Capture Caps Lock** is enabled:

- Caps Lock is remapped to F18;
- F18 down/up is consumed by a Core Graphics event tap;
- the normal Caps Lock function is unavailable;
- preexisting `hidutil` mappings are kept and restored on quit.

slock stores the prior mapping before applying its own. It restores on normal termination, SIGINT/SIGTERM when possible, and at the next launch after a crash. Failed restoration keeps the recovery journal for retry. Only one instance can own the keyboard mapping at a time. `SIGKILL` and power loss cannot run process cleanup, but logging out/restarting also clears session-scoped `hidutil` mappings.

Use **Capture Caps Lock** to release the key without quitting. The preference is
remembered, and successful cleanup restores the logical Caps Lock state that
preceded capture. Physical F18 is also consumed while capture is active. A disabled
event tap releases the current hold; release and press Caps Lock again to resume.

## Hardware and OS compatibility

The build target is macOS 13+ with Apple Silicon and Intel slices. The intended
primary path is the built-in keyboard in a MacBook. See `VALIDATION.md` for the
actual build and test results; successful compilation does not validate keyboard,
LED, permission, login-item, or two-Mac audio behavior.

External USB/Bluetooth keyboards are best-effort. This prototype uses
`hidutil` and an event tap; it does not implement exclusive HID capture or event
reinjection for devices that need a different interception path.

## LED compatibility

Choose **Test Caps Lock Light** before pairing.

slock tries:

1. direct writes to keyboard HID Caps Lock LED elements;
2. `IOHIDSetModifierLockState` as a fallback.

The second path reaches more internal keyboards but changes the logical lock bit internally. slock removes the alpha-shift flag from downstream key events while active, so normal typing should remain unaffected. Applications that query the global lock bit directly may still notice the fallback state.

Open **Diagnostics…** to see which LED path succeeded.

## Troubleshooting

### Caps Lock still behaves normally

Open **Diagnostics…**. Accessibility must be trusted and **Caps capture active** must be true. Toggle **Capture Caps Lock** off and on after granting permission, or relaunch the app.

Also check whether macOS has Caps Lock assigned to another modifier in **System Settings → Keyboard → Keyboard Shortcuts → Modifier Keys**. Remove that assignment for the first test.

### The app has Accessibility permission but receives no key events

Some macOS/hardware combinations may additionally require **Input Monitoring** permission under **Privacy & Security**. Add slock there, relaunch, and toggle capture.

### Light self-test fails

This is the most hardware-dependent part. Record the Mac model, keyboard type, macOS version, architecture, and the **LED mode** from Diagnostics. The network/key/PTT path can work even where direct LED output does not; the fallback is the next thing to inspect.

### The peer remains offline

The public broker may be down, slow, or WebSocket/TLS service may be temporarily unavailable. Both Macs must be able to reach TCP port `8081` on `test.mosquitto.org`. A corporate firewall may block non-443 ports.

### PTT is silent

Verify both menus say **PTT Enabled**, then check macOS microphone permission and the selected system input/output devices. Use Diagnostics to capture the first audio error.

### Gatekeeper blocks the app

Move it to `/Applications`, then Control-click → **Open**. For wider distribution, sign and notarize with an Apple Developer ID rather than asking users to bypass Gatekeeper.

## Suggested two-person test report

Capture this for each Mac:

```text
Mac model:
macOS version:
CPU architecture:
Built-in or external keyboard:
Caps interception works:
Normal Caps behavior suppressed:
LED self-test works:
Diagnostics LED mode:
Pairing works:
Tap latency:
Held-light reliability:
PTT send/receive:
First error text:
```
