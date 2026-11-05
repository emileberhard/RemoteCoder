import { memo, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { Dialog } from "../design-system/dialog";
import { basename } from "../formatting";
import { useRead } from "../remote-operations";
import { useRun, useWorkspace } from "../workspace-context";
import { downloadFile } from "./download";

export const FilePreview = memo(function FilePreview({
  path,
  hostId,
  cwd,
  kind,
  line,
  close,
}: {
  path: string;
  hostId: string;
  cwd: string;
  kind: "pdf" | "text" | "image";
  line?: number;
  close(): void;
}) {
  const workspace = useWorkspace();
  const run = useRun();
  const [url, setURL] = useState<string>();
  const preview = useRead(JSON.stringify([hostId, path, cwd, kind]), async (signal) => {
    const blob = await workspace.filePreviews.read(hostId, path, cwd, signal);
    if (kind === "pdf" || kind === "image")
      return {
        blob: new Blob([blob], {
          type: kind === "pdf" ? "application/pdf" : (imageMimeType(path) ?? blob.type),
        }),
      };
    if (blob.size > 512 * 1024)
      throw new Error("This file is too large to preview. Download it to read the full file.");
    return { text: await blob.text() };
  });
  useEffect(() => {
    if (!preview.value?.blob) return;
    const retained = URL.createObjectURL(preview.value.blob);
    setURL(retained);
    return () => {
      URL.revokeObjectURL(retained);
      setURL(undefined);
    };
  }, [preview.value]);
  const text = preview.value?.text;
  const pre = useRef<HTMLPreElement>(null);
  const mark = useRef<HTMLElement>(null);
  const selected = useMemo(() => {
    if (text === undefined || line === undefined) return;
    const lines = text.split("\n");
    if (line < 1 || line > lines.length) return;
    return {
      before: lines.slice(0, line - 1).join("\n") + (line > 1 ? "\n" : ""),
      selected: lines[line - 1],
      after: line < lines.length ? `\n${lines.slice(line).join("\n")}` : "",
    };
  }, [text, line]);
  useLayoutEffect(() => {
    if (!selected || !pre.current || !mark.current) return;
    pre.current.scrollTop = mark.current.offsetTop - pre.current.clientHeight / 2;
  }, [selected]);
  return (
    <Dialog title={basename(path)} close={close} wide>
      {preview.error ? (
        <div className="inline-error">
          <span>{preview.error}</span>
          <button type="button" onClick={preview.refresh}>
            Retry
          </button>
        </div>
      ) : url && kind === "image" ? (
        <img className="viewed-media-full" src={url} alt={basename(path)} />
      ) : url ? (
        <iframe className="file-pdf" src={url} title={basename(path)} />
      ) : preview.value?.text !== undefined ? (
        <pre ref={pre} className="file-text">
          {selected ? (
            <>
              {selected.before}

              <mark ref={mark}>{selected.selected}</mark>
              {selected.after}
            </>
          ) : (
            preview.value.text
          )}
        </pre>
      ) : (
        <p className="subtle" role="status">
          Loading preview…
        </p>
      )}
      <div className="panel-actions">
        <button type="button" onClick={() => run(() => downloadFile(hostId, path, cwd))}>
          Download
        </button>
        <button type="button" onClick={() => run(() => navigator.clipboard.writeText(path))}>
          Copy path
        </button>
        {text !== undefined && (
          <button type="button" onClick={() => run(() => navigator.clipboard.writeText(text))}>
            Copy text
          </button>
        )}
      </div>
    </Dialog>
  );
});

const imageTypes: Record<string, string> = {
  png: "png",
  jpg: "jpeg",
  jpeg: "jpeg",
  gif: "gif",
  webp: "webp",
  avif: "avif",
  svg: "svg+xml",
  heic: "heic",
  tiff: "tiff",
  bmp: "bmp",
};
export function imageMimeType(path: string) {
  const type = imageTypes[path.split(".").at(-1)?.toLowerCase() ?? ""];
  return type ? `image/${type}` : undefined;
}
export function filePreviewKind(path: string): "image" | "pdf" | "text" | undefined {
  if (imageMimeType(path)) return "image";
  const extension = path.split(".").at(-1)?.toLowerCase();
  if (extension === "pdf") return "pdf";
  if (
    /^(txt|md|markdown|json|jsonl|csv|tsv|log|yaml|yml|xml|html|css|js|jsx|ts|tsx|py|rs|swift|c|h|cpp|cs|sh|toml|sql)$/.test(
      extension ?? "",
    )
  )
    return "text";
}
