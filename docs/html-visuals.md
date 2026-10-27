# Inline HTML visuals

`publish_visual` publishes an HTML document or coherent fragment
for an inline transcript block on iOS and Mac. Its contract is separate from
the interactive remote-file reader described in [Remote files](remote-files.md).

## Publication and provider discovery

One definition in `host-daemon-rs/src/agents/tools/registry.rs` supplies the
schema and authoring guidance to both providers. Codex receives
`remotecoder.publish_visual` through the gateway's `dynamicTools` projection
on `thread/start`; resumed threads keep their original declarations. Claude
receives the same definition through the gateway MCP `tools/list` projection.
Both execute the same `dispatch` and `storage::visuals::PublishVisual` owner.

The tool takes a `title` and exactly one source: inline `html`, the default
that saves agents a file write and a round trip, or the absolute `path` of a
regular UTF-8 file the agent generated, for example with a script, so large
generated output is not re-emitted as model tokens. Either source is at most
2 MiB. The decoder turns the arguments into one `Source`, so a call with both
or neither never reaches the publisher. The publisher refuses final-component
source symlinks, NUL bytes, incoherent HTML, and declared host-file resource
references in HTML and CSS, which cannot load on the device; network
references publish unchanged. Titles contain 1–200 UTF-8 bytes, are nonblank,
and contain no control characters. Audits record source lengths, never the
HTML.

### Local images

Agents show local images by path: an absolute path, `file:` URL or, for a
`path` source, a path relative to that file in `<img src>`, `<video poster>`
or SVG `<image href>`. Inline HTML has no directory, so a relative local path
there fails with an error asking for an absolute one.
`storage::visual_bundle` finds those positions with `lol_html`, so scripts,
styles, comments and text never count, and resolves them with the `url` crate.
A local path must not contain a raw `&` (the parser would decode an entity).
Local files anywhere else, including CSS `url()`, are rejected with an error
that points to `<img src>`. At most 16 distinct images; discovery stops at the
seventeenth. Repeated references share one prepared image, and each occurrence
receives its own `data:` URL.

`storage::visual_images` owns the image policy and the only `sips` process. It
snapshots each source with `O_NOFOLLOW` into the gateway's own
`visual-staging/<pid>` directory (a regular file of at most 64 MiB), probes the
extension-less copy so the format comes from content, and accepts PNG, JPEG,
GIF, HEIC/HEIF, TIFF, WebP and BMP up to 64 megapixels. Every image converts
once as its decode check, scaled down to a displayed width of at most 1,600 px
and 4 megapixels, to JPEG quality 80, or PNG when it has alpha. `sips` keeps
EXIF orientation but cannot report it. A PNG's own `eXIf` chunk is read
directly; other formats that may carry orientation limit their longer side. A PNG, JPEG or GIF that needed no scaling and is at most 512 KiB
keeps its original bytes, which preserves lossless screenshots and animation.
One preparation runs per gateway with at most three more publications waiting;
a fifth fails at once. The preparation permit and its staging directory share
one owner, so a cancelled publication keeps both until cleanup finishes. The whole publication has a 30-second deadline and each
`sips` run 10 seconds, after which the child is killed and reaped. Staging is
removed when the preparation ends, and the next preparation reclaims
directories left by dead gateway processes.

`LocalImages::embed` computes the exact final size before allocating, then
splices `data:` URLs into the attribute values. The validator and store then
see an ordinary document without host references, so the 2 MiB limit applies after
embedding, and a failure itemizes each image's encoded size and count. The
published visual never depends on the source images. Each failure names every
bad image with its reason, stores nothing, and records a redacted category
(`image_file`, `unsupported_image`, `budget`, `timeout`, `capacity`,
`local_reference`, `css_local_reference`, …) in the dispatch audit.

