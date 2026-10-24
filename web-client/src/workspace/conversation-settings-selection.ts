import { type ExecutionTarget, sameBinding } from "../execution-context";
import { canonicalModelID, clampedEffort, reasoningEffort } from "../preferences";
import { type Address, addressKey, object, type Provider } from "../protocol/boundary";
import claudeCatalog from "../protocol/claude-models.json";
import nativeModelDefaults from "../protocol/native-model-defaults.json";
import { blank, type ComposerDraftStore, type Draft } from "./composer-draft-store";
import type { Conversation } from "./conversation-session";
import type { HostServices, HostState, ModelChoice } from "./host-services";
import type { SyncedPreferenceExchange } from "./synced-preference-exchange";

type PickerSettings = Pick<Draft, "model" | "provider" | "effort" | "fast">;
type PickerUpdate = {
  settings: PickerSettings;
  resolve: () => void;
  reject: (error: unknown) => void;
};
type PickerSync = { confirmed: PickerSettings; running: boolean; pending?: PickerUpdate };

export class ConversationSettingsSelection {
  private readonly pickerSyncs = new WeakMap<Conversation, PickerSync>();
  constructor(
    private readonly hosts: HostServices,
    private readonly drafts: ComposerDraftStore,
    private readonly preferences: SyncedPreferenceExchange,
    private readonly current: () => {
      host: HostState | undefined;
      conversation: Conversation | undefined;
      draft: Draft;
      draftKey: string;
      selected: Address | undefined;
    },
    private readonly selectTarget: (target: ExecutionTarget) => Promise<void>,
    private readonly isRetired: () => boolean,
    private readonly report: (error: unknown) => void,
  ) {}
  private get newChatDefaults() {
    const model = this.preferences.get("codex.newChatModel");
    const reasoning = this.preferences.get("codex.newChatReasoning");
    return {
      model:
        model !== null && model !== "last-selected" ? model : this.preferences.get("codex.defaultModelID"),
      reasoning:
        reasoning && reasoning !== "last-selected"
          ? reasoning
          : (this.preferences.get("codex.defaultReasoningSelection") ?? "effort-high"),
      fast: this.preferences.get("codex.fastModeEnabled") ?? false,
    };
  }
  seedNewDraft() {
    const current = this.current();
    if (
      current.selected ||
      this.drafts.get(current.draftKey)?.model ||
      current.host?.choices.status !== "ready" ||
      this.preferences.waitingForInitial(this.hosts.get(current.host.host.id))
    )
      return;
    const defaults = this.newChatDefaults;
    const preferred = defaults.model ? canonicalModelID(defaults.model) : undefined;
    const provider = claudeCatalog.some((choice) => choice.id === preferred) ? "claude" : "codex";
    const visible = this.modelVisibilityChoices().filter(
      (choice) => choice.visible && choice.provider === provider,
    );
    const choice =
      visible.find((choice) => choice.id === preferred) ??
      (provider === "codex"
        ? (visible.find((choice) => choice.id === nativeModelDefaults.initialCodexModelID) ??
          visible.find((choice) => choice.upstreamDefault))
        : undefined) ??
      visible[0];
    const availableEfforts =
      choice?.efforts.filter((effort) => this.preferences.visibleEfforts(provider).has(effort)) ?? [];
    this.drafts.update({
      provider,
      model: choice?.id ?? "",
      effort: clampedEffort(reasoningEffort(defaults.reasoning) ?? "high", availableEfforts),
      fast: choice?.fast === true && defaults.fast,
    });
  }
  choices(): ModelChoice[] {
    const catalog = this.modelVisibilityChoices();
    const selected = this.drafts.snapshot.get(this.current().draftKey);
    const conversation = this.current().conversation;
    const provider = selected?.provider ?? conversation?.header.provider;
    const storedModel = selected?.model || conversation?.header.model;
    const model = provider === "claude" && storedModel ? canonicalModelID(storedModel) : storedModel;
    const route =
      conversation && provider === "codex"
        ? catalog.find((choice) => choice.provider === "codex" && choice.id === model)
        : undefined;
    const result: ModelChoice[] = catalog
      .filter((choice) => choice.visible)
      .filter(
        (choice) => !route || choice.provider !== "codex" || choice.modelProvider === route.modelProvider,
      )
      .map((choice) => ({
        ...choice,
        efforts: choice.efforts.filter((effort) =>
          this.preferences.visibleEfforts(choice.provider).has(effort),
        ),
      }));
    if (model && provider && !result.some((choice) => choice.id === model && choice.provider === provider)) {
      const listed = catalog.find((choice) => choice.id === model && choice.provider === provider);
      if (listed)
        result.push({
          ...listed,
          id: model,
          efforts: listed.efforts.filter((effort) => this.preferences.visibleEfforts(provider).has(effort)),
        });
      else if (provider === "codex" && conversation)
        result.push({
          id: model,
          name: model,
          provider,
          efforts: selected?.effort ? [selected.effort] : [],
          defaultEffort: selected?.effort ?? "",
          fast: selected?.fast ?? false,
          images: true,
        });
    }
    return result;
  }
  modelVisibilityChoices() {
    const host = this.current().host;
    const catalog = host?.choices.status === "ready" ? host.choices.value : [];
    return catalog.map((choice) => ({
      ...choice,
      visible: this.preferences.modelVisible(choice.provider, choice.id, !choice.hiddenUpstream),
    }));
  }
  setModelVisible(provider: Provider, id: string, visible: boolean) {
    if (this.isRetired()) return;
    const canonical = provider === "claude" ? canonicalModelID(id) : id;
    const entry = this.modelVisibilityChoices().find(
      (choice) => choice.provider === provider && choice.id === canonical,
    );
    if (!entry) throw new Error("The model catalog has no matching visibility setting");
    this.preferences.setModelVisible(provider, canonical, visible, !entry.hiddenUpstream);
  }
  async chooseModel(choice: ModelChoice | undefined) {
    if (!choice || this.isRetired()) return;
    const current = this.current().draft;
    await this.applyPickerSettings(
      choice,
      clampedEffort(current.effort, choice.efforts),
      choice.fast && current.fast,
      () => this.preferences.set("codex.defaultModelID", choice.id),
    );
  }
  async chooseReasoning(effort: string) {
    if (this.isRetired()) return;
    const choice = this.currentModelChoice();
    const selected = effort === "" ? "" : reasoningEffort(effort);
    if (selected === undefined || (selected !== "" && !choice.efforts.includes(selected)))
      throw new Error("Choose an available reasoning effort");
    await this.applyPickerSettings(choice, selected, this.current().draft.fast, () =>
      this.preferences.set("codex.defaultReasoningSelection", selected ? `effort-${selected}` : "automatic"),
    );
  }
  async chooseFastMode(enabled: boolean) {
    if (this.isRetired()) return;
    const choice = this.currentModelChoice();
    if (enabled && !choice.fast) throw new Error("The selected model does not support Fast mode");
    await this.applyPickerSettings(choice, this.current().draft.effort, enabled, () =>
      this.preferences.set("codex.fastModeEnabled", enabled),
    );
  }
  private currentModelChoice() {
    const draft = this.current().draft;
    const choice = this.choices().find(
      (choice) => choice.id === draft.model && choice.provider === draft.provider,
    );
    if (!choice) throw new Error("Choose an available model first");
    return choice;
  }
  private async applyPickerSettings(choice: ModelChoice, effort: string, fast: boolean, record: () => void) {
    const conversation = this.current().conversation;
    if (conversation && choice.provider !== conversation.header.provider)
      throw new Error("Start a new conversation to change agent provider");
    const next = { model: choice.id, provider: choice.provider, effort, fast };
    const key = this.current().draftKey;
    const current = this.current().draft;
    const previous: PickerSettings = {
      model: current.model,
      provider: current.provider,
      effort: current.effort,
      fast: current.fast,
    };
    record();
    this.drafts.update(next, key);
    const host = this.current().host;
    if (!conversation && choice.provider === "claude" && host?.target.enrollment) {
      const target = { hostId: host.host.id };
      await this.selectTarget(target);
      const selected = this.current();
      if (!selected.host || !sameBinding(selected.host.target, target) || selected.conversation) return;
      const original = this.drafts.get(key);
      this.drafts.update({ ...(original ?? blank(selected.host.host)), ...next });
      return;
    }
    if (!conversation) return;
    let sync = this.pickerSyncs.get(conversation);
    if (!sync) {
      sync = { confirmed: previous, running: false };
      this.pickerSyncs.set(conversation, sync);
    }
    const owner = sync;
    await new Promise<void>((resolve, reject) => {
      owner.pending?.resolve();
      owner.pending = { settings: next, resolve, reject };
      if (!owner.running) void this.flushPickerSettings(conversation, owner);
    });
  }
  private async flushPickerSettings(conversation: Conversation, sync: PickerSync) {
    sync.running = true;
    while (sync.pending) {
      const update = sync.pending;
      sync.pending = undefined;
      try {
        const result = object(
          await this.hosts.get(conversation.address).rpc.call(
            "conversation/settings/update",
            {
              threadId: conversation.address.threadId,
              model: update.settings.model,
              effort: update.settings.effort || null,
              serviceTier: update.settings.fast ? "fast" : null,
              summary: "detailed",
            },
            { timeout: 90000, signal: conversation.controller.signal },
          ),
        );
        if (result.status === "targetUnavailable")
          throw new Error("Conversation settings could not be applied");
        sync.confirmed = update.settings;
        if (!sync.pending) {
          if (result.warning) this.report(result.warning);
          if (result.status === "nextTurn") this.report("The selected settings will apply to the next turn.");
        }
        update.resolve();
      } catch (error) {
        if (sync.pending) update.resolve();
        else {
          if (!this.isRetired() && !conversation.controller.signal.aborted)
            this.drafts.update(sync.confirmed, addressKey(conversation.address));
          update.reject(error);
        }
      }
    }
    sync.running = false;
  }
}
