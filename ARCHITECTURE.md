# slock 0.2 — architecture and test plan

## Goal

slock turns the physical Caps Lock key and LED into a private, one-bit link between two Macs:

- while A physically holds Caps Lock, B's Caps Lock light is on;
- while B physically holds Caps Lock, A's light is on;
- Caps Lock never performs its normal capitalization behavior while capture is enabled;
- either user can invite the other to enable push-to-talk;
- after both consent, holding Caps Lock also transmits low-bitrate voice;
- the process has no Dock icon or main window and can launch at login.

The prototype intentionally supports exactly one peer. That keeps the interaction legible and the state machine small.

## Assumptions

1. Both Macs run macOS 13 or newer; this is the deployment target, not a completed validation matrix.
2. The build script requires both Apple Silicon and Intel slices by default. The built-in MacBook keyboard is the primary target; external keyboards are best-effort.
3. A test build may be ad-hoc signed and manually opened; a public release would need a Developer ID signature and notarization.
4. Internet communication needs a rendezvous/relay. The test build uses the public `test.mosquitto.org` MQTT-over-WSS endpoint, with end-to-end encryption. It is replaceable with a private Mosquitto broker by changing one constant.
5. Direct independent control of a built-in keyboard LED is not uniform across MacBook generations. slock uses direct HID LED elements only; unsupported lights are reported as unavailable. LED output never enables the OS Caps Lock state.
6. The app owns Caps Lock while capture is enabled. Existing `hidutil` mappings are preserved and restored on normal exit; crash recovery runs at the next launch.

## Why this is the lightest practical shape

A pure peer-to-peer client still needs NAT traversal, signaling, and often TURN. Native WebRTC would add a large framework. slock instead embeds roughly the minimum MQTT 3.1.1 client needed for one subscription and QoS-0 publishes over `URLSessionWebSocketTask`.

The client has:

- one Swift source file;
- no package manager;
- no embedded browser;
- no database;
- no server account or API key;
- no third-party runtime library;
- AppKit, IOKit, CryptoKit, AVFoundation, AudioToolbox, and ServiceManagement only.

## Data flow

```text
LOCAL INPUT

physical Caps Lock
        │
        ▼
hidutil: Caps → F18
        │
        ▼
CGEventTap consumes F18 down/up
        │
        ├──────────── key-state message ────────────┐
        │                                            │
        └─ when PTT enabled                          │
             microphone → 16 kHz mono → Opus         │
                    → 3-packet batch ────────────────┤
                                                     ▼
                                         X25519 + HKDF key
                                         ChaCha20-Poly1305
                                                     │
                                                     ▼
                                           MQTT over WSS
                                                     │
                                            public test relay
                                                     │
                                                     ▼
REMOTE OUTPUT                                        │
                                                     ▼
                                              decrypt/validate
                                                     │
              ┌──────────────────────────────────────┴─────────┐
              ▼                                                ▼
       Caps LED driver                                  Opus decoder
 direct HID only                                   AVAudioPlayerNode
```

Control and audio use the same WebSocket, MQTT connection, encrypted envelope, and recipient inbox topic.

## Identity and pairing

Each installation creates a persistent Curve25519 key-agreement private key at:

```text
~/Library/Application Support/CapsLink/identity.key
```

The file is mode `0600`. The public key determines:

- a short display ID, such as `6A8E2-9D417`;
- an inbox topic derived from `SHA-256(publicKey)` (routing information, not authentication);
- a copied pairing code: `CL1.<base64url-public-key>`.

Pairing is asymmetric to start and symmetric when accepted:

```text
B copies A's pairing code
B derives shared key(B_private, A_public)
B and A exchange encrypted HELLO challenges to establish fresh sessions
B publishes encrypted PAIR_REQUEST to A's inbox
A derives the same key(A_private, B_public)
A exposes Accept / Reject in its menu
A accepts and sends encrypted PAIR_ACCEPT
both persist the other public key
```

The broker sees topics, ciphertext sizes, and timing. It cannot decrypt content. A pairing code is not a password to past traffic; it contains only a public key. The recipient still has to accept a new peer.

## Encrypted envelope

```text
byte 0       protocol version
bytes 1..32  sender X25519 public key
remaining    ChaChaPoly combined box:
               nonce || ciphertext || authentication tag

plaintext:
byte 0       message kind
bytes 1..8   sender boot ID
bytes 9..16  monotonic sequence
bytes 17..24 recipient boot ID (zero for initial discovery)
remaining    message payload
```

The symmetric key is:

