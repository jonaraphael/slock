# Review and fixes — 2026-09-04

The imported prototype had build, privacy, and reliability defects. The following
were fixed in version 0.2. Findings came from source review and focused regression
tests; physical keyboard and two-Mac operation still need hardware validation.

| Finding | Resulting change |
| --- | --- |
| **High: MQTT parsing could crash after the first packet.** `Data.removeFirst` advances its indices, but the parser indexed from zero. | Incremental parser respects `startIndex`; byte helpers also handle slices and overflowing offsets. Fragmented and coalesced streams are tested. |
| **High: replay protection could roll back to a recorded sender boot.** Only the latest boot's sequence was remembered; receiver restart also forgot replay state. | Protocol 2 requires a fresh receiver challenge, confirmed sender session, increasing sequence, and retirement of previous sender boots. Recorded messages from either side's previous process cannot authorize commands. |
| **High: unsolicited or delayed PTT acceptance could enable audio without a current local invitation.** | PTT uses explicit invitation IDs, matches accept/reject responses, cancels stale permission callbacks, and persists consent only for the current peer. |
| **High: a pair request could change while its menu item was visible, pairing a different identity from the one displayed.** | Accept/reject actions retain the displayed public key and refuse to act if the pending request changed. Pairing instructions require checking the other Mac's ID through the trusted channel. |
| **High: losing a QoS-0 PTT-disable message left the peer enabled.** | HELLO repeats the revoked agreement ID; old revocations cannot disable a newer agreement. Concurrent invitations converge deterministically. |
| **High: keyboard recovery could discard the original journal after failure, or overwrite it during a subsequent startup.** | Failed recovery blocks capture and retains the journal; cleanup clears it only after successful restoration. A failed stop retains the event tap. |
| **High: duplicate app processes could compete over one global keyboard mapping.** | An exclusive process lock is acquired before identity loading or stale-map recovery. |
| **Build blocker: an IOKit function returning a nonoptional value was used in optional binding.** | Corrected LED value construction. |
| **Missing distribution files made the documented build impossible.** | Added universal build and test commands, bundle metadata and microphone purpose string, license attribution, and generated-artifact ignores. |
| **Repeated stop could overwrite later user mapping changes; empty arrays prevented capture restarting.** | Successful stop relinquishes ownership; empty `hidutil` array formats are accepted. |
| **Missed key-up during event-tap disable could leave voice transmission latched.** | Tap-disable handling releases the hold before reenabling capture. |
| **Menus could delay watchdogs, while wall-clock adjustments distorted timeouts.** | Timers run in common run-loop modes; timeouts use system uptime. |
| **Transport failures left audio recording, and reconnect could resume audio without a new TALK_START.** | Connection loss immediately stops audio and key state; every new talk checks connection, capture, presence, and consent. |
| **MQTT accepted failed subscriptions and had no application-level handshake or ping timeout.** | Validate SUBACK; bound inbound packets, pending messages, and ordered outbound writes; reconnect on handshake, send, or ping stalls. |
| **Audio capture shared mutable state across queues, and delayed callbacks could target a new peer.** | Capture state is serialized, queued input is bounded and tagged by generation, and outgoing batches retain their original peer and consent ID. |
| **Playback could grow without bound or truncate the last word when handing over the floor.** | Bound outstanding buffers, track actual playback completion, and drain before starting local transmission. Engine startup failures stop the playback path. |
| **Quick release/repress could lose a new PTT hold while the prior stop was deferred.** | A pending new hold is retried after the prior talk finishes stopping. |
| **Signal handlers allocated Swift objects and skipped ordinary LED/audio cleanup.** | Dispatch signal sources invoke normal application termination; the existing emergency restore is only used during ordinary process exit. |
| **Launching, quitting, or a delayed LED self-test could change normal Caps Lock state while capture was disabled.** | Touch the LED only while capture owns it; restore the preceding logical state on successful stop; ignore stale self-test completion. Remember the capture preference. |
| **Unreadable/corrupt identity keys were silently replaced, and permission failures were ignored.** | Existing invalid keys fail with an error. New keys use private permissions, and loaded keys have permissions checked/set. |
| **Waiting for subprocess exit before draining pipes could deadlock the UI.** | Drain stdout and stderr concurrently with child execution. |
| **A failed first login-item registration was never retried.** | Persist the first-run completion flag only after successful registration. |

## Validation boundaries

See [VALIDATION.md](VALIDATION.md) for the exact checks and environment.

The public relay remains prototype infrastructure. The protocol authenticates
messages but exposes routing metadata and does not provide forward secrecy.
Hardware LED support, permission flows, microphone device changes, sleep/wake,
and two-person latency/voice quality require the manual matrix in
[ARCHITECTURE.md](ARCHITECTURE.md). These are validation gaps, not claims that the
entire application has been exercised end to end.

Both peers must upgrade to version 0.2 together and enable PTT again.
