import { CircleUserRound, History, type LucideIcon, MessageSquareText, Server } from "lucide-react";
import { useState } from "react";
import { Dialog } from "../design-system/dialog";
import { AccountsSettings } from "./accounts-settings";
import { AutomationsSettings } from "./automations-settings";
import { ChatSettings } from "./chat-settings";
import { HostsSettings } from "./hosts-settings";

export type SettingsTab = "chat" | "accounts" | "hosts" | "automations";
const tabs: readonly { id: SettingsTab; title: string; Icon: LucideIcon }[] = [
  { id: "chat", title: "Chat", Icon: MessageSquareText },
  { id: "accounts", title: "Accounts", Icon: CircleUserRound },
  { id: "hosts", title: "Hosts", Icon: Server },
  { id: "automations", title: "Automations", Icon: History },
];

export function SettingsDialog({ initialTab, close }: { initialTab: SettingsTab; close(): void }) {
  const [tab, setTab] = useState(initialTab);
  const focus = (index: number) => {
    const next = tabs[(index + tabs.length) % tabs.length];
    if (!next) return;
    setTab(next.id);
    document.getElementById(`settings-tab-${next.id}`)?.focus();
  };
  return (
    <Dialog title="Settings" close={close} wide>
      <div className="settings-tabs" role="tablist" aria-label="Settings">
        {tabs.map(({ id, title, Icon }, index) => (
          <button
            key={id}
            id={`settings-tab-${id}`}
            type="button"
            role="tab"
            aria-selected={tab === id}
            aria-controls="settings-panel"
            tabIndex={tab === id ? 0 : -1}
            onClick={() => setTab(id)}
            onKeyDown={(event) => {
              const keys: Record<string, number> = {
                ArrowRight: index + 1,
                ArrowLeft: index - 1,
                Home: 0,
                End: tabs.length - 1,
              };
              const next = keys[event.key];
              if (next === undefined) return;
              event.preventDefault();
              focus(next);
            }}
          >
            <Icon size={19} />
            {title}
          </button>
        ))}
      </div>
      <div
        id="settings-panel"
        role="tabpanel"
        aria-labelledby={`settings-tab-${tab}`}
        className="settings-panel"
      >
        {tab === "chat" && <ChatSettings />}
        {tab === "accounts" && <AccountsSettings />}
        {tab === "hosts" && <HostsSettings />}
        {tab === "automations" && <AutomationsSettings />}
      </div>
      <p>
        <a href="/THIRD_PARTY_NOTICES.md" target="_blank" rel="noreferrer">
          Third-party licenses
        </a>
      </p>
    </Dialog>
  );
}
