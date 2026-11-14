# Shared dictation library

RemoteCoder's built-in iOS and macOS dictation optionally uses SpeechKit's
`DictationLibrary` product. `SharedDictationLibrary`, owned by the workspace,
keeps its producer spool under the device's `dictation-library` directory.
The local **Use WisprClone Library** choice is off by default and is not synced.
WisprClone is the main editor of the personal profile and dictionary. RemoteCoder's model and language controls edit that same account-bound profile when connected; local preferences apply when disconnected. The displayed model is the same resolved model the capture uses.

A capture freezes the effective model, ordered languages, dictionary and cleanup
plan with explicit `chat` context. Retained RemoteCoder model preference raw
values remain unchanged; removed OpenAI/Gemini selections use the available default. Shared model keys identify provider, native model and
transport; an unsupported preference uses the local model and shows that
resolution without changing the shared preference. RemoteCoder no longer advertises cleanup because its Gemini vendor path has no
upstream. Existing cleanup results remain readable; new captures archive the
selected provider output and any speaker-filtered result. Shared language and
dictionary settings remain effective when original archiving is off.

`AudioRecorder` retains microphone/session/route ownership. Its capture sink
configures the archival journal before the engine starts and appends microphone
buffers before provider resampling. The journal manifest and stable UUID exist
before audio; its sealed original is 48 kHz mono Opus CAF. The provider PCM
recovery writer uses that same UUID but has a separate directory and lifecycle.
Saving a draft receipt and flushing it can discard only the provider recovery
copy. It never discards the shared original or result versions.

The producer spool has a 512 MiB budget. Unpublished originals are never evicted
to make space. Each publication pass releases the oldest originals iCloud has
acknowledged and still holds until the spool is at most half full, so a full
spool of uploaded audio never stops archiving; an original iCloud cannot
confirm stays local and shows as a publication failure. Settings offers an explicit Free Uploaded Local
Audio action for the remaining acknowledged originals; its confirmation
distinguishes iCloud acknowledgment from independent backup. Account confirmations freeze the confirmed
lease so an account change cannot redirect assignment or deletion. A full/unwritable spool is visible and leaves ordinary local
recovery dictation usable; it does not claim the capture was archived. An
unconfirmed account uses local settings without personal hints and holds the
capture without assigning an iCloud owner. Known other-account captures remain
fenced. Settings provides an explicit current-account assignment only for
unowned captures, with a confirmation explaining its consequence.

Provider output and any speaker-filtered Azure output are separately identified
immutable versions. The raw selected-provider result is the parent of the
filtered result. Historical cleanup versions retain their original provenance. Each version names the model that produced its text, using the existing
result kinds. Only Mine defaults to on for MAI-Transcribe-2; other models require
an explicit choice before a second Azure request. The workspace owns one local
voice template independently of this library, with live learning and one replay
of recent local originals when the library is enabled. Composer drafts retain everyone’s text for Restore Everyone until the
filtered text is sent or replaced. Saved recovery recordings deliver everyone's
text because no live watcher ran for them; retrying does not send an extra Azure
request.

Failure versions contain the error type, never a credential or
provider response body. Publication retries on capture completion and foreground
activation; settings also exposes retry. Saved locally, pending uploads, held
captures, cloud acknowledgment and independent backup are distinct states.
RemoteCoder does not own the primary service host export or independent backup.

Both app targets use the explicitly configured CloudKit container and the private
`TranscriptionHistory` zone through the companion. Extensions gain no CloudKit
capability. Debug source pins Production; distribution source omits the
environment key so distribution signing selects Production.

## Delivery gates

- Pin the released SpeechKit revision, removing any temporary local package path.
- Run actual iOS/macOS app compilation and focused recording/capture tests.
- Run the direct transcription factory with nonempty synthetic hints.
  A skipped live test does not satisfy this gate.
- Verify App ID/container association, exact profiles and final signed entitlements.
- With WisprClone closed on the capture device, record in RemoteCoder, publish,
  then find/play the original in WisprClone. Verify the primary service host export checksum and
  independent backup restore separately.
- Lead integration owns merge, version selection, release, signing changes,
  schema promotion, installation and acceptance. No device install follows from
  an unsigned compile receipt.

The live gate is `RC_LIVE_GATEWAY=1 just ios-simulator-test
RemoteCoderTests/TranscriptionIntegrationTests`. It uses the app's
`GatewaySpeechAccess` and locally provisioned ignored `RemoteCoderLocalConfig.json`.
The build runner carries that private file only for installation or this explicit
live simulator test; ordinary test, macOS build and archive snapshots exclude it.

## Stop latency

The workspace-owned library runs original sealing and each result write as its
own utility-priority task and retains them until they finish, so a result never
waits for Opus encoding. Recording stop admits that work without awaiting
encoding, result writes or cloud publication. Stop-to-text delivery never waits
on the `DictationLibraryStore` actor: account checks read the store's synchronous
session snapshot, and account monitors wake on the library's observed account
events, so a store busy with publication cannot delay them. The live upload ends
its input as soon as the recovery writer has finished, before the audio session
is released. Provider recovery audio and its durable draft receipt remain
independent. Termination drains the tasks. A process kill leaves the
microphone-rate PCM journal recoverable but loses a result not yet written, so
that original stays in the library without its transcript. A failed result
write stays queued in memory for the next publication pass, and its count stays
in the library status without failing the dictation; a write that can never
succeed, for a missing capture or a conflicting version, is logged and dropped.

The blocked-encoder regression test delivers and durably receipts composer text
and writes its provider result while original sealing is still blocked, then
checks the retained original. The live
Azure test drives the actual composer start/stop path, production factory,
progressive upload, result and draft persistence with identical synthetic audio.
Its measured exit includes draft flushing; audio hardware is injected separately.

