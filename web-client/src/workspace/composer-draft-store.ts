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
  serviceTier?: string | null;
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

export function reportedServiceTier(value: unknown): string | null | undefined {
  if (value === null || value === "default") return null;
  return typeof value === "string" ? value : undefined;
}

export function fastServiceTier(tier: string | null | undefined) {
  return tier === "fast" || tier === "priority" || tier === "ultrafast";
}

export function supportedServiceTier(
  tier: string | null | undefined,
  choice: { fast: boolean; ultrafast?: boolean },
) {
  if (tier === "ultrafast") return choice.ultrafast ? tier : undefined;
  if (tier === "fast" || tier === "priority") return choice.fast ? tier : null;
  return tier;
}

const draftStorageKey = "remotecoder.web.drafts.v1";
export const maximumDraftDocumentLength = 1024 * 1024;
export const maximumDraftTextLength = 256_000;
export const maximumDraftCount = 32;

function restorableDraft(key: unknown, draft: Record<string, unknown>) {
  return (
    typeof key === "string" &&
    typeof draft.text === "string" &&
    draft.text.length <= maximumDraftTextLength &&
    Array.isArray(draft.attachments)
  );
}

function serializeDictationDrafts(drafts: ReadonlyMap<string, Draft>) {
  if (
    drafts.size > maximumDraftCount ||
    [...drafts.values()].some((draft) => draft.text.length > maximumDraftTextLength)
  )
    throw new Error("The draft exceeds browser storage limits. Keep this tab open until it is sent.");
  const raw = JSON.stringify([...drafts]);
  if (raw.length > maximumDraftDocumentLength)
    throw new Error("The draft exceeds browser storage limits. Keep this tab open until it is sent.");
  return raw;
}

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
    const raw = this.storage?.getItem(draftStorageKey);
    if (raw && raw.length <= maximumDraftDocumentLength) {
      for (const pair of array(JSON.parse(raw), maximumDraftCount)) {
        const [key, value] = array(pair, 2);
        const draft = object(value);
        if (typeof key === "string" && restorableDraft(key, draft))
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
  private candidate(change: Partial<Draft>, key: string) {
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
    while (drafts.size > maximumDraftCount) {
      const protectedKeys = this.protectedKeys();
      const oldest = [...drafts.keys()].find(
        (candidate) => candidate !== key && candidate !== this.current().key && !protectedKeys.has(candidate),
      );
      if (!oldest)
        throw new Error("All saved drafts are awaiting delivery. Resolve one before adding another.");
      drafts.delete(oldest);
    }
    return drafts;
  }
  update(change: Partial<Draft>, key = this.current().key) {
    this.drafts = this.candidate(change, key);
    this.publish();
    clearTimeout(this.persistence);
    this.persistence = setTimeout(() => this.persist(), 1000);
  }
  applyDictation(key: string, text: string) {
    const draft = this.drafts.get(key);
    if (!draft) throw new Error("The original dictation draft is unavailable; the recording was retained.");
    const candidate = this.candidate({ text: [draft.text.trimEnd(), text].filter(Boolean).join("\n") }, key);
    if (!this.storage) throw new Error("Browser draft storage is unavailable. Keep this tab open.");
    const serialized = serializeDictationDrafts(candidate);
    try {
      this.storage.setItem(draftStorageKey, serialized);
    } catch {
      throw new Error("The browser could not save your draft. Keep this tab open until it is sent.");
    }
    clearTimeout(this.persistence);
    this.drafts = candidate;
    this.publish();
  }
  persist(required = false) {
    try {
      this.storage?.setItem(draftStorageKey, JSON.stringify([...this.drafts]));
    } catch {
      if (required)
        throw new Error("The browser could not save your draft. Keep this tab open until it is sent.");
      this.report("The browser could not save your draft. Keep this tab open until it is sent.");
    }
  }

  flush() {
    clearTimeout(this.persistence);
    this.persist();
  }
  flushRequired() {
    clearTimeout(this.persistence);
    if (!this.storage) throw new Error("Browser draft storage is unavailable. Keep this tab open.");
    this.persist(true);
  }
}
