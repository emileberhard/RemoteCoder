import { useEffect, useState } from "react";
import { webBuild } from "../gateway";
import { useWorkspace } from "./workspace-context";

export function DeploymentUpdate() {
  const workspace = useWorkspace();
  const [available, setAvailable] = useState(false);
  useEffect(() => {
    if (!webBuild) return;
    let controller: AbortController | undefined;
    const check = async () => {
      if (document.hidden || controller) return;
      const owner = new AbortController();
      controller = owner;
      try {
        const response = await fetch("/build-id.txt", {
          cache: "no-store",
          signal: AbortSignal.any([owner.signal, AbortSignal.timeout(10000)]),
        });
        if (response.ok) {
          const build = (await response.text()).trim();
          if (!owner.signal.aborted && build && build.length <= 128) setAvailable(build !== webBuild);
        }
      } catch {
        return;
      } finally {
        controller = undefined;
      }
    };
    const visible = () => {
      void check();
    };
    const timer = setInterval(visible, 120000);
    document.addEventListener("visibilitychange", visible);
    visible();
    return () => {
      clearInterval(timer);
      document.removeEventListener("visibilitychange", visible);
      controller?.abort();
    };
  }, []);
  if (!available) return null;
  return (
    <button
      type="button"
      className="deployment-update"
      onClick={() => {
        workspace.flushDrafts();
        location.reload();
      }}
    >
      Update available · Reload
    </button>
  );
}
