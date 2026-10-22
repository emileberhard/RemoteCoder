import {
  type PreferenceDocument,
  type PreferenceKey,
  type PreferenceValues,
  preferenceDocument,
  SyncedPreferences,
} from "../preferences";
import type { Provider } from "../protocol/boundary";
import type { HostServices, HostState } from "./host-services";
import { failure } from "./load-state";
export class SyncedPreferenceExchange {
  private readonly preferences: SyncedPreferences;
  private readonly events = new AbortController();
  private readonly exchanges = new WeakMap<
    HostState,
    { read: number; requested: boolean; task?: Promise<void> }
  >();
  private hasSynced = false;
  private disposed = false;
  constructor(
    storage: Storage | undefined,
    private readonly hosts: HostServices,
    private readonly publish: () => void,
    private readonly seedNewDraft: () => void,
    private readonly report: (error: unknown) => void,
  ) {
    this.preferences = new SyncedPreferences(storage);
    if (typeof window !== "undefined") {
      window.addEventListener(
        "focus",
        () => {
          void this.sync();
        },
        { signal: this.events.signal },
      );
      window.addEventListener(
        "storage",
        (event) => {
          if (event.storageArea !== storage) return;
          try {
            if (this.preferences.receiveStorage(event.key, event.newValue)) this.changed();
          } catch (error) {
            this.report(error);
          }
        },
        { signal: this.events.signal },
      );
      document.addEventListener(
        "visibilitychange",
        () => {
          if (document.visibilityState === "visible") void this.sync();
        },
        { signal: this.events.signal },
      );
    }
  }
  get restoreError() {
    return this.preferences.restoreError;
  }
  get themeID() {
    return this.preferences.themeID;
  }
  get<K extends PreferenceKey>(key: K) {
    return this.preferences.get(key);
  }
  set<K extends PreferenceKey>(key: K, value: PreferenceValues[K] | null) {
    if (!this.disposed && this.preferences.set(key, value)) this.changed();
  }
  visibleEfforts(provider: Provider) {
    return this.preferences.visibleEfforts(provider);
  }
  modelVisible(provider: Provider, id: string, defaultVisible: boolean) {
    return this.preferences.modelVisible(provider, id, defaultVisible);
  }
  setModelVisible(provider: Provider, id: string, visible: boolean, defaultVisible: boolean) {
    if (!this.disposed && this.preferences.setModelVisible(provider, id, visible, defaultVisible))
      this.changed();
  }
  receive(document: PreferenceDocument) {
    if (this.preferences.merge(document)) this.changed();
  }
  waitingForInitial(host: HostState) {
    return !this.hasSynced && Boolean(this.exchanges.get(host)?.task);
  }
  invalidate(host: HostState) {
    this.preferenceExchange(host).read++;
  }
  private changed() {
    this.publish();
    void this.sync();
  }
  async sync() {
    await Promise.all(
      this.hosts.snapshot
        .filter((host) => !host.connection || host.status === "connected")
        .map((host) => this.syncHost(host)),
    );
  }
  private preferenceExchange(host: HostState) {
    let exchange = this.exchanges.get(host);
    if (!exchange) {
      exchange = { read: 0, requested: false };
      this.exchanges.set(host, exchange);
    }
    return exchange;
  }
  syncHost(host: HostState): Promise<void> {
    const exchange = this.preferenceExchange(host);
    exchange.requested = true;
    if (exchange.task) return exchange.task;
    const run = async () => {
      while (exchange.requested && this.hosts.present(host) && !this.disposed) {
        exchange.requested = false;
        const read = exchange.read;
        this.hosts.setPreferences(host, { status: "loading" });
        try {
          let document = preferenceDocument(
            await host.rpc.call("preferences/read", {}, { signal: host.controller.signal }),
          );
          if (!this.hosts.present(host) || read !== exchange.read) continue;
          if (this.preferences.merge(document)) this.changed();
          this.hasSynced = true;
          this.seedNewDraft();
          const entries = this.preferences.pending(document);
          if (Object.keys(entries).length) {
            document = preferenceDocument(
              await host.rpc.call("preferences/update", { entries }, { signal: host.controller.signal }),
            );
            if (!this.hosts.present(host) || read !== exchange.read) continue;
            if (this.preferences.merge(document)) this.changed();
          }
          this.hosts.setPreferences(host, { status: "ready", value: document });
        } catch (error) {
          if (this.hosts.present(host) && read === exchange.read)
            this.hosts.setPreferences(host, { status: "failed", error: failure(error) });
        }
        this.publish();
      }
    };
    exchange.task = Promise.resolve()
      .then(run)
      .finally(() => {
        exchange.task = undefined;
        if (exchange.requested && this.hosts.present(host) && !this.disposed) return this.syncHost(host);
        if (this.hosts.present(host) && !this.disposed) this.seedNewDraft();
      });
    return exchange.task;
  }

  dispose() {
    this.disposed = true;
    this.events.abort();
  }
}
