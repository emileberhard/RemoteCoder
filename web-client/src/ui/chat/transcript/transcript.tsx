import { AlertCircle, ArrowDown } from "lucide-react";
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { addressKey, type VisualPublication } from "../../../protocol/boundary";
import type { Conversation, Row } from "../../../workspace/conversation-session";
import { downloadFile } from "../../files/download";
import { FilePreview, filePreviewKind } from "../../files/preview";
import { useRun, useWorkspace } from "../../workspace-context";
import { MessageRow } from "../bubbles/message-row";
import { ApprovalCard } from "../questions/approval-card";
import { Timeline } from "./timeline";
import { timelineSegments } from "./timeline-segments";
import { ViewedMedia } from "./viewed-media";

export function Transcript({ conversation }: { conversation: Conversation }) {
  const workspace = useWorkspace();
  const run = useRun();
  const ref = useRef<HTMLDivElement>(null);
  const anchored = useRef(true);
  const edge = useRef<"older" | "newer" | undefined>(undefined);
  const anchor = useRef<
    | { identity: string; windowKey: string; id?: string; offset: number; height: number; top: number }
    | undefined
  >(undefined);
  const lastTop = useRef(0);
  const touchY = useRef<number | undefined>(undefined);
  const previous = useRef<string | undefined>(undefined);
  const [file, setFile] = useState<
    { path: string; kind: "image" | "pdf" | "text"; line?: number } | undefined
  >(undefined);
  const closeFile = useCallback(() => setFile(undefined), []);
  const [away, setAway] = useState(false);
  const identity = addressKey(conversation.address);
  const windowKey = conversation.rows.map((row) => row.entry.item.id).join("\0");
  useLayoutEffect(() => {
    if (previous.current !== identity) {
      previous.current = identity;
      edge.current = undefined;
      anchor.current = undefined;
      setFile(undefined);
      anchored.current = true;
      setAway(false);
      if (ref.current) {
        ref.current.scrollTop = ref.current.scrollHeight;
        lastTop.current = ref.current.scrollTop;
      }
    }
  }, [identity]);
  useLayoutEffect(() => {
    const element = ref.current;
    const held = anchor.current;
    if (!element || !held || held.identity !== identity || held.windowKey === windowKey) return;
    const retained = [...element.querySelectorAll<HTMLElement>("[data-transcript-anchor]")].find(
      (node) => node.dataset.transcriptAnchor === held.id,
    );
    if (retained)
      element.scrollTop +=
        retained.getBoundingClientRect().top - element.getBoundingClientRect().top - held.offset;
    else element.scrollTop = held.top + element.scrollHeight - held.height;
    lastTop.current = element.scrollTop;
    held.windowKey = windowKey;
  }, [identity, windowKey]);
  const page = useCallback(
    (direction: "older" | "newer") => {
      const element = ref.current;
      if (!element || conversation.historyLoading || conversation.status !== "ready") return;
      anchored.current = false;
      setAway(true);
      const top = element.getBoundingClientRect().top;
      const visible = [...element.querySelectorAll<HTMLElement>("[data-transcript-anchor]")].find(
        (node) => node.getBoundingClientRect().bottom > top + 8,
      );
      const held = {
        identity,
        windowKey,
        id: visible?.dataset.transcriptAnchor,
        offset: visible ? visible.getBoundingClientRect().top - top : 0,
        height: element.scrollHeight,
        top: element.scrollTop,
      };
      anchor.current = held;
      void (direction === "older" ? workspace.older() : workspace.newer())
        .catch(() => undefined)
        .finally(() => {
          requestAnimationFrame(() => {
            if (anchor.current === held) anchor.current = undefined;
          });
        });
    },
    [conversation, identity, workspace, windowKey],
  );
  const demand = useCallback(() => {
    const element = ref.current;
    if (!element || conversation.historyError) return;
    if (
      edge.current === "older" &&
      element.scrollTop < 400 &&
      (conversation.older || conversation.historyReloadRequired)
    )
      page("older");
    else if (
      edge.current === "newer" &&
      element.scrollHeight - element.scrollTop - element.clientHeight < 400 &&
      conversation.newer
    )
      page("newer");
  }, [conversation, page]);
  useEffect(() => {
    if (
      !windowKey ||
      conversation.historyLoading ||
      (!conversation.older && !conversation.newer && !conversation.historyReloadRequired)
    )
      return;
    demand();
  }, [
    demand,
    windowKey,
    conversation.historyLoading,
    conversation.older,
    conversation.newer,
    conversation.historyReloadRequired,
  ]);
  useEffect(() => {
    const element = ref.current;
    if (!element) return;
    const wheel = (event: WheelEvent) => {
      if (event.ctrlKey) return;
      if (event.deltaY) edge.current = event.deltaY < 0 ? "older" : "newer";
      demand();
    };
    const start = (event: TouchEvent) => {
      touchY.current = event.touches[0]?.clientY;
    };
    const move = (event: TouchEvent) => {
      const next = event.touches[0]?.clientY;
      if (next !== undefined && touchY.current !== undefined && next !== touchY.current)
        edge.current = next > touchY.current ? "older" : "newer";
      touchY.current = next;
      demand();
    };
    const end = () => {
      touchY.current = undefined;
    };
    const lifetime = new AbortController();
    const options = { passive: true, signal: lifetime.signal };
    element.addEventListener("wheel", wheel, options);
    element.addEventListener("touchstart", start, options);
    element.addEventListener("touchmove", move, options);
    element.addEventListener("touchend", end, options);
    element.addEventListener("touchcancel", end, options);
    return () => lifetime.abort();
  }, [demand]);
  useEffect(() => {
    const element = ref.current;
    const content = element?.querySelector(".transcript-content");
    if (!element || !content) return;
    const observer = new ResizeObserver(() => {
      if (anchored.current) {
        element.scrollTop = element.scrollHeight;
        lastTop.current = element.scrollTop;
      }
    });
    observer.observe(content);
    return () => observer.disconnect();
  }, []);
  const hostId = conversation.address.hostId;
  const segments = timelineSegments(conversation.rows, typeof conversation.activeTurnId === "string");
  const questions = conversation.questions;
  const marks = workspace.conversationMarks(conversation.address)?.marks;
  const changeView = marks?.threads[conversation.address.threadId]?.changesView;
  const renderRow = (row: Row, reply = false, visual?: VisualPublication) => (
    <div
      key={visual ? `published-visual-${row.entry.item.id}` : row.entry.item.id}
      data-transcript-anchor={visual ? `visual-${row.entry.item.id}` : row.entry.item.id}
    >
      <MessageRow
        key={visual ? `published-visual-${row.entry.item.id}` : row.entry.item.id}
        row={row}
        reply={
          reply &&
          !conversation.newer &&
          conversation.activeTurnId !== undefined &&
          row.entry.turnId !== conversation.activeTurnId
        }
        countChanges={
          reply &&
          !conversation.newer &&
          conversation.activeTurnId !== undefined &&
          row.entry.turnId !== conversation.activeTurnId &&
          (marks?.schemaVersion ?? 0) >= 4 &&
          !(
            changeView?.kind === "since" &&
            changeView.turnId === row.entry.turnId &&
            changeView.boundary === "end"
          )
        }
        visual={visual}
        address={conversation.address}
        cwd={conversation.header.cwd}
        question={
          questions.status === "ready"
            ? questions.value.records.find((question) => question.itemId === row.entry.item.id)
            : undefined
        }
        questionReady={questions.status === "ready" && questions.value.coverage === "ready"}
      />
    </div>
  );
  const actions = useCallback(
    async (event: { target: EventTarget | null; preventDefault(): void }) => {
      const target = event.target as HTMLElement;
      const copy = target.closest<HTMLButtonElement>("[data-copy-code]");
      if (copy) {
        const code = copy.closest(".code-block")?.querySelector("code")?.textContent;
        if (code) {
          await navigator.clipboard.writeText(code);
          copy.textContent = "Copied";
          setTimeout(() => {
            if (copy.isConnected) copy.textContent = "Copy";
          }, 1500);
        }
      }
      const link = target.closest<HTMLAnchorElement>("[data-host-path]");
      if (link?.dataset.hostPath) {
        event.preventDefault();
        const kind = filePreviewKind(link.dataset.hostPath);
        if (kind)
          setFile({
            path: link.dataset.hostPath,
            kind,
            line: link.dataset.hostLine ? Number(link.dataset.hostLine) : undefined,
          });
        else await downloadFile(hostId, link.dataset.hostPath, conversation.header.cwd);
      }
    },
    [hostId, conversation.header.cwd],
  );
  useEffect(() => {
    const element = ref.current;
    if (!element) return;
    const handler = (event: MouseEvent) => {
      void actions(event).catch((error) => workspace.report(error));
    };
    element.addEventListener("click", handler);
    return () => element.removeEventListener("click", handler);
  }, [actions, workspace]);
  return (
    <div className="transcript-shell">
      {file && (
        <FilePreview
          key={`${hostId}:${file.path}`}
          path={file.path}
          hostId={hostId}
          cwd={conversation.header.cwd}
          kind={file.kind}
          line={file.line}
          close={closeFile}
        />
      )}
      <div
        ref={ref}
        className="transcript"
        onScroll={() => {
          const element = ref.current;
          if (!element) return;
          if (element.scrollTop !== lastTop.current)
            edge.current = element.scrollTop < lastTop.current ? "older" : "newer";
          lastTop.current = element.scrollTop;
          anchored.current =
            !conversation.newer && element.scrollHeight - element.scrollTop - element.clientHeight < 90;
          setAway(!anchored.current || Boolean(conversation.newer));
          demand();
        }}
      >
        <div className="transcript-content">
          {(conversation.older || conversation.historyReloadRequired) && (
            <button
              type="button"
              className="older-button"
              disabled={Boolean(conversation.historyLoading)}
              onClick={() => page("older")}
            >
              {conversation.historyLoading === "older"
                ? "Loading earlier messages…"
                : "Load earlier messages"}
            </button>
          )}
          {conversation.historyError && (
            <div className="inline-error">
              <AlertCircle size={17} />
              <span>{conversation.historyError}</span>
              <button
                type="button"
                onClick={() => run(() => workspace.loadConversation(conversation.address))}
              >
                Refresh history
              </button>
            </div>
          )}
          {conversation.status === "loading" && <p className="subtle loading">Reading this conversation…</p>}
          {conversation.error && (
            <div className="inline-error">
              <AlertCircle size={17} />
              <span>{conversation.error}</span>
              <button
                type="button"
                onClick={() => run(() => workspace.loadConversation(conversation.address))}
              >
                Refresh
              </button>
            </div>
          )}
          {segments.map((segment) =>
            segment.kind === "timeline" ? (
              <div
                key={segment.rows[0]?.entry.item.id ?? "live"}
                data-transcript-anchor={segment.rows[0]?.entry.item.id}
              >
                <Timeline rows={segment.rows} live={segment.live} renderRow={renderRow} />
              </div>
            ) : segment.kind === "media" ? (
              <div
                key={`media-${segment.row.entry.item.id}`}
                data-transcript-anchor={`media-${segment.row.entry.item.id}`}
              >
                {segment.media.map((media) => (
                  <ViewedMedia key={media.path} media={media} hostId={hostId} cwd={conversation.header.cwd} />
                ))}
              </div>
            ) : (
              renderRow(segment.row, segment.reply, segment.visual)
            ),
          )}
          {conversation.requests.map((request) => (
            <ApprovalCard key={request.id} request={request} />
          ))}
          {conversation.activeTurnId === undefined && conversation.status === "ready" && (
            <div className="subtle activity-unknown">
              Turn status unavailable{" "}
              <button
                type="button"
                className="text-button"
                onClick={() => run(() => workspace.loadConversation(conversation.address))}
              >
                Refresh
              </button>
            </div>
          )}
          {conversation.newer && (
            <button
              type="button"
              className="older-button"
              disabled={Boolean(conversation.historyLoading)}
              onClick={() => page("newer")}
            >
              {conversation.historyLoading === "newer" ? "Loading newer messages…" : "Load newer messages"}
            </button>
          )}
          <div className="transcript-bottom" />
        </div>
      </div>
      {(away || conversation.newer) && (
        <button
          type="button"
          className="jump-latest"
          onClick={() =>
            run(async () => {
              edge.current = undefined;
              anchor.current = undefined;
              if (conversation.newer || conversation.historyReloadRequired)
                await workspace.loadConversation(conversation.address);
              if (previous.current !== identity) return;
              anchored.current = true;
              setAway(false);
              ref.current?.scrollTo({
                top: ref.current.scrollHeight,
                behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "instant" : "smooth",
              });
            })
          }
        >
          <ArrowDown size={16} />
          Latest
        </button>
      )}
    </div>
  );
}
