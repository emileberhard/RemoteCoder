import { closeSync, mkdirSync, openSync, realpathSync, renameSync, writeSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const release = realpathSync(import.meta.dir);
const directory = join(homedir(), "Library/Logs/remote-coder/web-client");
mkdirSync(directory, { recursive: true, mode: 0o700 });
const path = join(directory, "bridge.log");
let size = Bun.file(path).size;
let output = openSync(path, "a", 0o600);
const child = Bun.spawn([process.execPath, join(release, "server.js")], {
  cwd: release,
  env: { ...process.env, RC_WEB_STATIC_DIR: join(release, "dist") },
  stdin: "ignore",
  stdout: "pipe",
  stderr: "pipe",
});
let stopping = false;
const stop = () => {
  if (stopping) return;
  stopping = true;
  child.kill("SIGTERM");
  setTimeout(() => child.kill("SIGKILL"), 4000).unref();
};
process.on("SIGTERM", stop);
process.on("SIGINT", stop);
async function capture(stream: ReadableStream<Uint8Array>) {
  for await (const bytes of stream) {
    if (size + bytes.byteLength > 1024 * 1024) {
      closeSync(output);
      renameSync(path, `${path}.1`);
      output = openSync(path, "w", 0o600);
      size = 0;
    }
    size += writeSync(output, bytes);
  }
}
try {
  await Promise.all([capture(child.stdout), capture(child.stderr), child.exited]);
} finally {
  if (child.exitCode === null) child.kill("SIGKILL");
  closeSync(output);
}
process.exit(child.exitCode ?? 1);
