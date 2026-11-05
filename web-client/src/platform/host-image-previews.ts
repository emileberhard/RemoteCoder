import { HostFileBusy, readHostFile } from "./host-files";

type Preview = {
  path: string;
  cwd: string;
  signal: AbortSignal;
  resolve(blob: Blob): void;
  reject(error: unknown): void;
  cleanup(): void;
};
type Queue = { running: boolean; pending: Preview[] };

export class HostImagePreviews {
  private readonly queues = new Map<string, Queue>();
  private readonly lifetime = new AbortController();

  read(hostId: string, path: string, cwd: string, signal: AbortSignal): Promise<Blob> {
    const combined = AbortSignal.any([signal, this.lifetime.signal]);
    combined.throwIfAborted();
    let queue = this.queues.get(hostId);
    if (!queue) {
      if (this.queues.size >= 24) return Promise.reject(new Error("Too many image preview hosts"));
      queue = { running: false, pending: [] };
      this.queues.set(hostId, queue);
    }
    if (queue.pending.length >= 24) return Promise.reject(new Error("Too many pending image previews"));
    const owner = queue;
    return new Promise((resolve, reject) => {
      const cancel = () => {
        const index = owner.pending.indexOf(preview);
        if (index >= 0) owner.pending.splice(index, 1);
        preview.cleanup();
        reject(combined.reason);
        if (!owner.running && !owner.pending.length) this.queues.delete(hostId);
      };
      const preview: Preview = {
        path,
        cwd,
        signal: combined,
        resolve,
        reject,
        cleanup: () => combined.removeEventListener("abort", cancel),
      };
      combined.addEventListener("abort", cancel, { once: true });
      owner.pending.push(preview);
      this.pump(hostId, owner);
    });
  }

  private pump(hostId: string, queue: Queue) {
    if (queue.running) return;
    const preview = queue.pending.shift();
    if (!preview) {
      this.queues.delete(hostId);
      return;
    }
    preview.cleanup();
    queue.running = true;
    void this.load(hostId, preview)
      .then(preview.resolve, preview.reject)
      .finally(() => {
        queue.running = false;
        this.pump(hostId, queue);
      });
  }

  private async load(hostId: string, preview: Preview): Promise<Blob> {
    for (let attempt = 0; ; attempt++) {
      preview.signal.throwIfAborted();
      try {
        const blob = await readHostFile(hostId, preview.path, preview.cwd, preview.signal, 32 * 1024 * 1024);
        preview.signal.throwIfAborted();
        return blob;
      } catch (error) {
        if (!(error instanceof HostFileBusy) || attempt >= 3) throw error;
        const delay = error.retryAfterMs ?? 500 * 2 ** attempt * (1 + Math.random() / 4);
        await new Promise<void>((resolve, reject) => {
          const cancel = () => {
            clearTimeout(timer);
            reject(preview.signal.reason);
          };
          const timer = setTimeout(() => {
            preview.signal.removeEventListener("abort", cancel);
            resolve();
          }, delay);
          preview.signal.addEventListener("abort", cancel, { once: true });
          if (preview.signal.aborted) cancel();
        });
      }
    }
  }

  dispose() {
    this.lifetime.abort();
  }
}
