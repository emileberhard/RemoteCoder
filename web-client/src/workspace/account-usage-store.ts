import {
  type AccountCatalog,
  accountCatalog,
  type CodexChoice,
  type ExecutionTarget,
  sameBinding,
} from "../execution-context";
import { api } from "../gateway";
import { array, identifier, object, type Provider, string } from "../protocol/boundary";
import type { HostState } from "./host-services";
import { failure, type Load } from "./load-state";

export type UsageRow = Readonly<{
  id: string;
  title: string;
  kind: "fiveHour" | "weekly" | "fable" | "other";
  remainingPercent: number;
  stale: boolean;
  resetsAt?: number;
  runOutWarning?: Readonly<{ leadSeconds: number; severity: number }>;
}>;
export type UsageAccount = Readonly<{
  id: string;
  title: string;
  plan?: string;
  targets: readonly ExecutionTarget[];
  rows: readonly UsageRow[];
  notice?: string;
  availability?: string;
  availableAt?: number;
  shared?: boolean;
  credential?: "ready" | "rejected";
  observedAt?: number;
}>;
export type ProviderUsage = Readonly<{
  provider: Provider;
  accounts: readonly UsageAccount[];
  account?: UsageAccount;
  weekly?: UsageRow;
  fiveHour?: UsageRow;
  innerRing?: UsageRow;
  loading: boolean;
  status: "unread" | "loading" | "ready" | "failed";
  error?: string;
}>;
export type AccountUsageSnapshot = Readonly<{
  codex: ProviderUsage;
  claude: ProviderUsage &
    Readonly<{
      automatic?: string;
      preference?: string | null;
      selecting: boolean;
      canSelect: boolean;
    }>;
}>;
export type UsageWindow = {
  id: string;
  label: string;
  durationMinutes?: number;
  usedPercent: number;
  resetsAt?: number;
  model?: string;
};
type Sample = { windows: UsageWindow[]; observedAt?: number; plan?: string };
export type CodexUsageSample = Sample & { choice: CodexChoice; stale: boolean };
export type ClaudeUsageSample = Sample & {
  id: string;
  label: string;
  shared: boolean;
  credential: "ready" | "rejected";
  availability: string;
  availableAt?: number;
};
export type ClaudeUsageDirectory = {
  accounts: ClaudeUsageSample[];
  automatic: string;
  preference: string | null;
};
type HostRead = {
  host: HostState;
  controller: AbortController;
  accounts: CodexUsageSample[];
  catalog?: AccountCatalog;
  loading: boolean;
  error?: string;
  task?: Promise<void>;
  foreground?: object;
};
type Request = (path: string, init?: RequestInit) => Promise<unknown>;

