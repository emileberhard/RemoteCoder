import { useEffect, useRef } from "react";
import { webBuild } from "../../../gateway";
import { browserVisuals } from "../../../platform/visuals";
import type { VisualPublication } from "../../../protocol/boundary";

export function PublishedVisual({ visual, hostId }: { visual: VisualPublication; hostId: string }) {
  const root = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!root.current) return;
    const lifetime = browserVisuals.mount(
      root.current,
      `/api/hosts/${encodeURIComponent(hostId)}/visuals/${visual.digest}${webBuild ? `?v=${encodeURIComponent(webBuild)}` : ""}`,
      visual.title,
    );
    return () => lifetime.dispose();
  }, [visual.digest, visual.title, hostId]);
  return (
    <div className="agent-row">
      <div className="html-visual" ref={root} />
    </div>
  );
}
