# RemoteCoder browser client

A React 19 browser client built and checked with stable TypeScript 7.0.2 and Bun 1.4.3. The UI follows RemoteCoder's native Paper, Neutral and named accent themes, with a host drawer, readable transcript and glass composer. The browser talks to the existing gateway through a same-origin Bun bridge; bearer credentials stay on that bridge's host.

```sh
bun install --frozen-lockfile
bun run build
bun run typecheck
bun test
bun run check
bun scripts/serve.ts --fixtures
```

Open `http://127.0.0.1:4173`. Fixture hosts exercise the actual browser JSON-RPC transport, streaming, questions and queue without starting production turns. Fixture hosts are explicitly named and coexist with configured real hosts.

Register an existing gateway on the bridge machine:

```sh
bun scripts/host.ts --id my-mac --name "My Mac" \
  --url https://gateway.example.com \
  --token-file /absolute/path/to/private-gateway-token \
  --cwd /Users/you/Projects
```

The credential file must contain one bearer token, be private on Unix, and remain outside source control. Browser host editing changes names and default directories; gateway addresses and credential sources can only be bound by the server-side CLI. Registry writes reload the latest bindings under a cross-process lock before atomic replacement.

## Hosting

Run the bridge behind HTTPS on a network you control, with a private access-key
file for remote browser origins. Every admitted browser session can act with the
full authority of the configured gateway credentials. Network access alone is
not a per-user permission system. See [security](../SECURITY.md) and
[privacy](../PRIVACY.md) before admitting anyone else.

Gateway bindings and mode-0600 credential files stay on the bridge host, outside
source control and browser builds. Register bindings with `scripts/host.ts`;
browser edits change display metadata only. Cookies are HttpOnly, SameSite
Strict and scoped to the browser origin. Explicit trusted-proxy deployments
must enforce their access policy before forwarding requests to the bridge.
Omitting the bridge access key for a remote HTTPS origin requires both a loopback
bind and explicit `RC_WEB_TRUST_PRIVATE_PROXY=true`; a direct network listener
always requires HTTPS and an access-key file.

The bridge can serve another browser bundle with `--static-dir /absolute/path`.
API and socket contracts remain unchanged. Precompressed `.wasm.gz` and `.js.gz`
siblings are served when gzip is accepted and the compressed mtime is at least
the asset's mtime; stale siblings fall back to the original. Generate compression
after building, never on the request path.

