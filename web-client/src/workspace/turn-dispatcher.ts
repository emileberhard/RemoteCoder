import {
  conversationAddress,
  decodeAddress,
  requireCurrentEnrollment,
  sameBinding,
} from "../execution-context";
import { RpcError } from "../gateway";
import { canonicalModelID } from "../preferences";
import { providerForThread } from "../protocol/agent-provider";
import {
  type Address,
  addressKey,
  array,
  type Entry,
  entry,
  identifier,
  object,
  string,
} from "../protocol/boundary";
import type { UserInput } from "../protocol/generated/v2/UserInput";
import { blank, type ComposerDraftStore, type Draft } from "./composer-draft-store";
import { conversationHeader } from "./conversation-header";
import type { Conversation, Row } from "./conversation-session";
import type { ConversationSessions } from "./conversation-sessions";
import type { HostServices, HostState, ModelChoice } from "./host-services";
import { failure } from "./load-state";
export type SubmissionReceipt = {
  address: Address;
  draftKey: string;
  revision: number;
  destinationRevision: number;
  steer?: { entry: Entry; input: Pick<Draft, "text" | "attachments">; acknowledged: boolean };
};

export class TurnDispatcher {
  private readonly admissions = new Set<string>();
  private readonly preparations = new Map<string, Promise<Conversation>>();
  private readonly receipts = new Map<string, SubmissionReceipt>();
  constructor(
    private readonly hosts: HostServices,
    private readonly sessions: ConversationSessions,
    private readonly drafts: ComposerDraftStore,
    private readonly storage: Storage | undefined,
    private readonly current: () => {
      host: HostState | undefined;
      conversation: Conversation | undefined;
      draft: Draft;
      draftKey: string;
      selected: Address | undefined;
      selection: number;
    },
    private readonly actions: {
      choices(): ModelChoice[];
      selectStarted(address: Address, fence: number): void;
      isRetired(): boolean;
      publish(): void;
      report(error: unknown): void;
    },
  ) {}
  get pendingReceipts(): ReadonlyMap<string, SubmissionReceipt> {
    return this.receipts;
  }
  protectedDraftKeys() {
    return new Set([
      ...this.admissions.keys(),
      ...[...this.receipts.values()]
        .filter((receipt) => !receipt.steer?.acknowledged)
        .flatMap((receipt) => [receipt.draftKey, addressKey(receipt.address)]),
    ]);
  }
  isSubmitting(key: string) {
    return this.admissions.has(key) || this.current().conversation?.submitting === true;
  }
  private publish() {
    this.actions.publish();
  }
  private report(error: unknown) {
    this.actions.report(error);
  }
  restore() {
    const saved = this.storage?.getItem("remotecoder.web.submissions.v1");
    if (saved && saved.length > 1024 * 1024) throw new Error("Saved submission receipts exceed capacity");
    if (saved)
      for (const pair of array(JSON.parse(saved), 64)) {
        const [id, value] = array(pair, 2);
        const receipt = object(value);
        const address = object(receipt.address);
        const parsed: SubmissionReceipt = {
          address: decodeAddress(address),
          draftKey: identifier(receipt.draftKey),
          revision: Number(receipt.revision),
          destinationRevision: Number(receipt.destinationRevision ?? receipt.revision),
        };
        if (receipt.steer !== undefined) {
          const steer = object(receipt.steer);
          const input = object(steer.input);
          parsed.steer = {
            entry: entry(steer.entry),
            acknowledged: steer.acknowledged === true,
            input: {
              text: string(input.text),
              attachments: array(input.attachments).map((value) => {
                const file = object(value);
                if (!Number.isSafeInteger(file.bytes) || Number(file.bytes) < 0)
                  throw new Error("Saved steer attachment has an invalid size");
                return {
                  id: identifier(file.id),
                  name: string(file.name),
                  path: string(file.path),
                  type: string(file.type),
                  sha256: string(file.sha256),
                  bytes: Number(file.bytes),
                };
              }),
            },
          };
        }
        if (
          parsed.steer &&
          (parsed.steer.entry.item.type !== "userMessage" || parsed.steer.entry.item.clientId !== id)
        )
          throw new Error("Saved steer receipt has an invalid client identity");
        if (
          !Number.isSafeInteger(parsed.revision) ||
          parsed.revision < 0 ||
          !Number.isSafeInteger(parsed.destinationRevision) ||
          parsed.destinationRevision < 0
        )
          throw new Error("Saved submission receipt has an invalid revision");
        this.receipts.set(identifier(id), parsed);
        if (parsed.steer?.acknowledged) continue;
        const key = addressKey(parsed.address);
        this.drafts.restoreUncertain(key, parsed.draftKey, identifier(id));
      }
  }
  private inputs(draft: Draft): UserInput[] {
    const files = draft.attachments;
    const text =
      `${draft.text.trim()}${files.length ? `\n\nAttached files (uploaded to this host; use these absolute paths):\n${files.map((file) => `- ${file.path}`).join("\n")}` : ""}`.trim();
    if (!text) throw new Error("Write a message or attach a file first");
    return [{ type: "text", text, text_elements: [] }];
  }
  private async validateExecution(host: HostState) {
    if (host.target.enrollment) {
      const physical = this.hosts.get(host.host.id);
      if (physical.accounts.status !== "ready") await this.hosts.refreshAccounts(host.host.id);
      if (physical.accounts.status !== "ready")
        throw new Error("Read this host's account directory before starting enrolled work");
      requireCurrentEnrollment(host.target, physical.accounts.value);
    }
    if (!this.hosts.present(host))
      throw new Error("The captured execution context was retired before dispatch");
  }
  private async startConversation(
    host: HostState,
    draft: Draft,
    draftKey: string,
    fence: number,
    serviceName: "RemoteCoder" | "RemoteCoder Voice",
  ) {
    if (!draft.cwd) throw new Error("Choose a host working directory first");
    const modelID = draft.provider === "claude" ? canonicalModelID(draft.model) : draft.model;
    const choice = (host.choices.status === "ready" ? host.choices.value : []).find(
      (choice) => choice.id === modelID && choice.provider === draft.provider,
    );
    if (!choice) throw new Error("Choose a model from the host catalog first");
    await this.validateExecution(host);
    const release = this.sessions.reserve();
    let response: Record<string, unknown>;
    try {
      response = object(
        await host.rpc.call(
          "thread/start",
          {
            model: draft.model,
            cwd: draft.cwd,
            approvalPolicy: "never",
            sandbox: "danger-full-access",
            serviceName,
            ...(serviceName === "RemoteCoder" ? { acceptProviderFallback: true } : {}),
            serviceTier: draft.fast && choice.fast ? "fast" : null,
            provider: draft.provider,
            ...(draft.effort ? { config: { model_reasoning_effort: draft.effort } } : {}),
          },
          { timeout: 150000, signal: host.controller.signal },
        ),
      );
      await this.validateExecution(host);
    } finally {
      release();
    }
    const rawThread = object(response.thread);
    const header = conversationHeader(
      {
        ...rawThread,
        model: rawThread.model ?? response.model,
        reasoningEffort: rawThread.reasoningEffort ?? response.reasoningEffort,
      },
      providerForThread(identifier(rawThread.id)),
    );
    const changedRoute =
      header.provider !== draft.provider ||
      (header.model != null && header.model !== modelID) ||
      (typeof rawThread.modelProvider === "string" &&
        rawThread.modelProvider !== (choice.modelProvider ?? "openai") &&
        header.provider === "codex");
    const settings = {
      provider: header.provider,
      model: header.model ?? draft.model,
      effort:
        !changedRoute && draft.effort === ""
          ? ""
          : (header.reasoningEffort ?? (changedRoute ? "" : draft.effort)),
      fast:
        header.extra && Object.hasOwn(header.extra, "serviceTier")
          ? header.extra.serviceTier === "priority" || header.extra.serviceTier === "fast"
          : !changedRoute && draft.fast && choice.fast,
    };
    const address = conversationAddress(host.target, header.id);
    const destinationKey = addressKey(address);
    const session = this.sessions.admitStarted(host, address, header);
    const conversation = session.snapshot;
    this.hosts.recordThread(host, header);
    this.actions.selectStarted(address, fence);
    const latest = this.drafts.snapshot.get(draftKey) ?? draft;
    const settingsUnchanged =
      latest.provider === draft.provider &&
      latest.model === draft.model &&
      latest.effort === draft.effort &&
      latest.fast === draft.fast;
    const latestChoice = (host.choices.status === "ready" ? host.choices.value : []).find(
      (choice) =>
        choice.provider === latest.provider &&
        choice.id === (latest.provider === "claude" ? canonicalModelID(latest.model) : latest.model),
    );
    const latestRouteCompatible =
      latest.provider === header.provider &&
      latestChoice !== undefined &&
      (header.provider !== "codex" ||
        (latestChoice.modelProvider ?? "openai") === (rawThread.modelProvider ?? "openai"));
    this.drafts.update(
      {
        ...latest,
        ...(!latestRouteCompatible || settingsUnchanged
          ? { ...settings, fast: latestRouteCompatible ? latest.fast : settings.fast }
          : {}),
      },
      destinationKey,
    );
    const destinationRevision =
      latest.revision === draft.revision
        ? (this.drafts.snapshot.get(destinationKey)?.revision ?? draft.revision)
        : draft.revision;
    if (draftKey.startsWith("new:")) this.drafts.remove(draftKey);
    this.drafts.persist(true);
    this.publish();
    if (header.provider === "claude") {
      try {
        await this.sessions.syncClaudeSubscriptions(host);
      } catch (error) {
        session.setError(`Live subscription unavailable: ${failure(error)}`);
        this.publish();
      }
      await this.validateExecution(host);
    }
    return { conversation, destinationRevision, settings };
  }
  prepareVoiceConversation(): Promise<Conversation> {
    const key = this.current().draftKey;
    const pending = this.preparations.get(key);
    if (pending) return pending;
    if (this.admissions.has(key))
      return Promise.reject(new Error("This draft already has an operation awaiting acknowledgment"));
    const host = this.current().host;
    if (!host) return Promise.reject(new Error("Choose a configured host first"));
    const selected = this.current().conversation;
    if (this.current().selected && !selected)
      return Promise.reject(new Error("Wait for the selected conversation header to load"));
    if (selected) {
      if (selected.status !== "ready" || selected.submitting)
        return Promise.reject(new Error("Wait for this conversation to finish loading or submitting"));
      return this.validateExecution(host).then(() => selected);
    }
    const draft = { ...this.current().draft, attachments: [...this.current().draft.attachments] };
    const fence = this.current().selection;
    this.admissions.add(key);
    this.publish();
    const operation = this.startConversation(host, draft, key, fence, "RemoteCoder Voice")
      .then(({ conversation }) => conversation)
      .finally(() => {
        this.preparations.delete(key);
        this.admissions.delete(key);
        this.publish();
      });
    this.preparations.set(key, operation);
    return operation;
  }
  async send(mode: "send" | "queue" = "send", override?: string) {
    const key = this.current().draftKey;
    if (this.admissions.has(key)) throw new Error("This draft is already being submitted");
    this.admissions.add(key);
    this.publish();
    try {
      return await this.dispatchSend(mode, override);
    } finally {
      this.admissions.delete(key);
      this.publish();
    }
  }
  private async dispatchSend(mode: "send" | "queue", override?: string) {
    const host = this.current().host;
    if (!host) throw new Error("Choose a configured host first");
    const draftKey = this.current().draftKey;
    const draft = { ...this.current().draft, ...(override ? { text: override, attachments: [] } : {}) };
    if (mode === "queue" && draft.provider === "claude")
      throw new Error("Queued submissions are unavailable for Claude.");
    const input = this.inputs(draft);
    const fence = this.current().selection;
    if (!draft.cwd) throw new Error("Choose a host working directory before sending");
    if (draft.uncertain)
      throw new Error(
        "This draft has an uncertain delivery. Refresh the conversation and explicitly keep or discard it before resending.",
      );
    const choice = this.actions
      .choices()
      .find((choice) => choice.id === draft.model && choice.provider === draft.provider);
    if (!choice) throw new Error("Choose a model from the host catalog before sending");
    let settings = { model: draft.model, effort: draft.effort, fast: draft.fast && choice.fast };
    let conversation = this.current().conversation;
    if (this.current().selected && !conversation)
      throw new Error("Wait for the selected conversation header to load");
    await this.validateExecution(host);

    if (conversation && conversation.activeTurnId === undefined && mode === "send") {
      const read = this.hosts.beginActivityRead(host);
      const activity = await host.rpc.call("daemon/activeTurns", {});
      if (host.activityRead === read) this.sessions.applyActivity(host, activity);
      if (conversation.activeTurnId === undefined)
        throw new Error("Turn status is unavailable. Refresh its authoritative status before sending.");
    }
    if (conversation?.submitting) throw new Error("A submission is still waiting for acknowledgment");
    const clientId = crypto.randomUUID();
    let destinationRevision = draft.revision;
    if (!conversation) {
      ({ conversation, destinationRevision, settings } = await this.startConversation(
        host,
        draft,
        draftKey,
        fence,
        "RemoteCoder",
      ));
    }
    const current = conversation;
    const destinationKey = addressKey(current.address);
    const session = this.sessions.get(current.address);
    if (!session) throw new Error("The conversation owner is unavailable");
    session.setSubmitting(true);
    let submitted = false;
    let accepted = false;
    const steerTurnId = mode === "queue" ? null : current.activeTurnId;
    const optimistic: Entry = {
      turnId: steerTurnId ?? `submission-${clientId}`,
      item: { type: "userMessage", id: clientId, clientId, content: input },
      startedAtMs: Date.now(),
      completedAtMs: null,
      isComplete: true,
    };
    session.appendSubmission(optimistic);
    const delivery = (value: Row["delivery"], error?: string) =>
      session.setDelivery(clientId, Boolean(steerTurnId), value, error);
    delivery("sending");
    this.publish();
    try {
      if (mode !== "queue" && current.resumeRequired) {
        await host.rpc.call(
          "thread/resume",
          { threadId: current.address.threadId, excludeTurns: true },
          { timeout: 150000 },
        );
        session.markResumed();
      }
      let result: Record<string, unknown>;
      if (this.receipts.size >= 64)
        throw new Error(
          "Too many unresolved submission receipts. Resolve unconfirmed submissions in their conversations before sending more.",
        );
      this.receipts.set(clientId, {
        address: current.address,
        draftKey,
        revision: draft.revision,
        destinationRevision,
        ...(steerTurnId
          ? {
              steer: {
                entry: optimistic,
                input: structuredClone({ text: draft.text, attachments: draft.attachments }),
                acknowledged: false,
              },
            }
          : {}),
      });
      this.drafts.persist(true);
      this.persistReceipts();
      submitted = true;
      const preview = input
        .flatMap((value) => (value.type === "text" ? [value.text] : []))
        .join("\n")
        .slice(0, 512);
      this.hosts.seedThreadPreview(host, current.address.threadId, preview);
      session.seedPreview(preview);
      this.publish();
      if (mode === "queue")
        result = object(
          await host.rpc.call("thread/queue/add", {
            threadId: current.address.threadId,
            input,
            clientUserMessageId: clientId,
          }),
        );
      else if (steerTurnId)
        result = object(
          await host.rpc.call("turn/steer", {
            threadId: current.address.threadId,
            input,
            expectedTurnId: steerTurnId,
            clientUserMessageId: clientId,
          }),
        );
      else
        result = object(
          await host.rpc.call("turn/start", {
            threadId: current.address.threadId,
            input,
            clientUserMessageId: clientId,
            model: settings.model,
            effort: settings.effort || null,
            cwd: current.header.cwd,
            approvalPolicy: "never",
            sandboxPolicy: { type: "dangerFullAccess" },
            serviceTier: settings.fast ? "fast" : null,
          }),
        );
      if (mode !== "queue") {
        const turnId = result.turn ? identifier(object(result.turn).id) : identifier(result.turnId);
        if (steerTurnId && turnId !== steerTurnId)
          throw new Error("The steer acknowledgement changed its owning turn");
        if (!steerTurnId) session.admitTurn(turnId);
      }
      accepted = true;
      delivery(
        steerTurnId && current.activeTurnId !== undefined && current.activeTurnId !== steerTurnId
          ? "uncertain"
          : "admitted",
      );
      const receipt = this.receipts.get(clientId);
      if (receipt?.steer) receipt.steer.acknowledged = true;
      else this.receipts.delete(clientId);
      try {
        this.persistReceipts();
      } catch {
        this.report(
          "The gateway accepted the message, but its saved receipt could not be updated. Refresh after reloading.",
        );
      }
      if (!override) {
        if (this.drafts.snapshot.get(draftKey)?.revision === draft.revision)
          this.drafts.update({ text: "", attachments: [], uncertain: undefined }, draftKey);
        if (
          destinationKey !== draftKey &&
          this.drafts.snapshot.get(destinationKey)?.revision === destinationRevision
        )
          this.drafts.update({ text: "", attachments: [], uncertain: undefined }, destinationKey);
      }
      if (mode === "queue") {
        session.removeQueuedSubmission(clientId);
        await session.refreshQueue();
      }
      this.drafts.persist();
    } catch (error) {
      if (accepted) throw error;
      const uncertain = submitted && this.receipts.has(clientId) && !(error instanceof RpcError);
      if (!uncertain) {
        this.receipts.delete(clientId);
        this.persistReceipts();
      }
      delivery(uncertain ? "uncertain" : "failed", failure(error));
      if (uncertain) this.drafts.update({ uncertain: clientId }, addressKey(current.address));
      this.drafts.persist();
      throw error;
    } finally {
      session.setSubmitting(false);
      this.publish();
    }
  }
  async interrupt() {
    const conversation = this.current().conversation;
    if (!conversation?.activeTurnId)
      throw new Error("The running turn identity is unavailable. Refresh its status before stopping.");
    await this.hosts.get(conversation.address).rpc.call("turn/interrupt", {
      threadId: conversation.address.threadId,
      turnId: conversation.activeTurnId,
    });
  }
  reconcileReceipts(conversation: Conversation) {
    for (const row of conversation.rows) {
      if (row.delivery || row.entry.item.type !== "userMessage" || !row.entry.item.clientId) continue;
      const id = row.entry.item.clientId;
      const receipt = this.receipts.get(id);
      if (!receipt || addressKey(receipt.address) !== addressKey(conversation.address)) continue;
      this.receipts.delete(id);
      for (const key of new Set([receipt.draftKey, addressKey(receipt.address)])) {
        const draft = this.drafts.snapshot.get(key);
        if (draft?.uncertain === id)
          this.drafts.update(
            {
              uncertain: undefined,
              ...(draft.revision ===
              (key === receipt.draftKey ? receipt.revision : receipt.destinationRevision)
                ? { text: "", attachments: [] }
                : {}),
            },
            key,
          );
      }
    }
    this.persistReceipts();
  }
  restoreSteer(address: Address, clientId: string): void {
    const key = addressKey(address);
    const conversation = this.sessions.get(address)?.snapshot;
    const row = conversation?.rows.find(
      (row) => row.entry.item.type === "userMessage" && row.entry.item.clientId === clientId,
    );
    const receipt = this.receipts.get(clientId);
    if (
      this.actions.isRetired() ||
      !conversation ||
      !sameBinding(conversation.address, address) ||
      !row?.steer ||
      row.delivery !== "uncertain" ||
      !receipt?.steer ||
      addressKey(receipt.address) !== key
    )
      throw new Error("Only an unconfirmed steer in this conversation can be restored");
    const input = receipt.steer.input;
    const draft = this.drafts.snapshot.get(key) ?? blank(this.hosts.get(address).host);
    const alreadyInDraft = draft.uncertain === clientId && draft.revision === receipt.destinationRevision;
    const attachments = new Map(draft.attachments.map((attachment) => [attachment.id, attachment]));
    for (const attachment of input.attachments)
      if (!attachments.has(attachment.id)) attachments.set(attachment.id, attachment);
    const text = alreadyInDraft
      ? draft.text
      : [draft.text, input.text].filter((text) => text.length).join("\n");
    if (text.length > 256000)
      throw new Error("Restoring this steer would exceed the saved draft text capacity");
    const previousDrafts = this.drafts.snapshot;
    this.drafts.update(
      {
        text,
        attachments: [...attachments.values()],
        ...(draft.uncertain === clientId ? { uncertain: undefined } : {}),
      },
      key,
    );
    try {
      if (JSON.stringify([...this.drafts.snapshot]).length > 1024 * 1024)
        throw new Error("Restoring this steer would exceed the saved draft capacity");
      this.drafts.persist(true);
      this.receipts.delete(clientId);
      this.persistReceipts();
    } catch (error) {
      this.receipts.set(clientId, receipt);
      this.drafts.restoreSnapshot(previousDrafts);
      this.drafts.persist();
      this.publish();
      throw error;
    }
    this.sessions.get(address)?.removeRestoredSteer(row);
    this.publish();
  }
  private persistReceipts() {
    const saved = JSON.stringify([...this.receipts]);
    if (saved.length > 1024 * 1024) throw new Error("Saved submission receipts exceed capacity");
    this.storage?.setItem("remotecoder.web.submissions.v1", saved);
  }
}