```text
X25519(my_private, peer_public)
  → HKDF-SHA256(
        salt = "CapsLink/v1/E2E",
        info = sorted(my_public || peer_public),
        output = 32 bytes
    )
```

The version and sender public key are authenticated as additional data. Protocol 2
uses `capslink/v2/inbox/` topics. The existing HKDF label is retained, but the
authenticated protocol version and receiver challenge separate the new wire format.

An initial HELLO learns the sender's boot ID and requests a reply. It cannot update
presence, LEDs, or consent. Each cached peer session has its own fresh random local
boot ID. A HELLO must echo that receiver challenge before the sender session is
confirmed. Commands must target it and carry an increasing sequence from the
confirmed sender boot. A sender restart retires its previous boot; old boots cannot
become current again. Receiver restart or session-cache eviction creates a new
challenge, invalidating recorded commands without wall-clock timestamps or writes
to disk for every audio packet. This keeps the protocol-2 wire layout and works with
peers using the original process-wide boot ID.

The session cache is limited to 32 identities and preserves the current peer and
pending pairing identities for both received messages and outgoing handshakes.
An unknown sender's non-HELLO command cannot evict an entry. Each entry retains up to 128 retired sender boots;
further boots fail closed until the receiving app restarts. Static identity keys
provide authentication and encryption, but this protocol does not provide forward
secrecy if a private identity key is later compromised.

## Message vocabulary

```text
PAIR_REQUEST / PAIR_ACCEPT / PAIR_REJECT
HELLO
KEY_STATE(up|down [, capture_timestamp_ns])
PTT_INVITE(invitation_id) / PTT_ACCEPT(invitation_id) / PTT_REJECT(invitation_id)
PTT_DISABLE(agreement_id)
UNPAIR
TALK_START(talk_id)
AUDIO(talk_id, opus_packet_batch)
TALK_STOP(talk_id)
```

`HELLO` is sent every ten seconds. Confirmed paired HELLO payloads contain one
key-state byte and an eight-byte last-revoked PTT agreement ID. This retransmits a
revocation even if the original QoS-0 disable message was lost. PTT acceptances
require a matching outstanding local invitation. Consent, pending outgoing
invitations, and revocation IDs persist for the current peer; changing peers clears
them. Concurrent invitations converge on the smaller ID because both users have
already consented, and retry that ID until acknowledged. Declined invitations are
remembered and rejected again if the sender retries after a lost response. Menu
actions retain the invitation ID that was displayed.

A physical transition carries its original `CGEvent` timestamp, captured before
deferred controller work: one state byte followed by an eight-byte big-endian
nanosecond timestamp. Only timestamp differences matter; the two clocks need no
synchronization. The receiver starts playback with a one-second buffer and
preserves each source interval below one second, including dark gaps. Intervals
of one second or more refill the buffer, with a minimum playback duration of one
second, so longer holds and pauses absorb drift. A one-shot dispatch timer with
one-millisecond leeway drives each edge, independently of the maintenance tick.
Late timer wakeups shift the remaining queue instead of compressing queued pulses.
Delays beyond the buffer and hardware/OS scheduling stalls can still stretch an
interval that has already started; the light is not a hard real-time output.

This adds eight bytes per physical transition and no packets. Older protocol-2
receivers read the leading state byte immediately; new receivers accept legacy
one-byte key states immediately. Upgrade both Macs to preserve rhythm in both
directions. Held-key refreshes stay one byte and HELLO stays unchanged. Matching
snapshots renew freshness without jumping ahead of buffered edges; a conflicting
snapshot clears the queue and resynchronizes immediately. PTT still follows the
local key immediately and does not use the LED playback buffer.

The replay queue is capped at 256 edges and 2.5 seconds of scheduled lead.
Discontinuous timestamps, repeated transition states, or excess backlog clear
the queue and light. Disconnect, a fresh peer session, capture stop, unpairing,
shutdown, and stale input also cancel pending playback, preventing delayed relights.

A held key is refreshed once per second. Key input expires after 2.5 seconds and
presence after 25 seconds, checked by a one-second timer in common run-loop modes
(so expiry can occur up to one additional second later). All elapsed-time checks
use system uptime. Each playback callback also checks freshness before lighting.
Transport failure releases audio and remote key state immediately.

MQTT validates subscription acknowledgement, limits packet size and queued work,
serializes writes, and reconnects on a stalled handshake, send queue, or missing
PINGRESP. Audio playback bounds its queue and drains the final buffers before
transferring the half-duplex floor.

## Caps Lock ownership

