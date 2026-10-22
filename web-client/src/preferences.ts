import { object, type Provider } from "./protocol/boundary";
import type { JsonValue } from "./protocol/generated/serde_json/JsonValue";

export type ThemeID = (typeof themes)[number];
export type Effort = (typeof efforts)[number];
export type ReasoningSelection = "automatic" | `effort-${Effort}` | Effort;
export type PreferenceValues = {
  "codex.modelVisibility": string;
  "claude.modelVisibility": string;
  "reasoning.visibleLevels.codex": string;
  "reasoning.visibleLevels.claude": string;
  "codex.newChatModel": string;
  "codex.newChatReasoning": ReasoningSelection | "last-selected";
  "codex.defaultModelID": string;
  "codex.defaultReasoningSelection": ReasoningSelection;
  "codex.fastModeEnabled": boolean;
  "appearance.selectedThemeID": ThemeID;
  "conversationDrawer.mode": "priority" | "projects";
};
export type PreferenceKey = keyof PreferenceValues;
export type PreferenceEntry = { value: JsonValue; updatedAt: number; device: string };
export type PreferenceDocument = { entries: Partial<Record<PreferenceKey, PreferenceEntry>> };
const kinds: Record<PreferenceKey, "string" | "boolean"> = {
  "codex.modelVisibility": "string",
  "claude.modelVisibility": "string",
  "reasoning.visibleLevels.codex": "string",
  "reasoning.visibleLevels.claude": "string",
  "codex.newChatModel": "string",
  "codex.newChatReasoning": "string",
  "codex.defaultModelID": "string",
  "codex.defaultReasoningSelection": "string",
  "codex.fastModeEnabled": "boolean",
  "appearance.selectedThemeID": "string",
  "conversationDrawer.mode": "string",
};
const themes = [
  "caribbeanSunset",
  "midnightOcean",
  "forestDusk",
  "orchidNight",
  "paperLight",
  "night",
] as const;
const efforts = ["low", "medium", "high", "xhigh", "max", "ultra"] as const;
const stateKey = "remotecoder.web.preferences.v1";
const encoder = new TextEncoder();
const bytes = (value: string) => encoder.encode(value).length;
const propertyList = (value: unknown, depth = 0): boolean => {
  if (depth > 64 || value === null) return false;
  if (typeof value === "number") return Number.isFinite(value);
  if (typeof value === "string" || typeof value === "boolean") return true;
  if (Array.isArray(value)) return value.every((entry) => propertyList(entry, depth + 1));
  return typeof value === "object" && Object.values(value).every((entry) => propertyList(entry, depth + 1));
};
const laterDevice = (left: string, right: string) => {
  const lhs = encoder.encode(left);
  const rhs = encoder.encode(right);
  for (let index = 0; index < Math.min(lhs.length, rhs.length); index++) {
    if (lhs[index] !== rhs[index]) return (lhs[index] ?? 0) > (rhs[index] ?? 0);
  }
  return lhs.length > rhs.length;
};
export const newerPreference = (entry: PreferenceEntry, previous?: PreferenceEntry) =>
  !previous ||
  entry.updatedAt > previous.updatedAt ||
  (entry.updatedAt === previous.updatedAt && laterDevice(entry.device, previous.device));

export function preferenceEntry(value: unknown, adopted: boolean): PreferenceEntry {
  const entry = object(value);
  const encoded = JSON.stringify(entry.value);
  if (
    !Number.isSafeInteger(entry.updatedAt) ||
    Number(entry.updatedAt) < (adopted ? 0 : 1) ||
    typeof entry.device !== "string" ||
    !entry.device ||
    bytes(entry.device) > 64 ||
    /\p{Cc}/u.test(entry.device) ||
    encoded === undefined ||
    bytes(encoded) > 8192
  )
    throw new Error("Invalid synced preference entry");
  return {
    value: entry.value as JsonValue,
    updatedAt: Number(entry.updatedAt),
    device: entry.device,
  };
}

export function preferenceDocument(value: unknown, adopted = false): PreferenceDocument {
  const entries = object(object(value).entries);
  if (Object.keys(entries).length > 64) throw new Error("Preference document exceeds 64 keys");
  const parsed: PreferenceDocument["entries"] = {};
  for (const [key, raw] of Object.entries(entries)) {
    if (!Object.hasOwn(kinds, key)) continue;
    parsed[key as PreferenceKey] = preferenceEntry(raw, adopted);
  }
  return { entries: parsed };
}

