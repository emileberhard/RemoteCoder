import { Check, Folder, Search } from "lucide-react";
import { type ReactNode, useEffect, useId, useMemo, useRef, useState } from "react";
import { providerForThread } from "../../protocol/agent-provider";
import { commandPaletteResults } from "../../workspace/command-palette-search";
import { ProviderMark } from "../design-system/provider-mark";
import { useRun, useWorkspace } from "../workspace-context";
import { type ChatCommand, type ChatWindowActions, chatCommands } from "./chat-commands";

type Entry = {
  key: string;
  icon: ReactNode;
  title: string;
  detail: string;
  subtitle?: string;
  current?: boolean;
  shortcut?: string;
  run(): void;
};
const resultLimit = 50;

export function CommandPalette({ actions, close }: { actions: ChatWindowActions; close(): void }) {
  const workspace = useWorkspace();
  const run = useRun();
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState(0);
  const dialog = useRef<HTMLDialogElement>(null);
  const list = useId();
  useEffect(() => {
    const element = dialog.current;
    element?.showModal();
    return () => element?.close();
  }, []);
  const [entries] = useState<Entry[]>(() => {
    const conversations = workspace.unfoldedConversationRows().map((row) => {
      const where = row.showsHostLabel ? `${row.workingDirectory} · ${row.hostName}` : row.workingDirectory;
      return {
        key: row.id,
        icon: <ProviderMark provider={providerForThread(row.address.threadId)} />,
        title: row.title,
        detail: where,
        subtitle: where,
        current: row.isSelected,
        run: () => run(() => workspace.selectConversation(row.address)),
      };
    });
    const folders = workspace.favoriteFolders.map((folder) => {
      const where = folder.showsHostLabel ? `${folder.displayPath} · ${folder.hostName}` : folder.displayPath;
      return {
        key: `folder:${folder.id}`,
        icon: <Folder size={16} />,
        title: folder.title,
        detail: where,
        subtitle: where,
        run: () => run(() => workspace.selectFavoriteFolder(folder)),
      };
    });
    const provider = workspace.selectedConversation?.header.provider;
    const { draft } = workspace;
    const models = workspace
      .choices()
      .filter((choice) => !provider || choice.provider === provider)
      .map((choice) => ({
        key: `model:${choice.provider}:${choice.id}`,
        icon: <ProviderMark provider={choice.provider} />,
        title: choice.name,
        detail: "Model",
        subtitle: "Model",
        current: choice.id === draft.model && choice.provider === draft.provider,
        run: () => run(() => workspace.chooseModel(choice)),
      }));
    const commands = (Object.keys(chatCommands) as ChatCommand[])
      .filter((command) => chatCommands[command].inPalette && actions.isEnabled(command))
      .map((command) => {
        const { Icon, shortcut } = chatCommands[command];
        return {
          key: `command:${command}`,
          icon: <Icon size={16} />,
          title: actions.title(command),
          detail: "Command",
          current: actions.isOn(command),
          shortcut: shortcut?.label,
          run: () => actions.run(command),
        };
      });
    return [...conversations, ...folders, ...models, ...commands];
  });
  const [candidates] = useState(() =>
    entries.map((entry, index) => ({ id: index, title: entry.title, detail: entry.detail })),
  );
  const results = useMemo(() => commandPaletteResults(query, candidates, resultLimit), [query, candidates]);
  const active = Math.min(selected, Math.max(results.length - 1, 0));
  const choose = (index: number | undefined) => {
    const entry = index === undefined ? undefined : entries[index];
    if (!entry) return;
    close();
    entry.run();
  };
  useEffect(() => {
    document.getElementById(`${list}-${active}`)?.scrollIntoView({ block: "nearest" });
  }, [list, active]);
  return (
    <dialog
      ref={dialog}
      className="command-palette"
      aria-label="Command palette"
      onCancel={close}
      onClick={(event) => {
        if (event.target === event.currentTarget) close();
      }}
      onKeyDown={(event) => {
        if (event.key === "Escape") close();
      }}
    >
      <label className="palette-search">
        <Search size={17} />
        <input
          role="combobox"
          aria-expanded="true"
          aria-controls={list}
          aria-activedescendant={results.length ? `${list}-${active}` : undefined}
          placeholder="Go to a conversation, folder, model or command"
          value={query}
          onChange={(event) => {
            setQuery(event.target.value);
            setSelected(0);
          }}
          onKeyDown={(event) => {
            if (event.key === "ArrowDown" || event.key === "ArrowUp") {
              event.preventDefault();
              const step = event.key === "ArrowDown" ? 1 : -1;
              setSelected(Math.min(Math.max(active + step, 0), Math.max(results.length - 1, 0)));
            } else if (event.key === "Enter" && !event.nativeEvent.isComposing) {
              event.preventDefault();
              choose(results[active]);
            }
          }}
        />
      </label>
      <div id={list} role="listbox" aria-label="Results" className="palette-results">
        {results.length === 0 && <p className="subtle">No results</p>}
        {results.map((index, position) => {
          const entry = entries[index];
          if (!entry) return null;
          return (
            <div
              key={entry.key}
              id={`${list}-${position}`}
              role="option"
              tabIndex={-1}
              aria-selected={position === active}
              className="palette-row"
              onPointerMove={() => setSelected(position)}
              onClick={() => choose(index)}
              onKeyDown={(event) => {
                if (event.key === "Enter") choose(index);
              }}
            >
              <span className="palette-icon">{entry.icon}</span>
              <span className="palette-text">
                <span>{entry.title}</span>
                {entry.subtitle && <small>{entry.subtitle}</small>}
              </span>
              {entry.current && <Check size={15} aria-label="Current" />}
              {entry.shortcut && <kbd>{entry.shortcut}</kbd>}
            </div>
          );
        })}
      </div>
    </dialog>
  );
}
