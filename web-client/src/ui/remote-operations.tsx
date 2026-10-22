import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from "react";
import { RpcError } from "../gateway";
import { array, identifier, object, string } from "../protocol/boundary";
import type { Workspace } from "../workspace/workspace";

export type FeatureTransport = ReturnType<Workspace["featureTransport"]>;
export type PanelProps = { transport: FeatureTransport };
export const failure = (error: unknown) => (error instanceof Error ? error.message : "The operation failed");
export const optionalText = (value: unknown) => (value == null ? undefined : string(value));
export function boolean(value: unknown): boolean {
  if (typeof value !== "boolean") throw new Error("The gateway returned an invalid flag");
  return value;
}
export function number(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value))
    throw new Error("The gateway returned an invalid number");
  return value;
}
export const optionalNumber = (value: unknown) => (value == null ? undefined : number(value));
export function revision(value: unknown): number {
  const result = number(value);
  if (!Number.isSafeInteger(result) || result < 0)
    throw new Error("The gateway returned an invalid revision");
  return result;
}
export function unique<T>(items: T[], identity: (item: T) => string): T[] {
  if (new Set(items.map(identity)).size !== items.length)
    throw new Error("The gateway returned duplicate identities");
  return items;
}
export function date(value: unknown): string {
  if (value == null) return "Unknown";
  const timestamp = new Date(number(value) * 1000);
  return Number.isFinite(timestamp.getTime()) ? timestamp.toLocaleString() : "Unknown";
}
export class ServiceRejection extends Error {}
export function automationResult(value: unknown): unknown {
  const envelope = object(value);
  if (envelope.ok === false) {
    const error = object(envelope.error);
    const fields =
      error.fields == null
        ? []
        : array(error.fields, 100).map((value) => {
            const field = object(value);
            return `${array(field.path, 32).join(".")}: ${string(field.message)}`;
          });
    throw new ServiceRejection(
      [string(error.message), optionalText(error.hint), ...fields].filter(Boolean).join("\n"),
    );
  }
  if (envelope.ok !== true) throw new Error("The automation service returned an invalid response");
  if (!("data" in envelope)) throw new Error("The automation acknowledgement is missing its result");
  return envelope.data;
}
export const automationValue = (value: unknown) => object(automationResult(value));
export function acknowledgementUnknown(error: unknown, method: string): boolean {
  if (error instanceof ServiceRejection) return false;
  if (!(error instanceof RpcError)) return true;
  const kind =
    error.data && typeof error.data === "object" && !Array.isArray(error.data)
      ? (error.data as Record<string, unknown>).kind
      : undefined;
  if (
    ["automationAcknowledgementUnknown", "requestTimedOut", "inputDeliveryUncertain"].includes(String(kind))
  )
    return true;
  if (method === "conversation/agents/action" && error.code === -32603)
    return error.message !== "Agent execution changed; refresh before acting";
  return false;
}

type ReadState<T> = { identity: string; loading: boolean; value?: T; error?: string };
export function useRead<T>(identity: string, operation: (signal: AbortSignal) => Promise<T>) {
  const reader = useRef(operation);
  reader.current = operation;
  const owner = useRef<{ controller?: AbortController; mounted: boolean; identity: string }>({
    mounted: false,
    identity,
  });
  const [state, setState] = useState<ReadState<T>>({ identity, loading: true });
  const refresh = useCallback(() => {
    if (!owner.current.mounted || owner.current.identity !== identity) return;
    owner.current.controller?.abort();
    const controller = new AbortController();
    owner.current.controller = controller;
    setState((previous) => ({
      identity,
      loading: true,
      value: previous.identity === identity ? previous.value : undefined,
    }));
    void reader
      .current(controller.signal)
      .then((value) => {
        if (
          owner.current.mounted &&
          owner.current.identity === identity &&
          owner.current.controller === controller &&
          !controller.signal.aborted
        )
          setState({ identity, loading: false, value });
      })
      .catch((error) => {
        if (
          owner.current.mounted &&
          owner.current.identity === identity &&
          owner.current.controller === controller &&
          !controller.signal.aborted
        )
          setState((previous) => ({ ...previous, identity, loading: false, error: failure(error) }));
      });
  }, [identity]);
  useEffect(() => {
    owner.current.identity = identity;
    owner.current.mounted = true;
    refresh();
    return () => {
      owner.current.mounted = false;
      owner.current.controller?.abort();
    };
  }, [identity, refresh]);
  return { ...(state.identity === identity ? state : { identity, loading: true }), refresh };
}