Maintainers: immutable service deployment, private DNS, ingress, retained
releases, read-only smoke checks and rollback configuration live in the private
[RemoteCoder-deploy operations entrypoint](https://github.com/emileberhard/RemoteCoder-deploy/blob/main/AGENTS.md).

## Browser bridge contract

For loopback or explicitly trusted-proxy no-key deployments, an initial `GET /` creates the private browser session. `GET /api/session` returns `{authenticated,loginRequired,fixture}` and reuses or renews that no-key session after expiry or a bridge restart. An access-key deployment remains unauthenticated until a valid `POST /api/session` with `{key}`; `DELETE /api/session` closes that session's sockets and HTTP relays. The session owns every upstream connection and expires after twelve hours. Socket bootstrap reads the session first, coalesces simultaneous callers, and cancels its HTTP owner on connection retirement. A key-required response directs the person to sign in again.

`GET /api/hosts` returns `{hosts:[{id,name,url,cwd,credentialStatus}]}`. Credential status describes whether the private source can be read; socket initialization separately proves gateway authentication. `PUT /api/hosts` accepts an existing host's `{id,name,cwd}`. Configured IDs never change when names or directories change.

`/api/hosts/<exact-id>/ws` carries the gateway's JSON-RPC frames unchanged. The bridge supplies the existing operator bearer to `/ws`; the browser supplies only its own HttpOnly session cookie. Initialize with `clientInfo` and `{experimentalApi:true}`, send `initialized`, then declare the browser's empty native device-tool list with `device/tools/declare`. Host-default and enrolled Codex connections use immutable execution contexts. Enrolled connections carry exactly `accountId=<UUID>&accountGeneration=<generation>` to the native `/ws` route; incomplete bindings are rejected, and unavailable or stale owners never fall back to another account.

Fixed HTTP routes mirror `/health`, `/version`, `/accounts`, the generation-bound account PATCH/remove routes, and `/claude/accounts` read/refresh/preference. Browser file upload is `POST /api/hosts/<id>/uploads?name=...` with raw bytes and `X-RemoteCoder-SHA256`; download is `POST /api/hosts/<id>/download` with `{path:absoluteHostPath}`. Native length, digest and file metadata headers are preserved. `speech/<provider>/<path>` supports only the gateway's native allowlisted speech HTTP/WebSocket routes. No arbitrary credential-bearing URL proxy is exposed.

Host history uses `thread/list` and `claude/thread/list`; stored transcripts use `thread/items/list`. Passive `thread/subscribe` provides an observation checkpoint and cursor when loaded. A `notLoaded` response remains a stored-history read until an explicit send resumes its exact thread. The subscribe receipt is a local connection/sequence fence, not a guessed wire revision.

An exact host and thread opens through `thread/read` with `includeTurns:false` when its summary is absent from the loaded history, including during reload restoration and before older pages load. Reads verify the returned thread identity and never resume or replace the conversation. Accepted local messages survive transcript refreshes until a canonical user item with the same client identity reconciles them; conversations with unconfirmed messages remain protected from eviction.

## Shared native code assessment

`Core/Package.swift` currently targets macOS/iOS27 with Swift6.4. The actual gateway owner uses `URLSessionWebSocketTask`, an `AppStorageScope` network configuration and `OSLog`; the conversation owner also uses Foundation and OSLog. Reusing that package in WebAssembly would require browser transport, storage and logging adapters, a WASM Swift toolchain, JavaScript interop and a UI-facing concurrency boundary before it could replace these browser owners. That cost is material for the independently designed TypeScript UI. This client instead generates the protocol dependency closure from the approved Codex runtime and extracts the Claude model catalog from its native owner. State contracts follow the existing native ownership and recovery rules while browser transport/rendering/media have explicit platform owners. Future portable Swift reducers can be evaluated individually without committing the entire browser UI to WASM.

## Feature status

The client implements multi-host chat/history, send/steer/queue/interrupt,
questions, agent inspection, automations, remote files, account/settings reads,
dictation and browser voice. Optional services need their own configured
integrations. Browser microphone, audio playback and WebRTC need browser and
provider acceptance on the deployment being used.

Files have no editor. History search covers loaded summaries. Automation drafts
are bounded in memory; unacknowledged actions retain exact request IDs in
sessionStorage. No offline service worker is registered. Background suspension,
microphone permission and audio autoplay follow the browser's policy.

Claude content subscriptions use the gateway's read-only live checkpoint, with
exact epoch/sequence filtering. An unknown or interrupted prefix never accepts
appended text until a live start or complete snapshot restores it. Codex queue,
archive and native observation features stay unavailable for Claude where its
gateway does not support them. Recovery errors stay with their owning host or
conversation.

## Owners and contracts

- `server/` owns session access, configured-host credential binding and bounded upstream transport. It forwards the gateway protocol; it does not translate it into a second application protocol.
- `src/gateway.ts` owns each host socket, initialization, request correlation, reconnect and local connection receipts. It never retries a mutation after losing its acknowledgment.
- `src/workspace/workspace.ts` coordinates native-style state owners under `src/workspace/`: exact host contexts, conversation sessions, drafts, turn dispatch, picker settings and preference exchange. [AGENTS.md](AGENTS.md#state-owners) maps each owner to its native counterpart. Observation buffers notifications until the subscribe checkpoint and cursor-anchored history are merged. Per-read generations prevent late reads from overwriting newer replicas.

Draft directories configure new conversations. An existing conversation's header owns its directory; both the displayed draft and turn dispatch derive it from that header, including when an older saved draft or model defaults arrive during history loading. Selecting another directory starts a fresh draft and preserves the old conversation's unsent input.
- `src/markdown.worker.ts` owns incremental Markdown parsing and highlighting off the browser UI thread. Streaming parses only the unsettled tail; completion preserves settled blocks and resolves the final document. Raw HTML is escaped and links are restricted at this boundary.
- `src/protocol/generated/` comes from the approved runtime pinned by `docs/codex/compatibility.json`. `bun run protocol` checks the binary identity before regeneration. Claude's picker entries are extracted from the native `ClaudeModelCatalog`, with no independent catalog copy.
- `src/features/` and `src/platform/` extend the shared transport for additional host features and browser media.
- `src/platform/visuals.ts` owns HTML visual frames ([contract](../docs/html-visuals.md)): at most eight live near the viewport, with released frames kept as placeholders at their measured height. The bridge serves each visual only after verifying its digest and 2 MiB limit, inside a CSP sandbox without the bridge origin, so visual code cannot reach the session cookie, `/api` or the parent page. Opaque-origin visuals get no `localStorage`, unlike native's per-digest storage.
- `src/platform/diagrams.ts` owns lazy Mermaid rendering, cancellation, sanitized static SVG and visibility lifetimes. Incomplete fences stay copyable source; a matching closing fence is eligible immediately, and terminal messages can render an unclosed final fence. Completed diagrams keep their DOM during later prose and terminal publication.

Publication is paced at 80 ms for live deltas. There are at most 24 retained execution connections, each bound to its exact account generation. A conversation retains at most 240 rows and 8 MiB; at most six conversations are retained, with active, unknown, submitting and request-bearing conversations protected from eviction. Host history retains 500 entries per host, model discovery 200 entries, drafts 32 entries, submission receipts 64 entries, RPCs 128 pending requests, and observation buffering 4 MiB/8192 events. Capacities fail or evict explicitly. Tokens and unread state are never represented as zero usage or idle activity.

Submission receipts are written before dispatch. A reload restores unacknowledged receipts as uncertain; a start/queue acknowledgment confirms delivery, while a steer acknowledgment confirms admission only. Steer receipts retain the exact structured input plus the original text and attachment objects until a canonical host echo with the same client identity reconciles it or the user explicitly restores it. A completed turn leaves untaken steers unconfirmed; their transcript window may be evicted because the bounded durable receipt restores the row on reopen or reload. `workspace.restoreSteer(address: Address, clientId: string): void` accepts an unconfirmed steer in that loaded conversation, appends its original text to the current draft with a newline and merges attachments by their existing IDs, then removes its row/render entry and receipt and persists both owners. It sends no RPC. Acknowledged steer receipts do not pin cleared drafts. Older receipts lacking original attachment metadata retain their complete wire text and host paths when restored. Transcript trimming preserves unresolved steer rows backed by receipts so the explicit restore action remains reachable. Recovered rows follow their owning turn's last loaded row; when the turn is absent, known later-turn timestamps or the active turn place them before later output. The browser never automatically resends unconfirmed input. The gateway's User Stop contract discards untaken steers and leaves resubmission to the client; an echo in a later turn still reconciles the original receipt. Fresh conversations start their first turn directly; only unloaded stored conversations need resume. An acknowledgment clears only the captured draft revision, preserving text typed during thread creation or while the earlier prompt is in flight. User acceptance of a duplicate-risk retry is explicit.

Every uploaded attachment, including images, uses the native `AttachedFilesPromptBlock` text handoff on both providers. The absolute host paths are appended after the typed message; no `localImage` input is sent. `protocol-fixtures/attached-files-block.json` defines the shared bytes used by native, browser and gateway probes.

`workspace.prepareConversation()` shares Send's captured draft admission and thread creation. Repeated preparation coalesces; a send cannot start a second thread while preparation is pending. It preserves text and attachments, validates the exact enrolled generation after the acknowledgment, and changes selection only when its captured navigation fence still matches. Preparation sends no prompt and performs no stored-history resume/read. `prepareVoiceConversation()` uses the same owner with service name `RemoteCoder Voice`, retaining the signed-in realtime admission contract. The Voice entry opens only for the prepared conversation that remains selected; microphone access begins with a separate explicit Start voice action.

The diagram owner pins eligible Mermaid 12.1.0. The vendor's [12.2.0 release](https://github.com/mermaid-js/mermaid/releases/tag/mermaid%4012.2.0) was less than twelve hours old during adoption. The [official render API](https://mermaid.js.org/config/usage.html#api-usage) returns SVG; strict security and protected host configuration prevent source directives from changing policy. Source is bounded to 32 KiB, edges to 250 and SVG to 2 MiB with dimensions at most 20,000. Embedded media is unavailable. Scripts, navigation, event attributes, external resources and animations cannot enter the displayed SVG. One serial owner coalesces equal requests, admits sixteen queued jobs and sixty-four subscribers, and retains thirty-two results within eight MiB. At most sixty-four mounted diagram lifetimes exist; hidden views remove their SVG and canceled work cannot publish later.

For a non-React browser client, copy `dist/diagrams.js` and its relative split chunks together. `import {browserDiagrams} from './diagrams.js'` exposes `render(source,{dark?,signal?})` and `mount(element,source,{dark?,complete?,onState?})`. The latter returns `{dispose()}` and reports `waiting`, `rendering`, `ready` or `failed`, with `{svg,width,height,title?,description?}` on success. Pass `complete:false` for unfinished source. Dispose each view's lifetime when it leaves its owning UI; dispose the shared service only at application teardown. The engine remains outside the initial chat bundle and needs no CDN or React runtime.

The UI uses positional keys only inside stable, ordered item content and incremental Markdown blocks; transcript row identity is the exact wire item ID. Scoped Biome exceptions cover these stable positional keys, safe renderer HTML, the keyboard-accessible attachment drop area, and independent CSS selector scopes. The Markdown boundary is tested against unsafe markup and chunked equivalence.

## Verification

The test suite covers multi-host identity, live events during history reads,
duplicate admission, successor drafts, unknown activity, stale question reads,
uncertain input, bounded storage, Markdown safety and cross-process registry
writes. Synthetic sessions prove transport behavior without claiming acceptance
against a production gateway. Run the owner tests, strict client/server
TypeScript checks, Biome and the production asset build.

`bun scripts/probe.ts <private-origin>` performs authenticated reads using the
UI's parsers. Keep its receipts, logs and any live screenshots outside Git.
Use synthetic fixture hosts for shareable screenshots.

Apple-only OS surfaces such as Live Activities, system call integration, background location and share extensions remain native platform features. Browser permissions, audio autoplay and background suspension follow browser behavior.

## Workspace data ownership

The browser preserves Core's marks, activity, sidebar, directory and usage rules
without depending on Swift presentation. Exact execution contexts own marks
replicas; physical hosts own favorites/home and versions; provider HTTP
inventories own account usage. The drawer is a pure projection cached by
metadata identity, so streamed text does not re-project history. Mutable
transcripts remain inside conversation sessions. The compact drawer uses the
native iOS five-row project cap and holds ranks while open; local folds,
unread-only and reveals remain separate from the synced drawer mode.

Keeping these rules in UI components or extending the old workspace state bag
would duplicate native policy and tie unrelated lifetimes together. Project
normalization stays on the gateway rather than introducing a second Git remote
parser. Browser storage retains bounded pending marks and favorites, while full
reads establish coverage; unread, empty and failed stay distinct. These owners
retain the existing single-window browser assumption; shared offline replicas
across browser windows would require a shared persistence writer.

`HostServices` owns the account document store so context selection and usage
rings consume one acknowledged HTTP response. The store owns the 120-second
foreground refresh and Claude routing; Workspace owns browser visibility and
agent parent/child navigation. Drawer actions return one five-second undo
deadline, with draft restoration and cross-host partial failures kept by their
owners. Missing pinned headers recover by exact address within the existing
500-header cap rather than synthesizing rows from pin names.

Marks, favorites, preferences and questions retain distinct synchronization
loops: their acknowledgment, revision, retry and durability contracts differ.
Each worker releases its own in-flight slot before completing, so reentrant
requests cannot land in a finished promise. Sidebar memo keys derive from
stable host inputs; selected action state reads the addressed marks directly.
