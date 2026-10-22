# Repository and branch model

RemoteCoder owns the app, gateway, protocol integration, runtime packaging and
public contributor tooling. `main` is the canonical default branch. The exact
approved Codex source and runtime identity lives in
[`codex/compatibility.json`](codex/compatibility.json); a newer upstream or fork
commit is not automatically approved.

## Source and operations

Original RemoteCoder code uses the root license. Required forks and bundled
third-party components keep their upstream licenses and attribution; see
[`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md). Keep a narrow, reviewed
Codex patch set and public source/package closure for the pinned runtime.

Private operator configuration, host service inventory, signing, fleet delivery,
upgrade skills and acceptance receipts belong to the private
[RemoteCoder-deploy operations entrypoint](https://github.com/emileberhard/RemoteCoder-deploy/blob/main/AGENTS.md).
Public builds must not require a maintainer's dotfiles, named machines or private
services for basic chat. Optional integrations need explicit configuration.

## Codex source

The public Apache-2.0 [Codex fork](https://github.com/emileberhard/codex) owns
the narrow integration patch set; [OpenAI upstream](https://github.com/openai/codex)
remains the design authority. Both source repositories use `main`. Build the
exact pinned source through the [runtime bootstrap](codex/runtime.md); a newer
fork `main` is not automatically approved. Operator acceptance stays private.

## Runtime changes

1. Inspect the exact source revision and protocol changes against the approved
   revision. Preserve upstream behavior unless a demonstrated integration
   requirement needs a focused difference.
2. Build the matched runtime package through the owning builder. Never distribute
   a bare executable without its matching code-mode host and manifest.
3. Validate the package with `just codex-runtime-approve <package>` and run the
   affected protocol tests and an isolated stored-history compatibility probe.
4. Land the reviewed source and integration pins on their canonical branches.
   Maintainer deployment follows the private transaction, canary and acceptance
   workflow. A successful build does not prove deployment or acceptance.

## Public history and hygiene

The public repository begins with a curated source snapshot. Private legacy
history, branches, tags, notes, live screenshots and operational receipts stay
in the private archive. Never mirror, merge or push that ancestry into the
public repository, including from an old worktree or clone.

Use short-lived branches and isolated worktrees. Preserve user changes and
remove only worktrees whose work is safely committed and no longer in use.
`AGENTS.md` is canonical at every instruction scope; its sibling `CLAUDE.md`
symlink is an adapter. Keep source versions and hashes in the compatibility
record rather than duplicating them through instruction files. Keep private
host acceptance evidence outside the public tree.

A release is a strictly increasing stable `X.Y.Z` tag on the pushed default
branch. That tag is every artifact's version. Public hosted CI and private
production deployment have separate authority and credentials.
