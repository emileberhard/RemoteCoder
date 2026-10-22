# Async questions

## Contract

The host owns the question lifecycle. Transcript pagination owns row visibility,
not pending/answered knowledge. The iOS conversation session holds a host replica
and its existing local submission receipts, not another lifecycle reducer.

A set is identified by host + thread + item ID; a slot retains its original
zero-based index. Canonical answers resolve only addressed slots. Later genuine
plain user input supersedes older pending slots, not answered slots. Synthetic
voice/context input and malformed reply envelopes cannot clear questions.
Turn completion changes execution state, not question state.

Close dismisses a presentation. Dismiss question durably dismisses remaining
pending slots without sending model input or interrupting work. An explicit
canonical answer can subsequently replace dismissal or supersession. Suggested
options are not consent and are never submitted automatically.

Local persistence, upstream admission, and canonical confirmation are separate
receipts. Uncertain sends are never automatically replayed. An admitted input
cannot become unadmitted because the connection later drops.

## Recovery

Read canonical native item pages at a passive observation checkpoint. A summary
is not an outstanding-question inventory. Use opaque returned cursors unchanged;
first-projection ordinals are not update watermarks. Late completions and missed
notifications must be reconciled before declaring coverage ready. Passive
observation must not acquire execution/recovery ownership.

Durable per-thread records use the existing private-state replacement primitive
and cross-process file locking. Dismissal commits before acknowledgment. Corrupt
or unsupported documents are preserved. Runtime restart does not erase state.

## Wire boundary

`conversation/questions/read` returns bounded per-thread attention inventories
and requested historical records, with epoch, revision, and explicit coverage.
`conversation/question/dismiss` carries `threadId`, `itemId`, `expectedEpoch`,
`expectedRecordRevision`, and `mutationId`. It is an epoch/revision-checked,
idempotent host mutation. A history replacement cannot accept an old dismissal
just because an item ID and numeric revision happen to repeat.
`conversation/questions/changed` invalidates the affected host/thread replica.
Existing `turn/steer` and `turn/start` remain the answer transport.

## Regression witness

`protocol-fixtures/questions/answered-outside-viewport.json` is sanitized. The
question is at 956, its canonical answer at 976, and the later 50-item page starts
at 985 while the summary still contains the question. Both a warm client and a
fresh client must show no actionable question after loading that page.

The implementation plan lives in Obsidian at
`agents/reports/remotecoder/2026-09-20 - Async question lifecycle implementation plan.md`.
This branch is developed and tested independently; production runtime and
physical-phone installation are not evidence supplied by simulator testing.

## App ownership and limits

`ConversationSession` checkpoints the host replica and existing submission receipts.
Attention reads publish pending counts independently of transcript ownership and
merge records only into existing sessions. Unknown coverage clears the known count;
reading or invalidating an unopened thread never creates a transcript session.
Binding a transcript session with unknown coverage requests that thread alone,
even when a prior attention read already included it. A ready session reuses its
replica without another binding read.
An editor is keyed by host/thread/item and recreated for a changed epoch.
Mac native virtualization retains only question expansion/confirmation UI state
in `TranscriptRowPresentation`; answer drafts and flow remain in the editor.
Focused fields and open confirmation dialogs pin their row host. Original
question indices survive partial answers and refreshes; unsent text is preserved
when another client resolves other slots. Sending returns local submission identity,
not false success. The sheet closes after admission or canonical resolution of its
own question. Rejected input is retryable; uncertain input requires status checking
and explicit duplicate-risk confirmation before another send.

Progress dots carry immutable draft-status values keyed by original slot indices.
Deferred SwiftUI children never index the editor's changing pending list; a delayed
selection of a removed slot is ignored. Editors reconcile the initial host record
before their first render, so resolved history never begins as an interactive form.
`QuestionCardRenderingTests` mounts actual cards through two/one/zero pending slots,
admission and historical resolution, and exercises a retained dot snapshot.

An unavailable replica displays its reason and offers Refresh. Old gateways without
these RPCs do not trigger the removed viewport fallback. Ordinary chat still works.
Old push taps request the exact historical question and open a read-only resolved
card rather than resurrecting attention. The drawer displays question attention
separately from execution, so an async question does not imply a blocked turn.
The Mac Dock badge sums the known per-thread counts of unseen questions
(`AttentionSummary`); threads outside the question scope contribute nothing,
and no known count shows no badge rather than zero.

The host admits at most two history scans and 32 retained watch entries, batches
at most 16 thread reads, limits historical selection to 128 IDs, and caps responses
at 2 MiB. Per-thread private state is capped at 16 MiB. Passive subscriptions are
retained while a turn is active or while a loaded thread has recently interested
clients; idle interest expires after 45 seconds. Disconnect/replacement releases
only the owned resources. Per-token deltas never trigger lifecycle storage.

## Attention

A pending question needs you only while it is unseen: asked after the
conversation was last read, that is after the later of the marks' read
baseline and the thread's `seenThrough`. Reading the turn that asked it, or
settling the conversation, stops it counting as attention; its card stays
answerable. A question without an ask time is never attention, and neither
is one that settlement covers: asked at or before the conversation's
`settled(through)`, or three days or more ago unless an `active(through)` still
holds the row (`docs/system-architecture.md`, *Conversation drawer order*). The drawer's needs-you tier and row badges, the Mac Dock badge and the
Live Activity's question marker all apply the unseen rule (`ConversationMarks.isUnseenQuestion`,
`asked_since_read` in `host-daemon-rs/src/gateway/live_activity.rs`). A
question never puts a conversation in the Live Activity by itself; only an
unread finished turn does.

## Verification

Shared fixtures cover the original 956/976/985 window and a fresh client. Rust tests
own canonical ordering, malformed input, partial answers, transactional dismissal,
recovery, epoch replacement, and observer cleanup. Swift tests own replica merging,
receipt recovery, editor lifetime, original indices, stale reads, and presentation.

`rc-gateway e2e-questions-live --cwd <test-directory> --receipt <json>` exercises
actual Codex item handling and both host RPCs. For deterministic UI verification,
run the pinned app-server and candidate gateway under a temporary HOME/CODEX_HOME
on the GUI test host, with `question_model_fixture.py` as a loopback Responses provider.
No account credentials or production conversations are needed. The app's ignored
local configuration points only at that lab. `QuestionLifecycleUITests` proves
Close versus Dismiss, answer admission, and persistence through app relaunch.
The fixture run is distinct from a subscription-provider probe and deployment.

Quiescent unloaded watches may serve a verified snapshot for at most ten seconds;
source invalidation and connection-generation changes bypass that freshness bound.
They do not keep a provider subscription alive. On the client, observation-only
revision and coverage changes are not reasons to rewrite the transcript checkpoint.
Question records/epochs and local action receipts retain their durability, and
unavailable coverage remains explicitly unavailable to the UI.
