import { AlertCircle, ArrowDown } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { addressKey, type VisualPublication } from "../../../protocol/boundary";
import type { Conversation, Row } from "../../../workspace/conversation-session";
import { downloadFile } from "../../files/download";
import { useRun, useWorkspace } from "../../workspace-context";
import { MessageRow } from "../bubbles/message-row";
import { ApprovalCard } from "../questions/approval-card";
import { Timeline } from "./timeline";
import { timelineSegments } from "./timeline-segments";

export function Transcript({ conversation }: { conversation: Conversation }) {
  const workspace = useWorkspace();
  const run = useRun();
  const ref = useRef<HTMLDivElement>(null);
  const anchored = useRef(true);
  const previous = useRef<string | undefined>(undefined);
  const [away, setAway] = useState(false);
  const identity = addressKey(conversation.address);
  useEffect(() => {
    if (previous.current !== identity) {
      previous.current = identity;
      anchored.current = true;
      setAway(false);
      if (ref.current) ref.current.scrollTop = ref.current.scrollHeight;
    }
  }, [identity]);
  useEffect(() => {
    const element = ref.current;
    const content = element?.querySelector(".transcript-content");
    if (!element || !content) return;
    const observer = new ResizeObserver(() => {
      if (anchored.current) element.scrollTop = element.scrollHeight;
    });
    observer.observe(content);
    return () => observer.disconnect();
  }, []);
  const hostId = conversation.address.hostId;
  const segments = timelineSegments(conversation.rows, typeof conversation.activeTurnId === "string");
  const questions = conversation.questions;
  const renderRow = (row: Row, reply = false, visual?: VisualPublication) => (
    <MessageRow
      key={visual ? `published-visual-${row.entry.item.id}` : row.entry.item.id}
      row={row}
      reply={reply}
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
        await downloadFile(hostId, link.dataset.hostPath, conversation.header.cwd);
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
      <div
        ref={ref}
        className="transcript"
        onScroll={() => {
          const element = ref.current;
          if (!element) return;
          anchored.current = element.scrollHeight - element.scrollTop - element.clientHeight < 90;
          setAway(!anchored.current);
        }}
      >
        <div className="transcript-content">
          {conversation.older && (
            <button
              type="button"
              className="older-button"
              onClick={() => {
                anchored.current = false;
                const top = ref.current?.scrollHeight ?? 0;
                run(async () => {
                  await workspace.older();
                  requestAnimationFrame(() => {
                    if (ref.current) ref.current.scrollTop = ref.current.scrollHeight - top;
                  });
                });
              }}
            >
              Load earlier messages
            </button>
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
              <Timeline
                key={segment.rows[0]?.entry.item.id ?? "live"}
                rows={segment.rows}
                live={segment.live}
                renderRow={renderRow}
              />
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
          <div className="transcript-bottom" />
        </div>
      </div>
      {away && (
        <button
          type="button"
          className="jump-latest"
          onClick={() => {
            anchored.current = true;
            setAway(false);
            ref.current?.scrollTo({
              top: ref.current.scrollHeight,
              behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "instant" : "smooth",
            });
          }}
        >
          <ArrowDown size={16} />
          Latest
        </button>
      )}
    </div>
  );
}
