import { useEffect, useState } from "react";
import { sameBinding } from "../../execution-context";
import { addressKey, array, identifier, object, string } from "../../protocol/boundary";
import {
  boolean,
  date,
  failure,
  MutationStatus,
  optionalNumber,
  optionalText,
  type PanelProps,
  ReadStatus,
  unique,
  useMutation,
  useRead,
} from "../remote-operations";
import { useRun, useWorkspace } from "../workspace-context";

export function parseAgents(value: unknown) {
  const page = object(value);
  identifier(page.revision);
  return {
    warnings: array(page.warnings, 100).map((value) => string(value)),
    agents: unique(
      array(page.agents, 512).map((value) => {
        const agent = object(value);
        const capabilities = object(agent.capabilities);
        return {
          id: identifier(agent.id),
          title: string(agent.title),
          provider: string(agent.provider),
          ownerThreadId: identifier(agent.ownerThreadId),
          threadId: optionalText(agent.threadId),
          parentId: optionalText(agent.parentId),
          model: optionalText(agent.model),
          executionId: optionalText(agent.executionId),
          accountId: optionalText(agent.accountId),
          state: ["working", "waiting", "completed", "interrupted", "failed"].includes(string(agent.state))
            ? string(agent.state)
            : "unknown",
          source: string(agent.source),
          lastActiveAt: optionalNumber(agent.lastActiveAt),
          capabilities: {
            inspect: boolean(capabilities.inspect),
            openConversation: boolean(capabilities.openConversation),
            message: boolean(capabilities.message),
            continueWork: boolean(capabilities.continueWork),
            stop: boolean(capabilities.stop),
            askParent: boolean(capabilities.askParent),
          },
        };
      }),
      (agent) => agent.id,
    ),
  };
}
type Agent = ReturnType<typeof parseAgents>["agents"][number];
export function AgentsPanel({ transport }: PanelProps) {
  const workspace = useWorkspace();
  const conversation = workspace.selectedConversation;
  if (!conversation || !sameBinding(conversation.address, transport.target))
    return <p className="panel-muted">Open a conversation on this host to inspect its agents.</p>;
  return (
    <AgentInventory
      key={addressKey(conversation.address)}
      transport={transport}
      threadId={conversation.address.threadId}
    />
  );
}
function AgentInventory({ transport, threadId }: PanelProps & { threadId: string }) {
  const inventory = useRead(`${transport.hostId}:${threadId}:agents`, async (signal) =>
    parseAgents(await transport.request("conversation/agents/list", { threadId }, { signal })),
  );
  const [selected, setSelected] = useState<string>();
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const unsubscribe = transport.subscribe((frame) => {
      if (
        !frame.method ||
        !["thread/status/changed", "turn/completed", "conversation/agents/changed"].includes(frame.method)
      )
        return;
      const params = frame.params;
      if (!params || typeof params !== "object" || Array.isArray(params)) return;
      if ((params as Record<string, unknown>).threadId !== threadId || timer) return;
      timer = setTimeout(() => {
        timer = undefined;
        inventory.refresh();
      }, 250);
    });
    return () => {
      unsubscribe();
      clearTimeout(timer);
    };
  }, [transport.subscribe, threadId, inventory.refresh]);
  const agent = inventory.value?.agents.find((agent) => agent.id === selected);
  return (
    <>
      <div className="panel-toolbar">
        <p className="panel-muted">Agents in this conversation · {transport.hostName}</p>
        <button type="button" onClick={inventory.refresh} disabled={inventory.loading}>
          Refresh
        </button>
      </div>
      <ReadStatus {...inventory} />
      {inventory.value?.warnings.map((warning) => (
        <p key={warning} className="panel-notice">
          {warning}
        </p>
      ))}
      {inventory.value?.agents.length === 0 && (
        <p className="panel-muted">No agents were reported for this conversation.</p>
      )}
      <div className="panel-list">
        {inventory.value?.agents.map((agent) => (
          <button
            type="button"
            key={agent.id}
            className={`panel-row ${selected === agent.id ? "selected" : ""}`}
            onClick={() => setSelected(agent.id)}
          >
            <strong>{agent.title || agent.id}</strong>
            <span>
              {agent.provider} · {agent.state} · {agent.source}
            </span>
            {agent.model && <span>{agent.model}</span>}
          </button>
        ))}
      </div>
      {agent && (
        <AgentDetail
          key={agent.id}
          transport={transport}
          threadId={threadId}
          agent={agent}
          refreshed={inventory.refresh}
        />
      )}
    </>
  );
}
function AgentDetail({
  transport,
  threadId,
  agent,
  refreshed,
}: PanelProps & { threadId: string; agent: Agent; refreshed(): void }) {
  const workspace = useWorkspace();
  const run = useRun();
  const [inspect, setInspect] = useState(false);
  const [text, setText] = useState("");
  const [error, setError] = useState<string>();
  const mutation = useMutation(transport, `agent:${threadId}:${agent.id}`);
  const output = useRead(`${transport.hostId}:${threadId}:${agent.id}:${inspect}`, async (signal) => {
    if (!inspect) return undefined;
    const value = object(
      await transport.request("conversation/agents/read", { threadId, agentId: agent.id }, { signal }),
    );
    return {
      truncated: boolean(value.truncated),
      messages: array(value.messages, 512).map((value) => {
        const message = object(value);
        return { id: crypto.randomUUID(), role: string(message.role), text: string(message.text) };
      }),
    };
  });
  async function action(action: "message" | "continue" | "stop") {
    setError(undefined);
    try {
      await mutation.run("conversation/agents/action", {
        threadId,
        agentId: agent.id,
        executionId: agent.executionId ?? null,
        action,
        mutationId: crypto.randomUUID(),
        ...(action !== "stop" ? { text } : {}),
      });
      if (action !== "stop") setText("");
      refreshed();
      output.refresh();
    } catch (error) {
      setError(failure(error));
      refreshed();
    }
  }
  async function retry() {
    try {
      await mutation.retry();
      refreshed();
      output.refresh();
      setError(undefined);
    } catch (error) {
      setError(failure(error));
    }
  }
  const busy = Boolean(mutation.pending);
  const canOpen =
    agent.capabilities.openConversation &&
    agent.threadId &&
    (!agent.accountId ||
      agent.accountId.toLowerCase() === transport.target.enrollment?.accountId.toLowerCase()) &&
    ["codex", "claude"].includes(agent.provider);
  return (
    <section className="panel-card">
      <h3>{agent.title || agent.id}</h3>
      <p className="panel-muted">Last activity: {date(agent.lastActiveAt)}</p>
      <div className="panel-actions">
        {agent.capabilities.inspect && (
          <button type="button" onClick={() => (inspect ? output.refresh() : setInspect(true))}>
            {inspect ? "Refresh output" : "Inspect output"}
          </button>
        )}
        {canOpen && (
          <button
            type="button"
            onClick={() => {
              const child = agent.threadId;
              if (child)
                run(() =>
                  workspace.openAgentConversation(
                    { ...transport.target, threadId: child },
                    { ...transport.target, threadId },
                  ),
                );
            }}
          >
            Open conversation
          </button>
        )}
        {agent.capabilities.askParent && (
          <button
            type="button"
            onClick={() => {
              const key = addressKey({ ...transport.target, threadId });
              const draft = workspace.getSnapshot().drafts.get(key);
              const reference = `Regarding your agent "${agent.title}" (${agent.id})${agent.threadId ? `, conversation ${agent.threadId}` : ""}: `;
              workspace.updateDraft(
                { text: `${draft?.text ?? ""}${draft?.text ? "\n\n" : ""}${reference}` },
                key,
              );
            }}
          >
            Ask parent in composer
          </button>
        )}
        {agent.capabilities.stop && (
          <button type="button" disabled={busy} onClick={() => void action("stop")}>
            Stop
          </button>
        )}
      </div>
      {agent.accountId && <p className="panel-muted">This agent uses a separate enrolled account.</p>}
      {(agent.capabilities.message || agent.capabilities.continueWork) && (
        <form
          className="panel-form"
          onSubmit={(event) => {
            event.preventDefault();
            void action(agent.capabilities.message ? "message" : "continue");
          }}
        >
          <label>
            {agent.capabilities.message ? "Message this agent" : "Continue with these instructions"}
            <textarea
              value={text}
              onChange={(event) => setText(event.target.value)}
              maxLength={131072}
              rows={3}
              disabled={busy}
            />
          </label>
          <button type="submit" disabled={busy || !text.trim()}>
            {agent.capabilities.message ? "Send message" : "Continue agent"}
          </button>
        </form>
      )}
      {error && (
        <p className="panel-error" role="alert">
          {error}
        </p>
      )}
      <MutationStatus mutation={mutation} retry={() => void retry()} />
      {inspect && (
        <>
          <ReadStatus {...output} />
          {output.value?.messages.map((message) => (
            <div key={message.id}>
              <strong>{message.role}</strong>
              <pre>{message.text}</pre>
            </div>
          ))}
          {output.value?.truncated && (
            <p className="panel-muted">Earlier output was omitted by the gateway.</p>
          )}
        </>
      )}
    </section>
  );
}
