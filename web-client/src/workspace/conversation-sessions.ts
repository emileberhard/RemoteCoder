import { conversationAddress, decodeAddress, type ExecutionTarget, sameBinding } from "../execution-context";
import { providerForThread } from "../protocol/agent-provider";
import {
  type Address,
  addressKey,
  array,
  type Frame,
  identifier,
  object,
  type Questions,
  string,
} from "../protocol/boundary";
import type { MarkdownBlocks } from "../rendering";
import { type ConversationHeader, conversationHeader } from "./conversation-header";
import { type Conversation, ConversationSession, type Renderer } from "./conversation-session";
import type { HostServices, HostState } from "./host-services";
import { failure } from "./load-state";
import type { SubmissionReceipt } from "./turn-dispatcher";

type ClaudeSubscriptions = {
  desired: string;
  applied?: string;
  failed?: string;
  error?: string;
  pending?: Promise<void>;
};
export class ConversationSessions {
  private readonly sessions = new Map<string, ConversationSession>();
  private readonly claudeSubscriptions = new WeakMap<HostState, ClaudeSubscriptions>();
  private pending = 0;
  private renderer?: Renderer;
  constructor(
    private readonly hosts: HostServices,
    private readonly selected: () => Address | undefined,
    private readonly publish: (live?: boolean) => void,
    private readonly receipts: () => ReadonlyMap<string, SubmissionReceipt>,
    private readonly reconcileReceipts: (conversation: Conversation) => void,
    private readonly replay: (target: ExecutionTarget, notification: Frame) => void,
    private readonly receiveActivity: (host: HostState, value: unknown) => void,
    private readonly receiveQuestions: (host: HostState, threadId: string, inventory: Questions) => void,
  ) {}
  get snapshot(): ReadonlyMap<string, Conversation> {
    return new Map([...this.sessions].map(([key, session]) => [key, session.snapshot]));
  }
  setRenderer(renderer: Renderer) {
    this.renderer = renderer;
  }
  get(address: Address) {
    return this.sessions.get(addressKey(address));
  }
  hasContext(target: ExecutionTarget) {
    return [...this.sessions.values()].some((session) => sameBinding(session.snapshot.address, target));
  }
  reserve() {
    this.makeRoom();
    this.pending++;
    return () => {
      this.pending--;
    };
  }
  private makeRoom(address?: Address) {
    if (address && this.sessions.has(addressKey(address))) return;
    if (this.sessions.size + this.pending < 6) return;
    const selected = this.selected();
    const candidate = [...this.sessions].find(([key, session]) => {
      const conversation = session.snapshot;
      return (
        key !== (selected ? addressKey(selected) : "") &&
        conversation.activeTurnId === null &&
        !conversation.submitting &&
        !conversation.rows.some(
          (row) =>
            row.delivery === "sending" ||
            row.delivery === "admitted" ||
            (row.delivery === "uncertain" && !row.steer),
        ) &&
        conversation.requests.length === 0
      );
    });
    if (!candidate)
      throw new Error(
        "Six conversations have active, unknown or unconfirmed work. Wait for one to finish before opening another.",
      );
    this.evict(candidate[0]);
  }
  private create(host: HostState, address: Address, header: ConversationHeader, started: boolean) {
    const session = new ConversationSession(host, address, header, started, this.hosts, {
      publish: this.publish,
      renderer: () => this.renderer,
      present: (owner) => this.sessions.get(addressKey(owner.snapshot.address)) === owner,
      receipts: this.receipts,
      reconcileReceipts: this.reconcileReceipts,
      syncClaudeSubscriptions: (host) => this.syncClaudeSubscriptions(host),
      applyActivity: (host, value) => this.applyActivity(host, value),
      receiveQuestions: this.receiveQuestions,
      replay: this.replay,
    });
    this.sessions.set(addressKey(address), session);
    return session;
  }
  admitStarted(host: HostState, address: Address, header: ConversationHeader) {
    if (this.sessions.has(addressKey(address)))
      throw new Error("The gateway reused an existing conversation identity");
    return this.create(host, address, header, true);
  }
  async load(address: Address): Promise<void> {
    address = conversationAddress(address, address.threadId);
    const host = this.hosts.get(address);
    const key = addressKey(address);
    let session = this.sessions.get(key);
    if (session) session.rebind(host, address);
    else {
      this.makeRoom(address);
      let header = host.threads.find((thread) => thread.id === address.threadId);
      if (!header) {
        this.pending++;
        try {
          const fetched = await this.hosts.readHeader(host, address.threadId, (header) => {
            this.hosts.recordThread(host, header);
            this.publish();
            void this.hosts.refreshAgentClassifications(host);
          });
          header = host.threads.find((thread) => thread.id === address.threadId) ?? fetched;
        } finally {
          this.pending--;
        }
        if (this.sessions.has(key)) return this.load(address);
      }
      session = this.create(host, address, header, false);
    }
    await session.load();
  }
  evict(key: string) {
    const session = this.sessions.get(key);
    if (!session) return;
    const conversation = session.snapshot;
    session.dispose();
    this.sessions.delete(key);
    if (conversation.header.provider === "claude") {
      const host = this.hosts.get(conversation.address);
      void this.syncClaudeSubscriptions(host).catch((error) => {
        if (this.hosts.present(host)) {
          this.hosts.setError(host, error);
          this.publish();
        }
      });
    }
  }
  retireHost(host: HostState) {
    for (const [key, session] of this.sessions)
      if (sameBinding(session.snapshot.address, host.target)) this.evict(key);
  }
  disconnected(host: HostState) {
    if (host.status !== "connecting") this.claudeSubscriptions.delete(host);
    for (const session of this.sessions.values())
      if (sameBinding(session.snapshot.address, host.target)) session.disconnected();
  }
  syncClaudeSubscriptions(host: HostState): Promise<void> {
    const desired = JSON.stringify(
      [...this.snapshot.values()]
        .filter(
          (conversation) =>
            sameBinding(conversation.address, host.target) && conversation.header.provider === "claude",
        )
        .map((conversation) => conversation.address.threadId)
        .sort(),
    );
    const owner = this.claudeSubscriptions.get(host) ?? { desired };
    this.claudeSubscriptions.set(host, owner);
    owner.desired = desired;
    if (owner.pending) return owner.pending;
    if (owner.applied === desired) return Promise.resolve();
    if (owner.failed === desired) return Promise.reject(new Error(owner.error));
    const operation = (async () => {
      while (owner.applied !== owner.desired) {
        const intent = owner.desired;
        try {
          await host.rpc.call(
            "conversation/subscriptions/set",
            { threadIds: JSON.parse(intent) },
            { signal: host.controller.signal },
          );
          if (
            !this.hosts.present(host) ||
            this.claudeSubscriptions.get(host) !== owner ||
            host.controller.signal.aborted
          )
            throw new DOMException("Canceled", "AbortError");
          owner.applied = intent;
          owner.failed = undefined;
          owner.error = undefined;
        } catch (error) {
          owner.failed = intent;
          owner.error = failure(error);
          throw error;
        }
      }
    })().finally(() => {
      owner.pending = undefined;
    });
    owner.pending = operation;
    return operation;
  }

