# Shared dictation library

RemoteCoder's built-in iOS and macOS dictation optionally uses SpeechKit's
`DictationLibrary` product. `SharedDictationLibrary`, owned by the workspace,
keeps its producer spool under the device's `dictation-library` directory.
The local **Use WisprClone Library** choice is off by default and is not synced.
WisprClone is the main editor of the personal profile and dictionary. RemoteCoder's model and language controls edit that same account-bound profile when connected; local preferences apply when disconnected. The displayed model is the same resolved model the capture uses.

A capture freezes the effective model, ordered languages, dictionary and cleanup
plan with explicit `chat` context. Existing RemoteCoder model preference raw
values remain unchanged. Shared model keys identify provider, native model and
transport; an unsupported preference uses the local model and shows that
resolution without changing the shared preference. The library owns cleanup,
including distinguishing a cleaned transcript from a model answer. Shared settings
and cleanup remain effective when the shared profile turns original archiving off.

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

Provider output, any speaker-filtered Azure output, and subsequent cleanup are
separately identified immutable versions. The raw selected-provider result is
the parent of the filtered result, and cleanup uses the delivered text as its
parent. Each version names the model that produced its text, using the existing
result kinds. Only Mine defaults to on for MAI-Transcribe-2; other models require
an explicit choice before a second Azure request. The workspace owns one local
voice template independently of this library, with live learning and one replay
of recent local originals when the library is enabled. Filtering happens before
cleanup. Composer drafts retain everyone’s text for Restore Everyone until the
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
- Run the live production transcription factory with nonempty personal hints,
  plus the common cleanup runner. A skipped live test does not satisfy this gate.
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
