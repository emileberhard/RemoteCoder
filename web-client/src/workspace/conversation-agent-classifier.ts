import type { Rpc } from "../gateway";
import { array, identifier, object, string } from "../protocol/boundary";
import {
  agentRelation,
  type ConversationAgentClassification,
  type ConversationHeader,
  isNativeAgent,
} from "./conversation-header";

export class ConversationAgentClassifier {
  private task?: Promise<void>;
  private requested = false;
  constructor(
    private readonly rpc: Rpc,
    private readonly signal: AbortSignal,
    private readonly current: () => ConversationHeader[],
    private readonly apply: (
      classifications: ReadonlyMap<string, ConversationAgentClassification>,
      warnings: string[],
    ) => void,
  ) {}
  refresh(): Promise<void> {
    this.requested = true;
    if (this.task) return this.task;
    this.task = this.run().finally(() => {
      this.task = undefined;
      if (this.requested && !this.signal.aborted) return this.refresh();
    });
    return this.task;
  }
  private async run() {
    while (this.requested && !this.signal.aborted) {
      this.requested = false;
      const pending = this.current().filter(
        (header) => !isNativeAgent(header) && header.agentClassification.kind === "unresolved",
      );
      const classifications = new Map<string, ConversationAgentClassification>();
      const warnings = new Set<string>();
      for (let offset = 0; offset < pending.length; offset += 200) {
        const batch = pending.slice(offset, offset + 200);
        try {
          const result = object(
            await this.rpc.call(
              "conversation/agents/classify",
              { threadIds: batch.map((header) => header.id) },
              { signal: this.signal },
            ),
          );
          if (this.signal.aborted) return;
          const relations = object(result.relations);
          const roots = new Set(array(result.knownRoots ?? [], 200).map(identifier));
          for (const warning of array(result.warnings, 200)) warnings.add(string(warning));
          const parsed = batch.map((header): [string, ConversationAgentClassification] => [
            header.id,
            relations[header.id] !== undefined
              ? { kind: "child", relation: agentRelation(relations[header.id]) }
              : roots.has(header.id)
                ? { kind: "root" }
                : { kind: "unresolved" },
          ]);
          for (const [id, classification] of parsed) classifications.set(id, classification);
        } catch {
          if (this.signal.aborted) return;
          warnings.add("Agent relationships unavailable; unclassified conversations remain visible.");
          break;
        }
      }
      if (!this.signal.aborted) this.apply(classifications, [...warnings]);
    }
  }
}
