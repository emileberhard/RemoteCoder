import {
  Check,
  ChevronDown,
  Circle,
  Code2,
  File,
  Folder,
  GitBranch,
  Globe,
  MessageCircle,
  RefreshCw,
  Search,
  Terminal,
} from "lucide-react";
import { memo } from "react";
import type { Address, QuestionRecord, VisualPublication } from "../../../protocol/boundary";
import type { Row } from "../../../workspace/conversation-session";
import { downloadFile } from "../../files/download";
import { basename } from "../../formatting";
import { useRun, useWorkspace } from "../../workspace-context";
import { SpeakButton } from "../media";
import { QuestionCard } from "../questions/question-card";
import { MarkdownBlock } from "../transcript/markdown-block";
import { PublishedVisual } from "../transcript/published-visual";
import { CopyButton } from "./copy-button";
import { Diff } from "./diff";

export const MessageRow = memo(function MessageRow({
  row,
  reply,
  address,
  cwd,
  question,
  questionReady,
  visual,
}: {
  row: Row;
  reply: boolean;
  address: Address;
  cwd: string;
  question?: QuestionRecord;
  questionReady: boolean;
  visual?: VisualPublication;
}) {
  const workspace = useWorkspace();
  const run = useRun();
  const hostId = address.hostId;
  const item = row.entry.item;
  if (visual) return <PublishedVisual visual={visual} hostId={hostId} />;
  if (item.type === "hookPrompt") return null;
  if (item.type === "userMessage")
    return (
      <article className="user-row">
        <div className="user-bubble">
          {item.content.map((input, index) =>
            input.type === "text" ? (
              <p key={`part:${index}`}>
                {input.text.startsWith("<send_user_message_question_reply>")
                  ? "Answered the agent’s question"
                  : input.text}
              </p>
            ) : input.type === "localImage" ||
              input.type === "localAudio" ||
              input.type === "mention" ||
              input.type === "skill" ? (
              <button
                type="button"
                className="attachment-link"
                key={`part:${index}`}
                onClick={() => run(() => downloadFile(hostId, input.path, cwd))}
              >
                <File size={15} />
                {basename(input.path)}
              </button>
            ) : input.type === "image" &&
              "url" in input &&
              /^data:image\/(png|jpeg|gif|webp);base64,/.test(input.url) ? (
              <img
                className="message-image"
                key={`part:${index}`}
                src={input.url}
                alt="Attachment"
                loading="lazy"
              />
            ) : (
              <span className="attachment-link" key={`part:${index}`}>
                <File size={15} />
                {input.type}
              </span>
            ),
          )}
        </div>
        {row.delivery && (row.delivery !== "admitted" || row.steer) && (
          <div className={`delivery ${row.delivery}`}>
            {row.delivery === "sending" && !row.steer
              ? "Sending…"
              : row.delivery === "sending" || row.delivery === "admitted"
                ? "Steer pending"
                : row.delivery === "failed"
                  ? "Not sent"
                  : "Unconfirmed"}
            {row.error && <span>{row.error}</span>}
            {row.steer && row.delivery === "uncertain" && (
              <button
                type="button"
                className="delivery-action"
                onClick={() => run(async () => workspace.restoreSteer(address, item.id))}
              >
                Move to composer
              </button>
            )}
          </div>
        )}
      </article>
    );
  if (item.type === "agentMessage" || item.type === "plan") {
    if (item.type === "agentMessage" && item.delivery === "async" && item.questions)
      return question ? (
        <QuestionCard record={question} ready={questionReady} />
      ) : (
        <article className="question-unavailable">
          <MessageCircle size={17} />
          <span>{item.text || "Agent question"}</span>
          <button type="button" onClick={() => run(() => workspace.refreshQuestions())}>
            Refresh question status
          </button>
        </article>
      );
    return (
      <article
        className={`agent-row ${item.type === "agentMessage" && item.phase === "commentary" ? "commentary" : ""}`}
      >
        {item.type === "plan" && <div className="agent-label">Plan</div>}
        <div className="markdown">
          {row.markdown?.blocks.length ? (
            row.markdown.blocks.map((html, index) => (
              <MarkdownBlock
                key={`part:${index}`}
                html={html}
                complete={row.entry.isComplete === true}
                hostId={hostId}
              />
            ))
          ) : (
            <p className="raw-message">{item.text}</p>
          )}
          {row.markdown?.error && <p className="error">{row.markdown.error}</p>}
        </div>
        {item.type === "agentMessage" && reply && row.entry.isComplete === true && (
          <div className="message-actions">
            <CopyButton text={item.text} />
            <SpeakButton id={`${hostId}:${item.id}`} text={item.text} />
          </div>
        )}
      </article>
    );
  }
  if (item.type === "reasoning") {
    const thoughts = [...item.summary, ...item.content].map((text) => text.trim()).filter(Boolean);
    if (!thoughts.length) return null;
    return (
      <details className="reasoning-row">
        <summary>
          <Circle size={13} />
          <span>Thinking</span>
          <span className="reasoning-preview">
            {thoughts[0]?.split("\n")[0]?.replace(/^\*\*(.+?)\*\*$/, "$1")}
          </span>
          <ChevronDown size={13} />
        </summary>
        <div>
          {thoughts.map((text, index) => (
            <p key={`part:${index}`}>{text}</p>
          ))}
        </div>
      </details>
    );
  }
  if (item.type === "commandExecution")
    return (
      <details className={`tool-row ${item.status === "failed" ? "failed" : ""}`}>
        <summary>
          <Terminal size={15} />
          <code>{item.command}</code>
          {item.status === "inProgress" ? <span className="working-dot" /> : <Check size={14} />}
          <ChevronDown size={13} />
        </summary>
        <div className="tool-content">
          <div className="tool-meta">
            <Folder size={12} />
            {item.cwd}
            {item.exitCode != null && <span>Exit {item.exitCode}</span>}
          </div>
          <pre>{item.aggregatedOutput ?? "Output unavailable"}</pre>
        </div>
      </details>
    );
  if (item.type === "fileChange")
    return (
      <details className="tool-row file-change">
        <summary>
          <GitBranch size={15} />
          <span>
            {item.changes.length} {item.changes.length === 1 ? "file changed" : "files changed"}
          </span>
          <span className="tool-path">{item.changes[0] ? basename(item.changes[0].path) : ""}</span>
          <ChevronDown size={13} />
        </summary>
        <div className="tool-content">
          {item.changes.map((change) => (
            <div key={change.path}>
              <button
                type="button"
                className="file-path"
                onClick={() => run(() => downloadFile(hostId, change.path, cwd))}
              >
                <File size={13} />
                {change.path}
              </button>
              <Diff text={change.diff ?? ""} />
            </div>
          ))}
        </div>
      </details>
    );
  if (item.type === "mcpToolCall" || item.type === "dynamicToolCall")
    return (
      <details className="tool-row">
        <summary>
          <Globe size={15} />
          <span>
            {item.type === "mcpToolCall" ? `${item.server} / ` : item.namespace ? `${item.namespace} / ` : ""}
            {item.tool}
          </span>
          <span className="tool-path">{item.status}</span>
          <ChevronDown size={13} />
        </summary>
        <div className="tool-content">
          <pre>{JSON.stringify(item.arguments, null, 2)}</pre>
          {item.type === "mcpToolCall" ? (
            <pre>{item.error?.message ?? JSON.stringify(item.result, null, 2) ?? "Result unavailable"}</pre>
          ) : (
            item.contentItems?.map((content, index) =>
              content.type === "inputText" ? (
                <pre key={`part:${index}`}>{content.text}</pre>
              ) : (
                <img
                  key={`part:${index}`}
                  className="message-image"
                  src={content.type === "inputImage" ? content.imageUrl : undefined}
                  alt="Tool result"
                  loading="lazy"
                />
              ),
            )
          )}
        </div>
      </details>
    );
  if (item.type === "contextCompaction")
    return (
      <div className="compaction">
        <span />
        <RefreshCw size={12} />
        Context compacted
        <span />
      </div>
    );
  if (item.type === "webSearch")
    return (
      <details className="tool-row">
        <summary>
          <Search size={15} />
          <span>Search the web</span>
          <code>{item.query}</code>
          <ChevronDown size={13} />
        </summary>
        <pre>{JSON.stringify(item.action, null, 2)}</pre>
      </details>
    );
  if (item.type === "imageView")
    return (
      <button
        type="button"
        className="attachment-link"
        onClick={() => run(() => downloadFile(hostId, item.path, cwd))}
      >
        <File size={15} />
        {basename(item.path)}
      </button>
    );
  if (item.type === "imageGeneration")
    return (
      <div className="agent-row">
        <p>Image generation · {item.status}</p>
        {item.result.startsWith("data:image/") ? (
          <img className="message-image" src={item.result} alt={item.revisedPrompt ?? "Generated image"} />
        ) : (
          <pre>{item.result}</pre>
        )}
      </div>
    );
  if (item.type === "collabAgentToolCall" || item.type === "subAgentActivity")
    return (
      <details className="tool-row">
        <summary>
          <GitBranch size={15} />
          <span>{item.type === "collabAgentToolCall" ? item.tool : item.kind}</span>
          <ChevronDown size={13} />
        </summary>
        <pre>{JSON.stringify(item, null, 2)}</pre>
      </details>
    );
  return (
    <details className="tool-row">
      <summary>
        <Code2 size={15} />
        <span>{item.type === "unknown" ? item.wireType : item.type}</span>
        <ChevronDown size={13} />
      </summary>
      <pre>{JSON.stringify(item.type === "unknown" ? item.payload : item, null, 2)}</pre>
    </details>
  );
});