Apple references: [Task lifetime](https://developer.apple.com/documentation/swift/task)
and [structured concurrency](https://developer.apple.com/videos/play/wwdc2023/10170/).

Shared-settings edits retain the account lease of the displayed controls. A late
profile refresh cannot undo a completed local preference write. Producer
publication retries after sealing, and workspace termination drains pending
original finalizations even when no gateway targets remain.

## Performance check, 2026-10-21

The physical M1 test iPad replay compares pre-library `f14b50ea2` with corrected
`7d742a475`, using the identical 60-second fixture, Release configuration and
accepted device/driver/thermal metadata. Both reports are valid. Process CPU was
13.373 s before and 12.018 s after; main-thread CPU was 7.459 s and 7.246 s. Peak
sampled footprint was 244.47 MiB and 244.91 MiB. Frame callback p99 was 16.67 ms
and 16.55 ms; intervals over 50 ms were 14 and 15. No clear regression appeared,
so no repeated regression investigation was warranted. One pair does not prove
a speedup. This offline harness disables the live dictation library and cannot
measure background CloudKit work or physical microphone stop latency.

Private raw reports remain outside Git under
`~/perf-traces/remotecoder/unified-dictation-20261021/`. The separate live Azure
composer test passed four matched requests: 1.069 s and 0.181 s without archival
sealing, 0.222 s and 0.190 s with it. The first request was cold; these timings
show request variability, while the blocked-encoder test proves text delivery
does not wait for original sealing.

## Only Mine relay budget

The labelled pass uploads uncompressed 16 kHz mono PCM16: 1.92 MB per minute
(about 19.2 MB at the ten-minute recognition limit), in addition to the selected
provider's audio. This applies on cellular too. The device-local voice template
is never uploaded.

Synthetic dominant-owner dictations through the real gateway, measured on an
iOS simulator on a Wi-Fi Mac, produced these times in milliseconds. The final
three rows use SpeechKit 0.6.0; the earlier rows measured the same Azure adapter
before recognition integration:

| Audio seconds | Device-to-relay upload | Labelled completion | Added wait after ordinary text |
| --- | --- | --- | --- |
| 78.440 | 115 | 1024 | 617 |
| 165.640 | 307 | 4134 | 2905 |
| 340.040 | 460 | 2189 | 694 |
| 78.440 | 249 | 1822 | 746 |
| 165.640 | 499 | 1484 | 558 |
| 340.040 | 746 | 6003 | 4755 |

All six filtered successfully. An earlier 78.440-second request took 117 ms
to upload, 3664 ms to complete and 224 ms of added wait. These are seven requests,
not a phone or cellular benchmark. The largest upload ratio was 3.18 ms per
second of audio, rounded up to 4 ms. Added to the provider allowance of
4 s + 5 ms per audio second, RemoteCoder uses min(6 s, 4 s + 9 ms per audio
second), counted after the ordinary transcript arrives. The 6.003-second reply
added 4.755 seconds after ordinary text and does not require a larger cap. Past that budget it
delivers the selected provider's text and records a failed check; profile status
is unchanged. Production diagnostics record upload, completion and added wait
separately without recording audio or transcript contents.

History decoding keeps its streaming AVAudioConverter loop: the capture
processor has no file-reading/end-of-stream contract and buffers capture-sized
chunks without draining resampler tail at EOF. Reusing it would require a new
contract for file conversion, so the decoder remains the explicit file boundary.

## Publication lifetime and observability

`SharedDictationLibrary` owns a single background execution across overlapping
original sealing, result writes and its serial publication task. It acquires the
hold before admitting any of that work and releases it once all work is idle.
UIKit expiration cancels the pass and ends the hold; sealing that finishes
after expiry cannot restart publication in that expired interval. App
backgrounding keeps publication running. The Mac uses the existing foreground-only execution seam.
A committed write keeps its local receipt even when cancellation arrives during
the request, so a later pass resumes without losing progress.

Activation refreshes the shared profile explicitly. A publication pass refreshes
only when it has no verified account session, and never runs its own recovery.
SpeechKit owns recovery, the sealed/current-account pending predicate,
newest-first publication, chunk-before-capture-before-result ordering, and
bounded transient retries. An empty dictation logs a notice without replacing
the status with a recovery warning.

Every pass that did or attempted work emits one `AppLogger` notice in category
`DictationLibrary`: background state, duration, pending before/after, held count,
outcome and at most three capture failures with UUID, case, domain and code.
Unavailable counts stay unknown. Errors use their typed fields; account
identifiers and transcript text never enter these notices. Both app targets use
one producer in the main application process; extensions have no producer store,
and no command mode performs producer recovery or publication.

Apple references: [background execution lifetime](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)
and [CloudKit request configuration](https://developer.apple.com/documentation/cloudkit/ckdatabase/configuredwith(configuration:group:body:)-637p1).

## Direct native dictation

`GatewaySpeechAccess` uses a host-scoped dictation-only router key from
`GET /dictation`, stored with its origin in the device-only Keychain. It refetches
once on router 401 and retries saved uploads once with the replacement. Cached
access needs neither the gateway nor Tailscale. Provider credentials remain on
llm-router. Installation revocation does not revoke an already delivered router
key; revoke that host's dictation key on the router to invalidate its copies.

Azure MAI-Transcribe-2 uploads at stop through the public router origin;
`DictationUploadAudio` selects lossless FLAC for both saved recordings and Only
Mine labels. SpeechKit owns the encoder and preserves the local PCM recovery
copy. ElevenLabs and AssemblyAI realtime modes use the router directly.
The gateway relay remains for web and installed older builds. Upload time grows
with the encoded recording size and the available uplink bandwidth.