type Mutation = {
  key: string;
  hostId: string;
  method: string;
  params: Record<string, unknown>;
  state: "pending" | "uncertain";
  error?: string;
};
const storageKey = "remotecoder.web.feature-mutations.v1";
const admittedMethods = new Set([
  "automations/set",
  "automations/remove",
  "automations/restore",
  "automations/run",
  "conversation/agents/action",
]);
const mutations = new Map<string, Mutation>();
const listeners = new Set<() => void>();
let mutationRevision = 0;
let storageError: string | undefined;
if (typeof sessionStorage !== "undefined") {
  try {
    const saved = sessionStorage.getItem(storageKey);
    if (saved && saved.length > 512 * 1024) throw new Error("Saved feature actions exceed their capacity");
    if (saved)
      for (const value of array(JSON.parse(saved), 16)) {
        const record = object(value);
        const method = identifier(record.method);
        if (!admittedMethods.has(method)) throw new Error("A saved action has an unsupported method");
        const key = identifier(record.key);
        mutations.set(key, {
          key,
          hostId: identifier(record.hostId),
          method,
          params: object(record.params),
          state: "uncertain",
          error: "The browser closed before this action was acknowledged.",
        });
      }
  } catch (error) {
    storageError = failure(error);
  }
}
function persist(next: Map<string, Mutation>) {
  const encoded = JSON.stringify([...next.values()]);
  if (next.size > 16 || new TextEncoder().encode(encoded).byteLength > 512 * 1024)
    throw new Error("Too many unacknowledged feature actions. Resolve an existing action first.");
  if (typeof sessionStorage !== "undefined") sessionStorage.setItem(storageKey, encoded);
}
function updateMutation(key: string, mutation?: Mutation) {
  const next = new Map(mutations);
  if (mutation) next.set(key, mutation);
  else next.delete(key);
  persist(next);
  mutations.clear();
  for (const [id, value] of next) mutations.set(id, value);
  mutationRevision += 1;
  for (const listener of listeners) listener();
}
export function useMutation(transport: FeatureTransport, scope: string) {
  const key = JSON.stringify([transport.hostId, scope]);
  useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => mutationRevision,
  );
  const pending = mutations.get(key);
  async function execute(mutation: Mutation) {
    if (mutation.hostId !== transport.hostId) throw new Error("The action belongs to another host");
    updateMutation(key, { ...mutation, state: "pending", error: undefined });
    try {
      const value = await transport.request(mutation.method, mutation.params, {
        timeout: mutation.method.startsWith("automations/") ? 310000 : 60000,
      });
      const result = mutation.method.startsWith("automations/") ? automationResult(value) : object(value);
      updateMutation(key);
      return result;
    } catch (error) {
      if (!acknowledgementUnknown(error, mutation.method)) updateMutation(key);
      else updateMutation(key, { ...mutation, state: "uncertain", error: failure(error) });
      throw error;
    }
  }
  return {
    pending,
    storageError,
    run(method: string, params: Record<string, unknown>) {
      if (storageError) return Promise.reject(new Error(`Saved actions could not be read: ${storageError}`));
      if (mutations.has(key))
        return Promise.reject(new Error("Resolve the previous action before sending another"));
      if (!admittedMethods.has(method)) return Promise.reject(new Error("Unsupported feature action"));
      return execute({
        key,
        hostId: transport.hostId,
        method,
        params: structuredClone(params),
        state: "pending",
      });
    },
    retry() {
      const existing = mutations.get(key);
      if (existing?.state !== "uncertain")
        return Promise.reject(new Error("There is no uncertain action to retry"));
      return execute(existing);
    },
  };
}
export function ReadStatus({ loading, error }: { loading: boolean; error?: string }) {
  return (
    <>
      {loading && (
        <p className="panel-muted" role="status">
          Loading…
        </p>
      )}
      {error && (
        <p className="panel-error" role="alert">
          {error}
        </p>
      )}
    </>
  );
}
export function MutationStatus({
  mutation,
  retry,
}: {
  mutation: ReturnType<typeof useMutation>;
  retry(): void;
}) {
  return (
    <>
      {mutation.storageError && (
        <p className="panel-error">Saved actions could not be read: {mutation.storageError}</p>
      )}
      {mutation.pending && (
        <div className="panel-notice">
          <p>
            {mutation.pending.state === "pending"
              ? "Waiting for acknowledgement…"
              : "Acknowledgement is unknown. Retry sends the same action and request ID."}
          </p>
          {mutation.pending.error && <p>{mutation.pending.error}</p>}
          {mutation.pending.state === "uncertain" && (
            <button type="button" onClick={retry}>
              Retry original action
            </button>
          )}
        </div>
      )}
    </>
  );
}
