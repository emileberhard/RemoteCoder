import { AlertCircle, X } from "lucide-react";
import { useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { api } from "../gateway";
import { browserDiagrams } from "../platform/diagrams";
import { browserVisuals } from "../platform/visuals";
import { addressKey } from "../protocol/boundary";
import { useCommandShortcuts } from "./chat/chat-commands";
import { ChatHeader } from "./chat/chat-header";
import { type ChatWindow, useChatWindowActions } from "./chat/chat-window-actions";
import { CommandPalette } from "./chat/command-palette";
import { Composer, type ComposerHandle } from "./chat/composer/composer";
import { EmptyConversation } from "./chat/empty-conversation";
import { Inspector } from "./chat/inspector";
import { MediaProvider, VoiceDialog } from "./chat/media";
import { Transcript } from "./chat/transcript/transcript";
import { HistorySidebar } from "./conversations/history-sidebar";
import { PinNameDialog, type PinNameIntent } from "./conversations/pin-name-dialog";
import { DiagramThemeContext, useDarkAppearance, visualTheme } from "./design-system/appearance";
import { IconButton } from "./design-system/icon-button";
import { DirectoryPicker } from "./directory-picker/directory-picker";
import { enterWorkspace, savedSelection, saveSelection } from "./selection-restore";
import { SettingsDialog, type SettingsTab } from "./settings/settings-dialog";
import { UnlockScreen } from "./unlock-screen";
import { useRun, useSnapshot, useWorkspace } from "./workspace-context";

const compactQuery = "(max-width: 760px)";
type Modal =
  | { kind: "settings"; tab: SettingsTab }
  | { kind: "pin"; intent: PinNameIntent }
  | { kind: "directory" | "voice" | "palette" };

export function ChatRoot() {
  const workspace = useWorkspace();
  const run = useRun();
  const snapshot = useSnapshot();
  const [session, setSession] = useState<"loading" | "login" | "ready">("loading");
  const [loginError, setLoginError] = useState("");
  const [drawer, setDrawer] = useState(false);
  const [sidebarHidden, setSidebarHidden] = useState(false);
  const [compact, setCompact] = useState(() => matchMedia(compactQuery).matches);
  const [modal, setModal] = useState<Modal>();
  const [inspector, setInspector] = useState(false);
  const [restored, setRestored] = useState(false);
  const storedSelection = useRef(savedSelection);
  const theme = useSyncExternalStore(workspace.subscribe, () => workspace.selectedThemeID);
  const dark = useDarkAppearance();
  useEffect(() => {
    const query = matchMedia(compactQuery);
    const update = () => setCompact(query.matches);
    query.addEventListener("change", update);
    return () => query.removeEventListener("change", update);
  }, []);
  useEffect(() => {
    if (session !== "ready" || !restored) return;
    const { threadId, ...target } = snapshot.selected ?? { threadId: undefined };
    const draftKey = workspace.draftKey;
    const value = JSON.stringify(
      threadId ? { target, threadId } : snapshot.drafts.has(draftKey) ? { draft: draftKey } : null,
    );
    if (value === storedSelection.current) return;
    storedSelection.current = value;
    saveSelection(value);
  }, [session, restored, snapshot, workspace]);
  useLayoutEffect(() => {
    document.documentElement.dataset.theme = theme;
    browserVisuals.setTheme(visualTheme(dark));
  }, [theme, dark]);
  useEffect(() => {
    api<{ authenticated: boolean; loginRequired: boolean }>("/api/session")
      .then(async (result) => {
        if (!result.authenticated && result.loginRequired) {
          setSession("login");
          return;
        }
        if (!result.authenticated) await api("/api/session", { method: "POST", body: "{}" });
        setSession("ready");
        await enterWorkspace(workspace, () => setRestored(true));
      })
      .catch((error) => {
        setLoginError(error.message);
        setSession("login");
      });
    return () => {
      workspace.dispose();
      browserDiagrams.dispose();
    };
  }, [workspace]);
  useEffect(() => {
    const listener = (event: KeyboardEvent) => {
      if (event.key === "Escape" && !document.querySelector("dialog[open], :popover-open")) setDrawer(false);
    };
    window.addEventListener("keydown", listener);
    return () => window.removeEventListener("keydown", listener);
  }, []);
  const conversation = workspace.selectedConversation;
  const host = workspace.selectedHost;
  const composer = useRef<ComposerHandle>(null);
  const sidebarOpen = compact ? drawer : !sidebarHidden;
  const chatWindow = useMemo<ChatWindow>(
    () => ({
      sidebarOpen,
      inspectorOpen: inspector,
      composer,
      toggleSidebar: () => (compact ? setDrawer((value) => !value) : setSidebarHidden((value) => !value)),
      toggleInspector: () => setInspector((value) => !value),
      chooseFolder: () => setModal({ kind: "directory" }),
      openSettings: () => setModal({ kind: "settings", tab: "chat" }),
      togglePalette: () =>
        setModal((current) => (current?.kind === "palette" ? undefined : { kind: "palette" })),
      namePin: (intent) => setModal({ kind: "pin", intent }),
    }),
    [compact, sidebarOpen, inspector],
  );
  const actions = useChatWindowActions(chatWindow);
  const transcriptCovered = modal !== undefined || (compact && drawer);
  const seenKey = conversation?.status === "ready" ? addressKey(conversation.address) : undefined;
  const completedAt = conversation?.header.lastTurnCompletedAt;
  useEffect(() => {
    if (!seenKey || transcriptCovered || completedAt == null) return;
    const publish = () => {
      if (document.visibilityState === "visible") run(() => workspace.publishSeenCompletion());
    };
    publish();
    document.addEventListener("visibilitychange", publish);
    return () => document.removeEventListener("visibilitychange", publish);
  }, [workspace, run, seenKey, completedAt, transcriptCovered]);
  useCommandShortcuts(actions);
  if (session !== "ready")
    return (
      <UnlockScreen
        loading={session === "loading"}
        error={loginError}
        unlock={async (key) => {
          try {
            await api("/api/session", { method: "POST", body: JSON.stringify({ key }) });
            setSession("ready");
            await enterWorkspace(workspace, () => setRestored(true));
          } catch (error) {
            setLoginError(error instanceof Error ? error.message : "Unlock failed");
          }
        }}
      />
    );
  const close = () => setModal(undefined);
  return (
    <MediaProvider hostId={snapshot.selectedHostId}>
      <div
        className={`app ${drawer ? "sidebar-open" : ""} ${!compact && sidebarHidden ? "sidebar-collapsed" : ""} ${inspector ? "inspector-open" : ""}`}
      >
        {drawer && (
          <button
            type="button"
            className="sidebar-scrim"
            aria-label="Close conversation drawer"
            onClick={() => setDrawer(false)}
          />
        )}
        <HistorySidebar
          hidden={compact ? !drawer : sidebarHidden}
          onNavigate={() => setDrawer(false)}
          openSettings={(tab) => setModal({ kind: "settings", tab })}
          namePin={chatWindow.namePin}
        />
        <main className="main">
          <ChatHeader host={host} compact={compact} actions={actions} />
          {(snapshot.error || (host?.error && host.status !== "connected")) && (
            <div className="banners">
              {snapshot.error && (
                <div className="error-banner" role="alert">
                  <AlertCircle size={17} />
                  <span>{snapshot.error}</span>
                  <IconButton label="Dismiss error" onClick={() => workspace.clearError()}>
                    <X size={16} />
                  </IconButton>
                </div>
              )}
              {host?.error && host.status !== "connected" && (
                <div className="connection-banner">
                  <span className={`status-dot ${host.status}`} />
                  <span>{host.error}</span>
                </div>
              )}
            </div>
          )}
          {conversation ? (
            <DiagramThemeContext.Provider value={dark}>
              <Transcript conversation={conversation} />
            </DiagramThemeContext.Provider>
          ) : (
            <EmptyConversation
              hasHost={Boolean(host)}
              setUpHost={() => setModal({ kind: "settings", tab: "hosts" })}
            />
          )}
          <Composer
            ref={composer}
            conversation={conversation}
            openVoice={() =>
              run(async () => {
                const prepared = await workspace.prepareVoiceConversation();
                if (workspace.selectedConversation === prepared) setModal({ kind: "voice" });
              })
            }
          />
        </main>
        {inspector && <Inspector conversation={conversation} close={() => setInspector(false)} />}
        {modal?.kind === "settings" && <SettingsDialog initialTab={modal.tab} close={close} />}
        {modal?.kind === "palette" && <CommandPalette actions={actions} close={close} />}
        {modal?.kind === "directory" && <DirectoryPicker close={close} />}
        {modal?.kind === "pin" && <PinNameDialog intent={modal.intent} close={close} />}
        {modal?.kind === "voice" && conversation && (
          <VoiceDialog key={addressKey(conversation.address)} conversation={conversation} close={close} />
        )}
      </div>
    </MediaProvider>
  );
}
