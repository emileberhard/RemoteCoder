# Mermaid diagrams in conversations

## Decision and research (2026-09-20)

Use the **official, offline Mermaid 12.0.0 runtime**, a single short-lived WebKit
rendering session, native image previews, and a vector-only expanded viewer.
Do not turn every fenced block or message into a web view.

The research preceded implementation and included actual implementation sources,
not only package descriptions:

| Approach reviewed | Useful ideas | Decision |
| --- | --- | --- |
| [BeautifulMermaid Swift](https://github.com/lukilabs/beautiful-mermaid-swift), `6a23a29e` | Native Core Graphics/CALayer rendering, restrained two-color themes, image and SVG outputs | Attractive, but its six diagram families and independently maintained parser are not a general replacement for arbitrary assistant-generated Mermaid. No dependency added. |
| [GMarkdown](https://github.com/GIKICoder/GMarkdown), `c235d3a8` | Bundled iOS Mermaid and a separate diagram browser | Reuse the offline/browser separation concept, not its deprecated `mermaid.init`, source-string interpolation, private file-access preferences, or relaxed security. |
| [Streamdown](https://github.com/vercel/streamdown/tree/main/packages/streamdown/lib/mermaid), `6b14de42` | Deferred visible rendering, source/error recovery, normalized SVG dimensions and full-screen pan/zoom | Adopt those interaction ideas. Do not silently retain an obsolete valid diagram after a later final source fails. |
| [Official Mermaid API](https://mermaid.js.org/config/usage.html) | Complete supported grammar, `render` returning SVG, security configuration | Bundle the full IIFE, initialize explicitly, pin its bytes, pass source as data. No tiny build that silently omits families. |

The 12.0.0 archive was published September 10, more than 48 hours before adoption.
It costs **5,575,485 uncompressed bytes** for the JS runtime. This is an intentional
bundle-size trade-off for compatibility, offline operation and one upstream parser.
No new Swift package dependency or gateway endpoint is needed. Dagre is the host's
layout choice; diagrams cannot reconfigure the rendering environment.

### Apple and Swift guidance read

- [WebPage](https://developer.apple.com/documentation/webkit/webpage), its
  configuration, navigation decisions, JavaScript arguments, and image export:
  headless native WebKit control rather than a UIKit wrapper for every row.
- [WebView](https://developer.apple.com/documentation/webkit/webview-swift.struct):
  native SwiftUI integration and system magnification gestures for the viewer.
- [UIViewRepresentable](https://developer.apple.com/documentation/swiftui/uiviewrepresentable):
  considered; no bridge is necessary for the chosen architecture.
- [View task identity/cancellation](https://developer.apple.com/documentation/swiftui/view/task(id:name:priority:file:line:_:))
  and [scroll visibility](https://developer.apple.com/documentation/swiftui/view/onscrollvisibilitychange(threshold:_:)):
  only visible complete diagrams request rendering; stale tasks cannot publish.
- [The Swift Programming Language: Concurrency](https://docs.swift.org/latest/documentation/the-swift-programming-language/concurrency/):
  actor isolation is not background computation, and task cancellation is
  cooperative. File reads use `@concurrent`; WebKit does JS/layout out of process.
- [Apple HIG: Charts](https://developer.apple.com/design/human-interface-guidelines/charts):
  prioritize the content, preserve meaningful labels, provide descriptive
  accessibility and make the compact preview a large, easy-to-target control.

A standalone GUI test host probe verified headless WebPage image export with the actual
runtime before integrating it. It also caught an important integration detail:
the unmodified IIFE must execute as a **global script**, not a `callJavaScript`
function body. The app installs it as a `WKUserScript` without weakening CSP.

## Ownership and data flow

1. `MarkdownRendering` recognizes explicit, case-insensitive `mermaid` fence info
   strings on its existing serial worker. Backticks and tildes, opening length,
   legal indentation and matching closing fences are respected. Other code blocks
   remain code. No regex, Mermaid parsing or syntax highlighting runs in a view.
2. An open fence during streaming is a quiet **Diagram is being written** card.
   A closing fence is stable immediately, even while later prose continues. At
   terminal state, an unclosed fence gets a render attempt instead of spinning
   forever. Invalid syntax remains a visible error plus copyable source.
3. `MermaidDiagramView` requests work only while visible. Its `.task(id:)` includes
   source, appearance, contrast and retry identity. Publication checks cancellation
   after rendering and after image preparation. Presentation also matches the
   current source/appearance before allowing expansion, even before a replacement
   task starts. Inactive scenes retain the preview; background scenes and hidden
   rows release the decoded bitmap. A separate 256-entry aspect-ratio LRU reserves
   the height across bitmap eviction and remounting. The spinner appears after
   200 ms; the prepared image fades in.
4. `MermaidRenderer` coalesces equal requests and drains distinct requests serially.
   Admission retains at most 16 queued requests plus one active request and 64
   subscribers across them. Excess admission reports a transient busy state;
   **Try again** retries without retaining that rejection in the result cache.
   Each subscriber owns a cancellation handle. Queued abandoned work is removed;
   cancelling one subscriber never cancels another. An active JS operation may
   finish, but cannot publish to a cancelled subscriber or start parallel pages.
5. The batch-scoped rendering session owns one `WebPage`. It is released when the
   queue drains. The memory-only LRU caches at most **32 results / 24 MiB**, keyed
   by source, light/dark and increased-contrast state, including syntax failures.
   There is no diagram disk cache, transcript mutation, backend call or poller.
6. WebKit returns an SVG plus its intrinsic dimensions, title and description. A
   native image snapshot has its longest side bounded to **640 points** at device
   pixel density. Source is limited to **32 KiB**, edges to **250**, output SVG to
   **2 MiB**, and each intrinsic dimension to **20,000**. These are input/output
   resource guards, not a promise of a hard wall-clock timeout for JavaScript.
7. Only **Expand** presents a SwiftUI `WebView`. It receives the finished SVG, not
   the 5.6 MB renderer. The system owns pinch/pan; Fit reloads only that lightweight
   document. The source and image share/copy controls remain native. The expanded
   illustration is a snapshot of the source/appearance the person opened.

The existing `RenderedMessageStore`, 50 ms publication deadline, streaming block
fade and conversation identity remain authoritative. Mac native virtualization
retains the source/diagram choice in the logical row's presentation state and
pins a host while its expanded viewer is open. Preview resources still follow
the renderer's existing cache and visibility contracts; iOS keeps its eager layout.
Illustrations themselves are static: SVG animation elements and CSS animations
are disabled, including in the expanded viewer.

## Security and supported scope

- All resources are bundled and integrity-pinned. `loadsSubresources = false`,
  a nonpersistent data store, a restrictive CSP, and a navigation policy are
  independent defenses. No remote fonts, images, CDN requests, links or popups.
- User text is an argument to a fixed native JavaScript call, never interpolated
  into executable code or the HTML bootstrap. Mermaid uses `securityLevel: strict`;
  source directives cannot override the host's security, size, theme or layout
  policy. Event attributes, script elements, navigable anchors and SVG animations
  are removed before saving the vector result.
- Embedded media and external-image diagrams fail explicitly with source recovery;
  they are not silently rendered with missing images. External icon packs are not
  registered. This is a local illustration renderer, not the Mermaid Live Editor
  or a browser for author-provided HTML.
- Full-screen web content has page JavaScript disabled and the same offline and
  navigation restrictions. Share exports a PNG, not potentially active HTML/SVG.
- Mermaid `accTitle` and `accDescr` become native preview accessibility metadata;
  the expanded SVG retains its semantics. A source view is always available.
  Controls use Dynamic Type, 44-point targets and the app's haptic modifiers.
  Author-provided diagram labels are not reflowed by changing Dynamic Type; use
  the full-screen vector zoom or scalable source text to read dense diagrams.

## Verification

`MermaidMarkdownTests` covers fence boundaries, streaming completion, Unicode,
multiple diagrams, and unchanged non-Mermaid code. The Core `MermaidQueueTests`
cover serial/coalesced work, cancellation, admission limits, cache
identity/eviction/limits and retry without an app host or WebKit.
`MermaidWebKitTests` runs the **bundled runtime and real headless WebKit** against
14 diagram families, light/dark and accessibility metadata, malformed syntax,
source injection and attempts to enable navigation.

`MermaidDiagramUITests` opens a DEBUG-only, opt-in, offline fixture through
`-mermaid-preview-fixture`. It uses the production Markdown parser, ChatBubble and views,
not a screenshot-only replacement. Tests cover inline source/copy, vector zoom,
Fit, dark appearance, accessibility text size, streaming completion, invalid
source recovery and wide diagrams in landscape. Screenshots are retained in
`.xcresult` attachments. No prompt, command, or call is submitted.

For changes affecting Mermaid rendering or its UI, use the relevant explicit
GUI test host simulator suites. These are outside standard verification:

```sh
just ios-simulator-test RemoteCoderTests/MermaidMarkdownTests \
  RemoteCoderTests/MermaidWebKitTests
just core-test MermaidQueueTests
just ios-ui-test RemoteCoderUITests/MermaidDiagramUITests
just install-dev
```

Wait for document loading and landscape geometry before UI interaction.
Whole-screen captures avoid XCTest's rotated application-crop artifact.
Run logs and receipts stay outside source control. Physical VoiceOver and
tactile acceptance remain separate from simulator evidence, and device
installation requires its own source-scoped receipt.
