# Browser dictation

The browser records locally and saves the original for recovery. At stop it
converts the recording to 16 kHz mono PCM16 WAV, uploads it to the selected
gateway and calls `dictation/transcribe` with the upload path and duration.
The duration is positive and at most 30 minutes; the deadline is 120 seconds
plus that duration. A failed conversion, upload, request or host operation
falls back to the browser's existing relay using the original recording. A
failed relay leaves the saved recording available for Retry. A nonempty
transcript is inserted and durably flushed as one draft operation; a failed
flush restores the previous draft and retains the recording. A successful host
result is authoritative even when its filtered text is empty: the browser
inserts nothing and never falls back to the relay, which would restore other
voices.

An opted-in Mac app declares `dictation/host/declare` on each connection. The
newest serving declaration receives new operations; declarations are applied in
socket order and already admitted work stays with its chosen connection. A host
that reports it is no longer serving removes only the declaration selected for
that operation, preserving any newer declaration. The gateway permits four operations, validates the
path as a bounded finished upload, forwards `dictation/host/transcribe`, and
relays a matching `dictation/host/result`. It sends `dictation/host/cancel` on
requester loss, explicit request cancellation or deadline. Transcript text is
excluded from the gateway journal. A deadline is `unknown`: the library may
already contain the capture. Host loss is `hostLost`; absent and busy hosts report
`noHost` and `busy`. Turning the role off removes its declaration without moving
an admitted operation. The app admits work only while its role is enabled and
the connection's last sent declaration is serving. Declaration reconciliation
runs outside chat initialization with bounded retries, and a failed withdrawal
does not delay the role's drain. The connection stays held through bounded
result-delivery retries until acknowledgement or failure.
Finished uploads follow UploadStore retention, which has no supported removal
operation for finished entries.

The host downloads through `files/download` and runs the native library plan,
original archive, voice filtering, batch transcription and result archive. Its
recovery recordings are separate from composer recordings and discarded after
the operation. The host owns the process activity and background socket
liveness while the role is enabled and until admitted work drains after it is
disabled; normal target work loops stay separate.
CloudKit sync and the device-local voice profile remain the native owners.

## Decision

The goal is native settings, voice filtering and library parity without a second
implementation. The constraints are CloudKit entitlement, the device-local Core
ML voice model, the existing bridge routes, bounded work and local recovery.
The browser owns capture and fallback, the gateway owns only relay sessions and
bounds, and the Mac app owns the pipeline and settings.

A streaming handoff was rejected because it needs ordered append transport,
backpressure, sequence and journal rules, while the current default is batch.
A Wasm or TypeScript port duplicates unavailable native integrations; CloudKit
Web Services needs another sign-in and store; browser voice isolation is not
Only Mine; a new bridge route cannot yet ship; and device tools are agent tools
with different ownership. Batch uses the existing uploads and socket routes.

This depends on a backgrounded Mac remaining connected and reconnecting after
socket loss, and on browser microphone audio working with native voice-profile
calibration. An empty profile can leave everyone in the result. Changing the
wire contract or the newest-serving-host rule later would require coordinating
browser, gateway and app versions.

The host feeds a complete recording faster than real time, so its voice check
can still be running when the batch transcript returns. SpeechKit 0.10.1 waits
for that check within the delivery budget; a check still running at the budget's
deadline keeps everyone's text.
