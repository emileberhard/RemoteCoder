# Link chips

Links wherever `MarkdownBlockView` renders (assistant messages and Markdown
files in the file viewer: paragraphs, headings, lists, quotes and tables) draw
as rounded chips: a faint capsule, a leading site icon or symbol,
and a semibold label in the tint color. They stay ordinary Markdown links, so
taps, the context menu's text selection and VoiceOver keep their existing
behavior.

## Decision (2026-10-19)

Goals: any link looks intentional and recognizable without per-site code; the
transcript keeps its streaming, scrolling and energy invariants; no request
reveals what the user linked to.

- **Rendering: one `Text` plus a `TextRenderer`.** `InlineMarkdownText` composes
  each chip as a kerned non-breaking slot for the icon, then the semibold label,
  both carrying `.link` and a `LinkChipMark`. `LinkChipRenderer` fills capsules
  behind each chip's runs per line, draws the lines, then draws icons into the
  slot runs. The slot needs its own mark: SwiftUI can hand the renderer a chip's
  runs in separate passes, so "the chip's first run" is not a stable slot (a
  single-segment version drew one icon per run on the iPad). Wrapping,
  selection, link hit-testing and accessibility remain SwiftUI's.
- **Classification lives in Core.** `LinkChip` classifies a URL with the same
  `HostFileLink` rule the file opener uses, so a chip's icon never promises a
  different action from its tap. `annotatingLinkChips()` marks link runs once,
  in the render actor's existing Markdown pass, and shortens bare URL labels to
  `site[:port]/…/last-two-segments[#fragment]`.
- **Icons are generic.** `SiteIconStore` fetches `LinkMetadata` for the site
  root `https://<host>/`, never the linked URL, so private paths, signed links
  and side-effecting endpoints are never requested. Only public-looking hosts
  qualify; IPs, single labels, `localhost`, `.local`, `.ts.net` and similar get
  a globe.
- **Rejected alternatives.**
  - Whole-message HTML: a web view per message breaks the eager iOS transcript
    and Mac virtualization budgets, and loses native selection.
  - Splitting paragraphs into views around each chip: breaks line wrapping and
    selection across the chip.
  - A per-site icon catalog: maintenance with no coverage for new sites.
  - Fetching the linked page: leaks private URLs and can trigger actions.

Becomes expensive if: `TextRenderer` stops receiving custom attributes on link
runs, or a future SwiftUI changes link hit-testing for kerned runs. Either one
falls back to plain links by removing the renderer, without touching Core.

## Ownership and bounds

- `SiteIconStore` (one per workspace, injected as `\.siteIcons`) owns the
  in-memory entries (at most 384, LRU over idle entries), the fetch queue (32,
  oldest dropped), two concurrent fetches, and the backoffs: 10 minutes after a
  failure, 24 hours when a site has no icon, refresh after 30 days.
- `SiteIconDisk` keeps at most 256 64-pixel PNGs in the caches directory's
  `RemoteCoder/SiteIcons/`, newest first; unreadable files are deleted on load.
  All of them load at launch so known icons never flash a globe; decoding goes
  through `ImagePreparation`.
- A row requests its hosts 700 ms after it appears, so fast scrolling does not
  fetch; a partial host in a streaming tail that pauses longer can be fetched
  once. Each host's `SiteIcon` is observed alone, so an arriving icon redraws
  only the rows showing that host.
- Backgrounding and workspace teardown call `stopFetching()`, which cancels
  fetches and clears the queue; rows request again when they next appear.
- Accepted limits: a host dropped from a full queue, or an idle entry evicted
  while its row stays mounted, shows a globe until that row remounts. Avoiding
  it needs per-row observer tracking, and eviction needs over 384 hosts.
- The Mac row host forwards the store's identity in `TranscriptHostEnvironment`.

## Known gaps

- On the Mac, a drag selection's plain text holds each chip's short label after
  one non-breaking space; its rich text keeps the hyperlinks, and the message's
  Copy action keeps full URLs.
- User messages with pasted-text attachments render through
  `InlineMessageText` and keep plain links.
- `rc-visual:` links inside prose get the generic link symbol; tapping them
  still does nothing, as before.