function optionalNumber(value: unknown): number | undefined {
  if (value == null) return undefined;
  if (typeof value !== "number" || !Number.isFinite(value)) throw new Error("Invalid account usage number");
  return value;
}
function flag(value: unknown): boolean {
  if (typeof value !== "boolean") throw new Error("Invalid account usage flag");
  return value;
}
function optionalText(value: unknown): string | undefined {
  return value == null ? undefined : string(value);
}
function windows(value: unknown): UsageWindow[] {
  const seen = new Set<string>();
  return array(value, 32).map((value) => {
    const window = object(value);
    const id = identifier(window.id);
    const usedPercent = optionalNumber(window.usedPercent);
    const durationMinutes = optionalNumber(window.durationMinutes);
    if (
      seen.has(id) ||
      usedPercent === undefined ||
      usedPercent < 0 ||
      usedPercent > 100 ||
      (durationMinutes !== undefined && !Number.isSafeInteger(durationMinutes))
    )
      throw new Error("Invalid account usage window");
    seen.add(id);
    return {
      id,
      label: string(window.label),
      usedPercent,
      durationMinutes,
      resetsAt: optionalNumber(window.resetsAt),
      model: optionalText(window.model),
    };
  });
}
function accountUsageDirectory(
  hostId: string,
  value: unknown,
): { catalog: AccountCatalog; accounts: CodexUsageSample[] } {
  const catalog = accountCatalog(hostId, value);
  const records = array(object(value).accounts, 128).map(object);
  const accounts = catalog.choices.map((choice) => {
    const account = records.find((account) =>
      choice.isDefault
        ? account.id === "default-codex"
        : String(account.id).toLowerCase() === choice.target.enrollment?.accountId,
    );
    if (!account) throw new Error("Account usage has no exact enrollment");
    return {
      choice,
      windows: windows(account.windows),
      observedAt: optionalNumber(account.observedAt),
      stale: flag(account.stale),
      plan: optionalText(account.plan),
    };
  });
  return { catalog, accounts };
}
export function parseCodexUsageDirectory(hostId: string, value: unknown): CodexUsageSample[] {
  return accountUsageDirectory(hostId, value).accounts;
}
export function parseClaudeUsageDirectory(value: unknown): ClaudeUsageDirectory {
  const directory = object(value);
  const seen = new Set<string>();
  const accounts = array(directory.accounts, 128).map((value): ClaudeUsageSample => {
    const account = object(value);
    const id = identifier(account.id);
    const credential = string(account.credential);
    const availability = string(account.availability);
    if (
      seen.has(id) ||
      !["ready", "rejected"].includes(credential) ||
      !["available", "cooling", "exhausted", "rejected", "unavailable"].includes(availability)
    )
      throw new Error("Invalid Claude account usage");
    seen.add(id);
    return {
      id,
      label: string(account.label),
      plan: string(account.plan),
      shared: flag(account.shared),
      credential: credential as ClaudeUsageSample["credential"],
      availability,
      availableAt: optionalNumber(account.availableAt),
      observedAt: optionalNumber(account.observedAt),
      windows: windows(account.windows),
    };
  });
  const automatic = identifier(directory.automatic);
  const preference = directory.preference == null ? null : identifier(directory.preference);
  if (!seen.has(automatic) || (preference !== null && !seen.has(preference)))
    throw new Error("Claude routing refers to an unavailable account");
  return { accounts, automatic, preference };
}
function rows(sample: Sample, provider: Provider, stale: boolean, now: number): UsageRow[] {
  return sample.windows.map((window) => {
    const kind: UsageRow["kind"] =
      provider === "claude"
        ? window.durationMinutes === 300
          ? "fiveHour"
          : "weekly"
        : window.model?.toLowerCase().includes("fable")
          ? "fable"
          : window.model !== undefined
            ? "other"
            : window.durationMinutes === 300
              ? "fiveHour"
              : window.durationMinutes === 10080
                ? "weekly"
                : "other";
    let runOutWarning: UsageRow["runOutWarning"];
    if (
      kind === "fiveHour" &&
      window.durationMinutes !== undefined &&
      window.durationMinutes > 0 &&
      window.resetsAt !== undefined &&
      sample.observedAt !== undefined &&
      now < window.resetsAt
    ) {
      const remaining = 100 - window.usedPercent;
      const elapsed = sample.observedAt - (window.resetsAt - window.durationMinutes * 60);
      if (remaining < 60 && elapsed > 0) {
        const leadSeconds =
          window.resetsAt - (sample.observedAt + (remaining * elapsed) / window.usedPercent);
        if (leadSeconds > 0) runOutWarning = { leadSeconds, severity: Math.min(1, leadSeconds / 7200) };
      }
    }
    return {
      id: window.id,
      title:
        kind === "fiveHour"
          ? "5-hour"
          : kind === "weekly"
            ? "Weekly"
            : kind === "fable"
              ? "Fable weekly"
              : window.label,
      kind,
      remainingPercent: Math.round(100 - window.usedPercent),
      stale,
      resetsAt: window.resetsAt,
      runOutWarning,
    };
  });
}
function presentation(
  provider: Provider,
  accounts: UsageAccount[],
  account: UsageAccount | undefined,
  status: ProviderUsage["status"],
  error?: string,
): ProviderUsage {
  const weekly = account?.rows.find((row) => row.kind === "weekly");
  const fiveHour = account?.rows.find((row) => row.kind === "fiveHour");
  return {
    provider,
    accounts,
    account,
    weekly,
    fiveHour,
    innerRing: fiveHour?.runOutWarning ? fiveHour : undefined,
    loading: status === "loading",
    status,
    error,
  };
}
const stateTitles = {
  ready: "Ready",
  authenticationRequired: "Sign-in required",
  identityMismatch: "Account identity changed",
  unavailable: "Unavailable",
  disabled: "Disabled",
  unknown: "Unknown",
};

