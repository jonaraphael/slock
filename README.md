<p align="center">
  <img src="docs/images/firefly.svg" width="160" height="160" alt="Dit, the slock firefly, with a lime light">
</p>

# slock

Meet **Dit**, slock’s little firefly.

[![Download slock for macOS](https://img.shields.io/badge/Download_slock-macOS_13%2B-111111?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/jonaraphael/slock/releases/latest/download/slock.app.zip)

**Hold a key. Light up someone else’s Mac.**

slock connects two Macs through their Caps Lock keys. Hold yours to light up your
partner’s keyboard; release it to turn their light off. Enable push-to-talk
together, and that same key becomes an encrypted voice connection.

A small macOS menu-bar app. No account required. Built for Apple Silicon and Intel.

> **Prototype:** Download the app above or [build from source](#build-from-source).
> Independent Caps Lock light control depends on the keyboard; test both Macs
> before relying on it. See [validation results](VALIDATION.md).

## Get started

1. Download and unzip **slock.app.zip** on each Mac.
2. Move **slock.app** to **Applications**, then open it. Keep it there so permissions
   and the login item use a stable path.
3. Follow **Set up slock**, which opens automatically when required keyboard
   permissions are missing. Enable slock in both **Accessibility** and **Input
   Monitoring** under System Settings → Privacy & Security. The guide explains
   each permission and requests them in order. If macOS does not show a dialog,
   use the guide’s **Enable** buttons to open the corresponding settings.
4. If slock is missing from either list, click **+** and select the app you
   installed. **Show App in Finder** reveals the running copy. If an old entry is
   already enabled, remove it and add this copy again. Quit and reopen slock if
   macOS asks.
5. Choose **Resume Slock** if capture is inactive. The menu shows **Pause Slock**
   while the key is captured. Hold **Option** while the menu is open and choose
   **Test Caps Lock Light** to check your keyboard.

Requires **macOS 13 or later** and an internet connection. The prototype is
ad-hoc signed and **not notarized**, so macOS may block its first launch. Follow
[Apple’s instructions for opening an app from an unidentified developer](https://support.apple.com/en-us/102445).

slock requests each macOS keyboard permission automatically once. The setup guide
still opens on launch if capture is requested and either permission is missing,
including after a reinstall or update. Choose **Permissions…** to reopen it at
any time and explicitly retry. Capture starts only after both permissions are
granted; granting access while Slock is paused keeps it paused. If macOS still
reports incomplete event access, quit and reopen slock. **Resume Slock** means the
key is not currently captured; **Retry Capture** and permission recovery actions
appear when requested capture cannot start.

## Connect two Macs

1. On **Mac A**, open **Pairing…**, copy your displayed code, and send it to your
   partner through a channel you trust.
2. On **Mac B**, open **Pairing…**, paste it under **Someone else's pairing code**,
   and choose **Send Pairing Request**. Your own code is available in the same window.
3. On Mac B, hold **Option** in the menu to reveal **This Mac**. Compare that ID
   with the incoming request on Mac A over your trusted channel.
4. On Mac A, choose **Review Pair Request from …**, compare the codes, and choose
   **Accept Pairing** only if they match.
5. Wait for both Macs to show a connection, then hold Caps Lock on either Mac.
   The other Mac’s light should stay on for the duration of the hold.

Choose **Unpair** to disconnect immediately. Upgrade both Macs together:
version 0.2 uses protocol 2 and cannot communicate with version 0.1.

The **Pairing…** window also lets you name your Mac. Self-assigned nicknames are
exchanged during the request, before acceptance. If the other Mac hasn't supplied
a name, you can give it a nickname that stays on your Mac. Choose **Save Nicknames**
to edit names without starting another pairing request.

Accepted pairings appear in **Recent**, newest pairing first. Each entry uses the
other Mac's self-assigned nickname, then your local nickname, then the last six
characters of its pairing code. Names persist across restarts and unpairing.
Selecting an entry opens its pairing window; reconnecting sends a fresh request,
and switching from another Mac asks before disconnecting it. Older slock versions
can still pair, but don't provide nicknames.

## Talk with Caps Lock

1. One person chooses **Invite Peer to Enable PTT**.
2. The other chooses **Accept PTT Invitation**.
3. Grant microphone access on both Macs. When both menus show **PTT Enabled**,
   hold Caps Lock to talk and release it to stop.

Voice requires both people’s consent. Only one person transmits at a time; if
both press together, the apps choose one sender consistently. Select **PTT
Enabled** to disable voice for both peers. Audio uses end-to-end encrypted Opus.

## Everyday controls

| Menu item | What it does |
| --- | --- |
| **Pause Slock / Resume Slock** | Restores normal Caps Lock behavior, or gives slock control of the key. |
| **Permissions…** | Opens setup guidance and controls for Accessibility and Input Monitoring. |
| **Launch at Login** | Starts slock when you sign in. Enabled on first launch when macOS allows it. |
| **Update slock** | Appears when a newer stable release tag is available. Downloads the update, replaces the app in its current location, and restarts slock. |
| **Unpair** | Immediately removes the peer and stops key mirroring and voice. |
| **Quit slock** | Stops capture, restores the previous keyboard mapping, and exits. |

Hold **Option** while the menu is open to reveal **This Mac**, **Test Caps Lock
Light**, and **Diagnostics…**. Release Option to hide them again.

slock checks GitHub for updates at launch and hourly while running. Checks happen
in the background; a temporary network failure retries after five minutes. The
update option stays hidden when the installed version is current or ahead of the
latest release. The download's SHA-256 checksum, app identity, version, and code
signature are verified before slock quits. If replacement or relaunch fails, the
installer restores the previous app. Updating requires write access to the app's
folder. Pairings and preferences are retained; macOS may require renewed keyboard
permissions after an update.

Dit’s tail turns **blue when your paired peer’s capture is paused or inactive**,
so you know they cannot receive your light signals. Blue stays visible while you
press your key and clears when they resume. Both Macs need this update to share
pause status; disconnected peers still appear as offline in the menu.

Otherwise, Dit’s tail glows yellow-green while you hold your key, confirming the
outgoing light signal without lighting your own keyboard. An incoming press
leaves Dit’s tail hollow because your keyboard light carries that signal. While
you are not sending, red means a pairing request or PTT invitation needs
attention. The menu-bar mark adapts to light and dark backgrounds automatically.

While capture is **active**, Caps Lock must not capitalize text, display the
macOS Caps Lock cursor indicator, or latch the local light on. Your local light
follows your **partner’s** held key, except during the brief light test.
Disabling capture restores the Caps Lock state that preceded it.

Light playback prioritizes your rhythm: it buffers about one second, then keeps
short flashes and short dark gaps at their captured lengths. Holds and pauses of
one second or longer absorb timing adjustments. This adds eight bytes per key
transition, with no extra messages or faster heartbeats. Upgrade both Macs for
the timing improvement in both directions; older peers still work with immediate
light updates. PTT starts and stops immediately. Network stalls beyond the buffer
or a busy Mac can still stretch a flash or gap.

slock preserves existing keyboard mappings and restores them when capture stops
or the app quits. A recovery journal allows the next launch to restore mappings
after a crash. Force-quitting or losing power cannot run immediate cleanup.
Physical **F18** is also consumed while capture is active.

## Compatibility and privacy

- **Keyboard lights vary.** slock uses independent HID light control; it never
  enables system Caps Lock just to illuminate the LED. Unsupported lights are
  reported as unavailable. Key relay and voice can still work.
- **External keyboards are best-effort.** The primary target is a MacBook’s
  built-in keyboard. Compilation for Intel and Apple Silicon does not establish
  that every keyboard or macOS version has been tested.
- **The relay is experimental.** This build uses the public testing broker at
  `wss://test.mosquitto.org:8081/mqtt`. Availability is not guaranteed.
- **Contents are encrypted; metadata is visible.** Key-state messages and voice
  use X25519, HKDF-SHA256, and ChaCha20-Poly1305. Broker observers can see topic
  names, timing, and ciphertext sizes. Verify pairing IDs through a trusted
  channel.

For a production deployment, configure a broker you operate and add broker
authentication. See [the architecture](ARCHITECTURE.md) for protocol details and
[the validation report](VALIDATION.md) for tested behavior and remaining checks.

## Troubleshooting

Hold **Option** in slock’s menu to open **Diagnostics…**.

Pairing confirms that the network connection works; each Mac still needs working
keyboard capture and independent LED access. In version 0.2.3, use **Copy
Diagnostics** to share the checks below:

- **Local Caps presses** should increase when this Mac holds Caps Lock. If it
  stays at zero and Dit's tail never glows, check capture permissions and the
  keyboard event mask (required: `7168`).
- **Key messages queued** on the sender and **Key messages received** on the
  recipient separate keyboard capture from message delivery. Counters are since
  app launch; queued messages do not prove delivery.
- **HID listening access**, **LED devices**, and **LED error** distinguish missing
  permission from a keyboard that cannot control its light. Grant Input Monitoring
  access if requested, then choose **Retry Keyboard Light**.

The LED driver waits for keyboard permission before opening devices and recreates
failed device objects on retry. Granting permission after launch no longer leaves
the light driver stuck with its initial denial. Keyboard capture permissions can
still require reopening the app when macOS reports incomplete event access.

| Problem | Check |
| --- | --- |
| Caps Lock still capitalizes, shows a blue indicator, or leaves the light on | Diagnostics must show **Accessibility trusted: true** and **Caps capture active: true**. If capture is active and the issue persists, record the diagnostics and keyboard model. |
| Accessibility appears enabled, but capture is inactive after an update | Choose **Open Accessibility Settings…**, remove the old slock entry, and add the current app from Applications. Return to slock and choose **Retry Capture**. Ad-hoc signed rebuilds can require renewed permission. |
| Permission is granted, but key presses are not captured | Check **Privacy & Security → Input Monitoring** and any Caps Lock reassignment under **Keyboard → Keyboard Shortcuts → Modifier Keys**. |
| Input Monitoring appears enabled, but Dit never responds | A stale permission entry from an older build can block keyboard events even with Accessibility granted. Remove the old Input Monitoring entry and reopen the installed app. If the stale entry persists, run `tccutil reset ListenEvent com.jonaraphael.CapsLink`, then reopen slock. This resets only slock’s Input Monitoring record. |
| The keyboard light changes independently of the peer | Check for another Caps Lock utility. Apps or scripts watching the same Caps→F18 mapping can independently control the LED. |
| The light test fails | Check **LED mode**. Some keyboards cannot control their light independently; slock will not fall back to enabling system Caps Lock. |
| The peer stays offline | Confirm both Macs use the same protocol version and can reach `test.mosquitto.org` on TCP port `8081`. A firewall or broker outage can prevent connection. |
| Voice is silent | Both menus must show **PTT Enabled**. Check microphone permission and the system input/output devices, then inspect the first audio error in Diagnostics. |
| Launch at Login needs approval | Open **System Settings → General → Login Items** and allow slock. |

For a useful bug report, include both Macs’ models, macOS versions, keyboard types,
app versions, the relevant diagnostic error, and whether key capture, the light
test, and voice each work. State whether the menu shows **Pause Slock** or **Resume Slock**.

## Build from source

Install Xcode or the Xcode Command Line Tools, then run:

```sh
git clone https://github.com/jonaraphael/slock.git
cd slock
./build.command
```

The build creates a universal, ad-hoc signed app and a distributable ZIP:

```text
dist/slock.app
dist/slock.app.zip
```

There is no Xcode project or third-party package dependency. Compilation does not
need internet access. Generated artifacts are ignored by Git.

The build renders Dit's [vector artwork](docs/images/firefly.svg) into a macOS app
icon at standard and Retina sizes and bundles it before signing, so the unzipped
app shows Dit in Finder.

To build one architecture or run the regression suite:

```sh
CAPSLINK_ARCHS=arm64 ./build.command  # use x86_64 for Intel only
./test.command
```

Both scripts accept extra `swiftc` arguments. The tests use temporary identities,
fake keyboard commands, and synthetic audio; they do not capture the keyboard,
use the microphone, or contact the broker.

### Publish a release

Pushing a stable version tag such as `v0.2.3` runs the
[release workflow](.github/workflows/release.yml). It checks that the tag matches
`SlockConfig.appVersion` and `CFBundleShortVersionString`, runs the tests, builds
both architectures, and verifies the bundle before publishing a GitHub release
with `slock.app.zip` and `SHA256SUMS`. The download button follows GitHub's latest
stable release; pushing a commit to `main` alone does not change the download.

Update both version strings and increment `CFBundleVersion` before committing.
Optionally add release notes at `docs/releases/vMAJOR.MINOR.PATCH.md`; otherwise
GitHub generates them. Push the commit, then tag that commit and push the tag:

```sh
git tag -a v0.2.3 -m "Release v0.2.3"  # use the new version
git push origin v0.2.3
```

Monitor the Release run in GitHub Actions. If it fails, any draft stays unpublished;
rerunning the workflow can finish the draft. If the workflow itself needs a fix,
push the fix to `main`, then use **Run workflow** on `main` and enter the existing
tag, or run `gh workflow run release.yml --ref main -f tag=v0.2.3`. This uses the
updated workflow to rebuild the original tagged source. A rerun leaves an already
published release unchanged. Release automation uses the repository's built-in
GitHub token and needs no extra secret. Builds remain ad-hoc signed and are not
notarized.

### Project guide

| File | Purpose |
| --- | --- |
| [slock.swift](slock.swift) | Application, keyboard capture, pairing, relay, and audio. |
| [build.command](build.command) | Builds, packages, and signs the app. |
| [test.command](test.command) | Runs the [regression suite](Tests/RegressionTests.swift). |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Design, protocol, state machines, and manual test plan. |
| [VALIDATION.md](VALIDATION.md) | Verified results and remaining hardware checks. |
| [REVIEW.md](REVIEW.md) | Review findings and implemented fixes. |

slock was previously called **CapsLink**. Internal preference keys, the identity
storage directory, bundle identifier, and wire identifiers retain the old name
to preserve settings and pairing.

## License

[MIT](LICENSE). See [third-party notices](THIRD_PARTY_NOTICES.md) for attribution.
