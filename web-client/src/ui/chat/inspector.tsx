import { Check, Circle, X } from "lucide-react";
import { useState } from "react";
import { addressKey } from "../../protocol/boundary";
import type { Conversation } from "../../workspace/conversation-session";
import { condensedPath } from "../../workspace/working-directory-path";
import { AgentsPanel } from "../agents/agents-panel";
import { IconButton } from "../design-system/icon-button";
import { effortLabel } from "../formatting";
import { useWorkspace } from "../workspace-context";
import { Diff } from "./bubbles/diff";
import { contextTokensText } from "./composer/context-window-gauge";

export function Inspector({ conversation, close }: { conversation?: Conversation; close(): void }) {
  return (
    <aside className="inspector" aria-label="Conversation details">
      <div className="inspector-header">
        <h2>Details</h2>
        <IconButton label="Close details" onClick={close}>
          <X size={18} />
        </IconButton>
      </div>
      {conversation ? (
        <ConversationDetails key={addressKey(conversation.address)} conversation={conversation} />
      ) : (
        <p className="subtle">Start or open a conversation to see its details.</p>
      )}
    </aside>
  );
}
function ConversationDetails({ conversation }: { conversation: Conversation }) {
  const workspace = useWorkspace();
  const { header } = conversation;
  const { threadId: _, ...target } = conversation.address;
  const [transport] = useState(() => workspace.featureTransport(target));
  const { draft } = workspace;
  const model = workspace
    .choices()
    .find((choice) => choice.id === draft.model && choice.provider === draft.provider);
  const usage = workspace.contextWindowUsage;
  const context = usage ? `${usage.usedPercent}% · ${contextTokensText(usage)}` : "Unknown";
  return (
    <>
      <section className="inspector-section">
        <h3>Conversation</h3>
        <dl className="inspector-fields">
          <dt>Host</dt>
          <dd>{transport.hostName}</dd>
          <dt>Folder</dt>
          <dd className="selectable">
            {header.cwd ? condensedPath(header.cwd, workspace.homePath(target.hostId)) : "Unknown"}
          </dd>
          <dt>Model</dt>
          <dd>{model?.name ?? (draft.model || "Unknown")}</dd>
          <dt>Reasoning</dt>
          <dd>{effortLabel(draft.effort)}</dd>
          <dt>Context</dt>
          <dd>{context}</dd>
        </dl>
      </section>
      {conversation.plan?.length ? (
        <section className="inspector-section">
          <h3>Plan</h3>
          <ol className="plan-list">
            {conversation.plan.map((step) => (
              <li key={step.step}>
                {step.status === "completed" ? <Check size={15} /> : <Circle size={15} />}
                <span>{step.step}</span>
              </li>
            ))}
          </ol>
        </section>
      ) : null}
      {conversation.diff ? (
        <section className="inspector-section">
          <h3>Changes</h3>
          <Diff text={conversation.diff} />
        </section>
      ) : null}
      <section className="inspector-section">
        <h3>Agents</h3>
        <AgentsPanel transport={transport} />
      </section>
    </>
  );
}
