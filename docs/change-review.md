# Change review

Change review shows what changed in the checkouts a conversation worked in, or
what the conversation's own turns changed anywhere on the host, either its last
turn with edits or every turn since a chosen point, and turns line
comments into one pasted block in the composer, so the user can review an
agent's work and answer it without leaving the chat. On iPhone and
iPad it is a sheet opened from the changes pill above the composer; on the Mac
it is the inspector's Changes mode (the changes pill, ⇧⌘D, the toolbar's
Changes button or the command palette).

## Comparisons

`changes/read` takes an absolute `directory` and a `source`:

| Source | Compares | Includes untracked files |
|---|---|---|
| `uncommitted` | `HEAD` (or the empty tree before the first commit) with the working tree | yes |
| `staged` | `HEAD` with the index | no |
| `unstaged` | the index with the working tree | yes |
| `branch` | the merge base with the branch’s start point with the working tree | yes |

Branch reads HEAD's full branch ref and streams its reflog newest first, up to
1 MiB, stopping at the first `branch: Created from` or `branch: Reset to`
entry. A surviving named ref other than HEAD's own branch is the base. For
`HEAD`, `@`, a commit, an expression or a deleted ref, the entry's commit and
the default branch compete: the merge base leaving fewer commits ahead of
HEAD wins, with the default winning ties. A commit base is shown as an
abbreviated hash. `reset: moving to` entries are ignored.

Without a start point, including detached HEAD, the default branch is
`origin/HEAD`, then `origin/main`, `origin/master`, `main` and `master`, each
compared by its full ref name. The snapshot's `base` is its display name. A
read answers `ready` with a snapshot or `unavailable` with a reason
(`missingDirectory`, `notRepository`, `noBaseBranch`, `noMergeBase`). Only
Git's "not found" exit status means absent; other Git failures are RPC errors.
The app shows each as its own state, never as an empty comparison.

## Checkouts

A conversation's folder is often not the repository its agents changed: a
folder of repositories such as `~/stretch`, or a main checkout while agents
edit worktrees. `changes/summary` (`{threadId, directory}`, both required,
absolute directory, unknown fields rejected) discovers candidates and counts
them under one change-reader admission. An optional `source` of `uncommitted`,
`staged` or `unstaged` counts every checkout in that comparison instead;
`branch` is rejected, because omitting `source` already selects the summary's
own rule below. Older apps retain `changes/checkouts`
with its discovery-only reply.

- Discovery reads the conversation's newest ten history pages and, at the same
  time, five pages of each of its 16 most recently active same-host child
  agents, four agents at a time, keeping only folder paths. Completed
  `fileChange` paths and move targets provide `edited` evidence; commands
  provide `command` evidence.
- A command's folder is its `cwd`, except a leading literal `cd` to an
  unquoted absolute path, `~` or `~/…`, followed by `&&`, `;`, newline or end.
  Home expands from the gateway's HOME, read once; `.` and `..` normalize
  lexically. Relative paths, shell expansions, quotes, escapes, globs and
  other shell operators do not qualify. Codex's wrapped shell strings keep
  their recorded workdir.
- A folder's checkout is the nearest ancestor holding `.git` (directory or
  file), so worktrees and submodules stay separate. Missing folders are skipped.
- `workedIn` lists up to 16 checkouts, most recently observed first. A working
  folder inside a checkout adds `workingFolder` evidence. A working folder
  outside any checkout lists its unworked direct child checkouts in `inFolder`
  (up to 64, from its first 4,096 entries).
- `complete` is false when history or an agent could not be read, the agent
  list was incomplete, or a list was cut at its limit.

Each worked-in checkout is read sequentially with header-only patch budgets.
Its flattened outcome is `ready` with a snapshot, `unavailable` with a reason,
or `failed`. Git errors are logged with the checkout root and fail only that
checkout. A 20-second deadline after admission includes discovery and all
checkout reads; unfinished checkout reads become failed. Discovery exceeding
the deadline fails the request because no completed checkout inventory exists.
Per-file hunk omissions in these snapshots are expected and used only for counts;
review always reads its own full patches.

The summary reads Branch, except it reads Uncommitted when the base ref is
HEAD's own branch or a remote-tracking ref of the same branch name. Branch
unavailability from a missing base or merge base also falls back to
Uncommitted. Upstream tracking alone never identifies a base checkout: a new
feature worktree can track `origin/main` too.

## Changes views