export class SyncedPreferences {
  restoreError?: string;
  private entries: PreferenceDocument["entries"] = {};
  private readonly device = crypto.randomUUID().toLowerCase();
  constructor(private readonly storage?: Storage) {
    try {
      const raw = storage?.getItem(stateKey);
      if (raw) this.entries = this.decode(raw).entries;
      else {
        const theme = storage?.getItem("remotecoder.web.theme");
        if (theme)
          this.entries["appearance.selectedThemeID"] = { value: theme, updatedAt: 0, device: this.device };
      }
    } catch (error) {
      this.restoreError = error instanceof Error ? error.message : "Preference storage is unavailable";
    }
  }
  private decode(raw: string) {
    if (raw.length > 1024 * 1024) throw new Error("Saved preferences exceed capacity");
    return preferenceDocument(JSON.parse(raw), true);
  }
  receiveStorage(key: string | null, raw: string | null) {
    return key === stateKey && raw !== null ? this.merge(this.decode(raw)) : false;
  }
  get<K extends PreferenceKey>(key: K): PreferenceValues[K] | null {
    const value = this.entries[key]?.value;
    if (value === undefined || value === null) return null;
    if (typeof value !== kinds[key]) return null;
    if (key === "conversationDrawer.mode" && value !== "priority" && value !== "projects") return null;
    if (key === "appearance.selectedThemeID" && !themes.includes(value as ThemeID)) return null;
    if (
      (key === "codex.defaultReasoningSelection" || key === "codex.newChatReasoning") &&
      !(key === "codex.newChatReasoning" && value === "last-selected") &&
      reasoningEffort(String(value)) === undefined
    )
      return null;
    return structuredClone(value) as PreferenceValues[K];
  }
  set<K extends PreferenceKey>(key: K, value: PreferenceValues[K] | null) {
    const merged = this.mergeStorage();
    if (JSON.stringify(this.entries[key]?.value ?? null) === JSON.stringify(value)) return merged;
    const updatedAt = Math.max(Date.now(), (this.entries[key]?.updatedAt ?? 0) + 1);
    const document = preferenceDocument({ entries: { [key]: { value, updatedAt, device: this.device } } });
    return this.merge(document);
  }
  private mergeStorage() {
    if (this.restoreError) return false;
    const stored = this.storage?.getItem(stateKey);
    return stored ? this.merge(this.decode(stored)) : false;
  }
  merge(document: PreferenceDocument) {
    const next = { ...this.entries };
    let changed = false;
    for (const [rawKey, entry] of Object.entries(document.entries)) {
      const key = rawKey as PreferenceKey;
      if (entry.value !== null && !propertyList(entry.value)) continue;
      if (newerPreference(entry, next[key])) {
        next[key] = structuredClone(entry);
        changed = true;
      }
    }
    if (changed || this.restoreError) {
      this.storage?.setItem(stateKey, JSON.stringify({ entries: next }));
      this.entries = next;
      this.restoreError = undefined;
    }
    return changed;
  }
  pending(document: PreferenceDocument): PreferenceDocument["entries"] {
    return Object.fromEntries(
      Object.entries(this.entries).filter(
        ([key, entry]) =>
          entry.updatedAt > 0 && newerPreference(entry, document.entries[key as PreferenceKey]),
      ),
    );
  }
  get themeID(): ThemeID {
    return this.get("appearance.selectedThemeID") ?? "caribbeanSunset";
  }
  modelVisible(provider: Provider, id: string, defaultVisibility: boolean) {
    return visibility(this.get(`${provider}.modelVisibility`) ?? "").get(id) ?? defaultVisibility;
  }
  setModelVisible(provider: Provider, id: string, visible: boolean, defaultVisibility: boolean) {
    const merged = this.mergeStorage();
    const key = `${provider}.modelVisibility` as const;
    const overrides = visibility(this.get(key) ?? "");
    if ((overrides.get(id) ?? defaultVisibility) === visible) return merged;
    if (visible === defaultVisibility) overrides.delete(id);
    else overrides.set(id, visible);
    return this.set(
      key,
      [...overrides]
        .sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0))
        .map(([model, shown]) => `${shown ? "+" : "-"}${model}`)
        .join("\n"),
    );
  }
  visibleEfforts(provider: Provider) {
    const selected = new Set(
      (this.get(`reasoning.visibleLevels.${provider}`) ?? "low,medium,high,xhigh").split(","),
    );
    return new Set<string>(efforts.filter((effort) => selected.has(effort)));
  }
}
function visibility(raw: string) {
  return new Map(
    raw
      .split("\n")
      .filter((line) => line.length > 1 && (line[0] === "+" || line[0] === "-"))
      .map((line) => [line.slice(1), line[0] === "+"]),
  );
}
export function canonicalModelID(id: string) {
  return ["fable", "opus", "sonnet", "haiku"].find((family) => id.startsWith(`claude-${family}-`)) ?? id;
}
export function reasoningEffort(value: string): Effort | "" | undefined {
  const trimmed = value.trim();
  if (trimmed === "automatic") return "";
  const effort = trimmed.replace(/^effort-/, "");
  return efforts.includes(effort as Effort) ? (effort as Effort) : undefined;
}
export function clampedEffort(selection: string, available: string[]) {
  if (!selection) return "";
  const desired = efforts.indexOf(selection as Effort);
  if (desired < 0) return "";
  return (
    efforts
      .filter((effort) => available.includes(effort))
      .sort(
        (left, right) =>
          Math.abs(efforts.indexOf(left) - desired) - Math.abs(efforts.indexOf(right) - desired),
      )[0] ?? ""
  );
}
