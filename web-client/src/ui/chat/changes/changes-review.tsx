import { memo, useEffect, useMemo, useState, useSyncExternalStore } from "react";
import { addressKey, array, identifier, object } from "../../../protocol/boundary";
import {
  type ChangeFile,
  changeDirectories,
  type DiffLine,
  diffLines,
  readConversationChanges,
  reviewComment,
} from "../../../workspace/conversation-changes";
import type { ChangesView } from "../../../workspace/conversation-marks";
import type { Conversation } from "../../../workspace/conversation-session";
import { Dialog } from "../../design-system/dialog";
import { ReadStatus, useRead } from "../../remote-operations";
import { useRun, useWorkspace } from "../../workspace-context";

export const ChangesReview = memo(function ChangesReview({
  conversation,
  close,
}: {
  conversation: Conversation;
  close(): void;
}) {
  const workspace = useWorkspace();
  const run = useRun();
  const address = conversation.address;
  const schema = useSyncExternalStore(
    workspace.subscribe,
    () => workspace.conversationMarks(address)?.marks?.schemaVersion,
  );
  const savedView = useSyncExternalStore(
    workspace.subscribe,
    () => workspace.conversationMarks(address)?.marks?.threads[address.threadId]?.changesView,
  );
  const supportsViews = (schema ?? 0) >= 4;
  const [localView, setLocalView] = useState<ChangesView | null>(null);
  const view = supportsViews ? savedView : (localView ?? undefined);
  const identity = addressKey(address);
  const [transport] = useState(() => workspace.featureTransport(address));
  const cwd = conversation.header.cwd;
  const inventory = useRead(`${identity}:${cwd}:changes`, async (signal) =>
    changeDirectories(
      await transport.request("changes/summary", { threadId: address.threadId, directory: cwd }, { signal }),
    ),
  );
  const [selectedRoot, setSelectedRoot] = useState<string>();
  const directory = selectedRoot ?? inventory.value?.primary ?? cwd;
  const directories = [...new Set([...(inventory.value?.roots ?? []), cwd])];
  const effectiveView =
    !view && inventory.value?.sources[directory] === "uncommitted"
      ? { kind: "git" as const, source: "uncommitted" as const }
      : view;
  const read = useRead(JSON.stringify([identity, directory, effectiveView]), (signal) =>
    readConversationChanges(transport, address.threadId, directory, effectiveView, signal),
  );
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const unsubscribe = transport.subscribe((frame) => {
      if (!["turn/completed", "item/completed"].includes(frame.method ?? "")) return;
      const params = object(frame.params);
      if (
        params.threadId !== address.threadId ||
        (frame.method === "item/completed" && object(params.item).type !== "fileChange") ||
        timer
      )
        return;
      timer = setTimeout(() => {
        timer = undefined;
        inventory.refresh();
        read.refresh();
      }, 250);
    });
    return () => {
      unsubscribe();
      clearTimeout(timer);
    };
  }, [transport, address.threadId, inventory.refresh, read.refresh]);
  const [selectedFile, setSelectedFile] = useState<string>();
  const [annotation, setAnnotation] = useState<{ file: ChangeFile; line: DiffLine; comparison: string }>();
  const [comment, setComment] = useState("");
  const result = read.value?.status === "ready" ? read.value : undefined;
  const fileKey = (file: ChangeFile, index: number) => JSON.stringify([file.root, file.path, index]);
  const selectedIndex = result?.files.findIndex((file, index) => fileKey(file, index) === selectedFile) ?? -1;
  const index = Math.max(0, selectedIndex);
  const file = result?.files[index];
  const lines = useMemo(() => (file ? diffLines(file.patch) : []), [file]);
  const [lineLimit, setLineLimit] = useState(2000);
  const mode = view?.kind === "git" ? view.source : (view?.kind ?? "branch");
  const select = (view: ChangesView | null) => {
    if (supportsViews) run(() => workspace.selectChangesView(address, view));
    else setLocalView(view);
  };
  const startNow = () =>
    run(async () => {
      const response = await transport.request("thread/turns/list", {
        threadId: address.threadId,
        sortDirection: "desc",
        itemsView: "notLoaded",
        limit: 1,
      });
      const turn = array(object(response).data, 1)[0];
      if (!turn) throw new Error("This conversation has no turn to start from.");
      workspace.selectChangesView(address, {
        kind: "since",
        turnId: identifier(object(turn).id),
        boundary: "end",
      });
    });
  return (
    <Dialog title="Changes" close={close} wide>
      <div className="changes-toolbar">
        <label className="field">
          Compare
          <select
            value={mode}
            onChange={(event) => {
              const mode = event.target.value;
              if (mode === "branch") select(null);
              else if (mode === "lastTurn") select({ kind: "lastTurn" });
              else if (mode === "now") startNow();
              else if (mode === "uncommitted" || mode === "staged" || mode === "unstaged")
                select({ kind: "git", source: mode });
            }}
          >
            <option value="branch">Branch</option>
            <option value="uncommitted">Uncommitted</option>
            <option value="staged">Staged</option>
            <option value="unstaged">Unstaged</option>
            {supportsViews && (
              <>
                <option value="lastTurn">Last Turn</option>
                {view?.kind === "since" && <option value="since">Since selected turn</option>}
                <option value="now">Start From Now</option>
              </>
            )}
          </select>
        </label>
        {mode !== "lastTurn" && mode !== "since" && (
          <label className="field">
            Checkout
            <select value={directory} onChange={(event) => setSelectedRoot(event.target.value)}>
              {directories.map((root) => (
                <option key={root} value={root}>
                  {root}
                </option>
              ))}
            </select>
          </label>
        )}
        <button
          type="button"
          onClick={() => {
            inventory.refresh();
            read.refresh();
          }}
        >
          Refresh
        </button>
      </div>
      <ReadStatus loading={read.loading} error={read.error} />
      {inventory.error && <p className="subtle">Checkout inventory unavailable: {inventory.error}</p>}
      {inventory.value?.complete === false && <p className="subtle">Some checkouts could not be read.</p>}
      {read.value?.status === "unavailable" && (
        <p role="status">
          {{
            notRepository: "This folder is not a Git repository.",
            missingDirectory: "The folder is unavailable.",
            noBaseBranch: "No base branch is available.",
            noMergeBase: "The branches have no common base.",
          }[read.value.reason] ?? read.value.reason}
        </p>
      )}
      {result && (
        <>
          <p className="subtle">
            {result.files.length
              ? `${result.label} · ${result.files.length} ${result.complete ? (result.files.length === 1 ? "file" : "files") : "loaded files"} · ${result.files.every((file) => file.hasLineCounts) ? `+${result.files.reduce((sum, file) => sum + file.additions, 0)} −${result.files.reduce((sum, file) => sum + file.deletions, 0)}` : "Line counts unavailable"}`
              : result.complete
                ? "No changes"
                : "Change coverage is incomplete"}
            {result.unlisted > 0 && ` · ${result.unlisted} additional files not listed`}
          </p>
          {!result.complete && result.files.length > 0 && (
            <p className="subtle">Some changes are unavailable.</p>
          )}
          {result.files.length > 0 && (
            <label className="field changes-file">
              File
              <select
                value={file ? fileKey(file, index) : ""}
                onChange={(event) => {
                  setSelectedFile(event.target.value);
                  setLineLimit(2000);
                }}
              >
                {result.files.map((file, index) => (
                  <option key={fileKey(file, index)} value={fileKey(file, index)}>
                    {file.path ?? "Path unavailable"} ·{" "}
                    {file.hasLineCounts ? `+${file.additions} −${file.deletions}` : "Line counts unavailable"}
                  </option>
                ))}
              </select>
            </label>
          )}
          {file?.omitted && (
            <p className="subtle">
              Patch omitted:{" "}
              {{ fileTooLarge: "file exceeds preview capacity", responseBudget: "response capacity reached" }[
                file.omitted
              ] ?? file.omitted}
              .
            </p>
          )}
          {file?.replacedInvalidUtf8 && <p className="subtle">Invalid UTF-8 was replaced in this patch.</p>}
          {file && (
            <div className="change-lines">
              {lines.slice(0, lineLimit).map((line) => (
                <button
                  type="button"
                  key={line.offset}
                  className={`change-line ${line.kind}`}
                  disabled={
                    read.loading ||
                    !file.path ||
                    (line.kind === "deletion" ? line.oldNumber : line.newNumber) === undefined
                  }
                  title="Comment on this line"
                  onClick={() => {
                    if (getSelection()?.toString()) return;
                    setAnnotation({ file, line, comparison: result.comparison });
                    setComment("");
                  }}
                >
                  <span>{line.oldNumber}</span>
                  <span>{line.newNumber}</span>
                  <code>
                    {line.kind === "addition"
                      ? "+"
                      : line.kind === "deletion"
                        ? "-"
                        : line.kind === "context"
                          ? " "
                          : ""}
                    {line.text}
                  </code>
                </button>
              ))}
            </div>
          )}
          {file && (
            <button type="button" onClick={() => run(() => navigator.clipboard.writeText(file.patch))}>
              Copy patch
            </button>
          )}
          {lineLimit === 20000 && lines.length > lineLimit && (
            <p className="subtle">
              The preview reached its line limit. Copy the patch to read the remaining lines.
            </p>
          )}
          {lines.length > lineLimit && lineLimit < 20000 && (
            <button type="button" onClick={() => setLineLimit(Math.min(20000, lineLimit + 2000))}>
              Show more lines
            </button>
          )}
        </>
      )}
      {annotation && (
        <form
          className="review-comment"
          onSubmit={(event) => {
            event.preventDefault();
            run(() => {
              workspace.appendReviewComment(
                address,
                reviewComment(annotation.file, annotation.line, annotation.comparison, comment),
              );
              setAnnotation(undefined);
              setComment("");
            });
          }}
        >
          <p>
            {annotation.file.path}:{annotation.line.newNumber ?? annotation.line.oldNumber}
          </p>
          <label>
            Review comment
            <textarea
              value={comment}
              maxLength={8192}
              onChange={(event) => setComment(event.target.value)}
              autoFocus
            />
          </label>
          <div className="panel-actions">
            <button type="submit" disabled={!comment.trim()}>
              Add to message
            </button>
            <button type="button" onClick={() => setAnnotation(undefined)}>
              Cancel
            </button>
          </div>
        </form>
      )}
    </Dialog>
  );
});
