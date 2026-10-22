import { createContext, useCallback, useContext, useSyncExternalStore } from "react";
import type { Snapshot, Workspace } from "../workspace/workspace";

export const WorkspaceContext = createContext<Workspace | null>(null);
export function useWorkspace(): Workspace {
  const workspace = useContext(WorkspaceContext);
  if (!workspace) throw new Error("WorkspaceContext is missing");
  return workspace;
}
export function useSnapshot(): Snapshot {
  const workspace = useWorkspace();
  return useSyncExternalStore(workspace.subscribe, workspace.getSnapshot);
}
export function useRun() {
  const workspace = useWorkspace();
  return useCallback(
    (operation: () => unknown) => {
      void (async () => operation())().catch((error) => workspace.report(error));
    },
    [workspace],
  );
}
