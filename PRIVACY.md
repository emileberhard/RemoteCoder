# Privacy

RemoteCoder connects clients to gateways you choose. A gateway runs as its host
user and can access that user's files, commands, signed-in providers and tools.
The operator of each gateway, browser bridge and optional service controls that
service and can access data it processes. Self-hosting does not make provider
requests local. This document describes the source implementation; an operator
may configure additional tools, services, backups and retention.

## Conversations and files

Prompts, replies, reasoning summaries, tool activity, working directories,
attachments and conversation settings pass between your client and gateway.
Codex and Claude Code send the relevant conversation and tool context to the
provider you signed in to or explicitly configured. An optional llm-router
receives requests it routes. Provider account terms and privacy policies govern
their processing and retention. Agents can call other services with the host's
permissions; RemoteCoder does not restrict their access to a fixed provider list.

Provider histories remain in their host-side session stores. The gateway also
stores metadata, read/pin/settlement state, question state, device registrations
and recovery records. Native clients retain drafts, bounded history and render
caches, pending submissions and checkpoints in their application storage.
A browser keeps preferences, drafts and uncertain-action receipts in browser
storage; its bridge keeps gateway bindings and credentials on the bridge host.
Removing a client does not remove host-side histories or provider copies.

Shared, pasted, downloaded and camera files are copied into local staging and,
when attached, uploaded to the selected gateway. Agents receive absolute host
paths and can read those files. Uploaded files are retained on the gateway for
up to 30 days, unfinished uploads for up to 7 days, subject to the store's space
limits and earlier reclamation. Agent-requested original photos saved to the
host's Pictures folder remain until the operator removes them. Camera-roll
copies remain in Photos independently of attachment removal. Unclaimed share
and locked-camera handoffs have their own expiry; completed imports become
ordinary draft attachments. Removing a draft or file does not retract data
already sent to a provider.

Generated HTML visuals can request external HTTPS resources; those services
can receive ordinary request metadata and any data the visual sends. External
links, map resources and site icons may also contact their respective services.
Do not assume a displayed visual runs offline.

## Audio and calls

Dictation sends microphone audio through the configured gateway speech relay
to the selected speech provider. Spoken replies send reply text to the selected
speech provider. Supported configurations include OpenAI, Google Gemini,
ElevenLabs, AssemblyAI and Azure Speech; only the configured feature/provider
receives the corresponding request. Provider keys stay on the host/router.

Dictation keeps a local recovery recording until its transcribed text is saved.
The recovery store retains at most five recordings for seven days. If explicitly
enabled, the shared dictation library separately uploads original recordings,
text and profile information to the configured CloudKit container. Its copies
have a separate lifetime from recovery recordings; deleting a recovery copy does
not delete a library entry.

Realtime Voice Mode sends audio directly between the client and OpenAI over
WebRTC. Signaling and control pass through the gateway; transcripts and agent
handoffs are recorded in conversation history and host voice logs. The newest
100 host voice-session logs are retained and can contain full caller/assistant
transcripts, delegation text, timing and completion details.

An optional configured user name is included in voice prompts sent to the
provider. During outgoing telephone calls it can be spoken to the recipient
to identify whose behalf the assistant acts on.

Optional incoming calls use a push broker and Apple's VoIP push service.
Telephone calls additionally use the configured carrier worker and 46elks:
telephone numbers, call setup, audio and delivery/billing metadata pass through
that carrier. Call records can include a brief, steering, recipient, status,
timestamps and provider receipts. Gateway call history keeps up to 500 records
or 30 days while preserving live calls; worker receipts and provider records
have their own operator/provider retention. No call is automatically redialed
from an uncertain receipt.

## Location and maps

Location/navigation features require permission and optional service setup.
A location push can wake the iOS location extension. It encrypts location
samples for the requesting gateway and uploads them with a session-specific
credential. The authorized gateway and agent can read the resulting location,
accuracy, timestamps and route progress. The push broker and transport services
receive delivery metadata; encryption does not hide location from the gateway.

Google Maps/Navigation requests can include location, origin, destination,
search terms and route information. Google's policies apply to its processing.
Use your own restricted key and enabled APIs. Stopping a navigation session or
revoking location permission stops future collection; already delivered events,
logs, transcripts or provider copies may remain.

## Notifications and Apple services

When configured, the app registers device IDs, bundle IDs, push environment and
Apple-issued alert, Live Activity, VoIP and location tokens with its gateways.
The push broker and Apple Push Notification service process destination tokens
and payloads. Payloads may include notification title/body, host and conversation
identifiers, question identifiers, activity titles/counts, call signaling and
location wake-up metadata. They are not end-to-end encrypted conversation
storage. Lock Screen and Live Activity content may be visible to someone with
access to the device. Custom notification audio is downloaded from the URL
supplied by the configured notification service, limited to explicit HTTPS
origins. Its local cache retains at most 32 sound files within 32 MiB; individual
sounds are capped at 4 MiB.

Gateway endpoints, host names, operator credentials and deletion tombstones can
sync between the user's devices through iCloud Keychain. Installation tokens,
incoming-call identity and the active host stay in each device's protected
Keychain storage. CloudKit dictation storage is a separate opt-in feature.
Apple's account, backup and service policies apply to these services.

## Diagnostics, retention and deletion

Gateway logs live under `~/Library/Logs/remote-coder/`. The journal records RPC,
turn, tool, transport and error evidence and can include conversation content,
paths and selected provider responses; it is private operational data. The app
exports bounded diagnostic/log segments to its selected gateway for diagnosis,
including lifecycle, connection, performance and failure metadata. Device and
push tokens are redacted or represented by fingerprints in diagnostics. Voice
logs contain the text described above. Default journal, uploaded app-log and
Desktop-reconciliation retention is 30 days. Retention is not a guarantee that
all data is erased after 30 days: provider transcripts, recovery state, uploaded
files, screenshots/exports, worker receipts and operator backups have different
owners and lifetimes.

To remove data, stop active work, remove or revoke installation access, remove
client/browser application storage and Keychain entries as appropriate, and ask
the gateway/service operator to delete the corresponding histories, files,
registrations, logs and backups. Deleting a host from the app removes its
configuration through the synced directory; it does not erase remote provider
history. Uninstalling alone does not guarantee deletion of Keychain, iCloud or
host copies. Provider-held data must be handled through that provider.

## Questions

For source behavior, open a public issue with synthetic details at
[RemoteCoder](https://github.com/emileberhard/RemoteCoder/issues). Contact your
service operator for access or deletion requests. Report security issues
privately through [SECURITY.md](SECURITY.md); never post tokens or private data.
