import { type RefObject, useMemo } from "react";
import { addressKey, codexDesktopLink } from "../../protocol/boundary";
import { neighbor, nextNeedingAttention } from "../../workspace/conversation-sidebar-navigation";
import type { PinNameIntent } from "../conversations/pin-name-dialog";
import { useRun, useSnapshot, useWorkspace } from "../workspace-context";
import { type ChatCommand, type ChatWindowActions, chatCommands } from "./chat-commands";
import type { ComposerHandle } from "./composer/composer";

export type ChatWindow = Readonly<{
  sidebarOpen: boolean;
  inspectorOpen: boolean;
  composer: RefObject<ComposerHandle | null>;
  toggleSidebar(): void;
  toggleInspector(): void;
  chooseFolder(): void;
  openSettings(): void;
  togglePalette(): void;
  namePin(intent: PinNameIntent): void;
}>;

export function useChatWindowActions(chatWindow: ChatWindow): ChatWindowActions {
  const workspace = useWorkspace();
  const run = useRun();
  const snapshot = useSnapshot();
  const { sidebar, selected, agentNavigation } = snapshot;
  const conversation = workspace.selectedConversation;
  const host = workspace.selectedHost;
  const arrangement = workspace.drawerArrangement;
  const row = workspace.selectedConversationRowState;
  return useMemo<ChatWindowActions>(() => {
    const address = conversation?.address;
    const link = address && codexDesktopLink(address);
    const fast = workspace.choices().some((choice) => choice.id === workspace.draft.model && choice.fast);
    const visibleRows = () => sidebar.sections.flatMap((section) => section.rows);
    return {
      isEnabled(command: ChatCommand) {
        switch (command) {
          case "fork":
          case "copyReference":
          case "toggleInspector":
            return Boolean(conversation);
          case "togglePin":
            return row?.isPinned != null;
          case "rename":
            return row?.isPinned === true;
          case "settle":
            return row !== undefined && (row.settlement === "settled" || row.canSettle);
          case "markUnread":
            return row?.isUnread === false;
          case "stop":
            return Boolean(conversation?.activeTurnId);
          case "toggleFastMode":
            return fast;
          case "chooseFolder":
          case "focusComposer":
          case "attachFile":
            return Boolean(host);
          case "collapseAllSections":
          case "expandAllSections":
            return !arrangement.query.trim() && sidebar.sections.some((section) => section.kind !== "chats");
          case "previousConversation":
          case "nextConversation":
            return visibleRows().length > 0;
          case "returnToParent":
            return (
              agentNavigation !== undefined &&
              address !== undefined &&
              addressKey(address) === addressKey(agentNavigation.child)
            );
          default:
            return true;
        }
      },
      title(command: ChatCommand) {
        switch (command) {
          case "toggleSidebar":
            return chatWindow.sidebarOpen ? "Hide Sidebar" : "Show Sidebar";
          case "toggleInspector":
            return chatWindow.inspectorOpen ? "Hide Inspector" : "Show Inspector";
          case "togglePin":
            return row?.isPinned ? "Unpin" : "Pin…";
          case "copyReference":
            return link ? "Copy Link" : "Copy Thread ID";
          case "settle":
            return row?.settlement === "settled" ? "Unsettle Conversation" : "Settle Conversation";
          default:
            return chatCommands[command].title;
        }
      },
      isOn(command: ChatCommand) {
        if (command === "toggleFastMode") return workspace.draft.fast;
        if (command === "unreadOnly") return arrangement.unreadOnly;
        return undefined;
      },
      run(command: ChatCommand) {
        if (!this.isEnabled(command)) return;
        const go = (target: typeof address) => target && run(() => workspace.selectConversation(target));
        switch (command) {
          case "newChat":
            return workspace.newConversation();
          case "fork":
            return run(() => workspace.fork());
          case "chooseFolder":
            return chatWindow.chooseFolder();
          case "commandPalette":
            return chatWindow.togglePalette();
          case "toggleSidebar":
            return chatWindow.toggleSidebar();
          case "toggleInspector":
            return chatWindow.toggleInspector();
          case "refresh":
            return run(() => workspace.refreshHistories());
          case "stop":
            return run(() => workspace.interrupt());
          case "focusComposer":
            return chatWindow.composer.current?.focus();
          case "attachFile":
            return chatWindow.composer.current?.attachFile();
          case "toggleFastMode":
            return run(() => workspace.chooseFastMode(!workspace.draft.fast));
          case "togglePin":
            if (!address || !row) return;
            if (row.isPinned) return run(() => workspace.unpinConversation(address));
            return chatWindow.namePin({ kind: "pin", address, name: "" });
          case "rename":
            return address && row && chatWindow.namePin({ kind: "rename", address, name: row.title });
          case "copyReference":
            return address && run(() => navigator.clipboard.writeText(link ?? address.threadId));
          case "settle":
            if (!address) return;
            return run(() =>
              row?.settlement === "settled"
                ? workspace.unsettleConversation(address)
                : workspace.settleConversation(address),
            );
          case "markUnread":
            return address && run(() => workspace.markConversationUnread(address));
          case "unreadOnly":
            return workspace.setDrawerUnreadOnly(!arrangement.unreadOnly);
          case "markAllRead":
            return run(() => workspace.markAllRead());
          case "collapseAllSections":
            return workspace.setAllSectionsFolded(true);
          case "expandAllSections":
            return workspace.setAllSectionsFolded(false);
          case "previousConversation":
            return go(neighbor("previous", selected, visibleRows()));
          case "nextConversation":
            return go(neighbor("next", selected, visibleRows()));
          case "nextNeedingAttention":
            return go(nextNeedingAttention(selected, workspace.unfoldedConversationRows()));
          case "returnToParent":
            return run(() => workspace.returnToAgentParent());
          case "settings":
            return chatWindow.openSettings();
        }
      },
    };
  }, [workspace, run, chatWindow, conversation, host, row, sidebar, selected, arrangement, agentNavigation]);
}
