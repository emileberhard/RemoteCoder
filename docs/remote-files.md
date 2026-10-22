# Remote files

RemoteCoder opens explicit file links and uploaded-file chips from either
provider through one host-owned download path. Any readable regular file within
the transfer and storage limits can be saved or shared; preview support is a
separate capability. A successful download is a copy obtained when opened, not
evidence of the bytes present when the agent originally sent the link.

## References and provider boundary

`HostFileReference` identifies a physical host UUID and a normalized absolute
path. `HostFileOpener` captures account, conversation, transcript and working
directory as presentation provenance. Provider accounts share that host's
filesystem and cache; an account switch must not redirect an existing request.

The existing Codex file-reference instructions and shared Claude instructions
already own Markdown `file:///` formatting. This feature adds no URI scheme,
provider tool, or second prompt-formatting policy. Opening a link, including one
from history, never starts or resumes an agent turn.

`HostFileReference.resolve` accepts `file:` URLs with empty or `localhost`
authority and explicit Markdown absolute or relative paths. It decodes escapes
once, rejects credentials, queries, ports and other authorities, and resolves
relative paths against the originating remote directory. Links in a downloaded
Markdown document resolve against that document's remote parent, never its
iPhone cache location. HTTP and other non-file schemes retain system handling.
Bare paths and inline code are not scanned for implicit links.

`#L<n>` is separated from the filesystem path. The initial viewers do not
promise line navigation. Colon suffixes remain filename content. A missing
source directory produces a visible error instead of guessing a host path.

## Inline images

A chat paragraph made only of Markdown images (`![alt](file:///…)`) renders as
an image block; an image inside other text renders as a link named by its alt
text (or file name). An image block shows a preview when its URL resolves to a
host file whose type ImageIO decodes, or a PDF, previewed by its first page;
any other URL, including HTTP images,
stays a link and is never fetched automatically. Tapping either opens the file
through the ordinary open path; on iOS, Quick Look zooms from and back to a
loaded preview's current on-screen frame (`HostFileTransition`), including
layout changes while the viewer is open.

`HostImagePreviews` (one per physical host, in `HostServices`) downloads a
preview through that host's `HostFileStore`, one preview at a time, while the
block is mounted and its surface is visible in an active scene. It downsamples to at most 1600 pixels off
the main actor, releases the lease at once and keeps decoded previews in a
memory cache bounded to 24 images and 48 MiB of decoded pixel storage. Preview
requests are bounded to 24 pending operations; overflow shows a failure link
that can still open the original file. Cancellation fences both cache and view
publication. A preview is the file's content
when it loaded, like any opened link. Markdown documents opened in the reader
show their images as links.

Media the agent took in appears as its own row between the turn's action
groups, previewed the same way from its absolute host path: an image it viewed
(Codex `view_image`, or a Claude `Read` whose result is an image), a PDF a Claude
`Read` returned (whole or a page range), and every image a tool call's result
carried to the model (MCP image content and dynamic-tool `inputImage`, from
either provider). A tool call's media follow its event in the action group; an
image view replaces the tool call. A row is labeled with the file's name when
the agent named the file, otherwise with the tool's name. Only a successful
read produces an image view; a failed or text `Read` stays a tool call. Stored
image views from before the path was kept stay unrendered.