Nickname metadata is optional and remains separate from key and voice state.
`PAIR_REQUEST` and `PAIR_ACCEPT` may carry bounded JSON containing the sender's
self-assigned `nickname`. A new `PROFILE` message (kind 12) exchanges that same
metadata with the current or pending peer, including a reply before acceptance.
Only authenticated messages from the paired peer or a pending request can update
names. An empty nickname explicitly removes a previously supplied name. HELLO's
existing nine-byte payload remains unchanged; older peers ignore PROFILE.

Recent peers are stored locally by full public key, newest established pairing
first. Pending or declined requests never enter that list. Display names prefer
the peer's self-assigned name, then a private local alias, then the final six
characters of the canonical pairing code. Unpairing retains history but removes
active consent. Selecting Recent opens the modal and requires fresh acceptance to
reconnect; it never silently restores microphone consent.

The reliable cross-version input path is:

```text
USB HID usage Caps Lock (0x700000039)
                 ↓ hidutil UserKeyMapping
USB HID usage F18       (0x70000006D)
                 ↓
CGEvent key code 79
                 ↓
consume event; do not forward to applications
```

Startup order matters:

1. Acquire the single-instance lock and recover any stale mapping journal.
2. Check Accessibility permission if capture is enabled. Request it at most once,
   persisting the attempt before showing system UI. Existing installs skip the
   request on upgrade; subsequent activations and permission polling are silent.
3. Read the current `UserKeyMapping` and install the consuming event tap.
4. Persist the original mapping before replacing its Caps entry with Caps→F18; read it back to verify success.
5. Clear and verify the system Caps Lock state before reporting capture as active.
6. On stop, restore and verify the journal before removing the tap; clear the journal only on success, then restore the preceding system Caps Lock state.

A failed stale recovery blocks new capture. Empty `hidutil` arrays are accepted,
and repeated cleanup after a successful stop performs no further mapping writes.
SIGINT/SIGTERM are delivered through dispatch signal sources, allowing ordinary
application cleanup without allocating Swift objects inside a signal handler.

The event tap consumes native Caps Lock events as well as the remapped F18 events. It clears the system lock state for every captured press, and strips `.maskAlphaShift` while preserving other modifiers. The controller immediately reapplies only the remote LED state, so a local press cannot latch the local light. LED output never sets the logical lock bit, preventing capitalization and the macOS Caps Lock cursor indicator. Dit's tail is yellow-green for outgoing activity, hollow otherwise, and red for pending attention while no outgoing key signal is active. The keyboard LED itself indicates incoming activity.

## Compatibility boundary

The Caps→F18 plus `CGEventTap` path is intended for built-in MacBook keyboards.
Exclusive device capture and reinjection are not implemented. The test matrix
must record built-in versus external keyboard explicitly.

The LED itself is a second, independent compatibility surface: writable HID LED elements vary by keyboard firmware. Unsupported lights remain unavailable rather than changing the system Caps Lock state.

## LED strategy

```text
setRemoteLED(on):
    for every keyboard HID device:
        find LED usage-page element with Caps Lock usage
        try IOHIDDeviceSetValue(element, on)

    if at least one write succeeds:
        driver = direct HID
    else:
        driver = unavailable
```

Direct HID controls the indicator independently of the lock state. `IOHIDSetModifierLockState` is reserved for clearing the lock during capture and restoring the prior state after capture stops; it is never used to light the LED during capture.

## PTT audio

```text
microphone hardware format
    → AVAudioConverter
    → 16,000 Hz, mono, signed Int16
    → 320 samples / 20 ms
    → native kAudioFormatOpus encoder at 12 kbit/s
    → batch 3 packets / roughly 60 ms
    → encrypted AUDIO message
```

The receiver buffers six packets, about 120 ms, before starting playback. That trades a little radio-like latency for fewer underruns on a public relay.

PTT is half-duplex. If both peers press simultaneously, the lexicographically smaller public key wins the floor. The losing side stops capture and receives, so both clients make the same decision without another coordination round trip.

## Single-file class map

Everything below lives in `slock.swift`:

```text
IdentityStore          persistent X25519 identity and pairing code
PeerStore              one persisted peer, PTT agreement, and revocation
PTTConsent             invitation IDs, accepted agreement, and revocation state
SecureWire             HKDF, ChaChaPoly, replay filter
MQTTClient              CONNECT/SUBSCRIBE/PUBLISH/PING over WebSocket
MQTTPacketDecoder      bounded incremental MQTT framing
CapsInterceptor         AX permission, event tap, hidutil preservation
CapsLED                 independent direct HID LED output
OpusEncoder             Int16 PCM → native Opus
OpusDecoder             native Opus → Float32 PCM
AudioCapture            microphone, resampling, framing, batching
AudioPlayback           jitter prebuffer and AVAudioPlayerNode
SlockController      pairing/key/PTT/presence state machine
AppDelegate             NSStatusItem menu and launch-at-login UI
SingleInstanceLock     exclusive ownership of the mapping recovery journal
```

