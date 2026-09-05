# Paired Macs with no light relay — 2026-09-04

## Observed on this Mac

- The installed executable matched commit `94cf619` and the validated universal
  build. A peer was saved, and the network connection reached ready in process logs.
- At 22:00 local time, capture logged requested=true, active=true, trusted=true.
  An unsandboxed read of `hidutil` verified Caps Lock → F18. A sandboxed `hidutil`
  query returned `(null)` and was not used as evidence of the system mapping.
- LED writes repeatedly logged `TCC deny IOHIDDeviceOpen` after permission was
  granted. The device objects had been created before that grant.
- Restarting the unchanged installed app at 22:16 restored active capture without
  new keyboard-device denial logs. No remote hardware test was possible because
  the other Mac's user was unavailable.

The GitHub `v0.2.2` download still targeted commit `1baf7c0` when checked. That
build predates event-mask validation and can report active capture when macOS
removes key-down/key-up access from its tap. This is a plausible explanation for
the remote Dit tail staying idle; it is not confirmed without remote diagnostics.

## Confirmed driver defect and fix

Apple's HID device implementation caches its first authorization result. Closing
the device does not clear a denied result. Opening the same manager again also
does not reliably reopen its devices. See
[IOHIDDeviceClass](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDLib/IOHIDDeviceClass.m#L468-L607)
and [IOHIDManager](https://github.com/apple-oss-distributions/IOKitUser/blob/main/hid.subproj/IOHIDManager.c#L856-L922).

Version 0.2.3 creates keyboard LED devices only after HID listening access is
granted, matches keyboard devices explicitly, and discards failed objects before
retrying. It preserves open/write errors and reports permission failures separately
from unsupported LEDs. The menu exposes light retry and Input Monitoring recovery
when needed. Diagnostics include the event mask, local Caps press count, queued
and received key messages, peer HELLO count, and LED-device results, with a copy
button. Logs record link-status changes and Caps signal counters, not ordinary
keystrokes or audio content.

The capture menu now shows Pause Slock while capture is active and Resume Slock
otherwise. Each action sets the requested state explicitly, including retrying
capture when it was requested but is not yet active.

## Validation

- 53/53 regression tests and 7/7 nickname tests passed with normal native codec
  access. New lifecycle fakes retain their initial permission result, reproducing
  the HID caching behavior and proving recovery requires new objects.
- Two-controller tests verify that the diagnostic counters distinguish captured
  presses, queued messages, received messages, and the final released state.
- Universal arm64/x86_64 build passed, with macOS 13.0 minimum verified for both
  slices and strict code-signature verification passing. Version is 0.2.3.
- Shareable build: `dist/slock-0.2.3.app.zip`.
  SHA-256: `9622cddfa441ad7193c95e23b4b9cf806f8eef99c0dec3fa0832b113c1832656`.
- Validated source SHA-256:
  `93e9ee107bf769dfaac84c3f008a022b41601da93151d8d9812a486e59229455`.

The installed app was only restarted; this new source build has not been installed
or published. The two-Mac keyboard/LED test and second Mac's permission diagnosis
remain pending. No claim of working physical inter-computer light control is made.