export class AccountUsageStore {
  private readonly hosts = new Map<HostState, HostRead>();
  private claude?: ClaudeUsageDirectory;
  private claudeHost?: HostState;
  private claudeError?: string;
  private claudeOperation?: {
    controller: AbortController;
    task: Promise<void>;
    interactive: boolean;
    selecting: boolean;
    foreground?: object;
  };
  private disposed = false;
  private foreground?: { timer?: ReturnType<typeof setTimeout> };
  private presentationCache?: { now: number; target: string; value: AccountUsageSnapshot };
  constructor(
    private readonly getHosts: () => readonly HostState[],
    private readonly published: () => void,
    private readonly request: Request = api,
  ) {}

  private publish() {
    this.presentationCache = undefined;
    this.published();
  }
  reconcile() {
    if (this.disposed) return;
    this.presentationCache = undefined;
    const active = this.getHosts().filter(
      (host) => !host.target.enrollment && !host.controller.signal.aborted,
    );
    const changed = active.length !== this.hosts.size || active.some((host) => !this.hosts.has(host));
    if (changed) {
      this.claudeOperation?.controller.abort();
      this.claudeOperation = undefined;
    }
    for (const host of this.hosts.keys())
      if (!active.includes(host)) {
        this.hosts.get(host)?.controller.abort();
        this.hosts.delete(host);
      }
    for (const host of active)
      if (!this.hosts.has(host))
        this.hosts.set(host, { host, controller: new AbortController(), accounts: [], loading: false });
    if (this.claudeHost && !this.hosts.has(this.claudeHost)) {
      this.claudeHost = undefined;
      this.claude = undefined;
      this.claudeError = undefined;
      this.claudeOperation?.controller.abort();
      this.claudeOperation = undefined;
    }
    if (!active.length) {
      this.claude = undefined;
      this.claudeError = undefined;
    }
  }
  private present(host: HostState) {
    return (
      !this.disposed &&
      !host.controller.signal.aborted &&
      this.getHosts().includes(host) &&
      this.hosts.has(host)
    );
  }
  private http(host: HostState, path: string, controller?: AbortController, init?: RequestInit) {
    return this.request(`/api/hosts/${encodeURIComponent(host.host.id)}/${path}`, {
      ...init,
      signal: controller
        ? AbortSignal.any([controller.signal, host.controller.signal])
        : host.controller.signal,
    });
  }
  snapshot(now: number, selectedTarget: ExecutionTarget | undefined): AccountUsageSnapshot {
    const target = JSON.stringify(selectedTarget);
    if (this.presentationCache?.now === now && this.presentationCache.target === target)
      return this.presentationCache.value;
    const groups = new Map<string, { sample: CodexUsageSample; members: CodexUsageSample[] }>();
    for (const state of this.hosts.values())
      for (const sample of state.accounts) {
        const id = sample.choice.groupId ?? `codex:${JSON.stringify(sample.choice.target)}`;
        const group = groups.get(id);
        const effective: CodexUsageSample = state.error
          ? {
              ...sample,
              stale: true,
              choice: {
                ...sample.choice,
                usable: false,
                state: sample.choice.state === "ready" ? "unavailable" : sample.choice.state,
              },
            }
          : sample;
        if (!group) groups.set(id, { sample: effective, members: [sample] });
        else {
          group.members.push(sample);
          const rank = (value: CodexUsageSample) => Number(value.choice.usable) * 2 + Number(!value.stale);
          if (
            rank(effective) > rank(group.sample) ||
            (rank(effective) === rank(group.sample) &&
              (effective.observedAt ?? -Infinity) > (group.sample.observedAt ?? -Infinity))
          )
            group.sample = effective;
        }
      }
    let codexAccount: UsageAccount | undefined;
    const codexAccounts = [...groups].map(([id, group]): UsageAccount => {
      const sample = group.sample;
      const stale = sample.stale || sample.choice.state !== "ready";
      const account = {
        id,
        title: sample.choice.identity?.email ?? sample.choice.label,
        plan: sample.plan,
        targets: group.members.map((member) => member.choice.target),
        rows: rows(sample, "codex", stale, now),
        notice:
          sample.choice.state !== "ready"
            ? stateTitles[sample.choice.state]
            : stale
              ? "Last known usage"
              : undefined,
      };
      if (selectedTarget && account.targets.some((target) => sameBinding(target, selectedTarget)))
        codexAccount = account;
      return account;
    });
    const codexHosts = [...this.hosts.values()];
    const codexStatus = codexHosts.some((state) => state.loading)
      ? "loading"
      : codexHosts.some((state) => state.error)
        ? "failed"
        : !codexHosts.length || codexHosts.some((state) => state.catalog === undefined)
          ? "unread"
          : "ready";
    const codexErrors = codexHosts
      .filter((state) => state.error)
      .map((state) => `${state.host.host.name}: ${state.error}`);
    const claudeAccounts = (this.claude?.accounts ?? []).map((sample): UsageAccount => {
      const stale =
        Boolean(this.claudeError) ||
        sample.credential !== "ready" ||
        sample.observedAt === undefined ||
        now - sample.observedAt > 900;
      return {
        id: sample.id,
        title: sample.label,
        plan: sample.plan,
        shared: sample.shared,
        credential: sample.credential,
        observedAt: sample.observedAt,
        targets: [],
        rows: rows(sample, "claude", stale, now),
        availability: sample.availability,
        availableAt: sample.availableAt,
        notice:
          sample.credential === "rejected"
            ? "Credential rejected"
            : !sample.windows.length
              ? "Usage unavailable"
              : stale
                ? "Last known usage"
                : undefined,
      };
    });
    const value: AccountUsageSnapshot = {
      codex: presentation(
        "codex",
        codexAccounts,
        codexAccount,
        codexStatus,
        codexErrors.length ? codexErrors.join("\n") : undefined,
      ),
      claude: {
        ...presentation(
          "claude",
          claudeAccounts,
          claudeAccounts.find(
            (account) => account.id === (this.claude?.preference ?? this.claude?.automatic),
          ),
          this.claudeOperation && !this.claudeOperation.selecting
            ? "loading"
            : this.claudeError
              ? "failed"
              : this.claude
                ? "ready"
                : "unread",
          this.claudeError,
        ),
        automatic: this.claude?.automatic,
        preference: this.claude?.preference,
        selecting: Boolean(this.claudeOperation?.selecting),
        canSelect: Boolean(this.claudeHost && !this.claudeOperation?.selecting),
      },
    };
    this.presentationCache = { now, target, value };
    return value;
  }
  readCatalog(hostId: string): Load<AccountCatalog> {
    const state = [...this.hosts.values()].find((state) => state.host.host.id === hostId);
    if (!state) return { status: "unread" };
    if (state.loading) return { status: "loading" };
    if (state.error) return { status: "failed", error: state.error };
    return state.catalog ? { status: "ready", value: state.catalog } : { status: "unread" };
  }
  async refreshHost(hostId: string): Promise<void> {
    if (this.disposed) return;
    this.reconcile();
    const state = [...this.hosts.values()].find((state) => state.host.host.id === hostId);
    if (state) await this.refreshCodex(state);
  }
  refresh(provider: Provider, interactive = true): Promise<void> {
    return this.refreshProvider(provider, interactive);
  }
  private async refreshProvider(
    provider: Provider,
    interactive: boolean,
    foreground?: object,
  ): Promise<void> {
    if (this.disposed || (foreground && this.foreground !== foreground)) return;
    this.reconcile();
    if (provider === "claude") {
      const previous = this.claudeOperation;
      if (previous) {
        await previous.task;
        if (this.disposed || (foreground && this.foreground !== foreground)) return;
        if (
          previous.controller.signal.aborted ||
          (interactive && !previous.interactive && !previous.selecting)
        )
          return this.refreshProvider(provider, interactive, foreground);
        return;
      }
      return this.runClaude(
        interactive,
        false,
        async (controller) => {
          const failures: string[] = [];
          let succeeded = false;
          const hosts = [...this.hosts.keys()];
          for (let offset = 0; offset < hosts.length; offset += 3) {
            await Promise.all(
              hosts.slice(offset, offset + 3).map(async (host) => {
                try {
                  const value = parseClaudeUsageDirectory(
                    await this.http(
                      host,
                      interactive ? "claude/accounts/refresh" : "claude/accounts",
                      controller,
                      interactive ? { method: "POST", body: "{}" } : undefined,
                    ),
                  );
                  if (controller.signal.aborted || !this.present(host)) return;
                  this.claude = value;
                  this.claudeHost = host;
                  succeeded = true;
                } catch (error) {
                  if (!controller.signal.aborted && this.present(host))
                    failures.push(`${host.host.name}: ${failure(error)}`);
                }
              }),
            );
            if (controller.signal.aborted) return;
          }
          this.claudeError = succeeded
            ? undefined
            : failures.join("\n") || "No gateway is available for Claude accounts.";
          if (!succeeded) this.claudeHost = undefined;
        },
        foreground,
      );
    }
    const hosts = [...this.hosts.values()];
    for (let offset = 0; offset < hosts.length; offset += 3) {
      if (foreground && this.foreground !== foreground) return;
      await Promise.all(hosts.slice(offset, offset + 3).map((state) => this.refreshCodex(state, foreground)));
    }
  }
  private async refreshCodex(state: HostRead, foreground?: object): Promise<void> {
    if (!this.present(state.host)) return;
    if (state.task) {
      const controller = state.controller;
      await state.task;
      if (controller.signal.aborted && (!foreground || this.foreground === foreground))
        return this.refreshCodex(state, foreground);
      return;
    }
    const controller = state.controller;
    const current = () =>
      this.present(state.host) && !controller.signal.aborted && state.controller === controller;
    state.loading = true;
    state.foreground = foreground;
    const task = (async () => {
      try {
        const directory = accountUsageDirectory(
          state.host.host.id,
          await this.http(state.host, "accounts?refresh=true&wait=refresh", controller),
        );
        if (!current()) return;
        state.accounts = directory.accounts;
        state.catalog = directory.catalog;
        state.error = undefined;
      } catch (error) {
        if (current()) state.error = failure(error);
      } finally {
        if (current()) {
          state.loading = false;
          state.task = undefined;
          state.foreground = undefined;
          this.publish();
        }
      }
    })();
    state.task = task;
    this.publish();
    return task;
  }
  private runClaude(
    interactive: boolean,
    selecting: boolean,
    action: (controller: AbortController) => Promise<void>,
    foreground?: object,
  ) {
    const controller = new AbortController();
    const operation = { controller, task: Promise.resolve(), interactive, selecting, foreground };
    this.claudeOperation = operation;
    operation.task = action(controller).finally(() => {
      if (this.claudeOperation !== operation) return;
      this.claudeOperation = undefined;
      if (!this.disposed) this.publish();
    });
    this.publish();
    return operation.task;
  }
  async setClaudePreference(id: string | null): Promise<void> {
    if (this.disposed) return;
    this.reconcile();
    if (this.claudeOperation?.selecting) return;
    if (id !== null && !this.claude?.accounts.some((account) => account.id === id))
      throw new Error("Claude account unavailable.");
    this.claudeOperation?.controller.abort();
    return this.runClaude(false, true, async (controller) => {
      const hosts = [...this.hosts.keys()].sort(
        (a, b) => Number(b === this.claudeHost) - Number(a === this.claudeHost),
      );
      const failures: string[] = [];
      for (const host of hosts) {
        try {
          const available = parseClaudeUsageDirectory(await this.http(host, "claude/accounts", controller));
          if (controller.signal.aborted || !this.present(host)) return;
          this.claude = available;
          this.claudeHost = host;
          if (id !== null && !available.accounts.some((account) => account.id === id)) {
            this.claudeError = "Claude account unavailable.";
            return;
          }
        } catch (error) {
          if (controller.signal.aborted) return;
          failures.push(`${host.host.name}: ${failure(error)}`);
          continue;
        }
        try {
          const response = parseClaudeUsageDirectory(
            await this.http(host, "claude/accounts/preference", controller, {
              method: "PUT",
              body: JSON.stringify({ account: id }),
            }),
          );
          if (controller.signal.aborted || !this.present(host)) return;
          if (response.preference !== id)
            throw new Error("The gateway did not confirm the Claude account selection.");
          this.claude = response;
          this.claudeError = undefined;
        } catch (error) {
          if (controller.signal.aborted) return;
          const selectionError = failure(error);
          for (const candidate of [host, ...hosts.filter((candidate) => candidate !== host)]) {
            try {
              const confirmed = parseClaudeUsageDirectory(
                await this.http(candidate, "claude/accounts", controller),
              );
              if (controller.signal.aborted || !this.present(candidate)) return;
              this.claude = confirmed;
              this.claudeHost = candidate;
              this.claudeError = confirmed.preference === id ? undefined : selectionError;
              return;
            } catch (readError) {
              if (controller.signal.aborted) return;
              failures.push(`${candidate.host.name}: ${failure(readError)}`);
            }
          }
          this.claudeHost = undefined;
          this.claudeError = [selectionError, ...failures].join("\n");
        }
        return;
      }
      this.claudeHost = undefined;
      this.claudeError = failures.join("\n") || "No gateway is available for Claude account selection.";
    });
  }
  startForeground() {
    if (this.disposed || this.foreground) return;
    const foreground: { timer?: ReturnType<typeof setTimeout> } = {};
    this.foreground = foreground;
    const refresh = async () => {
      await Promise.all([
        this.refreshProvider("codex", false, foreground),
        this.refreshProvider("claude", false, foreground),
      ]);
      if (this.foreground === foreground)
        foreground.timer = setTimeout(() => {
          void refresh();
        }, 120_000);
    };
    void refresh();
  }
  stopForeground() {
    const foreground = this.foreground;
    if (!foreground) return;
    this.foreground = undefined;
    clearTimeout(foreground.timer);
    for (const state of this.hosts.values()) {
      if (state.foreground !== foreground) continue;
      state.controller.abort();
      state.controller = new AbortController();
      state.task = undefined;
      state.foreground = undefined;
      state.loading = false;
    }
    if (this.claudeOperation?.foreground === foreground && !this.claudeOperation.selecting) {
      this.claudeOperation.controller.abort();
      this.claudeOperation = undefined;
    }
    this.publish();
  }
  dispose() {
    this.stopForeground();
    this.disposed = true;
    this.claudeOperation?.controller.abort();
    this.claudeOperation = undefined;
    for (const state of this.hosts.values()) state.controller.abort();
    this.hosts.clear();
  }
}
