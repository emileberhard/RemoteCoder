import { api } from "../gateway";
import { object, string } from "../protocol/boundary";
import type { HostState } from "./host-services";
import { failure, type Load } from "./load-state";

export type GatewayVersion = Readonly<{ version: string; commit: string | null; modified?: boolean }>;
type VersionRead = { host: HostState; controller: AbortController; state: Load<GatewayVersion> };
type Request = (path: string, init?: RequestInit) => Promise<unknown>;

function version(value: unknown): GatewayVersion {
  const result = object(value);
  const field = (value: unknown, name: string) => {
    const text = string(value, name);
    if (!text.trim() || text.length > 128 || /\p{Cc}/u.test(text))
      throw new Error(`The gateway returned an invalid ${name}`);
    return text;
  };
  const version = field(result.version, "version");
  const recordedCommit = result.commit == null ? undefined : string(result.commit, "commit");
  const commit = recordedCommit && /^[0-9a-f]{40}$/i.test(recordedCommit) ? recordedCommit : null;
  if (result.modified != null && typeof result.modified !== "boolean")
    throw new Error("The gateway returned an invalid modified state");
  const modified = result.modified == null ? undefined : result.modified;
  if (
    version !== "dev" &&
    (!/^(0|[1-9]\d*)\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})$/.test(version) || !commit || modified !== false)
  )
    throw new Error("The gateway returned an invalid build identity");
  return { version, commit, ...(modified === undefined ? {} : { modified }) };
}

export class HostVersions {
  private readonly values = new Map<string, VersionRead>();
  private operation?: { entries: VersionRead[]; task: Promise<void> };
  private disposed = false;
  constructor(
    private readonly getHosts: () => readonly HostState[],
    private readonly publish: () => void,
    private readonly request: Request = api,
  ) {}
  reconcile() {
    if (this.disposed) return;
    const hosts = this.getHosts().filter(
      (host) => !host.target.enrollment && !host.controller.signal.aborted,
    );
    for (const [id, entry] of this.values) {
      if (hosts.includes(entry.host)) continue;
      entry.controller.abort();
      this.values.delete(id);
    }
    for (const host of hosts) {
      if (this.values.has(host.host.id)) continue;
      this.values.set(host.host.id, { host, controller: new AbortController(), state: { status: "unread" } });
    }
  }
  read(hostId: string): Load<GatewayVersion> {
    return this.values.get(hostId)?.state ?? { status: "unread" };
  }
  async refresh(): Promise<void> {
    if (this.disposed) return;
    this.reconcile();
    const entries = [...this.values.values()];
    const previous = this.operation;
    if (previous) {
      await previous.task;
      if (entries.some((entry) => !previous.entries.includes(entry))) await this.refresh();
      return;
    }
    const operation = { entries, task: Promise.resolve() };
    this.operation = operation;
    operation.task = (async () => {
      for (let offset = 0; offset < entries.length && !this.disposed; offset += 3)
        await Promise.all(entries.slice(offset, offset + 3).map((entry) => this.refreshHost(entry)));
    })().finally(() => {
      if (this.operation === operation) this.operation = undefined;
    });
    return operation.task;
  }
  private present(entry: VersionRead) {
    return (
      !this.disposed &&
      !entry.controller.signal.aborted &&
      !entry.host.controller.signal.aborted &&
      this.values.get(entry.host.host.id) === entry &&
      this.getHosts().includes(entry.host)
    );
  }
  private async refreshHost(entry: VersionRead) {
    if (!this.present(entry)) return;
    entry.state = { status: "loading" };
    this.publish();
    try {
      const value = version(
        await this.request(`/api/hosts/${encodeURIComponent(entry.host.host.id)}/version`, {
          signal: AbortSignal.any([entry.controller.signal, entry.host.controller.signal]),
        }),
      );
      if (!this.present(entry)) return;
      entry.state = { status: "ready", value };
    } catch (error) {
      if (!this.present(entry)) return;
      entry.state = { status: "failed", error: failure(error) };
    }
    this.publish();
  }
  dispose() {
    this.disposed = true;
    for (const entry of this.values.values()) entry.controller.abort();
    this.values.clear();
  }
}
