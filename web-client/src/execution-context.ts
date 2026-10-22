import { providerForThread } from "./protocol/agent-provider";
export type Enrollment = Readonly<{ accountId: string; generation: number }>;
export type ExecutionTarget = Readonly<{ hostId: string; enrollment?: Enrollment }>;
export type ConversationAddress = ExecutionTarget & Readonly<{ threadId: string }>;
export type AccountIdentity = Readonly<{ key: string; email?: string; workspace?: string }>;
export type AccountState =
  | "ready"
  | "authenticationRequired"
  | "identityMismatch"
  | "unavailable"
  | "disabled"
  | "unknown";
export type CodexChoice = Readonly<{
  target: ExecutionTarget;
  groupId?: string;
  identity?: AccountIdentity;
  label: string;
  state: AccountState;
  enabled: boolean;
  isDefault: boolean;
  usable: boolean;
  error?: string;
}>;
export type AccountCatalog = Readonly<{
  hostId: string;
  status: "unread" | "ready";
  refreshing?: boolean;
  choices: readonly CodexChoice[];
  retiredClaudeAccountIds: readonly string[];
}>;
export class ExecutionContextError extends Error {
  constructor(
    readonly code:
      | "invalidContext"
      | "directoryUnknown"
      | "preferredAccountMissing"
      | "accountUnavailable"
      | "staleGeneration"
      | "selectionUnknown",
    message: string,
  ) {
    super(message);
  }
}

