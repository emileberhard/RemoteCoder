# Operation ownership and persistence

RemoteCoder retains its canonical conversation state, per-host UI model, transparent
Codex connection, provider adapters and transactional runtime installer. The
architecture-alignment pass changes consequential ownership boundaries rather than
introducing a general effects framework or replacing the shared runtime.

## iOS ownership

A draft revision is reserved synchronously before submission suspends. Persistence
accepts the user record before the captured draft is consumed or remote execution
starts. Another revision may still be deliberately steered into an active turn.
Failed acceptance preserves the draft and removes the unaccepted local record.

Conversation restoration distinguishes unloaded, loading, ready and failed. A
missing file is an empty starting state; an unreadable file is not. Timers,
shutdown and submissions cannot overwrite a checkpoint whose restoration failed.
Reopening explicitly retries restoration. Checkpoints retain local-only records;
provider history is not an adequate replacement for those records.

Host retirement closes admission immediately and owns one joinable cleanup task.
The workspace waits for the predecessor before constructing another owner for the
same host storage. Gateway RPC waiters are failed before their callers are joined;
imports, observation, metadata synchronization and prefetching are retired before
final persistence. Removing another host never ends the current host's call.

`FileAttachmentImports` owns staging, transfer, cancellation and publication as one
operation. Its two execution slots remain occupied until cancelled operations
actually end. A captured draft receives the result even when the visible draft
changes. The local staged file is not removed until the uploaded placement is
saved. Cancelled stale completions cannot publish or remove a replacement's work.

Foreground directory discovery overlaps the selected conversation's restoration.
Both are structured under the scene generation; optional directory work no longer
precedes conversation reconciliation. Rendered messages retain independent
observation and off-main bounded rendering from the earlier performance pass.

## Metadata authority

`conversation/metadata/read` returns acknowledged records and an opaque snapshot
revision. A caller with a retained snapshot can send `knownRevision`; an exact
match returns `unchanged: true` and that revision without entries. The gateway
hashes the ordered serialized records inside the same file transaction as the
read, so changes to any record, deletions and restores invalidate the token.
An empty snapshot remains a full response, not an unchanged response. The
`conversation/metadata/update` request identifies a single session, desired
selection, expected server revision and mutation ID. The host owns the compound
read/modify/write operation; a file lock also protects two gateway processes during
handoff. Independent session updates survive concurrent writers. A stale revision
returns a typed `metadataConflict` with the current record rather than silently
choosing a client wall clock.

The iOS metadata owner keeps acknowledged values and a durable pending-edit outbox.
A lost acknowledgement retries the same mutation ID. A newer local edit may rebase
over its own successfully acknowledged predecessor, but not over an unrelated
writer. Conflicts expose explicit keep-local/use-remote controls. Corrupt stores
remain errors, and persistence failures remain pending.

The client keeps the validator in memory and clears it when an acknowledged
mutation or conflict readback changes its retained map. Full reads replace that
map authoritatively. Unchanged reads still reconcile observed settings and drain
the outbox; they must match both the requested token and the retained snapshot.
Older gateways return full records without a token, as registered in
[Compatibility](compatibility-register.md).

One service task owns separate refresh and outbox demands. Bootstrap, foreground
and connection requests join by actual connection identity and lifecycle
generation; only a successful refresh satisfies that context. Explicit retry,
fork and invalidation reads remain fresh requests. Work arriving across an await
is retained for the next pass. Sending an edit does not require another full-map
read, and a successful outbox flush cannot clear a failed-refresh error.

The per-device `codex-session-metadata.json` cache uses schema 3. Dates are
Foundation Date numeric values in seconds since 2001-01-01 UTC, preserving the
stored floating-point value. Schema 2 and legacy arrays retain their ISO date
decoder and migrate on the next save. This local format does not change the
gateway's Unix-second wire values. A schema-2 app rejects a schema-3 file;
its settings owner reports a synchronization error without replacing the file
or sending mutations. Pending edits stay on disk until a compatible app returns.

The authoritative host file is `~/.remote-coder/session-metadata-v2.json`. The
gateway no longer reads the legacy `session-metadata.json` array, and the iOS
remote shell/Python whole-map writer was removed.

Acknowledged host state uses a mode-0600 temporary file, file synchronization,
atomic rename and parent-directory synchronization. A retry following an ambiguous
post-rename error reestablishes durability before acknowledging it. This is the OS
filesystem durability contract, not an independently tested power-loss guarantee.
Derived high-frequency caches are not forced through the same synchronous policy.

## Gateway and Claude concurrency

Each Claude conversation has its own lifecycle serialization. A short registry
operation reserves global capacity, including starts not yet registered as
runtimes; provider control exchanges do not hold a global start lock. The same
conversation's settings/start/replacement remain ordered. Runtime processes,
stdout/stderr tasks, idle expiry, cancellation and token/config cleanup retain
explicit owners. A turn still has no arbitrary wall-clock deadline.

`ConnectionQueries` owns gateway queries inside the socket reader's event loop.
It retains a FIFO of up to 64 waiting reads / 2 MiB of input and tracks at most
eight running reads / 2 MiB of input. Handlers run in the connection's
`OwnedTasks`, so response preparation cannot block socket reading. This covers the observed 20-read
reconnect burst with headroom while bounding each connection's retained query
input to 4 MiB. Only the head waits for connection and host permits; that waiting
future survives other socket messages so its FIFO admission position is retained.
Queries across the default and account gateways share 32 slots / 16 MiB.
Commands share 16 slots / 32 MiB and urgent work shares eight slots / 1 MiB.
Command capacity is deliberately per host: account gateways share its CPU,
memory and I/O, so adding accounts must not multiply concurrent expensive work.
Status reads have their own 16 slots / 256 KiB, enough for five simultaneous
three-read reconnect bursts plus one slot. These requests carry only small
parameters and clone cached snapshots or the home path; the byte bound limits
retained input even for malformed callers. Commands, status reads and urgent
controls retain immediate admission with separate capacity. Only interrupt,
stop and teardown controls use the urgent reserve.
Full query queues return retryable `capacity` with an explicit resource. An
individual query exceeding the connection input budget is non-retryable and
reports its byte count and limit, because waiting cannot make it fit.

