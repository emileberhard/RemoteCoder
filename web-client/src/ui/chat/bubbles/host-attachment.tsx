import { File } from "lucide-react";
import { useState } from "react";
import { downloadFile } from "../../files/download";
import { FilePreview, filePreviewKind, imageMimeType } from "../../files/preview";
import { basename } from "../../formatting";
import { useRun } from "../../workspace-context";
import { HostImagePreview } from "../transcript/viewed-media";

export function HostAttachment({ path, hostId, cwd }: { path: string; hostId: string; cwd: string }) {
  const run = useRun();
  const name = basename(path);
  const type = imageMimeType(path);
  const kind = filePreviewKind(path);
  const [preview, setPreview] = useState(false);
  return type ? (
    <HostImagePreview media={{ path, name, mimeType: type }} hostId={hostId} cwd={cwd} />
  ) : (
    <>
      <button
        type="button"
        className="attachment-link"
        onClick={() => (kind ? setPreview(true) : run(() => downloadFile(hostId, path, cwd)))}
      >
        <File size={15} />
        {name}
      </button>
      {preview && kind && (
        <FilePreview path={path} hostId={hostId} cwd={cwd} kind={kind} close={() => setPreview(false)} />
      )}
    </>
  );
}