Each conversation has one changes view, which the pill counts and the review
opens on: Branch (the default), another Git comparison, Last Turn, or Since a
start point. The gateway stores it in the conversation's marks
(`changesView`, schema 4), so it syncs across the user's devices; Branch is
stored as absence. The view changes only when the user picks one, from the
review's comparison menu, the pill's context menu (hold on iOS, secondary-click
on the Mac), or a reply's Count Changes from Here. A gateway with an older marks schema offers no views: the pill and
review keep their Branch-first behavior and the conversation entries are hidden.

- A start point is a turn boundary: the start of a turn (a prompt) or the end
  of a turn (after its final reply). Count Changes from Here uses the end of
  the chosen turn. Start From Now asks the gateway for the conversation's
  newest turn (`thread/turns/list`, one turn) when chosen and uses its end, so
  a transcript scrolled back or a stale inspector cannot pick an older turn.
  The Start From submenu lists the six most recent loaded prompts that started
  a turn, by their first line and time.
- Count Changes from Here appears in a reply's Fork group, only on the final
  reply of a completed turn, and not on the current start point.
- A non-Branch view names itself in the pill and keeps the pill visible at zero,
  so a fresh start point shows as Since 14:05 with no changes. Branch keeps the
  hide-at-zero rule. A Last Turn or Since read that could not cover the
  conversation's history in full and found no edits shows the view's name
  without a count, never zero. When the start turn is no longer in the
  conversation's history, the pill shows Start Not Found and the review offers
  Branch.

## Changes pill

The pill counts the conversation's view. For Branch it sums files across all
worked-in checkouts, including committed branch work, until that work is
merged into its base. Core prepares each checkout's
`ChangeTotals?`, the sum and the primary checkout off the main actor. File
counts add over known checkouts; line totals are shown only when every
checkout and file has known counts. An unavailable or failed checkout remains
unknown, and other checkouts still contribute. The primary is the first
worked-in checkout with known changed files and carries its snapshot's source.
A New Chat without a conversation has no pill.

`ChangeSummaryModel` owns one summary for the screen's conversation and folder.
It reads the stored view from the conversation list; Git views make one
`changes/summary` call per refresh and Last Turn and Since make one
`changes/turn` call. It publishes the pill's content, visibility, the current
start turn and the prepared summary only when they change. The pill reads only
its content; the transcript reads only visibility and the start turn. While it
refreshes it observes the conversation's effective view (acknowledged marks
plus pending changes), so any change to it, from this device, another device or
an acknowledgement, restarts the read at once.

- Refreshes happen on appear, non-replay file-change and command completions,
  turn completion, activation and reconnect, for the shown conversation and
  its listed agents. Only visible screens in active scenes request them;
  backgrounding cancels a running read. One read runs at a time, followed by
  ten quiet seconds, and intervening demand coalesces into one further read.
- A request failure retains the last summary and logs the error. An old
  gateway's MethodNotFound clears the pill and logs once per model; later
  refreshes can discover an updated gateway.
- The review shares the screen's summary and performs no separate discovery,
  except when it opens a Git comparison before the screen has any checkout
  inventory, such as after a Last Turn or Since view: it then reads one summary
  itself to start on the primary checkout instead of the working folder. Each
  reopening starts on the stored view. For Branch it starts on the primary's
  checkout and comparison; without a primary it opens Branch on the first
  worked-in checkout, else the working folder. Choosing a comparison stores it
  whenever it differs from the stored view, including Uncommitted when Branch
  already falls back to it. Selection stays fixed during refresh; refresh also requests a new
  summary. The checkout menu shows each worked-in checkout's file count,
  No changes or Couldn't read, plus in-folder candidates and incomplete coverage.
- Opening the review reads full patches again, so its state can be newer than
  the pill. On the Mac the toolbar's Changes button and ⇧⌘D also remain available.

## Last turn

`changes/turn` (`{threadId, since?}`) answers from the agents' own edit records, so it
works outside Git and across checkouts. It finds the newest of the last 20
turns whose window contains a completed `fileChange`: the conversation's own
items of that turn, or a same-host child agent's items between the turn's start
and the next turn's start (or now). Codex records each edit's hunks, with any
`Moved to:` note removed; Claude `Edit` and `Write` results carry a
`structuredPatch` or the created content, which the translator renders into
the same `diff` field. A record without content, such as `NotebookEdit`, has
a null `diff`; its file is counted in `unlistedFiles`, never shown as
unchanged.

