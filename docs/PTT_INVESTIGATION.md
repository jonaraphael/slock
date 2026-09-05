# One-way PTT audio investigation — 2026-09-05

Seth could hear this Mac, but this Mac could not hear Seth. The listener had
released Caps Lock and was using the same headphones that had played Bex's
microphone earlier. The Seth test was around 01:20 Eastern; the peer apps were
reported to be approximately version 0.2.5.

## Evidence and conclusion

- The running local installation is 0.2.6 on macOS 14.8.9. The native capture,
  Opus, and playback implementation is identical in the 0.2.5 tag and 0.2.6 HEAD.
- During the relevant 01:21–01:27 period, slock's system logs show input and
  output sessions, with output directed to the Bluetooth headphone device.
  Playback starts at 01:21:05, 01:21:10, 01:21:23, and later. In this code,
  playback creation/start follows an accepted remote TALK_START. This supports
  successful delivery of remote talk control messages, not necessarily audio.
- There are no Core Audio error lines in that interval. Earlier zero-channel,
  zero-rate converter errors at 00:01 and 00:53–00:54 are outside the reported
  Seth test and are not evidence of its cause.
- The old diagnostics and application logs did not count audio batches or
  record signal levels. Starting an output engine does not establish that it
  decoded nonzero samples, scheduled them, or produced audible sound.

The strongest lead is Seth's input/capture path: the selected microphone, input
gain or mute, microphone permission, or a capture/conversion failure. His ability
to hear the local speaker proves his receive path, not his microphone. Receiving
Bex successfully makes a persistent local output problem less likely. A transient
Bluetooth/output-engine problem remains possible. The evidence does not establish
a definitive cause, and Seth's Mac was not inspected.

## The two indicators

Both 0.2.5 and 0.2.6 draw a yellow-green Dit tail while the local key is down or
the Mac is transmitting. That tail also lights for lights-only activity and does
not prove that audio samples were captured or delivered. Neither version replaces
Dit with an orange microphone.

The orange dot beside Control Center is macOS's
[microphone-use indicator](https://support.apple.com/guide/mac-help/quickly-change-settings-mchl50f94f8f/mac).
The likely explanation for Bex's orange microphone is macOS's separate audio/Mic
Mode menu, whose availability depends on the app and Mac. This remains an inference
without seeing her menu. Apple's
[Mic Mode guidance](https://support.apple.com/en-us/121587) explains that the menu
may be absent when the feature does not apply. The much older pre-Dit app used a
template microphone symbol during voice activity, but 0.2.5 does not.

## Diagnostic changes

The source now exposes launch-total talk-start and audio-batch counters, and
latest-talk PCM sample counts and peak levels for capture and decoded playback.
It also shows generated batches, decoded packets, playback-completion counts,
engine/player state, microphone permission, and an audio error retained separately
from subsequent network errors. Clear Error clears that retained error.

Voice transitions log those summaries without logging each packet. Only aggregate
signal levels are retained; this does not save recordings or sample content.
Queued means submitted to the local transport, accepted means forwarded to the
decoder, and played means the audio framework's playback callback fired. None is
a claim that another person heard sound. Counters span peers within a launch;
compare before/after snapshots for the test in question.

For a repeat test, have Seth select his intended microphone in System Settings →
Sound → Input, verify that the input meter moves while speaking, and check slock's
Microphone permission. Use Standard if the macOS Mic Mode menu is present. Hold
Caps Lock for several seconds while the listener leaves it released. Copy
Diagnostics on both Macs immediately afterward using Option-click on Dit.

| Observation | What it narrows down |
| --- | --- |
| No captured PCM on Seth's Mac | Capture never started or the input engine delivered no converted samples. |
| Captured PCM is digital silence or has a very low peak | Investigate Seth's microphone, gain, mute, and input processing. |
| Batches generated but not queued | Investigate local session/transport state. |
| Batches queued at sender but none received | Investigate relay/session delivery. |
| Batches received but not accepted | Investigate talk-start delivery, consent, floor ownership, or a stopped/expired talk. |
| Accepted batches but no decoded packets | Investigate decoder/startup errors. |
| Nonzero decoded audio but no completed playback | Investigate playback scheduling and output-engine state. |
| Nonzero decoded audio and completed playback, still inaudible | Check the output device, output volume, and headphones. |

The playback code also lacks explicit recovery for
[audio-engine configuration changes](https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification).
Apple documents that hardware sample-rate/channel changes stop the engine. That
is a code-level risk to investigate with a device-switch reproduction, not a
confirmed explanation for this incident. No speculative routing fix, installation,
or release is part of this investigation.

## Validation

- All 123 tests passed with normal native-codec access: 91 regression, 8 light
  timing, 9 nickname, 8 security, and 7 update tests. The regression suite includes
  bidirectional audio delivery and rejection after a playback error, retained
  audio errors, and a nonzero synthetic signal through the native Opus codec.
- The first sandboxed run could not access the native Opus encoder; the same
  codec checks passed when rerun outside that restriction.
- The production source typechecks for arm64 with a macOS 13 deployment target.
- No physical microphone, headphone playback, remote-Mac test, or device-switch
  reproduction was performed. The installed app was not replaced.