function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new ExecutionContextError("invalidContext", "The execution context must be an object");
  return value as Record<string, unknown>;
}
function text(value: unknown, name: string, maximum = 4096): string {
  if (typeof value !== "string" || value.length > maximum)
    throw new ExecutionContextError("invalidContext", `Invalid ${name}`);
  return value;
}
function identifier(value: unknown, name: string): string {
  const result = text(value, name);
  if (!result) throw new ExecutionContextError("invalidContext", `Missing ${name}`);
  for (let index = 0; index < result.length; index++) {
    const code = result.charCodeAt(index);
    if (code < 32 || code === 127) throw new ExecutionContextError("invalidContext", `Invalid ${name}`);
  }
  return result;
}
function accountId(value: unknown): string {
  const result = text(value, "enrollment UUID", 36);
  if (!/^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/i.test(result))
    throw new ExecutionContextError("invalidContext", "An enrolled account requires its exact UUID");
  return result.toLowerCase();
}
function generation(value: unknown, minimum = 1): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < minimum)
    throw new ExecutionContextError(
      "invalidContext",
      "An enrollment generation must be a positive safe integer",
    );
  return value;
}
function flag(value: unknown, name: string): boolean {
  if (typeof value !== "boolean") throw new ExecutionContextError("invalidContext", `Invalid ${name}`);
  return value;
}
function collection(value: unknown, name: string): unknown[] {
  if (!Array.isArray(value) || value.length > 128)
    throw new ExecutionContextError("invalidContext", `Invalid ${name} collection`);
  return value;
}
export function executionTarget(hostId: string, enrollment?: Enrollment): ExecutionTarget {
  const host = identifier(hostId, "physical host ID");
  if (enrollment === undefined) return Object.freeze({ hostId: host });
  const binding = Object.freeze({
    accountId: accountId(enrollment.accountId),
    generation: generation(enrollment.generation),
  });
  return Object.freeze({ hostId: host, enrollment: binding });
}
export function decodeTarget(value: unknown): ExecutionTarget {
  const target = record(value);
  if ("accountId" in target || "accountGeneration" in target)
    throw new ExecutionContextError(
      "invalidContext",
      "Saved enrollment provenance must use the complete enrollment binding",
    );
  const hostId = identifier(target.hostId, "physical host ID");
  if (target.enrollment === undefined) return executionTarget(hostId);
  const enrollment = record(target.enrollment);
  return executionTarget(hostId, {
    accountId: accountId(enrollment.accountId),
    generation: generation(enrollment.generation),
  });
}
export function targetKey(target: ExecutionTarget): string {
  const valid = executionTarget(target.hostId, target.enrollment);
  return JSON.stringify([
    valid.hostId,
    valid.enrollment?.accountId ?? null,
    valid.enrollment?.generation ?? null,
  ]);
}
export function persistentTargetKey(target: ExecutionTarget): string {
  const valid = executionTarget(target.hostId, target.enrollment);
  return JSON.stringify([valid.hostId, valid.enrollment?.accountId ?? null]);
}
export function sameBinding(first: ExecutionTarget, second: ExecutionTarget): boolean {
  return targetKey(first) === targetKey(second);
}
export function targetForProvider(target: ExecutionTarget, provider: "codex" | "claude"): ExecutionTarget {
  if (provider !== "codex" && provider !== "claude")
    throw new ExecutionContextError("invalidContext", "Unknown execution provider");
  return executionTarget(target.hostId, provider === "claude" ? undefined : target.enrollment);
}
export function conversationAddress(target: ExecutionTarget, threadId: string): ConversationAddress {
  const thread = identifier(threadId, "thread ID");
  const context =
    providerForThread(thread) === "claude"
      ? executionTarget(target.hostId)
      : executionTarget(target.hostId, target.enrollment);
  return Object.freeze({ ...context, threadId: thread });
}
export function decodeAddress(value: unknown): ConversationAddress {
  const address = record(value);
  return conversationAddress(decodeTarget(address), identifier(address.threadId, "thread ID"));
}
export function conversationKey(address: ConversationAddress): string {
  const valid = conversationAddress(address, address.threadId);
  return JSON.stringify([valid.hostId, valid.enrollment?.accountId ?? null, valid.threadId]);
}
export function gatewayPath(target: ExecutionTarget): string {
  const valid = executionTarget(target.hostId, target.enrollment);
  const path = `/api/hosts/${encodeURIComponent(valid.hostId)}/ws`;
  if (!valid.enrollment) return path;
  const query = new URLSearchParams({
    accountId: valid.enrollment.accountId,
    accountGeneration: String(valid.enrollment.generation),
  });
  return `${path}?${query}`;
}
export function codexGroupId(identityKey: string): string {
  return `codex:${identifier(identityKey, "verified account identity")}`;
}
export function accountCatalog(hostId: string, value?: unknown): AccountCatalog {
  const host = identifier(hostId, "physical host ID");
  if (value === undefined)
    return Object.freeze({
      hostId: host,
      status: "unread",
      choices: Object.freeze([]),
      retiredClaudeAccountIds: Object.freeze([]),
    });
  const directory = record(value);
  if (directory.schemaVersion !== 2)
    throw new ExecutionContextError("invalidContext", "Unsupported account directory schema");
  const refreshing = flag(directory.refreshing, "account refresh state");
  const seen = new Set<string>();
  const choices: CodexChoice[] = [];
  for (const value of collection(directory.accounts, "account")) {
    const account = record(value);
    const provider = text(account.provider, "account provider");
    if (provider !== "codex" && provider !== "claude")
      throw new ExecutionContextError("invalidContext", "Unsupported account provider");
    const isDefault = flag(account.isDefault, "host default account");
    const id = isDefault ? identifier(account.id, "default account ID") : accountId(account.id);
    if (isDefault && id !== `default-${provider}`)
      throw new ExecutionContextError("invalidContext", "The default account ID does not match its provider");
    if (seen.has(id))
      throw new ExecutionContextError("invalidContext", "Duplicate account enrollment identity");
    seen.add(id);
    const currentGeneration = generation(account.generation, isDefault ? 0 : 1);
    const enabled = flag(account.enabled, "account enabled state");
    const observedState = text(account.state, "account readiness");
    const state: AccountState = [
      "ready",
      "authenticationRequired",
      "identityMismatch",
      "unavailable",
      "disabled",
    ].includes(observedState)
      ? (observedState as AccountState)
      : "unknown";
    const identityValue = account.identity == null ? undefined : record(account.identity);
    const identity = identityValue
      ? Object.freeze({
          key: identifier(identityValue.key, "verified account identity"),
          ...(identityValue.email == null ? {} : { email: text(identityValue.email, "account email") }),
          ...(identityValue.workspace == null
            ? {}
            : { workspace: text(identityValue.workspace, "account workspace") }),
        })
      : undefined;
    const label = text(account.label, "account label");
    const error = account.error == null ? undefined : text(account.error, "account error", 16384);
    if (provider !== "codex") continue;
    choices.push(
      Object.freeze({
        target: executionTarget(
          host,
          isDefault ? undefined : { accountId: id, generation: currentGeneration },
        ),
        ...(identity ? { identity, groupId: codexGroupId(identity.key) } : {}),
        label,
        state,
        enabled,
        isDefault,
        usable: enabled && state === "ready" && identity !== undefined,
        ...(error === undefined ? {} : { error }),
      }),
    );
  }
  const retired = collection(directory.retiredClaudeAccountIds, "retired Claude enrollment").map(accountId);
  if (new Set(retired).size !== retired.length)
    throw new ExecutionContextError("invalidContext", "Duplicate retired Claude enrollment identity");
  return Object.freeze({
    hostId: host,
    status: "ready",
    refreshing,
    choices: Object.freeze(choices),
    retiredClaudeAccountIds: Object.freeze(retired),
  });
}
export function usableCodexChoices(catalog: AccountCatalog): readonly CodexChoice[] {
  return Object.freeze(catalog.choices.filter((choice) => choice.usable));
}
export function initialCodexPreference(
  catalog: AccountCatalog,
  currentTarget: ExecutionTarget,
): string | undefined {
  if (catalog.hostId !== currentTarget.hostId || catalog.status !== "ready") return undefined;
  const current = catalog.choices.find((choice) => sameBinding(choice.target, currentTarget));
  return current?.groupId;
}
export function resolveCodexChoice(
  catalogs: readonly AccountCatalog[],
  preferredGroupId: string | undefined,
  currentHostId: string,
): CodexChoice {
  identifier(currentHostId, "physical host ID");
  if (!preferredGroupId)
    throw new ExecutionContextError(
      "selectionUnknown",
      "Choose a verified Codex account before starting new work",
    );
  identifier(preferredGroupId, "preferred Codex identity");
  const matching = catalogs
    .flatMap((catalog) => catalog.choices)
    .filter((choice) => choice.groupId === preferredGroupId);
  if (!matching.length) {
    if (catalogs.length === 0 || catalogs.some((catalog) => catalog.status !== "ready"))
      throw new ExecutionContextError("directoryUnknown", "Account membership is not available yet");
    throw new ExecutionContextError(
      "preferredAccountMissing",
      "The preferred Codex account is missing. Choose an account explicitly.",
    );
  }
  const usable = matching.filter((choice) => choice.usable);
  usable.sort(
    (a, b) =>
      Number(b.target.hostId === currentHostId) - Number(a.target.hostId === currentHostId) ||
      Number(a.isDefault) - Number(b.isDefault),
  );
  const selected = usable[0];
  if (!selected)
    throw new ExecutionContextError(
      "accountUnavailable",
      "The preferred Codex account has no ready connection",
    );
  return selected;
}
export function requireCurrentEnrollment(target: ExecutionTarget, catalog: AccountCatalog): ExecutionTarget {
  const valid = executionTarget(target.hostId, target.enrollment);
  if (valid.hostId !== catalog.hostId)
    throw new ExecutionContextError(
      "invalidContext",
      "The account directory belongs to another physical host",
    );
  if (!valid.enrollment) return valid;
  if (catalog.status !== "ready")
    throw new ExecutionContextError("directoryUnknown", "The enrollment directory is not available");
  const choice = catalog.choices.find(
    (choice) => choice.target.enrollment?.accountId === valid.enrollment?.accountId,
  );
  if (!choice)
    throw new ExecutionContextError(
      "preferredAccountMissing",
      "The owning enrollment is no longer present on this host",
    );
  if (!sameBinding(valid, choice.target))
    throw new ExecutionContextError(
      "staleGeneration",
      "The owning enrollment generation changed. Retire its previous connection before opening the new binding.",
    );
  if (!choice.usable)
    throw new ExecutionContextError(
      "accountUnavailable",
      "The owning enrollment is unavailable; its conversation cannot use another account",
    );
  return valid;
}
