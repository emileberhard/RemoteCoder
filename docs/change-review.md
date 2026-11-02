# Change review

Change review shows the Git changes in a conversation's working folder and
turns line comments into one pasted block in the composer, so the user can
review an agent's work and answer it without leaving the chat. On iPhone and
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

## Ownership and boundaries

- `host-daemon-rs/src/changes/` owns the read. It never writes the repository:
  untracked files become intent-to-add entries in a private copy of the index
  with a private object directory (`GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`
  with the repository's objects as an alternate). Every command runs with
  split index, shared-index expiry and fsmonitor off, and
  `GIT_OPTIONAL_LOCKS=0` keeps the read from contending with the user's Git.
  Untracked nested repositories are left out; an untracked file that
  disappears while it is added makes the read list them once more. Two reads
  run at once per gateway; each has 30 seconds.
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
  file content. The gateway does not otherwise parse patches.
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
- `ChangeReviewModel` owns one review: its folder, gateway client, comparison,
  load task, collapsed files and comments. A newer read supersedes an older one
  by revision. The chat screen keeps the model while the conversation's folder
  and gateway client stay the same, so closing and reopening the review keeps
  unsent comments. When either changes, an open review without written
  comments follows the conversation; one with written comments closes and is
  kept, so reviewing its folder again restores them, until a review of another
  folder replaces it. Adding comments checks the destination again.
- A comment is anchored to its comparison, path, side and line number. Comments
  whose line is not shown, after a refresh, in another comparison or in a file
  past the line limit, stay listed and editable in every state. The prompt groups comments by
  comparison and quotes at most 200 characters of each line. Adding comments
  goes through `ChatScreenModel.insertReviewComments`, which uses the
  composer's paste policy: a short block is inserted as text, a long one
  becomes a pasted-text attachment. The button is disabled where the
  conversation takes no input.

## Decision record

Goal: a fast, readable review of what an agent changed, on the phone first,
with a way to answer it. Constraints: the main actor only applies prepared
state, everything that grows is bounded, unknown stays unknown, and the gateway
stays a thin host boundary.

- Simplest alternative considered: rendering the turn's own `fileChange`
  items. They miss changes from shell commands, other agents and the user, and
  older turns lose them; reading Git covers every source of change.
- The gateway sends per-file patch text instead of a structured diff. One
  parser in Core avoids two diff models and keeps the wire stable; the gateway
  still bounds sizes and counts lines for files it omits.
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