`rpc/dispatch.rs` is the only lifetime classifier. Subscription replacement is
connection work, applied directly in socket order without read permits.
`daemon/activeTurns`, `daemon/liveActivity` and `host/info` use status admission
outside the read FIFO and urgent reserve. Their handlers must stay cheap; slow
discovery belongs to independently owned background work.
Owned replies touch the pending-turn ledger only for methods that capture a
pending turn start. `turn_state::captures_turn_start` owns that method policy;
ordinary read and subscription replies never wait on the ledger's core lock.
Native request correlation reserves capacity before capturing a pending turn
start, so capacity refusals and their retries leave the durable ledger unchanged.

Each query's 60-second deadline starts at receipt and includes queue, permit,
account and handler waits. `$/cancelRequest` removes a queued read or drops a
running future by exact same-connection id. A response claim is committed only
when the terminal response enters the outbound queue; cancellation claims that
same fence before sending `-32800` / `requestCancelled`. Completion and
cancellation therefore produce at most one terminal response, including while
the outbound queue is backpressured. A failed or panicking query task returns
`-32603` if no terminal response has committed. Disconnect cancels all these owned futures
and joins their cleanup before releasing the connection. `daemon/ready.capabilities.cancelRequest` gates client use;
native Codex requests and non-query work are never cancelled by this path.
Capacity rejections and cancellations are journalled as transport records with
method, client, optional thread, resource and queue depth, without request content.

Accepted commands move to gateway ownership;
a phone disconnection is not cancellation of an accepted turn. Interrupt/end work
has separate reserved capacity. Voice start/stop preserves socket order through a
bounded queue and completes in-progress setup before disconnected-client cleanup.
The transparent upstream Codex handshake and exact request IDs remain intact.

`OwnedTasks` adds an admission fence and cancellation to Tokio's `TaskTracker`;
closing the tracker alone does not stop future admission or cancel work. All stop
callers join the tracked cleanup. Shutdown does not wait for outstanding requests;
it captures and interrupts active agent work for automatic resume instead.
Gateway-owned errors use machine-readable kinds; prose is only their human message.
Identity/persistence warnings are routed rather than silently discarded.

## Gateway scheduling

`host-daemon-rs/src/platform/macos/scheduling.rs` owns macOS gateway QoS,
agent exec preparation and the runtime Darwin-background guard. The gateway and
its detached installer use launchd `ProcessType=Interactive`; the periodic
Desktop helper uses `Standard`. Installation requires gateway and app-server
effective priorities of at least 31.

The gateway's main thread, Tokio workers, blocking threads and log writer request
user-initiated QoS for work clients wait on. They use no nice adjustment,
process-wide QoS clamp or realtime policy. Elevation is best-effort: failure
preserves serving, log writes and graceful shutdown. The guard records the first
QoS failure once per process as `runtime scheduling_qos_failed` and a warning.

Claude runtimes, detached Codex daemons and launcher commands clear their own
Darwin-background request immediately before exec. That reset is allocation-free
and best-effort, so a scheduling failure never refuses a launch. macOS resets
requested thread QoS to Default on exec; agent commands and descendants therefore
use normal Terminal-equivalent scheduling when the reset succeeds.

