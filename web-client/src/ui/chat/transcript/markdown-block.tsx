import { memo, useContext, useEffect, useRef } from "react";
import { webBuild } from "../../../gateway";
import { browserDiagrams } from "../../../platform/diagrams";
import { browserVisuals } from "../../../platform/visuals";
import { DiagramThemeContext } from "../../design-system/appearance";

export const MarkdownBlock = memo(function MarkdownBlock({
  html,
  complete,
  hostId,
}: {
  html: string;
  complete: boolean;
  hostId: string;
}) {
  const root = useRef<HTMLDivElement>(null);
  const dark = useContext(DiagramThemeContext);
  const terminal = complete && html.includes('data-mermaid-complete="false"');
  useEffect(() => {
    const element = root.current;
    if (!element || !html) return;
    const lifetimes: { dispose(): void }[] = [];
    for (const block of Array.from(element.querySelectorAll<HTMLElement>("[data-mermaid-source]")).slice(
      0,
      16,
    )) {
      const preview = block.querySelector<HTMLElement>(".diagram-preview");
      const status = block.querySelector<HTMLElement>(".diagram-status");
      const source = block.querySelector<HTMLDetailsElement>(".diagram-source");
      const retry = block.querySelector<HTMLButtonElement>("[data-retry-diagram]");
      if (!preview) continue;
      let lifetime: { dispose(): void } | undefined;
      const mount = () => {
        lifetime?.dispose();
        lifetime = browserDiagrams.mount(preview, block.dataset.mermaidSource ?? "", {
          dark,
          complete: terminal || block.dataset.mermaidComplete === "true",
          onState: (state) => {
            block.dataset.diagramStatus = state.status;
            if (status)
              status.textContent =
                state.status === "failed"
                  ? (state.error ?? "Diagram could not be rendered")
                  : state.status === "rendering"
                    ? "Drawing diagram…"
                    : !terminal && block.dataset.mermaidComplete !== "true"
                      ? "Diagram is being written"
                      : "";
            if (retry) retry.hidden = state.status !== "failed";
            if (state.status === "ready" && source) source.open = false;
          },
        });
      };
      retry?.addEventListener("click", mount);
      mount();
      lifetimes.push({
        dispose: () => {
          retry?.removeEventListener("click", mount);
          lifetime?.dispose();
        },
      });
    }
    return () => {
      for (const lifetime of lifetimes) lifetime.dispose();
    };
  }, [html, terminal, dark]);
  useEffect(() => {
    const element = root.current;
    if (!element || !html) return;
    const lifetimes = Array.from(element.querySelectorAll<HTMLElement>("[data-visual-digest]"), (block) =>
      browserVisuals.mount(
        block,
        `/api/hosts/${encodeURIComponent(hostId)}/visuals/${block.dataset.visualDigest}${webBuild ? `?v=${encodeURIComponent(webBuild)}` : ""}`,
        block.dataset.visualTitle || "Visual",
      ),
    );
    return () => {
      for (const lifetime of lifetimes) lifetime.dispose();
    };
  }, [html, hostId]);
  return <div ref={root} className="markdown-block" dangerouslySetInnerHTML={{ __html: html }} />;
});