A successful call returns an automatic-publication receipt, an escaped Markdown
image embed as its own text block, and a host preview (see [Preview](#preview)):

```markdown
![Descriptive title](rc-visual:<64 lowercase SHA-256 hex characters>)
```

Publication displays automatically. The agent states the key point in text
for voice and clients without this renderer. To reuse a visual later, place
that exact embed on its own line where it belongs.
`MarkdownRendering` recognizes one standalone image with the `rc-visual`
scheme as an HTML visual block; `HTMLVisualReference` accepts only the exact
canonical digest form. Invalid references show an unavailable state.

`PublishVisual` hashes the published bytes and atomically creates a read-only
`~/.remote-coder/visuals/<digest>.html` file with mode `0400`. The store uses
process synchronization and a filesystem lock, checks existing content and
permissions rather than replacing it, and retains at most 256 MiB or 4,096
visual files. It evicts the oldest modification timestamps while protecting
the document currently being published. Re-publishing identical bytes refreshes
their modification timestamp. One inventory pass supplies retention decisions.
Editing a source and publishing again
produces a new reference; a published reference never means the latest source
at that path. Dispatch audit records keep argument sizes and a redacted
publication result, without the source path, title, HTML or returned embed.

## Automatic presentation

A successful `publish_visual` result displays inline at its canonical tool
position. The model need not reproduce an opaque reference to complete
publication. Outbound gateway projection derives one `rcVisual: {digest, title}`
descriptor from the successful result for Claude MCP and Codex dynamic tool
items, including historical reads. It changes neither provider history nor the
published bytes and maintains no separate publication journal. The descriptor
is validated by clients and becomes a `publishedVisual` transcript boundary,
using the existing document, preparation, renderer and retention owners.
Visual-only output counts as a reply without becoming an authored message for
speech, copy or fork actions.

Within one loaded turn, a later successful publication with exactly the same
title replaces the earlier automatic row. Distinct titles and later turns
remain independent. Canonical tool history keeps every publication. The
publisher owns title validation; clients preserve that value and validate the
descriptor's digest at their URL boundary.

The returned embed remains available for reuse and older tool declarations.
Within one loaded turn, a completed assistant message with a valid standalone
image embed claims placement of that digest and replaces its automatic row.
Streaming text does not withdraw the automatic row. Code examples, inline
references, ordinary links, user messages and malformed references never claim
placement. A later turn may independently show the same visual. Row identity
comes from the tool item, not the digest. Bare URIs remain text; publication no
longer depends on their interpretation.

Decision (2026-10-21). A real Claude session published successfully, omitted
one embed, then shortened another to a bare URI. The assistant error exposed
a brittle product contract. Chosen: render successful canonical tool results,
with one gateway descriptor projection shared by providers and clients.
Rejected: more reminders or a SessionStart rule, which retain the copying
dependency; injecting synthetic assistant messages, which creates a second
history owner; accepting guessed or fuzzy references; and parsing tool-result
text separately in every client. A completed explicit embed may relocate the
visual once; this preserves authored placement without rewriting reply text.
Exact-title replacement supports the tool's preview-and-republish correction
loop without exposing superseded drafts as additional automatic output.
Publication guarantees display eligibility, not successful file download,
WebKit rendering or physical acceptance, whose failures retain their existing
unavailable states.

This follows [OpenAI function-calling guidance](https://developers.openai.com/api/docs/guides/function-calling#best-practices-for-defining-functions)
on moving known values and mandatory sequential work into code,
[Anthropic tool design](https://www.anthropic.com/engineering/writing-tools-for-agents)
on meaningful results and reducing opaque identifiers, and
[context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
on small, high-signal contracts. [Claude Code output styles](https://code.claude.com/docs/en/output-styles)
explicitly distinguish instructions from guarantees. These sources informed
the design; they do not establish that Concise style caused this incident.

## Preview

After publishing, the gateway renders the stored visual once on its Mac so the
agent sees the result before the user does. One call yields the embed, a short
summary and one JPEG; the agent republishes only when something is wrong.

`rc-visual-preview` is a Swift helper beside the gateway executable in
`RemoteCoderGateway.app/Contents/MacOS`, compiled by `gateway-candidate-local`
from the app's own `HTMLVisualWebContent`, `HTMLVisualTheme` and Core visual
types and signed before the bundle. The `justfile`'s `visual_preview_swiftc`
holds that source list once; `gateway-check-local` typechecks it, so an app
edit that breaks the helper fails verification rather than the release. It therefore loads the visual with the
app's origin, CSP, base CSS, theme variables, layout bridge and navigation
policy, and captures it with the same PDF export as the app's snapshots, so
snapshot artifacts such as dropped gradient-stop alpha show up too. The
gateway passes the digest as its argument and the bytes on standard input; the
helper verifies them and prints one JSON report.

The helper renders light and dark pages concurrently at 360 pt with iOS system
colors and the default accent, each with its own `HTMLVisualWebContent` and
store, so storage written by one theme cannot change the other. Each page lives in a borderless, alpha-0,
click-through window of an accessory-policy process: such a window is on screen
for WebKit, so `requestAnimationFrame` and timers run, yet it is invisible,
never activates and takes no focus. An offscreen window would read as hidden,
which stops animation frames and throttles timers. Once the shared loader
reveals the page, the helper waits up to 4 s for the load event, then for fonts
and a 300 ms DOM-quiet window, at most 2.5 s, then measures and exports. Both PDF pages are
drawn straight into one composite, scaled so the longer edge is at most
1,568 px; the capture covers at most the top 2,000 pt, keeping text at least
three quarters of its size.

A page-world script reports uncaught errors with their line and column,
unhandled rejections, `console.error`, failed element loads and CSP
violations, deduplicated across both themes and capped at twelve. The visual
origin is not opaque, so error messages are not muted, and the document
prefix holds no newline, so a line number is the line in the agent's HTML.
The summary also names horizontal overflow beyond 360 pt, a capture shorter
than the content, resources still loading after 4 s, and a hidden page, for
example when the host display sleeps, which stops animation.

At most two previews run per gateway. A preview waits at most 15 seconds for a
slot, reported as busy, then has its own 15-second render deadline, after
which the gateway kills the helper; the helper also exits on its own after 20
seconds, so a gateway crash cannot strand it. Killing the helper ends its
WebKit processes, even while a page spins. Any failure, including a gateway build without the
helper, still returns the published embed, followed by `Preview unavailable:`
and the reason; the audit records `preview.failure`. The preview is for the
model only: `wire::tool_media` omits its JPEG from transcript media, because the
visual itself has a dedicated transcript row. WebKit gives the helper
only a fixed skeleton of data-store directories, because pages use a
nonpersistent store.

Decision (2026-10-20). Goal: few round trips while agents still catch their
own errors and see one render. Errors, wrong heights and dark-mode contrast were
invisible to agents, and the 2 KB Claude Code description limit leaves no
room for rules a render can detect. Chosen: a host render through the app's
own recipe, returned with the publish result. Rejected: a preview over the
device channel, which needs a foreground device; headless Chrome, whose engine
differs from WebKit; and up-front rules alone. The helper runs in a separate
process so a WebKit hang or crash cannot take down the gateway. This assumes
the gateway runs in a logged-in GUI session. While the display sleeps, WebKit
reads the page as hidden, so animation and timers stop and the summary says so.
Account for display sleep when validating animation. If WebKit changes how it decides
visibility, or the app recipe gains app-only dependencies, the helper and its
source list in the `justfile` change with it.

## Authoring and appearance

HTML is the preferred answer format: the tool description asks agents to
present anything beyond very basic text as HTML, with styled text, layout,
charts, SVG diagrams instead of Mermaid, and interaction where each helps.
Markdown remains for a few plain sentences, short lists, and commands or code
to copy. The reply opens with a short plain-text lead for voice and other
clients, and the visual carries the rest without a Markdown repeat. Libraries,
data and media load over HTTPS or are inlined; host files cannot load,
and cached visuals reopen offline.

The guidance keeps only rules with a rendering reason and leaves visual design
to the agent. Inline height follows the content, so `vh` and `height: 100%`
break sizing, and network media reserves its size so late loads do not move
the row; layouts fit roughly 360-point phone widths and wider Mac windows.
Text sized in `em` or `--rc-font-size` follows the app's text size, and the
theme variables below keep light, dark and contrast aligned with the app.
Gradient stops stay opaque, so snapshots keep hatching and fades. JavaScript
and CSS animation run freely on live pages. The renderer bounds how many pages
are live and shows a still snapshot while scrolling or off-screen; a live page
keeps running underneath that snapshot. The page bridge reports every root
resize and a height change re-lays out the row, so motion keeps the page height
stable, paused frames should read on their own, and animation respects
`prefers-reduced-motion`.
The injected base styles provide
system typography, inherited control fonts and accent colors, and border-box sizing.

`HTMLVisualEnvironment` derives one `HTMLVisualTheme` in its body from the
current environment's appearance, contrast, accent and text size, and supplies
it to both transcripts; the theme is never held as separately updated state. It
updates a live page without reloading it when the app appearance or typography
changes:

| Variable | Value |
|---|---|
| `--rc-font-family` | `-apple-system, system-ui, sans-serif` |
| `--rc-font-size` | App body font size in CSS pixels |
| `--rc-text` | Resolved primary text color |
| `--rc-secondary-text` | Resolved secondary text color |
| `--rc-background` | Resolved system background color |
| `--rc-surface` | Resolved secondary system background color |
| `--rc-accent` | Current app theme accent color |
| `--rc-color-scheme` | `light` or `dark` |

Color values are CSS RGBA strings, including the resolved opacity. Inline layouts inherit the app's interface
scale and body font metrics; width and the complete theme participate in the
layout cache key.

## Document ownership and offline reads

`ChatWorkspaceModel.htmlVisuals` owns one `HTMLVisualServices`, which supplies
the app-wide renderer and document cache. `HostServices.htmlVisualDocuments`
owns one `HTMLVisualDocumentStore` actor per
physical host, shared by its provider accounts. The screen passes that store
and its exact host ID through `HTMLVisualSource`. The renderer receives only
the verified HTML string, never a host path or file lease.

The store checks its verified local cache first. On a miss it calls
`HostFileAccess.openVisual` with the opaque digest. The authenticated
`POST /files/download` body is `{"visualDigest":"<64 lowercase hex>"}`;
clients neither resolve the host home nor construct the private store path.
The gateway resolves it through `HostPaths`, opens the store and file without
following symlinks, and enforces the fixed 2 MiB limit before any body or
unchanged response. Client download admission also checks that cap and the
expected digest filename. Ordinary file requests remain path-based, retain
`containingDirectory` scoping and the fixed 1 GiB limit. An older gateway
rejects the distinct request form; visuals never retry as ordinary files.

`HTMLVisualDocumentCache` performs bounded file reads, UTF-8 decoding and
SHA-256 verification on its actor. It creates a read-only temporary copy and
atomically moves it into Application Support under
`RemoteCoder/html-visuals/documents/<host UUID>-<digest>.html`. The original download lease
is released on success and failure. Later reads use this verified immutable
copy without contacting the host or recalculating its digest; they still
require a regular read-only file, bounded bytes and valid UTF-8.

The persistent client cache has one 64 MiB/256-entry budget across all hosts,
evicting oldest creation timestamps before adding a document. Host removal
or reconfiguration cancels pending store work but leaves verified copies
subject to that cache budget. Each host admits at most 24 pending document
requests and serializes them. Missing, unavailable, invalid and cancelled
loads remain explicit; eviction is not a promise of permanent archival.
Mounted blocks prefetch verified documents through this actor without creating
a page. Prefetch uses at most 20 request slots, reserving four for foreground
loads; concurrent consumers of the same reference share one operation, with
at most 64 consumers. Cancellation releases a consumer and cancels abandoned
work; cancelled queue entries remain bounded until they drain.

## WebKit sandbox

`HTMLVisualWebContent` loads verified bytes using WebKit's simulated HTTP
response API at `https://<digest>.rc-visual.invalid/`. It shares one app-owned
nonpersistent website data store to avoid independent WebKit process lifetimes
for every transient page. The response-header CSP sets `sandbox allow-scripts
allow-same-origin`, so each visual runs in its own per-digest origin, which is
same-origin with nothing else. Visuals get cookies, local and session storage,
IndexedDB and the Cache API, keyed to that digest and kept in memory. The
renderer discards that storage whenever its last live page is released, so
retained storage never outlives the visuals on screen; the HTTP memory cache
stays, keeping CDN libraries warm. A republished visual starts empty.
The real origin also unmutes script error messages and is the prerequisite
for camera and microphone capture, which WebKit refuses to opaque origins.

Visuals have the network. External services can receive request metadata and
any content a visual sends, so users must trust the agent-authored document.
Live data, CDN libraries, map tiles, frames, secure WebSockets, WebRTC, workers,
`eval` and WebAssembly are available over HTTPS. The `https:` visual origin makes WebKit
block active `http:` and `ws:` loads as mixed content, loopback included, while
passive images still load. Frames inherit the sandbox flags, so an embed runs
in its own origin without popups. The response CSP still denies
objects, base URLs and form submissions. The shared nonpersistent store keeps
cookies and storage only in memory
for the app session, sharing nothing with Safari or the app's other web views.
The page has no remote-file resource adapter or credential-bearing gateway
URL, so host files stay unreachable. Device sensor authorization is denied and AirPlay is
disabled. On iOS, `playsinline` video plays inline rather than in the system
fullscreen player. Cached visuals reopen offline, so a visual that depends on
the network should still show something sensible when a request fails. A page
goes live when its load event fires or 500 ms after commit, whichever comes
first; network resources keep loading on the live page, and the layout bridge
reports the first height whenever parsing finishes.

Navigation permits the initial simulated load, same-document link anchors and
any subframe navigation. Other main-frame and popup navigation is cancelled. A trusted click on an HTTP,
HTTPS, mail, telephone or `file:` link is passed to the app's `openURL` action
rather than navigating the visual; destinations are bounded to 4,096 bytes, and
`file:` links resolve through the same host-file path as Markdown links.

Embedded content opens through the same viewer as the rest of the transcript
([Remote files](remote-files.md#embedded-files)). A trusted tap on an image, or
on a video without `controls`, whose click the page did not cancel with
`preventDefault()` and that is not inside a link, button or other interactive
element (including the media element itself) sends its `data:` or `blob:`
source to the app; so does a trusted click on a `data:` or `blob:` link. The
`publish_visual` description tells agents to cancel the click when the page
handles media taps itself. The isolated bridge reads the source through WebKit
into a base64 `data:` URL, bounded to 8 MiB of content and checked before the
body is read; a larger or unreadable source opens nothing. Only the latest tap
in a visual is sent, and a newer tap aborts the previous read. The element's
frame is converted to window coordinates through `HTMLVisualFrameAnchor` when
iOS Quick Look asks for its zoom origin. A video with `controls` keeps WebKit's
own player. The base style gives such media a pointer cursor for Mac and
trackpad hover; iOS taps reach the bridge without it.
JavaScript alerts are suppressed, confirms and prompts return cancellation,
and file inputs cannot open a chooser. Back/forward gestures, magnification
and link previews are disabled.

The layout, interaction and link bridge lives in WebKit's isolated
`defaultClient` content world. Native handling checks the main frame and
synthetic origin and validates each bounded payload. Page-authored JavaScript
does not receive an app RPC or arbitrary native-operation bridge.
The content controller strongly retains that bridge, so link callbacks capture
only the open-URL action, file source, frame anchor and presentation scope;
they never capture a view value or its raster state.

## Visibility, interaction and cached geometry

`HTMLVisualInline` uses the transcript's existing row visibility, visual
visibility and active scene state. A focused control, active text selection, active pointer or
expanded view pins its instance. Pins are also reported through the existing
`TranscriptRowPresentation` owner, so native Mac row virtualization retains
an interacting visual without adding another visibility tracker.

On iPhone, the outer HTML occurrence also reports scroll visibility. Automatic
first admission waits until one percent is visible; explicit selection and pins
bypass that gate. Once loading or live, the page keeps its existing row-scoped
lifetime even when the occurrence itself leaves view. This avoids starting
unseen blocks inside a visible message without introducing earlier JavaScript
state resets. Near-viewport preparation and raster demand remain independent of
this admission gate. iPad and Mac keep row-scoped admission.

The workspace-owned `HTMLVisualRenderer` admits three live pages and at most sixteen
waiting requests. Routine admission is FIFO. Explicit Interact or Load
selection moves the selected waiting occurrence to the front and cancels the
oldest unpinned live instance to release its slot. A pinned instance is not an
eviction candidate; if every live page is pinned, selection retains its priority
while waiting. Expansion pins are reapplied on re-admission after backgrounding.
Under `AppEnergyPolicy.conservesEnergy`, automatic admission is limited to one
page; explicit selection may use the remaining slots within the three-page cap.
Background preparation (below) is the lowest admission kind inside the same
cap: waiting visible demand admits before it and cancels its page, and it is
the first eviction candidate. Under energy conservation it shares automatic
admission's one-page limit, and conservation releases its pages beyond it.
Leaving the active visibility scope cancels owned rendering,
theme updates and snapshot capture. The renderer retires the instance's page
by removing its `rcVisual` handler from `defaultClient` before stopping loading
and clearing the page, then releases admission. The instance owns the controller
from handler registration, including while page creation is suspended, so
cancellation before the page is assigned follows the same retirement path.
`HTMLVisualWebContent.make` also removes its handler if creation throws after
registration. This releases retired visual holders and their raster reservations;
otherwise WebKit can keep those pixels reserved outside the renderer's cache
eviction policy. Expansion runs its own selected, pinned page in a
scrollable sheet.
Inline document viewport overflow is clipped in the isolated style bridge;
SwiftUI's `scrollDisabled` does not disable the native WebKit scroll view.
Inline WebViews use size-based horizontal and vertical bounce behavior.
The expanded page's document scrolls.
Admission and release records identify the page request, document digest prefix,
surface, reason and visibility/pin state. Release adds lifetime and aggregate
layout, settled-event and snapshot-capture counts and duration. These are owned
by one admitted lifetime; they add no sampling timer or per-frame log.
Inline content is clipped to at most 6,000 points multiplied by the interface
scale, so a long document reads inline like Markdown; taller visuals expose
Expand. `HTMLVisualInlineHeight` owns that limit for the inline view, the Mac
row estimate and snapshot capture.
Text selection stays enabled in WebKit. Replies containing a visual attach the
chat menu to their native Markdown blocks, leaving WebKit's selection gesture
inside the visual. The context preview uses the reply's plain text and visual
title, so it never creates another live page.
The message-scoped `ChatBubbleMenuOwner` keeps a stable environment identity
while menu and preview leaves read the current message. Settled Markdown blocks
do not receive a changing message environment during streaming.
A WebPage belongs to one WebView for its whole life; WebKit traps when a second
WebView binds a page that is still bound. SwiftUI does not order one
representable's teardown before another's creation: on macOS the sheet bridge
builds sheet content synchronously inside the row host's layout, and a
dismissed sheet's content outlives its `onDisappear` and dismissal callback.
So each surface owns its own page instead of handing one over. The inline view
owns the expanded instance (`HTMLVisualInstance.Surface.expanded`) from Expand
until the sheet's dismissal callback and pins its row through
`htmlVisualExpansion` for that time, and runs it only while the scene is
active and the window visible. The inline page stays under the sheet as an
ordinary admission, so opening expansion at the three-page cap can suspend it. The expanded page records no heights and captures no snapshots, so it
never changes the inline layout cache. A measured live page replaces the
snapshot.

After the bounded reveal wait, the loader requests the first root layout
through the isolated bridge when its layout script has run, so a hidden page
does not wait for animation frames before it can be revealed. Root resize reports coalesce into
microtasks; appearance and width changes explicitly refresh the measurement,
including when the resulting height stays the same. Native code accepts integral
heights from 0 through 20,000 CSS pixels, including shrinkage; larger document
heights are clamped to that bridge limit. It starts with
a persisted height estimate, or 180 points on a cold miss, and reveals the live
page after a measurement. Until an occurrence can draw a decoded snapshot or a
measured live page, its reserved block shows a loading placeholder (the chat
image placeholder's fill, with a system progress indicator only while the row
is visible), or the failure with Try again, or Load while admission queues it.
Only a visible row fades a placeholder it actually showed into the content,
in 0.2 s, by animating the opacity of those two layers alone; warm content,
re-entry and the live/snapshot handoff stay direct, and height never animates. Each live occurrence owns its measured height;
shared records supply estimates only. Bridge and link callbacks carry the
current occurrence request fence. There is
no whole-transcript height polling.

Content that changes after the reveal without a height change recaptures after
one quiet second without body mutations, resource or font loads, `input` or
`change` events, so continuous animation never triggers a capture, while
anything updating less often than once a second, such as a polling dashboard,
exports a snapshot per update. Snapshot capture coalesces work for 180 ms and exports the inline region, up
to that limit, as a transparent PDF painted by the web content process. Image
export cannot cover tall content on iOS: it snapshots the on-screen layer tree,
which holds only the tiles WebKit renders around the enclosing scroll view's
visible rect. On the test iPad its content stopped at 1,024 points and a
5,000-point capture came back empty, while the PDF covered all of it, smaller
and faster. The PDF follows screen styling and keeps script and interaction
state. Its one known loss is WebKit's: PDF export drops the alpha of every
gradient stop, CSS and SVG alike, so a translucent stripe or fade paints
opaque and a translucent conic gradient vanishes. Solid translucent colors,
`opacity`, shadows and SVG patterns survive. The snapshot shows the loss during
motion and before the live page loads; the live page is unaffected. The publish
guidance therefore asks for opaque gradient stops.
Snapshot keys contain renderer version, digest, rounded width and
complete theme. The in-memory image cache retains at most 32 entries/24 MiB;
a separate height cache retains 256 keys so evicting an image need not erase
known geometry. The actor-owned persistent binary presentation cache under
`RemoteCoder/html-visuals/presentations/` keeps the same byte and height
limits and up to 128 snapshots, so warmed conversations keep theirs across
launches. Real snapshots measured 13-117 KB, with rare multi-megabyte
outliers, so the byte limit usually binds first. Its
version 2 envelope stores PDF snapshots; a version 1 file keeps its heights and
drops its PNG snapshots, which covered at most 800 CSS pixels. Snapshots remain
encoded until a visible occurrence or background preparation rasterizes one
off-main at display scale.
The renderer's `HTMLVisualRasterBudget` owns every prepared and in-flight
raster: 32 MiP (128 MiB) in total, and at most 8 MiP and 16,384 pixels per
side for one raster. A raster that does not fit is drawn at a lower scale, down
to one pixel per point, and refused below that; the occurrence then keeps its
live page or placeholder. Row visibility cannot tell which visuals of a long
message are on screen, so this total, not the page cap, bounds pixel memory.
The per-raster limit is a quarter of the total so that two long visuals on
screen and the next ones in either direction fit at once. It still draws a
6,000-point visual about 1.9 pixels per point at phone width and 1.4 at full
iPad width; the settled visual shows its live page, so the raster mostly
appears during motion.
A visible occurrence whose raster is drawn below display scale asks
`sharpRaster(for:capture:displayScale:)` for a sharper one once the transcript
is idle, while its scene is active and energy is not being conserved. The
renderer decodes the same capture revision in a separate 16 MiP
`HTMLVisualRasterBudget` whose per-raster limit is its whole capacity, so a
6,000-point visual reaches about 2.7 pixels per point at phone width and 1.7 at
full iPad width, and grants it only above the base scale. Raster memory is
therefore bounded at 48 MiP in all. The occurrence keeps it in
`PresentedRaster` next to the base raster and draws it in the same `Image`
while key and revision match. It arrives while settled, usually under the live
page, so the motion swap stays a pure opacity change with no new image. A
decode in flight finishes off the main actor, but motion discards its result;
leaving visibility, an inactive scene or energy conservation drops the sharp
raster and returns its pixels. The budget is first
come, first served: every sharp raster belongs to an occurrence in a visible row,
so taking one from another would only trade sharpness and decode again at every
settle. Occurrences of the same capture revision and scale share one sharp
raster and one decode. A started decode stays registered until it finishes,
even when every consumer is cancelled, so a remounted or duplicated occurrence
joins it instead of being refused by its reservation. The result is applied
only if the row is still visible and idle. A visual never settled on, or one beyond the remaining
budget, stays at base scale.
Each raster returns its pixels to the budget once neither its occurrence nor
the renderer's retained rasters hold it. The renderer keeps decoded rasters
keyed by layout key, snapshot revision and display scale. A retained raster is
in use while a preparation pins its key (an awaited or near visual) or while an
occurrence still holds it in its `PresentedRaster` holder, which it clears once
the row is no longer visible; evicting one in use would free nothing, so neither
trimming nor making room touches it. Rasters not in use form a least recently
used cache of at most 16 MiP, trimmed at each retain and released on memory
pressure. Cleanup uses the same pin and external-holder checks as eviction.
Before a new decode the
renderer evicts rasters not in use, least recently used first, until the
total budget has room for the raster at its expected size, so cached rasters
for rows already passed cannot shrink or refuse the one about to be shown. Every
stored or captured snapshot takes a renderer-unique revision. A key keeps one
retained raster: a newer revision replaces the older one, and a late older
revision is never retained over a newer one. Storing a newer capture marks the
key's retained raster superseded: occurrences keep drawing it, so a capture
never blanks a visual while its decode waits for budget, and the occurrence
keeps its live page over it during motion, but it no longer counts as
prepared. `preparedRaster(for:)` and preparation decode the newest stored
capture instead, so a decode cancelled with its row is redone by the next near,
opening or cache request rather than leaving stale pixels in place. Concurrent requests for one raster share a
single decode; the decode is cancelled when its last consumer is, or when the
renderer is released, and a cancelled request retains nothing.
Disk reads, validation, encoding and coalesced one-second writes run on the
cache actor. Index loading starts with workspace creation and never
gates the transcript mount. Layout-time lookups use prepared memory values.
Width changes resize WebKit immediately but commit a cache key only after
150 ms of stability. Snapshot capture is suspended during resize, transcript
scrolling/deceleration and streamed publications. New page admission waits until
transcript motion settles and the row has stayed active for 150 ms, so
visibility flips while a conversation opens never create a page. A settled, unpinned page can present its own latest
prepared capture through an opacity swap while keeping the same native page and
frame. Without a prepared occurrence capture, the healthy live surface stays
visible. Focus, selection and expansion keep their live surfaces. Touch tracking
before the scroll direction is known does not trigger a swap. The existing
transcript scroll-phase owner supplies this policy on each platform. Each live
occurrence owns its latest encoded capture and its layout key, bounded to
8 MiB per occurrence within the three-page cap. A capture is presented only
when its key matches the inline layout; resize and an oversized capture keep
the healthy live surface visible. Releasing the page releases those bytes. The shared layout-key cache supplies cold and suspended fallbacks.
A visible occurrence keeps its raster, tagged with its layout key and
capture, across the switch from its own capture to that cache until the
replacement is rasterized; leaving visibility releases it.
A suspended visual's cached image is itself the Interact control for obtaining
a live page; only overflow beyond the inline cap adds the Expand control below
it. The block's height never depends on whether a live page exists: page
lifetime follows row visibility, so a block that shrank when its page arrived
could push its row out at a viewport edge, release the page, regrow and repeat
every frame. Mac logical row estimates use the same
layout key and cached height before mounting the row. A terminated WebContent
process falls back to the snapshot and is rebuilt on the next activation.
Rebuilding a live page resets its JavaScript state.

## Readiness and background preparation

Inline visuals are meant to behave like Markdown: already painted when the
reader reaches them, whether a conversation opens at its latest turn, returns
to a saved reading position or from recent presentation, or scrolls up into
history. A visual counts as presentable when its layout key has a known height
and a retained raster of its newest stored capture, so the mounting row lays out
at its final height and draws in its first frame.

Ownership is split by scope. Each `ChatScreenModel`, and so each window's
presentation of a host, owns one `HTMLVisualPreparation`: its layout context,
active and energy state, job queue, lane, waiters and preparation surface. The
workspace `HTMLVisualRenderer` keeps what windows share: page admission, the
raster budget, the snapshot, height and raster caches and the persistent
cache. Two windows therefore never share a preparation page, and one window
going inactive or switching conversations does not stop or redirect another's
work.

A preparation's layout context holds the inputs for the layout key before any
row mounts: the transcript column width, reported on iOS by a zero-height
probe with the rows' column frame and on the Mac by the native container's
column width; and the theme, display scale and inline
height limit, reported by `HTMLVisualPreparationHost`. An inline occurrence
uses that width until it measures its own. The host claims its preparation's
surface, and only the claiming host renders the surface's WebView, because a
`WebPage` may back only one `WebView`. A second host for the same preparation,
such as a transient view replacement, waits and claims the surface once the
first releases it. The claiming host activates preparation while visuals are
visible and the scene is not in the background, and deactivates it when it
disappears. The host is mounted on both platforms. The Mac transcript has no
reveal waits and no speculative warming, and `prepareInBackground` returns
`unsupported` there; it runs near demand from its native visibility, so a
visual is decoded, or rendered and decoded, before its row scrolls into view.

A preparation keeps its demand as state and derives each next job from it,
so repeated, satisfied or withdrawn demand never runs:

- Awaited demand comes from a caller's wait. Each awaited visual needs either
  pixels (render if no stored snapshot and height exist, then decode into the
  retained rasters) or geometry (render only). A wait for presentable visuals
  plans pixels nearest first while their expected rasters fit 24 MiP, the
  budget less one raster, and geometry for the rest; the planned pixels are
  pinned until the wait ends. A wait for measured visuals plans geometry only.
- Near demand follows the viewport. On every visible-row change the
  transcript passes the visuals of the visible rows and of up to 16 rows on
  either side, visible first and then outward. The preparation keeps the
  prefix whose expected rasters fit 24 MiP, pins it, and decodes the missing
  ones, rendering any that are not stored. Visuals that leave the set are
  unpinned and become ordinary cache entries, so passed rows are evicted before
  upcoming ones.
- Speculative demand warms nearby history: render and store the snapshot and
  height, never decode. It holds at most 16 visuals, newest demand first.

The lane takes awaited pixels first, then near pixels, then awaited geometry,
then speculative work, then background work, skipping what is already
satisfied. Background work waits while the transcript scrolls, and a scroll
that starts during a background render cancels it. Awaited or near
demand for another visual preempts a running speculative render, which stays
queued. Under `AppEnergyPolicy.conservesEnergy` (Low Power Mode and serious or
critical thermal state) awaited and near demand still run, within
conservation's one-page admission limit; speculative warming stops and new
speculative demand is dropped. The preparation host hands the energy policy to
the renderer's admission before it activates its preparation, so the shared
limit holds across windows even before any visual has mounted.

A render uses one hidden `.inline` instance on the preparation surface, a
zero-opacity WebView at the column width that the host keeps inside the window
so WebKit paints it. The page measures, captures without the 180 ms coalescing
delay and persists like a visible occurrence, then releases after the first
stored snapshot or after 4 seconds. A key whose document fails to load or
render is remembered as unpreparable, at most 64 keys, so demand skips it
while the visible occurrence loads its live page as before. An attempt whose
layout key or display scale changed while it ran is retried at the new key.
A decode refused by the budget counts as attempted; near demand retries it at
the next visible-row change.

A wait settles when every awaited visual has had an attempt, at its deadline,
on deactivation or when demand is cancelled; its demand ends with it.
Deactivation cancels the running job and keeps near and speculative demand;
reactivation resumes from that state once the cancelled lane has exited.
`cancelDemand` drops all demand and near pins, cancels the lane and ends every
wait; the screen calls it when it resets rendering for another conversation or
a new chat and when it retires, and a released preparation unpins its near
set.

Opening a conversation never waits for HTML visuals: a cold block shows its
placeholder, and near demand prepares the visible rows once the transcript
reports them. Two callers wait, each bounded by
`TranscriptReadingRestoration.renderReadinessTimeout` (1 s):

- Revealing earlier history warms the next batch and waits once for the
  geometry of the slice about to mount, so mounted rows keep their final
  height; near demand supplies their pixels before the reader reaches them.
- A requested row above the mounted window waits for the rows it reveals to be
  presentable, the requested row first, then rechecks the request token and
  recomputes the rows.

A conversation without HTML visuals never waits or starts the lane. The
timeout is a recovery path: rows then mount with the cached height and the
live page or placeholder, as before. Each wait reports whether it suspended,
and its caller re-reads its snapshot or row state afterwards.

`ConversationWarmer` processes eligible conversations in drawer rank order,
filtering completed coverage. The first two retain their existing hot-session policy. For a
selected conversation, it first stores the opening tail. If no claimed, active,
fully laid-out preparation surface permits background work, that history-only
coverage completes without scanning visual references or retrying an impossible
render. A temporary loss of capability does not erase stronger visual coverage
for the same observation.

Each screen reports a new usable background preparation context to the target.
The target retains a request received during an active pass and drains it before
ending. It reuses the covered stored tail, including hot conversations whose raw
page-cache freshness has expired. With a usable surface, it scans visual
references off the main actor and awaits `prepareInBackground` in chunks of at
most 16. They get geometry and a stored snapshot only, never a decode.
The outcome is `settled` only when every eligible visual is stored or recorded
unpreparable; a visual whose render timed out leaves it `incomplete`, and the
next warm pass retries it from the stored tail. Deactivation, energy
conservation, a layout context change, `cancelDemand` and task cancellation
return `interrupted`, which never counts as warmed. Mac background capability is
absent, so the warmer completes history only; the preparation API retains its
explicit `unsupported` result. `HistoryWarmLedger`
records the width and theme a conversation was warmed for, so a new context
prepares it again without another history read. An agent message with a visual
in a conversation that is not shown moves the thread's header revision, and
the next eligible warm pass reads and prepares it. Opening such a conversation reserves
the final height at once and decodes the stored snapshot, so the block fades
in without changing size. A visual that was never prepared still opens with a
default-height placeholder and resizes once measured.

## Verification boundaries

`HTMLVisualTests` covers canonical references, byte/UTF-8/digest rejection,
immutable offline reuse, host identity, persistent eviction and cancelled
publication. `HTMLVisualPageAdmissionTests` covers bounded FIFO admission,
explicit selection priority, interaction pins, preparation yielding to
visible demand and preparation within the reduced energy-conservation limit. `HTMLVisualWebKitTests` exercises network loads with `eval`,
WebAssembly and workers, a reveal that does not wait for slow resources,
host-path isolation, navigation, per-visual browser storage, script errors
reported at their source line, inline blob canvas readback, intrinsic growth/shrink and theme updates. Gateway `storage::visuals::tests`, `storage::visual_html::tests`,
`storage::visual_preview::tests` and `files::tests` cover publishing, the
preview summary, resource validation and pre-body byte limits.
`HTMLVisualPresentationCacheTests` covers persistent bounds and coalescing;
`HTMLVisualRendererTests` exercises two live occurrences, re-admission pins,
selection, stale bridge events, an unchanged inline height across page
release and re-admission, preparation that makes a visual presentable before
it mounts, a preparation interrupted by a width change, one page owner per
window and per preparation, cancellation and reactivation during a wait,
deduplicated speculative demand that never decodes, awaited but not speculative
preparation under energy conservation, one preparation page across two
windows under conservation before any visual mounts, a 7,000-point visual presentable at a
readable scale within the per-raster limit, long-visual demand that fits the
budget nearest first and never evicts rasters an occurrence holds,
newest-revision retention, a newer stored capture that stays visible until
preparation decodes it, and cancelled raster work. `HTMLVisualStreamingBodyTests` verifies
settled block bodies do not rerun for streamed suffixes. The
`HTMLVisualAppearanceUITests` UI test checks that live and newly created
visual pages follow a switch to dark appearance.
These describe test coverage, not a claim that a particular build, install,
physical interaction or performance measurement has passed.