The gateway copies inline tool media into its tool media store and lists the
copies under the item's `rcMedia` (`[{path, mimeType, name?}]`, `name` only for
a file the agent named); see
[system architecture](system-architecture.md#tool-media). Audio and embedded
MCP resources are not shown.

Opens and previews log to the `HostFiles` category at `.notice`: the request
(file type, link or image), fetched bytes and elapsed time, the presentation
chosen, Quick Look presentation and dismissal, and failures at `.error`. They
carry operation and lease tags and closed file/error classifications, never
paths, arbitrary filename extensions, server strings or content.

## Embedded files

Images, videos and `data:`/`blob:` links inside an HTML visual
([HTML visuals](html-visuals.md#webkit-sandbox)) have no host path. The visual
bridge reads their source through WebKit and passes the bytes as a bounded
base64 `data:` URL to `HostFileOpener.open(_:origin:frame:)`.
`EmbeddedFile` (Core) decodes it off the main actor, names it from the element's
`download`, `alt` or `title` text and its MIME type, and stages it in a private
temporary folder. The opener then presents it exactly like a downloaded file,
using the same reader, Quick Look and information/export policy, including the iOS zoom
from the tapped element. `OpenedFile` is either a host lease or that staged
copy; the copy is deleted when its last presenter releases it. Embedded HTML
never opens the interactive HTML viewer.

Each request names the surface that presents it: `HostFileOrigin.presentationScope`
is `nil` for the chat screen and the expanded visual sheet's own scope for opens
from that sheet. A presenter shows only the current request of its scope
(`HostFileOpener.presents(in:)`), so files tapped in the sheet present over it
and return to it, while other presenters and Mac windows sharing the host's
opener are unaffected. When the sheet's `HostFileNestedPresentation` disappears,
it ends the opener's request only if that request belongs to its scope.

## Transfer and ownership

`HostServices.files` owns one `HostFileStore` per physical host.
`GatewayFileDownloadClient` uses disk-backed URLSession downloads and that host's
`GatewayRoutes`, including verified pinned LAN and configured-route fallback
after transport failures. HTTP application errors do not retry over another
route. The gateway's [HTTP contract](../host-daemon-rs/README.md#file-downloads)
owns request, metadata, revision and failure semantics. Binary bodies never
enter the transcript, a base64 RPC response, or a whole-file Swift `Data` value.

The endpoint accepts distinct file-path and opaque visual-digest requests.
Ordinary files carry `path`, optional `knownRevision` and optional
`containingDirectory`; the latter restricts preview resources to the resolved
source directory before conditional validation. Inline visuals instead carry
`visualDigest` and optional `knownRevision`. The gateway alone knows their
storage layout and opens them no-follow with a fixed 2 MiB limit. Ordinary
files retain the fixed 1 GiB limit; neither form accepts a caller-selected
byte limit.

Concurrent reads of the same path wait for the preceding acquisition to finish
before revalidation, so an automatic preview cannot make a tap fail as busy.
The store admits at most 24 cancellable path waiters; overflow reports busy.

Each successful acquisition returns a `HostFileLease` over immutable local
bytes with the original filename, remote metadata and download date. The
preview, information surface and native share/export controller retain the
opened-file owner; its final release returns the lease to the store. Refreshing
a path creates a separate revision rather than replacing a file in use.
Cancellation and host retirement fence publication and clean partial work.

The cache survives app relaunch under `Caches/RemoteCoder/RemoteFiles/`, scoped
by host, store generation and revision acquisition. Completed entries keep an
atomic `record.json` beside `original/<original filename>`. The record carries
remote metadata, download/access dates and an endpoint/credential fingerprint;
it never stores the raw bearer. Startup validates completed records and file
sizes, removes partial/invalid entries, and admits only matching source
identities into the host's store.

`HostFileDiskBudget` enforces a global 512 MiB/256-entry unheld LRU across hosts,
a 2 GiB retained-plus-in-flight working set, two simultaneous transfers and
64 MiB of free-space headroom. Pinned files can exceed the unheld cache budget;
a file above that budget is removed after its final release. Host endpoint or
credential changes invalidate the old source association. Removing or
reconfiguring a host retires its cache without deleting files still held by a
viewer or export.

Every ordinary open revalidates the saved revision with the source. A failed
request can offer **Open saved copy**, showing its download date and that the
original could not be verified. It never silently substitutes cached bytes as
current. Temporary host paths may disappear before the first download, and
cache eviction or OS cache cleanup can remove saved copies. Save to Files is the
durable user export; the cache is not permanent attachment retention.

## Presentation and export

One open operation is active per chat screen. A new tap cancels its predecessor;
leaving the conversation invalidates pending presentation. Fetch first, show a
delayed cancellable status surface in the chat, then present one viewer. The
status surface (`HostFileStatusBar`) is a pill in a bar below the chat header,
so it never covers header controls or transcript content. Unknown byte totals
remain indeterminate, and fast downloads do not flash a loading sheet.

| Content | Presentation |
| --- | --- |
| UTF-8 Markdown within 2 MiB and the 4000-block reader budget | Shared rendered Markdown, selectable text and Source view |
| HTML, HTM and XHTML | Shared interactive WebKit preview, selectable text, zoom and Find |
| Text, source, PDF, images and other types accepted by Quick Look | Native read-only Quick Look |
| Unsupported types, other active web formats, or unavailable custom preview | File information with Save to Files and Share |

`HostFileReader` reads and prepares Markdown off the main actor. Before parsing,
its conservative work budget admits at most 32768 logical lines, 4000 estimated
structural units and 16384 markup punctuation scalars; documents containing
triple backticks or tildes are limited to 128 KiB. Preflight checks cancellation
while scanning. Documents outside these limits still use native preview or the
information/export surface, with their original bytes unchanged. Plain or
hard-wrapped prose can still use the full 2 MiB source budget. A file that
cannot be read or rendered is a failure, not an absence of reader content: the
sheet reports it with the file's reference and offers Try Again.

The shared renderer joins hard-wrapped prose, preserves blank paragraphs and explicit hard
breaks, and exposes semantic heading levels. Consecutive `>` lines form one
quote block. Numbered lists, plus bullets and thematic/setext markers keep their
existing line boundaries even where the renderer has no specialized block
representation. The reader is
top-anchored with bounded source and block counts. Large or non-UTF-8 Markdown can use Quick Look
when permitted and supported; it remains exportable when no preview is usable.

`HostHTMLPreview` uses SwiftUI WebKit's `WebPage` and `WebView` on iOS, iPadOS
and macOS. The sheet retains its opened-file owner and keeps Save and Share
available, including after a preview failure. A dated saved copy uses the same
viewer and retains its warning. HTML has no separate preview-size cutoff beyond
the existing transfer and storage budgets. `showOptions` always opens file
information instead of starting another preview.

`HostHTMLDocument` gives each opened document a separate
`host-file-preview` origin with their remote paths as logical paths. The custom
`URLSchemeHandler` streams immutable leased bytes in 64 KiB chunks off the main
actor. Relative CSS, scripts, images, fonts, frames and data requests acquire
their own leases through the same host's `HostFileStore`; query parameters do
not become part of a filesystem path. The original opened document retains
its exact bytes for Save and Share. Leases for supporting resources are
released when their stream completes or is cancelled.
Supporting-file acquisition runs serially per viewer, with at most 128 waiting
requests, so a page's resource burst does not exhaust the transfer slots.

The HTML viewer uses normal WebKit execution and resource behavior, including
JavaScript, network requests, forms and frames, with an ephemeral website store.
It adds no content blocker or content security policy. Origins belong to one
document lease; separate documents cannot share browser state.
The scheme handler exposes only files within the source document’s folder, after
normalized-path admission. Supporting-file download requests carry that folder
to the gateway, which resolves symlinks, checks canonical containment and opens
through directory descriptors without following replacement symlinks. Each request
is validated on the host even when the local cache has the same revision.
Supporting-file responses grant no cross-origin read access. WebKit's standard
platform permission and web-origin behavior still applies. No gateway
credential is injected into a page.

Anchors and HTML navigation within the source folder stay in the web view.
Outside-folder host requests and links are rejected. Absolute `file:` hyperlinks
are normalized to the opened document's origin for clicks and native link actions.
Explicit links to non-HTML
host files use `HostFileOpener`; mail and telephone links use system URL
handling. New-window requests load in the same viewer. Link previews and
back/forward gestures are enabled alongside native selection, zoom and Find.
JavaScript alerts, confirmations and text prompts use native dialogs, and file
inputs use the system picker, retaining selected files' security-scoped access
until the viewer closes. The viewer owns scrolling and stops when
dismissed; pending and late dialogs are cancelled and loading errors remain visible
with Try Again for the failed destination, including after the initial load.
Native toolbar controls keep an opaque app background so their
contrast does not depend on the HTML page's colors.

Other active web formats remain information/export. Quick Look owns its native toolbar and internal rendering
errors. After dismissal the same pill names the last opened file and opens
app-owned Save and Share until it is dismissed, so a failed native preview does
not prevent export.
Do not infer successful rendering from `canPreview` alone.

On iOS the presenter shows Quick Look `.overFullScreen`. A `.fullScreen` UIKit
presentation removes the chat's hosting view from the window, SwiftUI reports
that as the chat disappearing, and `ChatRootView` detaches its window model,
which tears down the presenter and re-presents the still-open file in a loop.

Sharing hands the original local file to a SwiftUI `ShareLink`. Save to Files
uses `fileExporter` with copy semantics and announces success only from its
completion callback; a failure raises an alert. Cancelling is not a successful
save. Neither export path rewrites the original through a preview conversion.

## Verification boundaries

`StreamingRenderingTests` covers paragraph boundaries, hard breaks, streaming
chunk equivalence and settled-block reuse. File-reference, transfer/store and
opener tests cover their separate ownership boundaries. `HostHTMLDocumentTests`
checks remote link mapping and source-host origins; `HostHTMLWebKitTests` loads real
leased bytes in WebKit, checking embedded-image and style rendering, script execution and
network loading, local supporting files, forms, filters, anchors, clicked links,
native dialog responses, unchanged original bytes and navigation failure/retry.
The live
`gateway-e2e-files-live` probe covers HTTP bytes, metadata and provider-generated
links; its fixtures and retained conversations support phone acceptance.

Build, install, successful transport and provider output do not prove Quick Look
rendering, native export, or accessibility. Physical acceptance must check
actual exported bytes, Markdown relative links, unknown-file export, source
failure with an explicitly dated cached copy, repeated taps, navigation during
download, app relaunch, and VoiceOver focus and heading navigation.
