import { Check, ChevronRight, CircleCheck, Copy, Folder, FolderOpen, Star, StarOff } from "lucide-react";
import { useEffect } from "react";
import type { DirectoryItem, DirectoryPickerModel } from "../../workspace/directory-picker-model";
import type { FavoriteFolder } from "../../workspace/favorite-folder";
import { ContextMenu, useContextMenu } from "../design-system/context-menu";
import { Dialog } from "../design-system/dialog";
import { HostPicker } from "../design-system/host-picker";
import { MenuItem } from "../design-system/menu";
import { useRun, useSnapshot, useWorkspace } from "../workspace-context";

type Subject = Readonly<{ path: string; favorite: boolean; use(): void; toggleFavorite?(): void }>;

export function DirectoryPicker({ close }: { close(): void }) {
  const workspace = useWorkspace();
  const run = useRun();
  const { hosts, selectedHostId, directoryPicker: picker, favoriteFolders } = useSnapshot();
  const menu = useContextMenu<Subject>();
  useEffect(() => {
    workspace.openDirectoryPicker();
    return () => workspace.closeDirectoryPicker();
  }, [workspace]);
  const choose = (path: string) =>
    run(async () => {
      await workspace.chooseDirectory(path);
      close();
    });
  const chooseFavorite = (folder: FavoriteFolder) =>
    run(async () => {
      await workspace.selectFavoriteFolder(folder);
      close();
    });
  const home = picker?.directories.home;
  const homePath = home?.status === "ready" ? home.value : undefined;
  const isSelected = (path: string) =>
    path === "~"
      ? picker?.selectedPath === "~" || (homePath !== undefined && picker?.selectedPath === homePath)
      : picker?.selectedPath === path;
  return (
    <Dialog title="Working Directory" close={close} wide>
      <p className="dialog-subtitle">{picker?.selectedPath ?? "No folder selected"}</p>
      {hosts.length > 1 && (
        <HostPicker
          hosts={hosts}
          value={selectedHostId}
          choose={(id) => {
            workspace.selectHost(id);
            workspace.openDirectoryPicker(id);
          }}
        />
      )}
      {picker?.errorMessage && <p className="inline-error">{picker.errorMessage}</p>}
      <div className="directory-browser">
        {favoriteFolders.length > 0 && (
          <section>
            <h3 className="directory-heading">
              <Star size={14} className="favorite-star" />
              Favorites
            </h3>
            <div className="favorite-grid">
              {favoriteFolders.map((folder) => {
                const selected = folder.hostId === picker?.hostId && isSelected(folder.path);
                return (
                  <button
                    key={folder.id}
                    type="button"
                    className={`favorite-folder ${selected ? "selected" : ""}`}
                    title={folder.displayPath}
                    onClick={() => {
                      if (!menu.consumeHold()) chooseFavorite(folder);
                    }}
                    {...menu.triggerProps({
                      path: folder.path,
                      favorite: true,
                      use: () => chooseFavorite(folder),
                      toggleFavorite: () =>
                        run(() => workspace.hostDirectories(folder.hostId).removeFavorite(folder.path)),
                    })}
                  >
                    {selected ? <FolderOpen size={17} /> : <Folder size={17} />}
                    <span>
                      <span className="favorite-title">{folder.title}</span>
                      {folder.showsHostLabel && <small>{folder.hostName}</small>}
                    </span>
                    {selected && <Check size={14} strokeWidth={3} />}
                  </button>
                );
              })}
            </div>
          </section>
        )}
        <section>
          <h3 className="directory-heading">Browse</h3>
          {picker && (
            <DirectoryTree
              picker={picker}
              isSelected={isSelected}
              choose={choose}
              menuTrigger={(item) =>
                menu.triggerProps({
                  path: item.path,
                  favorite: picker.isFavorite(item.path),
                  use: () => choose(item.path),
                  toggleFavorite:
                    item.path === "~" ? undefined : () => run(() => picker.toggleFavorite(item.path)),
                })
              }
              consumeHold={menu.consumeHold}
            />
          )}
          {(!picker || ["unread", "loading"].includes(picker.root.children.status)) && (
            <p className="subtle directory-status">Loading…</p>
          )}
          {picker?.root.children.status === "ready" && picker.root.children.value.length === 0 && (
            <p className="subtle directory-status">No subdirectories found</p>
          )}
        </section>
      </div>
      <ContextMenu surface={menu.surface}>
        {menu.subject && (
          <>
            <MenuItem icon={<Folder size={16} />} onSelect={() => menu.subject?.use()}>
              Use this folder
            </MenuItem>
            {menu.subject.toggleFavorite && (
              <MenuItem
                icon={menu.subject.favorite ? <StarOff size={16} /> : <Star size={16} />}
                onSelect={() => menu.subject?.toggleFavorite?.()}
              >
                {menu.subject.favorite ? "Unfavorite" : "Favorite"}
              </MenuItem>
            )}
            <MenuItem
              icon={<Copy size={16} />}
              onSelect={() => {
                const path = menu.subject?.path;
                if (path) run(() => navigator.clipboard.writeText(path));
              }}
            >
              Copy path
            </MenuItem>
          </>
        )}
      </ContextMenu>
    </Dialog>
  );
}

function DirectoryTree({
  picker,
  isSelected,
  choose,
  menuTrigger,
  consumeHold,
}: {
  picker: DirectoryPickerModel;
  isSelected(path: string): boolean;
  choose(path: string): void;
  menuTrigger(item: DirectoryItem): object;
  consumeHold(): boolean;
}) {
  const run = useRun();
  return (
    <ul className="directory-tree">
      {picker.visibleRows().map(({ item, level }) => {
        const selected = isSelected(item.path);
        const root = item.path === "~";
        return (
          <li
            key={item.path}
            className={selected ? "selected" : ""}
            style={{ paddingLeft: `${level * 20}px` }}
          >
            {!root &&
              (item.children.status === "loading" ? (
                <span className="row-spinner directory-toggle" role="progressbar" aria-label="Loading" />
              ) : (
                <button
                  type="button"
                  className="directory-toggle"
                  aria-label={`${item.isExpanded ? "Collapse" : "Expand"} ${item.name}`}
                  aria-expanded={item.isExpanded}
                  title={item.isExpanded ? "Collapse" : "Expand"}
                  onClick={() => run(() => picker.toggleExpansion(item.path))}
                >
                  <ChevronRight size={13} strokeWidth={3} />
                </button>
              ))}
            <button
              type="button"
              className="directory-name"
              aria-current={selected ? "true" : undefined}
              onClick={() => {
                if (!consumeHold()) choose(item.path);
              }}
              {...menuTrigger(item)}
            >
              {selected ? <FolderOpen size={17} /> : <Folder size={17} />}
              <span>{item.name}</span>
              {!root && picker.isFavorite(item.path) && (
                <Star size={12} className="favorite-star" aria-label="Favorite" />
              )}
              {selected && <CircleCheck size={17} className="directory-check" aria-label="Selected" />}
            </button>
            {item.children.status === "failed" && (
              <p className="error directory-error">{item.children.error}</p>
            )}
          </li>
        );
      })}
    </ul>
  );
}
