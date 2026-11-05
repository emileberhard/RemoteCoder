import { Eye, File } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import type { ToolMedia } from "../../../protocol/boundary";
import { Dialog } from "../../design-system/dialog";
import { downloadFile } from "../../files/download";
import { useRun, useWorkspace } from "../../workspace-context";

export function ViewedMedia({ media, hostId, cwd }: { media: ToolMedia; hostId: string; cwd: string }) {
  const run = useRun();
  const caption = media.name ?? "Tool image";
  return (
    <figure className="viewed-media">
      <figcaption>
        <Eye size={14} />
        <span>{caption}</span>
      </figcaption>
      {media.mimeType.startsWith("image/") ? (
        <HostImagePreview media={media} hostId={hostId} cwd={cwd} />
      ) : (
        <button
          type="button"
          className="attachment-link"
          onClick={() => run(() => downloadFile(hostId, media.path, cwd))}
        >
          <File size={15} />
          {caption}
        </button>
      )}
    </figure>
  );
}

export function HostImagePreview({ media, hostId, cwd }: { media: ToolMedia; hostId: string; cwd: string }) {
  const [attempt, setAttempt] = useState(0);
  return (
    <ViewedImage
      key={`${hostId}:${media.path}:${attempt}`}
      media={media}
      hostId={hostId}
      cwd={cwd}
      retry={() => setAttempt(attempt + 1)}
    />
  );
}

function ViewedImage({
  media,
  hostId,
  cwd,
  retry,
}: {
  media: ToolMedia;
  hostId: string;
  cwd: string;
  retry(): void;
}) {
  const workspace = useWorkspace();
  const run = useRun();
  const root = useRef<HTMLSpanElement>(null);
  const [visible, setVisible] = useState(false);
  const [url, setURL] = useState<string>();
  const [error, setError] = useState<string>();
  const [expanded, setExpanded] = useState(false);
  const admitted = visible || expanded;
  const caption = media.name ?? "Tool image";
  useEffect(() => {
    const element = root.current;
    if (!element) return;
    const observer = new IntersectionObserver(([entry]) => setVisible(entry?.isIntersecting === true), {
      rootMargin: "400px",
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  useEffect(() => {
    if (!admitted) return;
    const controller = new AbortController();
    let retained: string | undefined;
    setURL(undefined);
    setError(undefined);
    void workspace.filePreviews
      .read(hostId, media.path, cwd, controller.signal)
      .then((blob) => {
        if (controller.signal.aborted) return;
        retained = URL.createObjectURL(
          blob.type.startsWith("image/")
            ? blob
            : new Blob([blob], { type: media.mimeType === "image/*" ? "" : media.mimeType }),
        );
        setURL(retained);
      })
      .catch((error: unknown) => {
        if (!controller.signal.aborted)
          setError(error instanceof Error ? error.message : "Image unavailable");
      });
    return () => {
      controller.abort();
      if (retained) URL.revokeObjectURL(retained);
      setURL(undefined);
    };
  }, [hostId, media.path, media.mimeType, cwd, admitted, workspace]);
  return (
    <span ref={root}>
      {error ? (
        <span className="viewed-media-status" role="status">
          <span>{error}</span>
          <button type="button" onClick={retry}>
            Retry
          </button>
          <button type="button" onClick={() => run(() => downloadFile(hostId, media.path, cwd))}>
            Download
          </button>
        </span>
      ) : url ? (
        <button
          type="button"
          className="viewed-media-preview"
          aria-label={`Open ${caption}`}
          onClick={() => setExpanded(true)}
        >
          <img
            className="message-image"
            src={url}
            alt={caption}
            onError={() => setError("Image could not be displayed")}
          />
        </button>
      ) : (
        <span className="viewed-media-status" role="status">
          Loading image…
        </span>
      )}
      {expanded && (
        <Dialog title={caption} close={() => setExpanded(false)} wide>
          {url && <img className="viewed-media-full" src={url} alt={caption} />}
          <button
            type="button"
            className="attachment-link"
            onClick={() => run(() => downloadFile(hostId, media.path, cwd))}
          >
            Download
          </button>
        </Dialog>
      )}
    </span>
  );
}