Every gateway invocation except `--version` and Claude hooks checks and clears
its own Darwin-background request before creating the runtime. The serving
gateway rechecks every second; an external `taskpolicy -B` cannot clear the
process's own request. It reports restoration and priority changes through the
[journal scheduling events](host-observability.md#gateway-journal).
Host build limits remain owned by the
[build policy](#build-and-release-ownership) below and the private host build policy.

## Credentials and transport

The app stores its complete endpoint/credential snapshot in the data protection
Keychain with `AfterFirstUnlockThisDeviceOnly`, not UserDefaults. On the Mac this
avoids the file keychain, whose lookups follow the calling session's keychain
search list: a launch from the release runner's session once found nothing and
saved an empty list over the hosts. The Mac moves a file-keychain item once,
deleting it only after the protected copy reads back. Keeping a pair in one item
prevents a partially saved endpoint edit. Legacy plaintext is removed only after
protected write and readback succeed. Loading never writes seed hosts alone:
with no saved snapshot and no synced directory, a build's seed hosts stay in
memory until the user saves. Locked, missing and malformed storage are distinct;
no plaintext fallback follows a Keychain failure. Settings expose retry and do
not publish a failed write.

Hosts sync across the user's devices through one iCloud Keychain item
(`host-directory-v1`, synchronizable, `AfterFirstUnlock`), stored in the app's
default access group, which the iOS and Mac apps share through the
configured app ID. `HostDirectory` holds each host's name,
endpoint, the operator token when a device knows one, the time of its last
explicit edit, and deletion tombstones. It never holds an `rc1.` installation
token: device tools, the speech allow-list and revocation identify one
installation, so each device keeps its own token, incoming-call identity and
active host in its device-only item. Merging is a union by host ID. The newer
edit wins, and a host missing on one device is added there, never removed
elsewhere; only a tombstone newer than a host's last edit removes it. Hosts saved
before sync merge with no edit time, so any explicit edit or deletion beats them.
A merge keeps a known operator token for the same endpoint when the winning
entry has none, and discovering a credential is not an edit. No credential
follows an endpoint change: a device that receives a new endpoint uses only the
synced operator token for it, or shows the host as invalid until a token is
entered on any device. A device that receives a host without its own token uses
the synced operator token and enrolls its own installation. A dev build's seed
supplies the operator token for its matching seed host. The newest 256
tombstones are kept; beyond that, a long-stale device can add a deleted host
back, never remove one. `SharedHostDirectory` owns the item's I/O off the main
actor and replaces it only if it still holds what the merge read, and
`HostStore` runs one sync at a time: at load, after each host edit, on scene
activation and on Mac app activation, because Keychain posts no change
notification. A failed read or a directory from a newer format is shown in
Settings and never overwritten.

New hosts default to HTTPS/WSS. Existing installations explicitly migrate to their
historical trusted-network HTTP/WS transport. Choosing that option in the editor
is an explicit trust decision, not a claim of application-layer TLS. HTTPS/WSS
requires a correctly configured TLS-terminating endpoint; the Rust listener itself
remains HTTP behind the operator's chosen network boundary.

The optional LAN listener (`RC_CODEX_GATEWAY_LAN_PORT`) is the one TLS listener
the gateway terminates itself. It is reachable from the whole local network, so
it relies on key pinning rather than on the network boundary: the app learns the
listener's SPKI pin only from the authorized `/health` on its configured address,
never from the LAN, and sends a request, including the bearer, only after the
LAN handshake presents that exact P-256 key. System trust, trust-on-first-use
and cellular paths are not used. The key lives in
`~/.remote-coder/lan-tls-key.der` (mode 0600); deleting it and restarting the
gateway rotates it, after which each app's next LAN attempt fails, relearns the
pin over the configured address, and returns to LAN. The app declares
`NSLocalNetworkUsageDescription` and no Bonjour services; the first LAN attempt
can fail while iOS shows the local-network prompt, and the configured address
carries that session.

The relay route (`docs/relay-route.md`) exposes that LAN listener through a VPS
without widening this boundary: the VPS terminates only the outer TLS, admits
only authenticated `CONNECT` requests for the two relay names, and forwards
ciphertext to each Mac's reverse SSH tunnel, so the app's inner handshake still
pins the LAN key before any bearer is sent. The relay admission credential and
the relay's TLS key are generated on the Mac mini (`~/.remote-coder/relay/server/`,
mode 0600) and live on the VPS; each Mac's `relay.json` holds the client copy,
the gateway serves it only on the authorized, uncached `GET /relay`, and the
app keeps it in the device-only Keychain.

The operator credential continues to authorize local management clients. The app
can exchange it once for a revocable installation token through operator-only
`POST /credentials/enroll`. Enrollment has an installation ID and an idempotent
result; revoked IDs cannot silently reenroll. Only token digests are persisted in
`~/.remote-coder/installation-credentials.json`. The app verifies the captured
endpoint and call ownership again after enrollment before replacing its token.
A revoked installation is denied new HTTP/WebSocket requests; an existing socket
checks its lease every five seconds and then uses normal connection cleanup.
An already accepted durable command is not rolled back by revocation.

Operator CLI, on the relevant host:

```sh
remote-coder-codex-gateway credentials issue --label 'Test phone' --output /private/path/new-token.txt
remote-coder-codex-gateway credentials list
remote-coder-codex-gateway credentials revoke INSTALLATION_ID
```

Issue creates a new mode-0600 output file and never prints its secret. Use the
installed binary under `~/localbin/remote-coder-gateway/` when it is not on PATH.
Enrollment/revocation does not restart the agent runtime. Provision a new ID
explicitly after revocation; do not add an automatic operator-secret fallback.

This application intentionally authorizes host code execution. Installation-token
revocation is a network admission control, not a sandbox for previously authorized
code or a revocation of credentials that code may already have acquired. Private
Debug builds may retain an explicitly provisioned operator token for personal
development. Such builds must not be distributed as public builds.

Speech-provider keys never enter the app, in Debug or release. The gateway relays
SpeechKit's provider traffic under `/speech/<provider>/…` and injects the key it
holds; the caller's operator or installation bearer is the identity boundary, so
revoking an installation also ends its speech relays. The gateway forwards to
llm-router's vendor passthrough with its host router key, and llm-router owns the
provider keys; `host-daemon-rs/README.md` (*Speech providers*) owns the vendor
mapping.

`RC_CODEX_GATEWAY_SPEECH_CLIENTS` in the gateway env restricts speech to listed
installation IDs. It is a usage and spend control, not a key-protection boundary:
provider keys never leave the gateway either way, and an installation credential
already grants `/ws`, including `command/exec` on the host. Unset or `all` admits
every authenticated client; the operator is always admitted. An explicitly empty
value fails gateway startup. A policy change applies at the next gateway start.

Configuration is allowlisted. `release-config.py` rejects gateway tokens,
speech-provider secrets and unknown fields before project generation/archive and
again inside the IPA before upload. A restricted iOS Google Maps client key is
allowed. `install-device` runs its `verify-development` profile, which additionally
allows only `codexGatewayAuthToken`, so a leftover speech key fails the install by
field name. Signing and distribution secrets stay outside Git.

## Build and release ownership

Plain `just` lists commands. `just install-dev`, `just gateway-candidate`,
`just core-test`, `just gateway-check`, `just gateway-test <filter>`, `just test`,
`just verify` and `just verify-all` snapshot source for the configured builder,
`scripts/build-host`, which defaults to the local machine. `just install-mac`
and `mac-bench` use the configured GUI host, which they install on and measure.
There is no implicit fallback after a builder fails. `RC_IOS_BUILD_HOST` (iOS
kinds, `verify-all`) or `RC_GATEWAY_BUILD_HOST` (the other kinds) set to `local` or a
host, such as `<gui-test-host>`, selects a builder through the same worker, capacity and
source-ownership checks. `just ios-device-build` prepares a device artifact
without contacting the phone.

Source snapshots compare file bytes before linking reusable files. Promotion to
the leased build mirror compares bytes and gives only changed files fresh mtimes;
identical files retain their mirror mtimes so Cargo and Xcode can reuse artifacts.
The source fingerprint binds file contents rather than transfer timestamps.
The committed JSON Xcode project and package lock are ordinary snapshot inputs.
Only obsolete workspace/Derived outputs are excluded from mirror deletion.

### Signed iPhone iteration

Interactive builds default to optimized incremental Swift (`-O`, `singlefile`).
`--optimized` explicitly selects whole-module optimization for performance checks;
`--unoptimized` selects `-Onone`. Separate DerivedData lanes and artifact identities
bind the actual verified compilation mode. Incremental retains optimization but
does not promise identical runtime performance to whole-module compilation.

`install-device` publishes an immutable signed app and matching symbols beneath
its DerivedData `device-artifacts/<buildId>/`. Reuse validates complete source,
private configuration, toolchain, optimization and signing inputs, app and symbol
hashes, signatures, profile expiry and original build identity. A reused artifact
retains its original identity; the current request has a separate ID. Its descriptor
is `ios-artifact.json` beside the request receipt. Current and previous completed
artifacts are retained; unknown or incomplete directories are protected.

Configured builders reserve development build numbers from the catalog
coordinator's canonical counter. The source lease covers building and delivery;
direct and managed delivery share its catalog lease so concurrent agents cannot
overwrite an in-flight update. Failure to reach the coordinator fails explicitly.

Automatic delivery resolves the enrolled iPhone and probes that exact UDID for
at most five seconds. A reachable paired phone gets CoreDevice installation and
launch; otherwise delivery uses SimpleMDM after the app's one-time managed
adoption. Explicit `delivery=direct` and `delivery=mdm` select the transport.
An uncertain or failed mutation never triggers an automatic transport switch.
The managed adapter
sanitizes a copy through the release configuration allowlist, selects production
APNs, and uses the shared `apple-devops` ad hoc packager without an archive.
The original development app remains unchanged. Shared `simplemdm` tooling
uploads without automatic deployment and targets only the selected installation.
Switching from another marketing version uses an audited force replacement:
all catalog assignments must resolve to the one selected phone before deployment.
`ios-delivery.json` records installed-build readback separately from launch.
An accepted MDM command alone never counts as an installed build.

A successful direct install saves proof beside its immutable artifact, binding
the original source build, app hash, device and actual installer receipt. When
that exact artifact is reused away from the Mac, fresh managed inventory can
confirm it without packaging, upload or another installation. This readback uses
the same catalog lease, rejects a newer or pending catalog, and requires a newer
inventory timestamp after refresh. Failed MDM recovery preserves the previous
accepted or completed receipt for a later readback attempt.

Every run has immutable source input and a fingerprint. Worktree-scoped leases
protect stable mutable mirrors and compiler caches. A job's processes inherit its
source and capacity leases, so a killed owner leaves them held until those
processes exit. After a normal finish the owner, which has drained the job's
process group, releases them explicitly; a daemon that left the group, such as a
Bazel server, keeps the descriptors but not the leases. Two build-capacity slots bound
each build host; each build uses the host's compiler parallelism, so a lone
build is never held to a share of it. Worker environments preserve configured
`EMIL_BUILD_JOBS` and `CARGO_BUILD_JOBS` limits. `scripts/gateway-check.py` defaults
`RUST_TEST_THREADS` to four for that gate, and `just codex-fork-run` defaults
`NEXTEST_TEST_THREADS` to the host's `EMIL_BUILD_JOBS` (four when unset); the host
environment does not limit other Rust tests. CI, agent and Terminal builds all use normal scheduling.
The operator owns runner scheduling and any shared sccache server; the build
worker and workflows add no priority clamp, because real-time gate tests can
miss their windows under one. Maintainer policies live in the private
RemoteCoder-deploy repository's AGENTS.md. Simulator/background builds
use slot 1, leaving slot 0 available to interactive work. Source leases are
acquired before capacity, so a queued writer cannot reserve an idle compiler
slot. The root `AGENTS.md` owns which gate covers what (`just test`,
`just verify`, `just verify-all`). Fresh xUnit and xcresult reports must verify at least one executed case; a filter typo or unreadable
report cannot pass. Simulator test recipes and `verify-all` create and dispose
of simulators; an explicitly selected simulator stays caller-owned. A separate physical-device lease covers
install, version/build readback and launch. A successful build is not an install
receipt, and a successful install is not a launch receipt.

`build_support.canonical_path` owns source and cache path identity. On macOS it
uses `F_GETPATH` on an open directory descriptor, so case aliases of one checkout
share source leases, manifest `worktreeId`, mirrors and compilation records.
Cargo and package seed keys describe compiler/package inputs rather than source
path spelling.

The initial canonical-identity cutover requires quiescence on both hosts. Drain
jobs and keep new admissions paused, then run
`python3 scripts/source-identity-preflight.py` on each host before merging and
syncing the change. Require exit 0 with empty `heldLeases` and `unverifiedLeases`
arrays; otherwise wait for owners or resolve unreadable paths. The helper only
tries existing locks non-blockingly and never breaks a lease. Keep admissions
paused through the sync so an old worker cannot start after the check. Legacy
mirrors retain their old keys, worktree/legacy leases and completion history;
existing cache retention retires them normally. Do not rename them or remove
lock files during the cutover.

Before acquiring probe locks, the preflight reserves descriptor capacity for the
entire snapshot by raising only its process soft `RLIMIT_NOFILE`, up to the hard
limit. It retains all probe descriptors until the snapshot completes. Insufficient
capacity returns exit 2 with JSON `error.kind: descriptorLimit` and an actionable
message; it never labels that resource failure as an unverified lease.

Legacy compilation records remain associated by their stored path through the
canonical path owner. Active, invalid, unreadable or ambiguous records cannot
fall through to timestamp reconstruction. Completed records retain their last-use
protection and normal retirement rules. New schema-2 records explicitly establish
canonical identity and supersede legacy records for that cache. An unassignable
legacy record fences caches without that new authoritative record; it is never
treated as absent.

The local device-install runner selects DerivedData from the selected Xcode build
and the canonical source-lease key, then passes `RC_DERIVED_DATA` explicitly.
The installer requires that owned choice; inherited logical `PWD` never selects
another cache. An explicit `RC_DERIVED_DATA` override remains caller-owned.

Hosted simulator tests build Debug with ad hoc signing. Before launching, the
recipe verifies the app and embedded extension signatures, checks Xcode's
simulator entitlement sections against their declared entitlements, and requires
the exact app and extension identities and embedded set from the committed JSON Xcode project.
It also requires Live Activities support and an embedded WidgetKit extension. The
verified build runs with `test-without-building`; generic build-only gates remain
unsigned.

Compiler admission passes briefly through `capacity/admission.lock` before
attempting a permitted slot. A `mac-bench run` reservation holds that gate while
previously admitted jobs finish, then retains both slots through capture copy and
app cleanup. A reservation publishes a locked intent in `capacity` before waiting
for the gate. Ordinary admissions yield to live intents; an abandoned unlocked
intent is removed by the next admission. Later builds cannot overtake a pending
reservation. Source/cache ownership precedes admission; cache eviction and clone
seeding follow it.

`runs/measurement-<run-id>/receipt.json` records source identity, queue wait,
acquisition/release times, hold limit and terminal status under the shared run
retention policy. Queue admission is limited to 1800 seconds. The command hold is
`runs × (timeout + 50 + 60 when sampling)`, capped at 1800 seconds, with a
30-second TERM grace before KILL. Post-KILL drain waits for group quiescence. Timeout returns 124; cancellation
remains nonzero. A completed bounded command also drains surviving descendants
before returning its original exit status. The connected client supplies a
heartbeat; disconnect or supported cancellation unwinds the owned command.
A separate command guard retains the leases and enforces the hold deadline. The
guard starts with a control socket and publishes its own audit identity before
registration. Only after registration succeeds does its supervisor transfer the
lease descriptors over that socket. The measured process group inherits none of
those descriptors. Before executing user
work, a group leader records its PID, group and native microsecond start time; it
stays alive while that group's descendants drain. If the reservation supervisor
dies, the guard detects its closed pipe. If the guard dies, the supervisor
observes child exit independently of stdout and drains the recorded group before
releasing capacity.

The capacity intent has an atomic record of both lease holders, the command
identity, boot identity and absolute monotonic deadline, including the 30-second
cleanup grace. Boot identity uses `kern.bootsessionuuid`; calendar-time changes
must not invalidate a live reservation. Phase changes and expiry claims use the stable
`capacity/state.lock`; record retirement never unlinks that mutex. If a writer
stalls while holding it, expiry suspends only the recorded actors through their
audit tokens, rereads the committed deadline and then terminates expired owners.
An updated future deadline resumes those actors without reclaiming their leases.
A later contender at source or capacity admission reclaims an expired record by
verifying process identity, draining the exact command group and terminating
the recorded lease holders. An unlocked intent with a live orphan group still
blocks ordinary admission until recovery. PID reuse never authorizes signaling a
new process; an unverifiable live group fails with its identity in the error.
External signaling uses `proc_signal_with_audittoken`, so the kernel rejects a
reused PID even after a successful preliminary lookup. Group cleanup stops the
anchor, signals descendants through their native PID-version tokens and keeps the
anchor alive until those members are quiescent; it terminates the anchor last.
Records and unique intents are removed after recovery. The reservation receipt
records the command identity and deadline. The guard's `command-result.json`
preserves the outcome; a supervisor killed before publishing its receipt leaves
that receipt's terminal status unknown.

`scripts/process_group.py` owns tooling process snapshots and external signaling.
`process_identity(pid)` returns parent, group, start time and PID version from one
native snapshot; `own_identity()` reads the registering task's audit token.
`same_process()` compares stable identity fields, excluding mutable parent/state.
`audit_path(identity)` reads the executable through the retained token; a missing
epoch returns absent, and permission/API failures remain errors. External callers
use `signal_process(identity, signal)` or `terminate_process(identity)`, never a
PID-only lookup followed by signaling.

Keep the separate configured GUI lease and idle checks. Do not wrap `mac-bench run`
in an external compiler-slot holder: the CLI now acquires those slots itself.
Adopt this protocol after older build workers and manual slot holders exit;
workers predating the admission gate cannot participate in its drain guarantee.

Mac benchmark plans, stdout, checks and captures belong to the same cache's
`runs/mac-bench-<run-id>/` directories, outside mutable source mirrors. Each run
holds its run lease and writes a terminal receipt even on a failed check. The
receipt and summary name the output directory; repeated labels preserve separate
runs. Shared run admission and retention protect active, recent and unknown
evidence, so a later snapshot's `rsync --delete` cannot erase a benchmark.
The app stages captures in its isolated temporary benchmark scope. The CLI copies
them before requesting termination; scope teardown removes the temporary copy.
The Mac benchmark launch inherits only allowlisted system variables and a fixed
system PATH. Its harness plan and switches arrive through arguments; no `RC_*`
environment variables are needed. Trace summaries export selected metadata and
measurement tables, never the TOC's launch environment.

`just verify` compiles the Mac app both normally and with `RC_PERF_HARNESS`, using
the same private DerivedData and compiler owner. `just mac-harness-build` runs the
harness compile alone. These checks use Debug compilation without signing or
launching; signed optimized bench artifacts still use `mac-bench`.
Each Mac and generic iOS Simulator compile validates any exit-zero task diagnostic
against its own start and output, recording that evidence in `macCompile` or
`iosCompile` receipt stages. An earlier product cannot satisfy a later invocation's
freshness check. Generic iOS Simulator build-for-testing requests only `arm64`:
its run destination has no active architecture, so `ONLY_ACTIVE_ARCH` does not
limit the platform's default architecture list.
An iOS extension diagnostic validates that extension's executable. An unmapped
target or a diagnostic without a target identity fails validation.
Xcode builds retain normal output. In Xcode 27, `-quiet` can misreport a
warning-bearing virtual per-file Swift batch task as failed with exit code 0.
The compiler can also retain an earlier object when its LLVM IR hash is unchanged,
so object timestamps relative to invocation start are not validation authority.
Native failure statuses and per-invocation target-product checks remain authoritative.

Hosted and UI test recipes disable verbose test diagnostics with
`-collect-test-diagnostics never`. Test failures still return Xcode's failure
status and retain their fresh xcresult in the owning build-cache run; verified
native successes also retain the summary. The shared run retention policy owns
those results. Receipts record verified
executed/skipped counts and the xcresult path in `testExecution` stages. Automatic
sysdiagnose collection must not hold build leases for minutes after tests finish.

One external worktree lease covers both iOS and gateway caches, including their
shared private Cargo target. Both legacy group leases remain held for older
workers. Local compiler recipes acquire the same source owner before generation
or compilation and publish completion records outside the mutable caches.

`build_cache.py` is the admission and eviction owner on both hosts.
Without a private policy, it applies a 40 GiB total cap across RemoteCoder-Build,
two-hour compiler protection, a 20 GiB free-space target and the newest two
completed directories of live worktrees when the budget and free-space target
permit. An optional maintainer policy overrides these limits; its provisioning
and activation live in the private RemoteCoder-deploy repository's AGENTS.md.
Under pressure, those directories join the oldest-first eviction candidates. Mirror source records bind the hash to its originating host and
canonical checkout; a missing checkout retires its completed compiler payloads
after compiler protection, without requiring merged ancestry or the 24-hour
retirement window. An unreachable source host remains unknown. After 48 hours
without use, the removed checkout’s mirror payload (including stale products and
downloaded packages) expires through mirror reclamation, with its external and
legacy leases held and no open files. Run evidence, source ownership records and
stable lease files remain intact. Merged, clean worktrees idle for more than 24
hours may retire all intermediates/incremental payloads. The owner rechecks
source/cache leases, tracked cleanliness, main ancestry and open FDs. A mirror
with a missing or active completion record may reclaim compiler payloads after
the two-hour idle window, but only after obtaining its leases, excluding open
files and rechecking the last-use evidence. This also retires interrupted
builds. Abandonment and checkout-expiry proof require a source association;
legacy unassociated mirrors retain their existing completion reconstruction and
unknown-evidence protection. Unreadable, invalid, leased or incompletely
inventoried caches remain protected. Products, dSYMs, downloads and evidence
never become compilation eviction targets. Total accounting includes shared
Codex targets, experiments, sources, runs, releases, packages, evidence and pinned
entries. The two shared Codex compiler targets use their existing build locks
and open-file checks; idle Cargo payloads can be reclaimed under pressure.
Unclassified data is counted but protected. Outside roots are listed with
outside-budget coverage and are neither measured nor evicted. Cargo dependency, build-script and
fingerprint caches are rebuildable payloads too. Filesystem traversal and
deletion reject symlink escapes and foreign mounts.

Admission reports known folder allocation, unknown entries, candidates, actual
evictions and protected overflow in `cache-admission.json` and the receipt. Its
per-directory `inventory` separates allocation coverage from completion
coverage: owned missing/active/invalid records, historical reconstruction and
source retirement proof. A deadline or an unperformed check is not evidence of
missing historical records. Unknown sizes remain null. Folder allocation can
overcount APFS clones; total-root allocation uses bounded native `du -skx`,
counts hard links once and does not traverse foreign mounts. Whole-root scans
run only in maintenance/preview, outside the shared maintenance lock, with a
120-second timeout. Build admission keeps its bounded compiler-entry estimate.
Reclamation conservatively credits no bytes from multiply-linked files; the
post-maintenance root measurement determines the actual remaining cap. Shared
Codex targets use one bounded system-wide open-file snapshot per acquired owner
lease, then match each payload prefix. Their build locks are stamped on entry
and exit, including no-op package reuse. Reclaimed physical space is a separate
before/after observation. Protected or unknown overflow prints a warning and
never blocks a build. The existing 15 GiB free-space floor remains the only disk
rejection threshold. Inventory and reclamation each have a separate 20-second
budget, so inventory cannot consume reclamation's turn. A skipped reclamation
check reports `reclamation-deadline`; incomplete inventory preserves unknown
values. Operators can schedule `cache-maintain` independently of builds.
The private maintainer schedule invokes it before repository synchronization, so
a failed sync does not suppress reclamation.
`RemoteCoder-Build/maintenance.json` is one replaced receipt; scheduled stdout
is a compact summary. Maintenance remeasures the entire root after reclamation
and exits nonzero if its total cap is unmet or cannot be measured. It atomically
replaces `~/.local/state/disk-cap-status/remotecoder-build.json` for the shared
disk-pressure owner: version 1, owner `remotecoder-build`, UTC `observed_at`,
`used_bytes`, `cap_bytes`, `unmet` and an actionable `reason`. Unknown allocation
publishes null `used_bytes` and `unmet`; a successful pass clears `unmet`. The
configured maintenance schedule refreshes this status on each build host. When
compilation eviction is disabled and fresh free space exceeds the policy target,
normal admission defers recursive inventory. Its
receipt marks unknown allocation and unperformed coverage explicitly. Read-only
preview, enabled eviction and low-space admission still take the full inventory
path; evidence retention and the fresh free-space floor remain active.

`python3 scripts/remote-build.py cache-preview <policy-file>` produces a
read-only manifest with the same eligibility checks.
The public default activates compiler eviction and expired mirror reclamation.
A private policy uses a separate activation file so stale workers cannot activate
their broader legacy deletion behavior; missing activation disables eviction for
that private policy, and malformed activation fails. Evidence retention stays
active independently: by default 128 runs, three-day retention and at least 48
hours of protection. Terminal receipts/outcomes permit old run
eviction, while active and unknown runs stay protected. Stable external and
legacy lock inodes are never retired. Legacy pinned runners keep their old
six-key policy file; its retirement is in the compatibility register.

Cold SourcePackages and Cargo targets can be APFS-cloned from an idle matching
sibling. Resolution, compiler and Cargo configuration checks select compatible
seeds; Cargo still owns artifact validation and rebuilds. Each clone is private.
DerivedData, module caches and SwiftPM scratch remain per worktree/toolchain.
The worker opts into Xcode compilation caching and project prefix mapping using
physical snapshot paths. Optional shared native CAS storage and bounds are
operator-owned; release archive compiler and signing settings remain unchanged.

`run_owned` retains the unreaped leader until its owned process group has no
live members, including on normal or failed leader exit. Grandchild zombies
are reaped by the system; the direct child is joined by this owner. Commands
must keep compiler descendants in that group. A deliberate `setsid` or group
escape requires a separate owner and must not retain these leases. TERM gets
a grace interval before KILL; post-KILL kernel exit is observed before releasing
leases and has no total wall-clock promise. Releasing a still-live lease holder
would invalidate the cache-safety contract.

The client sends heartbeats over the connected supervisor's stdin. Its build
worker and descendants receive `/dev/null`, so only the supervisor can read or
change the control pipe. Rsync transfer receivers retain their protocol stdin.
EOF or a missed heartbeat cancels the connected supervisor and its owned worker,
which joins or terminates its compiler process group before releasing leases.
Shared job runners hold a process-owned `PreventUserIdleSystemSleep` assertion
from dispatch through drain and cleanup. Connected scopes also cover admission
waits and receipt publication;
each build client starts a connected assertion owner on the build host before
its first transfer and retains that owner across uploads, stage handoffs and
final readback. EOF, cancellation or a missed heartbeat stops that owner only
after the run or collection lease is quiescent. The guard receives its tracked
source over the control connection, before any tool upload. Stage runners retain
their own cleanup protection. Every Codex tool, request and bundle upload holds
the collection lease in the shared supervisor through its actual rsync receiver
and child drain. Local uploads enter the same receiver through the connected
runner, so client death cannot release a still-active writer’s lease.
The standalone perf-sim CLI holds the same native
assertion through admission, measurement, result reads and trace cleanup.
Nested scopes in one process share the same assertion. Normal exit, failure and
cancellation release it, and macOS revokes it if its owning process dies. The
display sleep policy and system power settings are unchanged. A TERM-ignoring compiler
gets a bounded grace period; its supervisor waits longer than its cleanup owner.
Source transfers hold the same external run lease, including the remote rsync
child through transfer and cleanup. A known prelaunch transfer failure publishes a failed
outcome under that lease with a bounded remote command. An unavailable or busy
failure writer preserves the inputs as unknown. The run lease also covers remote
execution, and `outcome.json` records interruptions
that cannot produce a normal receipt. Worker diagnostics go to `worker.log`;
stdout carries one authoritative receipt, including failures before compilation.
Claim a result from that receipt's `exitCode`: a background wrapper that ends
with `echo` reports the echo's status, which once hid a failed iOS compile.

Xcode's exit-zero SwiftCompile diagnostic is recorded as a receipt warning.
Success also requires the affected app/test product to exist and be newer than
the command's start. Missing/stale products fail validation; the diagnostic alone
does not change a successful native exit into a failure.

Signed Mac bench builds retain UUID-matched executables and dSYMs under their
build-cache run's `symbols/` before publishing the app. The receipt identifies
that directory and the retained binary UUIDs. The existing run lease and
retention policy own these files. `perf-trace` discovers them by trace UUID, so
a later rebuild or installed-app replacement cannot substitute another binary's
symbols. Symbols remain available for the lifetime of their retained run.

Trace summaries report uncollected commit and GPU tables as null metrics with
`commitsUnavailableReason` and `gpuMsUnavailableReason`. A Time Profiler-only
recording can still report CPU cost; it does not establish zero commits or GPU
work. Collected empty tables report measured zero. An unreadable contributing
GPU duration makes that process's total null with a reason, even when other rows
have known durations. Render-server GPU cost uses the same availability rule.

Run receipts identify source commit plus dirty-source fingerprint, toolchain,
actual test/build exit, log location and artifact hash. `progress.json` records
the current phase while a job waits; receipts record phase durations, and gateway
`stages.jsonl` separates tooling, Clippy and test time. Candidate gates can reuse
a successful same-input receipt (source, compiler, Cargo config, flags and
commands), but runtime approval is checked afresh. `RC_FORCE_CHECKS=1` forces
the deterministic checks to rerun. Gateway candidates are
returned at `host-daemon-rs/target/deploy/BUILD_ID/remote-coder-codex-gateway`.
Use the returned receipt's path rather than a shared last-built filename. Run logs
and source snapshots remain on the build host under `RemoteCoder-Build/runs`; local
receipts are ignored under `build/receipts`.

Cargo seeding keeps a private APFS clone of compatible dependency artifacts.
Before publishing it, Cargo cleans `remote-coder-codex-gateway` in both owned
profiles (`dev` and `release`) using the candidate manifest. Both Cargo target
and build directories point at staging, so inherited paths cannot redirect that
cleanup. A copy or package-clean failure discards staging and continues with a
cold target; `cargoSeed.status=unseeded` and `cargoSeed.failure` retain its cause.
A package-clean failure never publishes the clone. A staging-cleanup failure
after publication keeps `cargoSeed.status=seeded` and records
`cargoSeed.cleanupWarning`; the cleaned target remains usable. Successful seed
receipts record `cargoSeed.workspaceProfilesInvalidated`; changing source mtimes is never a
substitute for rebuilding the workspace package. The gateway currently has one
workspace package and no path dependencies; new workspace packages or profiles
must extend this invalidation boundary before using seeding.

The compiler owner stores absolute private Cargo paths, then gives recipes the
equivalent cwd-relative `CARGO_TARGET_DIR`. This preserves private output
locations while removing worktree-specific absolute strings from sccache's
environment key. Other compiler inputs are retained. Reuse is proven between
matching layouts; gateway and mixed iOS/verify layouts can still differ.

`.xcode-version` owns the local default. The justfile exports it only on a host
that has that Xcode installed; elsewhere local tools keep the selected Xcode and
remote builds still derive the pin on the build host.
`RC_XCODE_DEVELOPER_DIR`/`DEVELOPER_DIR` are per-command overrides; the release
workflow selects `.xcode-version` on its hosted runner. No
compiler/runtime upgrade is implicit. Public contribution CI runs on disposable
hosted workers without personal-network access or deployment secrets. Private
release execution, host mappings, signing and catch-up live in the private
[RemoteCoder-deploy operations entrypoint](https://github.com/emileberhard/RemoteCoder-deploy/blob/main/AGENTS.md).
Snapshots exclude ignored private app configuration, and compilation environments
must exclude unrelated provider, account and signing credentials.

Optimized Mac installs and `mac-bench build` take their Developer ID entitlements,
profile and public configuration from the newest complete published release in
`RemoteCoder-Build/releases/<version>`, verified against its commit, bundle stamps,
signature and public-field allowlist. They copy those inputs into their own run
before compiling; `/Applications/RemoteCoder.app` is never a signing reference.
`release-reference.json` records the chosen release. Bench configuration keeps the
development allowlist and does not replace the copied release configuration.
Readers and release pruning share `release-reference.lock`; pruning retains three
versions and protects releases used or modified within 48 hours. After a GUI test
window, `python3 scripts/release-cache.py restore` restores the newest
verified public Mac release through the existing app lease and installer. It
does not install on the iPhone. Run it on the GUI test host under the authorized GUI
test protocol. Mac install skipping requires a verified matching signed digest,
so a bench app with the same version is still replaced.

Codex packaging uses `scripts/codex-build.py` from either Mac. It negotiates
missing Git objects, holds the source lease through compilation/publication and
uses the same build-host release target and sccache. Packages are keyed by exact
commit, compiler/Xcode, target/profile, Cargo config/flags and helper inputs;
complete package contents are rehashed before reuse and after transfer. The
cache reserves room before constructing a package and retains at most eight
packages, including the one under construction. Live collector leases protect
transfers and close on success, failure, cancellation or disconnect. If all
entries are in use, a new build fails with an explicit capacity error. Failed or
interrupted staging is removed under source ownership; there is no uncapped
fallback package path. Failed builds never publish success evidence. Fork tests
keep dependencies across version bumps. Admission checks shallow deps entry
counts against 250,000 (above measured 77k/full and 107k/warm footprints), and
build workers require at least 15 GiB of free volume space. A failed check
preserves the cache and asks its owner to reclaim stale artifacts under its
lease; no whole-target wipe happens automatically. Source rsync processes
raise their descriptor limit, clamped to the process hard limit and host maximum
(up to 65,536).

Deployment copies only the installer's tracked inputs (compatibility record,
gateway config, launchd plists, installer scripts and `build_artifacts.py`)
from the deploying checkout to a temporary stage on the target, removed when the
installer finishes. An installed runtime can supply an owned local package snapshot, avoiding another
network transfer only when its complete content digest matches. The installer
still owns all validation and cutover.

The gateway binary also embeds the tracked call-worker and tool sources, project
metadata and both frozen uv locks (128 files / 4 MiB maximum). Its `workerHash`
in `--version` and authenticated `/version` binds those bytes to the same build
identity. Before gateway handoff, the installer verifies the hash, stages the
worker under `~/.remote-coder/call-workers/HASH`, installs locked dependencies
with `uv sync --frozen`, and reads back the worker's hash and protocol. A failed
sync leaves the installed gateway and call configuration active. The carrier worker's registry
supports at most eight configured origins and sixteen protected worker hashes,
including each origin's selection and pending/rollback work. An offline origin
can retain its older selection while another origin takes a release. An install beyond that
fails with "Finish the pending worker rollout before staging another artifact"
until a host settles or gets its release gateway back (copy the bundle out of
`~/localbin/remote-coder-gateway/previous` and reinstall it with
`just gateway-install-prebuilt`). Probe a candidate with
`dev-tools/probes/isolated-gateway.mjs` instead of installing it. The immutable
worker path in `call-delivery.json` lives beside its gateway binary in an
immutable `localbin/remote-coder-gateway/versions/HASH` directory. Activation
and rollback replace the `current` symlink atomically, so startup observes one
matching pair. The launcher resolves that generation before executing it.
Each configured origin retains its own worker selection during catch-up.
The bounded origin registry under the carrier worker
install lock protects selected, pending and rollback hashes through a
generation-fenced activation acknowledgement. Pruning consults that registry
while locked, keeps current and previous artifacts, and refuses to delete a
leased worker. An interrupted installer retains its reservation; the next
owned install reconciles it against the atomically selected pair, including an
intent whose carrier-worker registration never happened. That reconciliation carries the
recorded source and target hashes and persists initial registry state under the
shared lock. A build claim is published atomically beside the cache before its
candidate directory is created. Claims and temporary metadata record PID and
process birth identity in UTC; only a dead recorded owner permits reclamation. Missing
or partial candidate manifests therefore remain recoverable. Selected, rollback
and leased artifacts remain protected. Frozen sync and contract-readback children
inherit the candidate's exclusive artifact lease, so an installer crash cannot
release a surviving writer's protection. Reclamation and final publication
acquire that lease again; after five seconds of contention they fail with holder
PIDs and preserve the candidate for a later retry. Same-binary deployment also verifies
this artifact; it never falls back to a mutable checkout.

Gateway staging records the parent and installer process identities before
writing staged files. Normal failure and signal paths join the installer and
clear only their claimed stage. The next install reclaims a dead owner's stage
and legacy PID-suffixed files only after confirming no live process owns or
uses them; it does not execute orphaned binaries.

The private release pipeline deploys the primary service host; its catch-up
workflow deploys the same published bytes to the configured secondary host. For a
manual gateway deployment, build a verified candidate, deploy it through
`shared-codex-host` to one host, validate, then promote the same candidate bytes
to the other. Keep the approved
Codex package unchanged for a gateway-only change. `gateway-candidate` assembles
`RemoteCoderGateway.app` and signs once, ad hoc for public local builds or with
the configured Developer ID for maintainer builds. Its tracked
`RemoteCoderGateway.template/Contents/Info.plist` owns the stable TCC identity
`com.remote-coder.codex-gateway`. Build receipts and transports verify the whole
bundle; the detached installer verifies its signature, never re-signs, and owns
handoff and rollback. Each `versions/<hash>/` holds the bundle and a relative
`remote-coder-codex-gateway` symlink into `Contents/MacOS`; the stable alias still
selects `current`. `pair.json` hashes the signed main executable, and immutable
version reuse compares every bundle file. Existing flat versions remain valid
rollback targets. Both hosts therefore run identical candidate bytes, and
`/version` names its source commit. Do not kill the shared app-server or substitute an ad-hoc service.

The template is not an `.app`, so a source checkout cannot register an
incomplete gateway in LaunchServices. The LaunchAgent associates the gateway
bundle identifier; its cold-start launcher unregisters other executable copies
of that identifier and registers only the selected bundle. Rollback uses the
same launcher. This does not grant Local Network access: Apple supports no
per-app MDM grant for that separate permission. Multiple-copy identity tracking
is a known macOS limitation; acceptance after a version change includes a
gateway-owned LAN read and checking that no new consent dialog appears.

A cross-version runtime transaction binds the configured source package and
its two executable hashes before capture, then binds the approved target after
activation. An ingress-free recovery gateway accepts only the package recorded
by its generation; ordinary gateways retain the compiled approval pins.
Rollback restores the source package and exact task identities before the
previous gateway returns. The previous gateway stays unloaded while a runtime
swap awaits the final candidate health gate, regardless of version equality.
Completed recovery journals are made readable by the previous gateway only
after default and enrolled recovery workers have finished. The gateway holds
a process-lifetime control lease separately from the lifecycle transaction
lease. Source normalization refuses while that control owner is alive,
including after its launching installer crashes.

Installer commit removes its previous-artifact backups. Later acceptance
failure uses a new reverse deployment with a retained source-approved build of
the current recovery owner, the complete source package and the verified source
app. A completed `runtime rollback` does not restore a committed installation.

Enrolled account startup binds the selected complete package and persists
`RuntimeInstalled` before starting its native daemon. Retry can then prove
and reuse that exact live startup; a live daemon beside `DaemonStopped`
without startup intent remains an ownership error.

Preserve deployed SQLite migration versions and checksums during upstream
integration. Validate a bounded source thread through candidate continuation
and source rollback in an isolated home; build success cannot establish
stored-history compatibility.

## Persistence and energy

See [persistence and idle energy](persistence-energy.md) for cache commit policy,
dirty-only checkpoints, native sidebar metadata and verified optimized installs.