- Turns are read newest first with ten item pages shared between them. Each
  child agent active since the examined turn started is read back only as far
  as that turn's start, five pages at most per agent and four agents at a time,
  so a latest turn with edits costs about one page per active child. The turn
  list and the agent list are read at once. The edits kept while reading are
  capped at 32 MiB. A turn without a start time ends the walk, since child
  agents' edits can't be placed around it. `complete` is false when a window
  up to the answer could not be read in full, a child edit has no time, the
  cap was reached or the walk ended early.

- Each file is shown relative to its checkout, or to its folder outside one,
  as one Git-format patch. Several edits to a file without a move become one
  net diff: the gateway reverses the recorded hunks from the file's current
  content (UTF-8, at most 8 MiB) and diffs the two states with
  `git diff --no-index` on private temporary files. If the file no longer
  matches its records, each edit is shown as recorded. A file whose edits
  cancel out is left out.
- Commands' changes are not listed; `commands` counts the commands that ran.
  `omittedAgents` counts agents active since the turn started whose edits
  could not be read, such as Claude subagents, agents on other hosts or agents
  beyond the 16 most recent. `latest` is false when later turns made no edits.
- The read shares `PatchSplitter`'s budgets and the change reader's admission
  and timeout. Net diffs run four at a time and stream into the splitter in
  file order; `noRecentEdits` answers when no recent turn edited a file.

## Since a start point

`changes/turn` with `since: {turnId, boundary}` (`start` or `end`) counts
every turn from the start point to now with the same records, net diffs and
budgets as Last Turn, and answers `ready` with `since: {turnId, boundary,
atMs?}` and the number of `turns` in place of `turn`.

- The gateway pages the conversation's turn list newest first, 100 turns a
  page and five pages at most, until it finds the start turn; if it does not,
  it answers `anchorMissing` with `complete` false when the list was cut.