  applyActivity(host: HostState, value: unknown) {
    this.hosts.beginActivityRead(host);
    this.receiveActivity(host, value);
    const activity = object(value);
    const coverage = object(activity.coverage);
    const active = array(activity.activeTurns, 1000).map(object);
    for (const session of this.sessions.values())
      if (sameBinding(session.snapshot.address, host.target)) session.applyActivity(active, coverage);
  }
  ingest(target: ExecutionTarget, notification: Frame) {
    if (!notification.method) return;
    const params = object(notification.params ?? {});
    const host = this.hosts.get(target);
    if (notification.method === "conversation/agents/changed") {
      void this.hosts.refreshAgentClassifications(host);
      return;
    }
    if (notification.method === "daemon/activeTurnsChanged") {
      this.applyActivity(host, params);
      this.publish();
      return;
    }
    const threadId = typeof params.threadId === "string" ? params.threadId : undefined;
    if (notification.method === "turn/completed" && threadId) {
      const completedAt = object(params.turn).completedAt;
      if (completedAt != null) {
        if (typeof completedAt !== "number" || !Number.isSafeInteger(completedAt))
          throw new Error("Invalid turn completion time");
        this.hosts.recordTurnCompletion(host, threadId, completedAt);
      }
    }
    const session = threadId ? this.sessions.get(addressKey({ ...target, threadId })) : undefined;
    if (session && !sameBinding(session.snapshot.address, target)) return;
    if (notification.method === "thread/name/updated") {
      const id = identifier(params.threadId);
      const name = params.threadName === null ? null : string(params.threadName);
      this.hosts.updateThreadName(host, id, name);
      session?.updateName(name);
      this.publish();
      return;
    }
    if (session) {
      session.ingest(notification);
      return;
    }
    if (notification.method === "thread/started") {
      const record = object(params.thread);
      this.hosts.recordThread(host, conversationHeader(record, providerForThread(identifier(record.id))));
      void this.hosts.refreshAgentClassifications(host);
      this.publish();
      return;
    }
    if (notification.method === "turn/completed") this.publish();
  }
  markdownReady(id: string, result: MarkdownBlocks) {
    const separator = id.indexOf("\u0000");
    const address = decodeAddress(JSON.parse(id.slice(0, separator)));
    this.get(address)?.markdownReady(id, result);
  }
  dispose() {
    for (const session of this.sessions.values()) session.cancel();
    this.renderer?.dispose();
  }
}
