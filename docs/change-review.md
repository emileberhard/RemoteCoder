# Change review

Change review shows what changed in the checkouts a conversation worked in, or
what its last turn with edits changed anywhere on the host, and turns line
comments into one pasted block in the composer, so the user can review an
agent's work and answer it without leaving the chat. On iPhone and
iPad it is a sheet opened from the header's diff button; on the Mac it is the
inspector's Changes mode (⇧⌘D, the toolbar's Changes button or the command
palette).

## Comparisons

`changes/read` takes an absolute `directory` and a `source`:

| Source | Compares | Includes untracked files |
|---|---|---|
| `uncommitted` | `HEAD` (or the empty tree before the first commit) with the working tree | yes |
| `staged` | `HEAD` with the index | no |
| `unstaged` | the index with the working tree | yes |
| `branch` | the merge base with the default branch with the working tree | yes |

The default branch is `origin/HEAD`, then `origin/main`, `origin/master`,
`main` and `master`, each compared by its full ref name; the snapshot's `base`
is the short name for display. A read answers `ready` with a snapshot or
`unavailable` with a reason (`missingDirectory`, `notRepository`,
`noBaseBranch`, `noMergeBase`). Only Git's "not found" exit status means
absent; every other Git failure is an RPC error. The app shows each as its own
state, never as an empty comparison.

## Checkouts

A conversation's folder is often not the repository its agents changed: a
folder of repositories such as `~/stretch`, or a main checkout while agents
edit worktrees. `changes/checkouts` (`{threadId?, directory}`) finds the
candidates without running Git:

- It reads the conversation's newest ten history pages and, at the same time,
  five pages of each of its 16 most recently active same-host child agents,
  four agents at a time, keeping only folder paths. Each completed
  `fileChange` path's folder (and move target) is `edited` evidence and each
  command's `cwd` is `command` evidence.
- A folder's checkout is the nearest ancestor holding `.git` (directory or
  file), so worktrees and submodules stay separate. Folders that no longer
  exist are skipped.
- `workedIn` lists up to 16 checkouts, most recently observed first. A
  working folder inside a checkout adds `workingFolder` evidence; a working
  folder that is not a checkout lists its direct child checkouts the agents did
  not work in as `inFolder` (up to 64, from its first 4,096 entries).
- `complete` is false when history or an agent could not be read, the agent
  list was incomplete, or a list was cut at its limit.

The app reads the first `workedIn` checkout with `edited` evidence, else the
first one, else the working folder, and shows every candidate in the
comparison menu. Opening or refreshing the review finds the checkouts again,
so the default follows the latest edits; switching comparisons reuses the
last answer. A chosen checkout stays selected while the review lives. When
discovery fails, the menu says so and the review reads the chosen checkout or
the working folder.

## Last turn

`changes/turn` (`{threadId}`) answers from the agents' own edit records, so it
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
- A comment is anchored to its comparison (a Git source, or the turn by id
  and start time, which names it in the prompt),
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
- Checkout discovery reads history and the filesystem only: no Git process,
  branch names or dirty filtering, so it stays cheap enough to repeat on every
  refresh.
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