- A `start` boundary includes the start turn; `end` begins after it. Child
  agents' edits are placed by time from the start turn's start, or from one
  second after its completion (else the next turn's start) for `end`, so a
  reply's own edits never count after it. `atMs` is that time, absent while
  an `end` start turn is still running; such a range is empty and complete.
- The conversation's own turns share 40 item pages, read newest first;
  running out of pages makes the answer incomplete rather than wrong.

## Ownership and boundaries

- `host-daemon-rs/src/changes/` owns the read. It never writes the repository:
  untracked files become intent-to-add entries in a private copy of the index
  with a private object directory (`GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`
  with the repository's objects as an alternate). Every command runs with
  split index, shared-index expiry and fsmonitor off, and
  `GIT_OPTIONAL_LOCKS=0` keeps the read from contending with the user's Git.
  Untracked nested repositories are left out; an untracked file that
  disappears while it is added makes the read list them once more. Two
  `changes/*` requests run at once per gateway; each has 30 seconds including
  its wait for a slot, and blocking filesystem work keeps its slot until it
  finishes, even after its request is gone.
- What the read still shares with the user's own `git status`: configured
  clean filters run, so Git LFS can add objects to its `.git/lfs` cache;
  reading a split index refreshes the shared index's modification time; and a
  partial clone fetches missing blobs from its promisor remote, kept in the
  read's private object directory. Turning filters off would show unchanged
  LFS files as changed.
- Every Git process runs in its own process group. Cutting its output off, the
  timeout or a dropped request kills the group, including clean filters Git
  started; error output is drained to the end and its first 64 KiB kept.
- `PatchSplitter` splits `git diff` output at `diff --git`, `diff --cc`,
  `diff --combined` and `* Unmerged path` lines and counts added and removed
  lines after a section's first `@@` by the same prefix-column rule Core uses.
  Content lines always carry their prefix columns, so neither rule can misread
  file content. The only other patch reading in the gateway is Last Turn's
  net diff, which parses recorded hunks to reverse them onto a file's current
  content.
- Budgets: 256 KiB of patch per file, 4 MiB of patch text before later hunks
  are omitted, a 6 MiB hard cap including headers, 2,000 files and 256 MiB of
  Git output. A file over a hunk budget keeps its header and line counts and
  reports an omission (`fileTooLarge` or `responseBudget`) with its hunk size.
  A file whose header no longer fits, or that is past the file count, is
  counted in `unlistedFiles`. `complete` is false when Git's output was cut off
  or files are unlisted; a file whose hunks were omitted reports that itself.
- Invalid UTF-8 is replaced with U+FFFD, counted against the budgets after
  replacement, and the file reports `replacedInvalidUtf8`.
- Core's `UnifiedDiff` is the one patch parser: paths (including Git's quoted
  forms), status, mode changes, binary files, hunks with both line numbers,
  LF and CRLF lines, missing final newlines, combined conflict hunks and
  unmerged paths.
- `ChangeReviewPreparation` builds display rows off the main actor: syntax
  highlighting by file extension, word-level emphasis for paired removed and
  added lines, and hunk gaps. It parses at most 10,000 patch lines; later files
  are read for their header only and show the `responseBudget` notice. It stops
  when a newer read supersedes it. The summary shows total line counts only
  when every file's counts are known. Lines longer than 2,000 characters are
  cut with a visible count of the rest.
- `ChangeReviewModel` owns one review: its conversation, folder, gateway
  client, comparison, checkout, load task, collapsed files and comments. A
  newer read supersedes an older one by revision. The chat screen keeps the
  model while the conversation, its folder and gateway client stay the same,
  so closing and reopening the review keeps unsent comments. When any changes,
  an open review without written comments follows the conversation; one with
  written comments closes and is kept, so reviewing that conversation again
  restores them, until another review replaces it. Adding comments checks the
  destination again.
- A comment is anchored to its comparison (a Git source, the turn by id
  and start time, or the start point and its time, which name it in the
  prompt),
  its checkout or folder, path, side and line number. Comments whose line is
  not shown, after a refresh, in another comparison or in a file past the line
  limit, stay listed and editable in every state. The prompt groups comments by
  comparison and checkout, names the checkout, and quotes at most 200
  characters of each line. Adding comments
  goes through `ChatScreenModel.insertReviewComments`, which uses the
  composer's paste policy: a short block is inserted as text, a long one
  becomes a pasted-text attachment. The button is disabled where the
  conversation takes no input.

## Decision record

Goal: a fast, readable review of what an agent changed, on the phone first,
with a way to answer it. Constraints: the main actor only applies prepared
state, everything that grows is bounded, unknown stays unknown, and the gateway
stays a thin host boundary.

- Git stays the default comparison because it covers every source of change:
  shell commands, other agents and the user. Last Turn complements it with the
  agents' own records, which work outside Git and across checkouts but miss
  command edits, so it says how many commands ran instead of guessing.
- The pill follows ChatGPT for iOS 1.2026.286's hide-at-zero behavior for its
  default view. Its Branch comparison deliberately departs from ChatGPT's
  Unstaged: agents commit as they work, so Uncommitted and Unstaged erase
  useful counts. ChatGPT's reset-on-open was dropped: in a long conversation
  the user wants the pill to keep counting the comparison they chose.
- The view is one choice per conversation, stored with the other marks rather
  than per device, so the phone and the Mac count the same thing. Start points
  sit on turn boundaries because edit records and child agents can only be
  placed by turn and time; a point inside a turn would guess.
- Base checkouts use Uncommitted so another agent's unpushed commits on shared
  main do not become this conversation's work. Shared uncommitted edits and
  branch changes still cannot be attributed to one agent by Git. A checkout
  whose branch starts from its same-named remote also uses this exception.
- The latest branch creation or forced branch reset defines its start point;
  ordinary commit resets do not change that intent. Commit start points compete
  with the default to exclude upstream work after a rebase. Reflog expiry and
  detached HEAD use the default rule; this can temporarily broaden a comparison.
- One summary RPC owns discovery and sequential header reads, avoiding duplicate
  app discovery and full patch decoding just to count. Partial checkout failures
  preserve known counts. Command completions cover shell-only edits, with ten-second
  spacing limiting refresh cost. Old gateways show no pill until updated.
- Discovery itself reads only history and the filesystem; Git reads follow it
  inside the same bounded admission. The summary and review share discovery state.
- The gateway sends per-file patch text instead of a structured diff. One
  display parser in Core avoids two diff models and keeps the wire stable; the
  gateway still bounds sizes and counts lines for files it omits. Last Turn's
  net diff adds a deliberate second hunk parser in the gateway, limited to
  reversing recorded hunks. Without it a file edited several times would show
  each edit separately.
- The private index and object directory keep reads free of side effects;
  the gateway tests compare the whole `.git` directory before and after a read,
  with split index and immediate shared-index expiry. Intent-to-add still
  hashes nothing into the repository only because both stores are private: a
  change that drops either one writes into the user's `.git`.
- Staged conflicts come from Git's `* Unmerged path` notice, read raw. A
  filename containing a newline is shown cut at the newline; reading those
  paths NUL-delimited would cost another Git call on every read.
- Expanding hidden context, a split view and staging from the app are left
  out. Each needs a further RPC or a write path; add them when the read-only
  review proves insufficient.
