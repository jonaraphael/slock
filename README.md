<p align="center">
  <img src="docs/images/firefly.svg" width="160" height="160" alt="Dit, the slock firefly, with a lime light">
</p>

# slock

**A very small way to say “hey, I’m here.”**

A one-bit, peer-to-peer messaging service, tucked inside your Caps Lock key.

Hold Caps Lock on your Mac. A little light comes on on someone else’s keyboard.
Let go, and it goes off.

That’s the idea. Caps Lock has spent quite enough time shouting. It can have a
small, gentle job now.

[![Download slock for macOS](https://img.shields.io/badge/Download_slock-macOS_13%2B-111111?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/jonaraphael/slock/releases/latest/download/slock.app.zip)

slock lives in your menu bar and connects two Macs. Send a tiny hello, invent a
secret blink language, or sit at opposite desks and be a little ridiculous.
If you both enable push-to-talk, the same key becomes a little walkie-talkie.

The firefly is **Dit**. Dit has one light and considerable enthusiasm.

**macOS 13+ · Apple Silicon and Intel · No account required · Open source**

> **A small experiment, with some rough edges.** Keyboard lights vary, the app
> uses a public test relay, and it is not notarized. Messages are encrypted, but
> metadata is visible and past traffic has no forward secrecy. Please use it
> with someone you trust, and keep sensitive conversations elsewhere.
> [The honest security details](SECURITY.md) · [What’s been tested](VALIDATION.md)

## Give it a blink

You’ll need two Macs, an internet connection, and one willing accomplice.

1. Download and unzip **slock.app.zip** on both Macs. Move **slock.app** to
   **Applications** and open it.
2. Follow the **Permissions Required** guide for Accessibility and Input
   Monitoring. macOS handles the approvals; slock explains where to click.
3. Choose **Resume Slock** if capture is inactive. When it’s working, the menu
   offers **Pause Slock** instead.
4. On one Mac, open **Pairing…**, copy your code, and send it to the other person
   through a channel you trust.
5. On the other Mac, paste it into **Other Mac’s pairing code** with **Command+V**
   or **Control+V**, then choose **Send Pairing Request**.
6. On the first Mac, choose **Review Pair Request from …**. Compare the complete
   pairing codes with your person before choosing **Accept Pairing**. You can
   also compare the entire **This Mac** fingerprint, revealed by holding
   **Option** in the menu. A nickname alone doesn’t verify who’s there.
7. Wait for the connection, then hold Caps Lock. Your person gets a light.
   You have successfully sent one very small hello.

Light signals have about a **one-second delay** to help preserve short blinks
and gaps. Hold **Option** in the menu and choose **Test Caps Lock Light** to
check whether your keyboard’s LED cooperates. Some keyboards are more willing
participants than others.

While slock is active, Caps Lock should stop capitalizing text. Your keyboard
light follows the *other person’s* key; Dit’s tail shows your outgoing activity.
**Pause Slock** restores normal Caps Lock behavior. Physical **F18** is also
consumed while capture is active.

<details>
<summary><strong>macOS is asking questions. Understandable.</strong></summary>

This prototype is ad-hoc signed and **not notarized**, so macOS may block its first
launch. See [Apple’s instructions for opening an app from an unidentified developer](https://support.apple.com/en-us/102445).

Keep slock in Applications so permissions and the login item use a stable path.
The app needs **Accessibility** and **Input Monitoring** for keyboard capture.
It requests each keyboard permission automatically once; the setup guide still
returns when a required grant is missing, including after an update.

- A permission marked **Enabled** needs no further action. Capture waits until
  both keyboard permissions are granted.
- If slock is missing from a permission list, click **+** and add the installed
  app. **Show App in Finder** reveals the running copy.
- If an old entry is already enabled but capture fails, remove it and add the
  current copy. Quit and reopen slock if macOS asks.
- Granting permissions while slock is paused keeps it paused. Choose
  **Resume Slock** when you’re ready.

The red **Permissions Required** item appears only while the current mode lacks
access. Push-to-talk adds **Microphone** after you choose to enable it; receiving
an invitation alone never requests microphone access. **Use lights only** turns
PTT off and removes that requirement.

</details>

## A tiny walkie-talkie, too

1. One person chooses **Invite Peer to Enable PTT**.
2. The other chooses **Accept PTT Invitation**.
3. Both grant microphone access. Once both menus show **PTT Enabled**, hold
   Caps Lock to talk and release it to stop.

Both people must agree. Only one person talks at a time; if you press together,
the apps pick one sender consistently. Excellent practice for saying “over.”

Select **PTT Enabled** to turn voice off for both of you. Voice uses end-to-end
encrypted Opus and does not use the light signal’s one-second buffer.

## Getting to know Dit

| What you see | What it means |
| --- | --- |
| **Yellow-green tail** | You’re holding the key or transmitting. Hello, person. |
| **Blue tail** | Your paired Mac is unavailable: offline, paused, or still connecting. |
| **Red tail** | A required permission is missing, or a pairing/PTT request needs attention. |
| **Hollow tail** | No outgoing activity. An incoming signal appears on your keyboard’s light. |

Missing permissions take priority over all other colors; an unavailable peer
stays blue even while you press. A relay disconnect appears immediately. A peer
that goes quiet is marked offline after about 25 seconds. Both Macs need a
version that supports pause status to report it.

A few useful things in the menu:

| Control | What it does |
| --- | --- |
| **Pause Slock / Resume Slock** | Give Caps Lock its old job back, or return to blinking. Pause stops voice playback and transmission. |
| **Pairing…** | Connect, name your Mac, or save nicknames. |
| **Recent** | Revisit a past pairing. Reconnecting sends a fresh request. |
| **Unpair** | Disconnect immediately and stop lights and voice. |
| **Launch at Login** | Start slock when you sign in. Enabled on first launch when macOS allows it; you can turn it off here. |
| **Download Update…** | Open a newer release on GitHub to review and download it. |
| **Quit slock** | Stop capture, restore the previous keyboard mapping, and let Dit clock out. |

Hold **Option** in the menu to reveal **This Mac**, **Test Caps Lock Light**,
**Diagnostics…**, and the installed version beside **slock** in the menu header.

<details>
<summary><strong>Names, old friends, and updates</strong></summary>

Sending a pairing request shares your nickname with its recipient. The recipient
shares theirs after accepting. A nickname you give someone else stays on your
Mac and is used if they haven’t supplied their own. **Save Nicknames** edits names
without starting another pairing request.

**Recent** lists accepted pairings, newest first. It uses the other Mac’s name,
then your local nickname, then the last six characters of its code. That short
label is for convenience, not identity verification. Unpairing keeps this history
but clears active voice consent. Switching to another Mac asks before disconnecting
your current peer.

slock checks GitHub for updates at launch and hourly, retrying temporary failures
after five minutes. **Download Update…** appears only for a newer stable release.
Download its ZIP, quit slock, replace the app in Applications, and reopen it.
Pairings and preferences stay; macOS may ask you to renew permissions.

The earlier self-installer has been removed: a checksum and an ad-hoc signature
do not authenticate the publisher. Updates now go through the release page.
Upgrade both Macs for the latest behavior. Version 0.2 uses protocol 2 and cannot
communicate with version 0.1.

</details>

## Small app, real caveats

This is still a prototype. Bug reports are welcome, especially from keyboards
that have decided to express themselves in unexpected ways.

- **Lights are best-effort.** The main target is a MacBook’s built-in keyboard.
  Some external keyboards cannot control the LED independently. slock reports
  that instead of turning on system Caps Lock to fake a light.
- **The relay is a public testing service.** It uses
  `wss://test.mosquitto.org:8081/mqtt`. Availability is not guaranteed; other
  clients can send spam or interrupt delivery.
- **Encryption has limits.** Key-state messages, nicknames, and voice are
  encrypted with X25519, HKDF-SHA256, and ChaCha20-Poly1305. Observers can still
  see sender public keys, topics, timing, and sizes. If either Mac’s private
  identity key is later stolen, recorded traffic can be decrypted: there is
  **no forward secrecy**. Keep identity files and backups private.
- **Recovery isn’t magic.** slock preserves existing keyboard mappings and
  restores them when capture stops or the app quits. After a crash, the next
  launch can use a recovery journal. Force-quitting or losing power cannot run
  immediate cleanup.

A production service would need an operated broker, per-user authentication,
topic permissions, and abuse controls. Putting one shared password in a public
app would not solve that. See [SECURITY.md](SECURITY.md) for the full limits and
private vulnerability reporting, or [the architecture](ARCHITECTURE.md) if you’d
like to see how the blinking sausage is made.

## If the little light doesn’t light

Start with **Option → Diagnostics…** in slock’s menu. Pairing tells you the Macs
can communicate; each still needs working keyboard capture and LED access.

| What’s happening | What to try |
| --- | --- |
| Caps Lock still capitalizes or shows a blue cursor indicator | Check **Accessibility trusted: true** and **Caps capture active: true** in Diagnostics. Look for another Caps Lock utility or an existing Modifier Keys reassignment. |
| Permissions look enabled, but nothing happens | Open **Permissions Required** if shown. Remove stale Accessibility/Input Monitoring entries, add the current app from Applications, and reopen if macOS asks. |
| The light test fails | Check **LED mode**, **HID listening access**, and **LED error**. Grant Input Monitoring if requested. The keyboard may not support independent LED control. |
| The other Mac stays offline | Check both app versions, internet connections, and access to `test.mosquitto.org` on TCP port `8081`. The test broker may also be having a day. |
| Voice is silent | Both menus should show **PTT Enabled**. Check Microphone permission and system input/output devices, then the first audio error in Diagnostics. |
| Launch at Login needs approval | Allow slock in **System Settings → General → Login Items**. |

<details>
<summary><strong>A few more clues for stubborn keyboards</strong></summary>

**Local Caps presses** should increase when you hold the key. If it stays at zero,
check permissions and the keyboard event mask (required: `7168`). **Key messages
queued** on the sender and **Key messages received** on the recipient help
separate capture trouble from delivery trouble. Queued does not mean delivered.

For a stale Input Monitoring entry that won’t budge, you can reset only slock’s
record with `tccutil reset ListenEvent com.jonaraphael.CapsLink`, then reopen the
installed app and follow the guide. Some permission changes require a relaunch.

The LED driver retries after keyboard access is granted. If the light changes
independently of your peer, check for another Caps Lock utility using the same
Caps→F18 mapping. Network stalls or a busy Mac can also stretch a blink or gap;
the timing buffer helps, but cannot make the internet behave.

</details>

For a useful bug report, include both Mac models, macOS and app versions, keyboard
types, and whether capture, the light test, and voice each work. **Copy Diagnostics**
helps, too—please review it before sharing, since it contains device fingerprints
and activity counters. Thank you for helping a very small firefly find its feet.

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

Pushing a stable version tag such as `v0.2.6` runs the
[release workflow](.github/workflows/release.yml). It checks that the tag matches
`SlockConfig.appVersion` and `CFBundleShortVersionString`, runs the tests, builds
both architectures, and verifies the bundle before publishing a GitHub release
with `slock.app.zip` and `SHA256SUMS`. The download button follows GitHub's latest
stable release; pushing a commit to `main` alone does not change the download.

Update both version strings and increment `CFBundleVersion` before committing.
Optionally add release notes at `docs/releases/vMAJOR.MINOR.PATCH.md`; otherwise
GitHub generates them. Push the commit, then tag that commit and push the tag:

```sh
git tag -a v0.2.6 -m "Release v0.2.6"  # use the new version
git push origin v0.2.6
```

Monitor the Release run in GitHub Actions. If it fails, any draft stays unpublished;
rerunning the workflow can finish the draft. If the workflow itself needs a fix,
push the fix to `main`, then use **Run workflow** on `main` and enter the existing
tag, or run `gh workflow run release.yml --ref main -f tag=v0.2.6`. This uses the
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
| [SECURITY.md](SECURITY.md) | Privacy, security limits, and private vulnerability reporting. |
| [SECURITY_REVIEW.md](SECURITY_REVIEW.md) | Security review, fixes, and verification. |

slock was previously called **CapsLink**. Internal preference keys, the identity
storage directory, bundle identifier, and wire identifiers retain the old name
to preserve settings and pairing.

## License

[MIT](LICENSE). See [third-party notices](THIRD_PARTY_NOTICES.md) for attribution.
