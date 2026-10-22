import type { Host, Provider } from "../protocol/boundary";
import { array, object } from "../protocol/boundary";
export type Attachment = {
  id: string;
  name: string;
  bytes: number;
  type: string;
  path: string;
  sha256: string;
};
export type Draft = {
  revision: number;
  modifiedAt?: number;
  text: string;
  attachments: Attachment[];
  model: string;
  provider: Provider;
  effort: string;
  fast: boolean;
  cwd: string;
  uncertain?: string;
};
export const blank = (host?: Host): Draft => ({
  revision: 0,
  text: "",
  attachments: [],
  model: "",
  provider: "codex",
  effort: "",
  fast: false,
  cwd: host?.cwd ?? "",
});

export class ComposerDraftStore {
  private drafts = new Map<string, Draft>();
  private persistence?: ReturnType<typeof setTimeout>;
  constructor(
    private readonly storage: Storage | undefined,
    private readonly current: () => { key: string; host: Host | undefined },
    private readonly protectedKeys: () => Set<string>,
    private readonly publish: () => void,
    private readonly report: (error: unknown) => void,
  ) {}
  get snapshot(): ReadonlyMap<string, Draft> {
    return this.drafts;
  }
  get(key: string) {
    return this.drafts.get(key);
  }
  restore() {
    const raw = this.storage?.getItem("remotecoder.web.drafts.v1");
    if (raw && raw.length <= 1024 * 1024) {
      for (const pair of array(JSON.parse(raw), 32)) {
        const [key, value] = array(pair, 2);
        const draft = object(value);
        if (
          typeof key === "string" &&
          typeof draft.text === "string" &&
          draft.text.length <= 256000 &&
          Array.isArray(draft.attachments)
        )
          this.drafts.set(key, {
            ...(value as Draft),
            modifiedAt:
              Number.isSafeInteger(draft.modifiedAt) && Number(draft.modifiedAt) >= 0
                ? Number(draft.modifiedAt)
                : undefined,
          });
      }
    }
  }
  restoreUncertain(key: string, sourceKey: string, id: string) {
    const draft = this.drafts.get(key) ?? this.drafts.get(sourceKey);
    if (draft) this.drafts.set(key, { ...draft, uncertain: id });
  }
  remove(key: string) {
    this.drafts = new Map(this.drafts);
    this.drafts.delete(key);
  }
  restoreSnapshot(snapshot: ReadonlyMap<string, Draft>) {
    this.drafts = new Map(snapshot);
  }
  update(change: Partial<Draft>, key = this.current().key) {
    const drafts = new Map(this.drafts);
    const previous = drafts.get(key);
    const edited =
      (change.text !== undefined && change.text !== previous?.text) ||
      (change.attachments !== undefined && change.attachments !== previous?.attachments);
    drafts.set(key, {
      ...(drafts.get(key) ?? blank(this.current().host)),
      ...change,
      modifiedAt: edited ? Date.now() : drafts.get(key)?.modifiedAt,
      revision:
        Math.max(drafts.get(key)?.revision ?? 0, change.revision ?? 0) +
        (Object.keys(change).some((field) => field !== "uncertain") ? 1 : 0),
    });
    while (drafts.size > 32) {
      const protectedKeys = this.protectedKeys();
      const oldest = [...drafts.keys()].find(
        (candidate) => candidate !== key && candidate !== this.current().key && !protectedKeys.has(candidate),
      );
      if (!oldest)
        throw new Error("All saved drafts are awaiting delivery. Resolve one before adding another.");
      drafts.delete(oldest);
    }
    this.drafts = drafts;
    this.publish();
    clearTimeout(this.persistence);
    this.persistence = setTimeout(() => this.persist(), 1000);
  }
  persist(required = false) {
    try {
      this.storage?.setItem("remotecoder.web.drafts.v1", JSON.stringify([...this.drafts]));
    } catch {
      if (required)
        throw new Error("The browser could not save the pending draft. No message was dispatched.");
      this.report("The browser could not save your draft. Keep this tab open until it is sent.");
    }
  }

  flush() {
    clearTimeout(this.persistence);
    this.persist();
  }
}
