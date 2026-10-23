export type ConversationDrawerMode = "priority" | "projects";
export type ConversationDrawerArrangement = Readonly<{
  mode: ConversationDrawerMode;
  unreadOnly: boolean;
  isPinnedFolded: boolean;
  isAutomationsFolded: boolean;
  isSettledFolded: boolean;
  foldedProjects: ReadonlySet<string>;
  revealedProjects: ReadonlySet<string>;
  projectRowLimit: number;
  automationRowLimit: number;
  settledRowLimit: number;
  query: string;
}>;
type LocalPreferences = Pick<
  ConversationDrawerArrangement,
  "unreadOnly" | "isPinnedFolded" | "isAutomationsFolded" | "isSettledFolded" | "foldedProjects"
>;
const storageKey = "remotecoder.web.drawer.v1";

export class ConversationDrawerPreferences {
  private state: Omit<ConversationDrawerArrangement, "mode"> = {
    unreadOnly: false,
    isPinnedFolded: false,
    isAutomationsFolded: false,
    isSettledFolded: true,
    foldedProjects: new Set(),
    revealedProjects: new Set(),
    projectRowLimit: 5,
    automationRowLimit: 5,
    settledRowLimit: 10,
    query: "",
  };
  private cached?: ConversationDrawerArrangement;
  readonly restoreError?: string;
  constructor(
    private readonly storage: Storage | undefined,
    private readonly mode: () => ConversationDrawerMode,
    private readonly publish: () => void,
  ) {
    try {
      const raw = storage?.getItem(storageKey);
      if (raw) {
        const value: unknown = JSON.parse(raw);
        if (!value || typeof value !== "object" || Array.isArray(value))
          throw new Error("Invalid drawer preferences");
        const preferences = value as Record<string, unknown>;
        const folded = preferences.foldedProjects;
        if (
          typeof preferences.unreadOnly !== "boolean" ||
          typeof preferences.isPinnedFolded !== "boolean" ||
          typeof preferences.isSettledFolded !== "boolean" ||
          (preferences.isAutomationsFolded !== undefined &&
            typeof preferences.isAutomationsFolded !== "boolean") ||
          !Array.isArray(folded) ||
          folded.length > 256 ||
          folded.some((key) => typeof key !== "string")
        )
          throw new Error("Invalid drawer preferences");
        this.state = {
          ...this.state,
          unreadOnly: preferences.unreadOnly,
          isPinnedFolded: preferences.isPinnedFolded,
          isAutomationsFolded: preferences.isAutomationsFolded === true,
          isSettledFolded: preferences.isSettledFolded,
          foldedProjects: new Set(folded),
        };
      }
    } catch (error) {
      this.restoreError = error instanceof Error ? error.message : "Drawer preferences could not be restored";
    }
  }
  get snapshot(): ConversationDrawerArrangement {
    const mode = this.mode();
    if (!this.cached || this.cached.mode !== mode) this.cached = { ...this.state, mode };
    return this.cached;
  }
  private change(change: Partial<Omit<ConversationDrawerArrangement, "mode">>, persist = false) {
    const next = { ...this.state, ...change };
    if (persist) {
      const local: LocalPreferences = next;
      this.storage?.setItem(
        storageKey,
        JSON.stringify({
          unreadOnly: local.unreadOnly,
          isPinnedFolded: local.isPinnedFolded,
          isAutomationsFolded: local.isAutomationsFolded,
          isSettledFolded: local.isSettledFolded,
          foldedProjects: [...local.foldedProjects],
        }),
      );
    }
    this.state = next;
    this.cached = undefined;
    this.publish();
  }
  setUnreadOnly(unreadOnly: boolean) {
    this.change({ unreadOnly }, true);
  }
  setQuery(query: string) {
    this.change({ query: query.slice(0, 4096) });
  }
  setPinnedFolded(isPinnedFolded: boolean) {
    this.change({ isPinnedFolded }, true);
  }
  setAutomationsFolded(isAutomationsFolded: boolean) {
    this.change({ isAutomationsFolded }, true);
  }
  setSettledFolded(isSettledFolded: boolean) {
    this.change({ isSettledFolded }, true);
  }
  setProjectFolded(key: string, folded: boolean, present: ReadonlySet<string>) {
    let keys = new Set(this.state.foldedProjects);
    if (folded) keys.add(key);
    else keys.delete(key);
    if (keys.size > 256) keys = new Set([...keys].filter((key) => present.has(key)).slice(0, 256));
    this.change({ foldedProjects: keys }, true);
  }
  setAllSectionsFolded(folded: boolean, present: ReadonlySet<string>) {
    const keys = folded
      ? new Set([...this.state.foldedProjects, ...present])
      : new Set([...this.state.foldedProjects].filter((key) => !present.has(key)));
    this.change(
      {
        isPinnedFolded: folded,
        isAutomationsFolded: folded,
        isSettledFolded: folded,
        foldedProjects: keys.size > 256 ? new Set([...present].slice(0, 256)) : keys,
      },
      true,
    );
  }
  revealProject(key: string) {
    this.change({ revealedProjects: new Set([...this.state.revealedProjects, key].slice(-256)) });
  }
  revealAllAutomations() {
    this.change({ automationRowLimit: Number.MAX_SAFE_INTEGER });
  }
  revealMoreSettled() {
    this.change({ settledRowLimit: this.state.settledRowLimit + 25 });
  }
  resetReveals() {
    if (
      this.state.revealedProjects.size ||
      this.state.automationRowLimit !== 5 ||
      this.state.settledRowLimit !== 10
    )
      this.change({ revealedProjects: new Set(), automationRowLimit: 5, settledRowLimit: 10 });
  }
}
