import { decodeTarget } from "../execution-context";
import type { Snapshot, Workspace } from "../workspace/workspace";

const selectionKey = "remotecoder.web.selection";
export const savedSelection = sessionStorage.getItem(selectionKey) ?? "";
export function saveSelection(value: string) {
  sessionStorage.setItem(selectionKey, value);
}
export async function enterWorkspace(workspace: Workspace, restored: () => void) {
  const { selected, newDraftId } = workspace.getSnapshot();
  const initial = { selected, newDraftId };
  await workspace.loadHosts();
  await Promise.all([restoreSelection(workspace, initial).finally(restored), workspace.refreshHistories()]);
}
async function restoreSelection(workspace: Workspace, initial: Pick<Snapshot, "selected" | "newDraftId">) {
  const current = workspace.getSnapshot();
  if (current.selected !== initial.selected || current.newDraftId !== initial.newDraftId) return;
  try {
    const saved = JSON.parse(savedSelection || "null");
    if (typeof saved?.draft === "string" && workspace.getSnapshot().drafts.has(saved.draft))
      await workspace.selectDraft(saved.draft);
    else if (typeof saved?.threadId === "string")
      await workspace.selectConversation({ ...decodeTarget(saved.target), threadId: saved.threadId });
  } catch {
    sessionStorage.removeItem(selectionKey);
  }
}
