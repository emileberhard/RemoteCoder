import { useState } from "react";
import { Dialog } from "../../design-system/dialog";

export function InlineImage({ src, name }: { src: string; name: string }) {
  const [expanded, setExpanded] = useState(false);
  return (
    <>
      <button
        type="button"
        className="viewed-media-preview"
        aria-label={`Open ${name}`}
        onClick={() => setExpanded(true)}
      >
        <img className="message-image" src={src} alt={name} loading="lazy" />
      </button>
      {expanded && (
        <Dialog title={name} close={() => setExpanded(false)} wide>
          <img className="viewed-media-full" src={src} alt={name} />
          <a href={src} download="image.png" className="attachment-link">
            Download
          </a>
        </Dialog>
      )}
    </>
  );
}
