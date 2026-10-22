import {
  BellDot,
  ChevronDown,
  ChevronLeft,
  ChevronUp,
  CircleCheck,
  Command,
  Copy,
  Folder,
  FoldVertical,
  GitBranch,
  type LucideIcon,
  Mail,
  MailOpen,
  PanelLeft,
  PanelRight,
  Paperclip,
  Pencil,
  Pin,
  RotateCw,
  Settings,
  Square,
  SquarePen,
  TextCursorInput,
  UnfoldVertical,
  Zap,
} from "lucide-react";
import { useEffect } from "react";

export type ChatCommand =
  | "newChat"
  | "fork"
  | "chooseFolder"
  | "commandPalette"
  | "toggleSidebar"
  | "toggleInspector"
  | "refresh"
  | "stop"
  | "focusComposer"
  | "attachFile"
  | "toggleFastMode"
  | "togglePin"
  | "rename"
  | "copyReference"
  | "settle"
  | "markUnread"
  | "unreadOnly"
  | "markAllRead"
  | "collapseAllSections"
  | "expandAllSections"
  | "previousConversation"
  | "nextConversation"
  | "nextNeedingAttention"
  | "returnToParent"
  | "settings";

type Shortcut = { key: string; control?: true; option?: true; shift?: true; label: string };
type Definition = { title: string; Icon: LucideIcon; shortcut?: Shortcut; inPalette: boolean };

export const chatCommands: Record<ChatCommand, Definition> = {
  newChat: { title: "New Chat", Icon: SquarePen, inPalette: true },
  fork: { title: "Fork Conversation", Icon: GitBranch, inPalette: true },
  chooseFolder: { title: "Choose Folder…", Icon: Folder, inPalette: true },
  commandPalette: {
    title: "Command Palette…",
    Icon: Command,
    shortcut: { key: "k", label: "⌘K" },
    inPalette: false,
  },
  toggleSidebar: {
    title: "Show Sidebar",
    Icon: PanelLeft,
    shortcut: { key: "s", control: true, label: "⌃⌘S" },
    inPalette: true,
  },
  toggleInspector: { title: "Show Inspector", Icon: PanelRight, inPalette: true },
  refresh: { title: "Refresh", Icon: RotateCw, inPalette: true },
  stop: { title: "Stop", Icon: Square, shortcut: { key: ".", label: "⌘." }, inPalette: true },
  focusComposer: { title: "Focus Composer", Icon: TextCursorInput, inPalette: true },
  attachFile: { title: "Attach File…", Icon: Paperclip, inPalette: true },
  toggleFastMode: { title: "Fast Mode", Icon: Zap, inPalette: true },
  togglePin: { title: "Pin…", Icon: Pin, inPalette: true },
  rename: { title: "Rename…", Icon: Pencil, inPalette: true },
  copyReference: { title: "Copy Thread ID", Icon: Copy, inPalette: true },
  settle: {
    title: "Settle Conversation",
    Icon: CircleCheck,
    shortcut: { key: "s", shift: true, label: "⇧⌘S" },
    inPalette: true,
  },
  markUnread: { title: "Mark as Unread", Icon: Mail, inPalette: true },
  unreadOnly: { title: "Unread Only", Icon: Mail, inPalette: true },
  markAllRead: { title: "Mark All as Read", Icon: MailOpen, inPalette: true },
  collapseAllSections: { title: "Collapse All Sections", Icon: FoldVertical, inPalette: true },
  expandAllSections: { title: "Expand All Sections", Icon: UnfoldVertical, inPalette: true },
  previousConversation: {
    title: "Previous Conversation",
    Icon: ChevronUp,
    shortcut: { key: "ArrowUp", option: true, label: "⌥⌘↑" },
    inPalette: true,
  },
  nextConversation: {
    title: "Next Conversation",
    Icon: ChevronDown,
    shortcut: { key: "ArrowDown", option: true, label: "⌥⌘↓" },
    inPalette: true,
  },
  nextNeedingAttention: {
    title: "Next Needing Attention",
    Icon: BellDot,
    shortcut: { key: "u", shift: true, label: "⇧⌘U" },
    inPalette: true,
  },
  returnToParent: {
    title: "Back to Parent Conversation",
    Icon: ChevronLeft,
    shortcut: { key: "[", label: "⌘[" },
    inPalette: true,
  },
  settings: { title: "Settings…", Icon: Settings, shortcut: { key: ",", label: "⌘," }, inPalette: true },
};

export type ChatWindowActions = {
  isEnabled(command: ChatCommand): boolean;
  title(command: ChatCommand): string;
  isOn(command: ChatCommand): boolean | undefined;
  run(command: ChatCommand): void;
};

const mac = /Mac|iPhone|iPad/.test(navigator.platform);
const repeatable = new Set<ChatCommand>(["previousConversation", "nextConversation"]);

function matches(event: KeyboardEvent, shortcut: Shortcut): boolean {
  const primary = mac ? event.metaKey : event.ctrlKey;
  const extra = mac
    ? event.ctrlKey === Boolean(shortcut.control) && event.altKey === Boolean(shortcut.option)
    : event.altKey === Boolean(shortcut.control || shortcut.option);
  return (
    primary &&
    extra &&
    event.shiftKey === Boolean(shortcut.shift) &&
    event.key.toLowerCase() === shortcut.key.toLowerCase()
  );
}

export function useCommandShortcuts(actions: ChatWindowActions) {
  useEffect(() => {
    const listener = (event: KeyboardEvent) => {
      for (const [command, definition] of Object.entries(chatCommands) as [ChatCommand, Definition][]) {
        if (!definition.shortcut || !matches(event, definition.shortcut)) continue;
        event.preventDefault();
        if (event.repeat && !repeatable.has(command)) return;
        if (command !== "commandPalette" && document.querySelector("dialog:modal")) return;
        if (actions.isEnabled(command)) actions.run(command);
        return;
      }
    };
    window.addEventListener("keydown", listener);
    return () => window.removeEventListener("keydown", listener);
  }, [actions]);
}
