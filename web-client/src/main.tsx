import { createRoot } from "react-dom/client";
import { MarkdownRendering } from "./rendering";
import { ChatRoot } from "./ui/chat-root";
import { WorkspaceContext } from "./ui/workspace-context";
import { Workspace } from "./workspace/workspace";
import "./styles.css";

const workspace = new Workspace(undefined, localStorage);
addEventListener("pagehide", () => workspace.flushDrafts());
workspace.setRenderer(new MarkdownRendering((id, result) => workspace.markdownReady(id, result)));
const container = document.getElementById("root");
if (!container) throw new Error("RemoteCoder root element is missing");
createRoot(container).render(
  <WorkspaceContext.Provider value={workspace}>
    <ChatRoot />
  </WorkspaceContext.Provider>,
);