## Pseudocode

```text
main:
    acquire exclusive instance lock
    run stale-keyboard-map recovery
    create menu-only NSApplication
    load-or-create identity
    load stored peer
    subscribe to inbox topic over WSS/MQTT
    request Accessibility permission
    when trusted:
        install F18 event tap
        preserve current hidutil map
        install Caps→F18 map
    register launch-at-login on first run
    run event loop

on physical_caps(down):
    local_down = down
    encrypted_send(KEY_STATE, down)

    if down and ptt_enabled and peer_online and not remote_talking:
        talk_id = random_u64()
        encrypted_send(TALK_START, talk_id)
        start microphone
    else if not down:
        stop microphone
        encrypted_send(TALK_STOP, talk_id)

on microphone_pcm(buffer):
    resample/downmix buffer to 16 kHz mono Int16
    append to pcm_accumulator
    while accumulator has 20 ms:
        opus_packet = encode(next_320_samples, 12_kbit)
        append packet to batch
        if batch has 3 packets:
            encrypted_send(AUDIO, talk_id + batch)

on encrypted_packet(packet):
    verify version
    derive key from sender public key
    authenticate and decrypt
    confirm fresh receiver challenge for HELLO; otherwise require confirmed session
    reject retired sender boots and duplicate sequence
    require sender == paired peer, except pairing messages

    switch message:
        PAIR_REQUEST: expose Accept / Reject menu items
        PAIR_ACCEPT: persist peer
        HELLO: mark online; refresh matching state or resynchronize a mismatch
        KEY_STATE: refresh watchdog; queue timestamped edges or apply legacy state
        PTT_INVITE: expose Accept / Reject menu items
        PTT_ACCEPT: enable PTT
        TALK_START: arbitrate floor; initialize playback
        AUDIO: decode packet batch and enqueue audio
        TALK_STOP: drain playback and release floor
        UNPAIR: clear peer, PTT, audio, and LED

on light_playback_deadline:
    if input is stale: cancel pending edges and turn LED off
    otherwise: apply the next edge and schedule the following interval

once_per_second:
    if local key is held:
        resend KEY_STATE(down)
    if ten seconds elapsed:
        send HELLO
        retry pending pair/PTT invitation
    if remote key refresh is older than 2.5 seconds:
        turn LED off
    if peer traffic is older than 25 seconds:
        mark peer offline; stop audio; turn LED off

on quit:
    send KEY_STATE(up) and TALK_STOP best effort
    stop audio
    turn LED off
    restore exact prior hidutil mapping
    disconnect MQTT
```

## Test plan

### Phase 0 — one Mac

1. Build and launch.
2. Grant Accessibility.
3. Confirm Caps Lock no longer capitalizes.
4. Run **Test Caps Lock Light**.
5. Quit and confirm normal Caps Lock behavior returns.
6. Re-run with a preexisting `hidutil` mapping and confirm it is restored byte-for-byte in meaning.

### Phase 1 — two Macs

1. Pair in both network directions.
2. Test 50 short taps and 10 holds of 5–30 seconds.
3. Disconnect Wi-Fi while the remote key is down; verify the light turns off within 2.5 seconds.
4. Reconnect and verify presence/key resynchronization.

### Phase 2 — PTT

1. Invite, accept, and grant microphone permission on both Macs.
2. Test alternating speech, simultaneous key-down, packet delay, and Wi-Fi loss.
3. Inspect Diagnostics for codec, broker, permission, and LED mode.

### Phase 3 — before distributing beyond friends

1. Replace the public broker with a private authenticated broker or small owned relay.
2. Add broker pinning/configuration and a migration/version mechanism.
3. Sign with Developer ID, enable hardened runtime, notarize, and ship a DMG.
4. Test a hardware matrix: Intel/T2, M1, M2, M3, M4/M5; built-in and external keyboards; macOS 13 through current.
5. Add packet-loss concealment or a more explicit jitter buffer if public-Internet audio needs to feel polished.

## Deliberate prototype limits

- one peer only;
- no offline message queue;
- no TURN or direct peer path;
- no contact discovery;
- no text/chat history;
- no broker SLA;
- no guarantee that direct built-in LED writes work on every keyboard controller;
- ad-hoc signed rather than notarized;
- build, regression, and hardware validation results are recorded in `VALIDATION.md`.
