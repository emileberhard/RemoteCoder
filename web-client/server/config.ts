import { mkdir, rename, rm, stat } from "node:fs/promises";
import { dirname, isAbsolute } from "node:path";

export type HostConfiguration = { id: string; name: string; url: string; tokenFile: string; cwd: string };
export type PublicHost = Omit<HostConfiguration, "tokenFile"> & {
  credentialStatus: "notChecked" | "ready" | "unavailable";
};
export function validateHost(value: unknown): HostConfiguration {
  if (!value || typeof value !== "object") throw new Error("Host configuration must be an object");
  const host = value as Record<string, unknown>;
  for (const key of ["id", "name", "url", "tokenFile", "cwd"])
    if (typeof host[key] !== "string" || String(host[key]).length > 4096)
      throw new Error(`Invalid host ${key}`);
  if (!/^[a-zA-Z0-9_-]{1,80}$/.test(String(host.id)) || !String(host.name).trim())
    throw new Error("Host needs a stable ID and a name");
  const url = new URL(String(host.url));
  if (
    !["https:", "http:"].includes(url.protocol) ||
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    !["", "/"].includes(url.pathname)
  )
    throw new Error("Gateway URL must be an HTTP(S) origin without credentials");
  const octets = url.hostname.split(".").map(Number);
  const tailnetAddress =
    (octets.length === 4 &&
      octets.every((part) => Number.isInteger(part) && part >= 0 && part <= 255) &&
      octets[0] === 100 &&
      (octets[1] ?? 0) >= 64 &&
      (octets[1] ?? 0) <= 127) ||
    url.hostname.endsWith(".ts.net");
  if (
    url.protocol === "http:" &&
    !["localhost", "127.0.0.1", "[::1]"].includes(url.hostname) &&
    !(process.env.RC_WEB_ALLOW_TAILNET_HTTP === "1" && tailnetAddress && url.port === "8787")
  )
    throw new Error("Remote gateways require HTTPS");
  if (!isAbsolute(String(host.tokenFile)))
    throw new Error("Credential file must use an absolute path on the bridge host");
  if (host.cwd && !isAbsolute(String(host.cwd)))
    throw new Error("Working directory must be an absolute host path");
  return {
    id: String(host.id),
    name: String(host.name).trim(),
    url: url.origin,
    tokenFile: String(host.tokenFile),
    cwd: String(host.cwd),
  };
}

export class HostRegistry {
  private hosts: HostConfiguration[] = [];
  private mutation: Promise<unknown> = Promise.resolve();
  constructor(private readonly path: string) {}
  async load() {
    const file = Bun.file(this.path);
    if (!(await file.exists())) {
      this.hosts = [];
      return;
    }
    const value: unknown = await file.json();
    if (!Array.isArray(value) || value.length > 12)
      throw new Error("Host configuration must contain at most 12 hosts");
    const hosts = value.map(validateHost);
    if (new Set(hosts.map((host) => host.id)).size !== hosts.length)
      throw new Error("Host IDs must be unique");
    this.hosts = hosts;
  }
  list(): PublicHost[] {
    return this.hosts.map(({ tokenFile, ...host }) => ({ ...host, credentialStatus: "notChecked" }));
  }
  get(id: string) {
    const host = this.hosts.find((candidate) => candidate.id === id);
    if (!host) throw new Error("Unknown configured host; register it on the bridge host first");
    return host;
  }
  save(value: unknown) {
    const host = validateHost(value);
    return this.transaction(async () => {
      const index = this.hosts.findIndex((entry) => entry.id === host.id);
      const next = [...this.hosts];
      if (index < 0) {
        if (next.length >= 12) throw new Error("At most 12 hosts can be configured");
        next.push(host);
      } else next[index] = host;
      await this.persist(next);
      return this.list();
    });
  }
  updateMetadata(id: string, name: unknown, cwd: unknown) {
    return this.transaction(async () => {
      const existing = this.get(id);
      const host = validateHost({ ...existing, name, cwd });
      await this.persist(this.hosts.map((value) => (value.id === id ? host : value)));
      return this.list();
    });
  }
  remove(id: string) {
    return this.transaction(async () => {
      this.get(id);
      await this.persist(this.hosts.filter((host) => host.id !== id));
      return this.list();
    });
  }
  private transaction<T>(operation: () => Promise<T>): Promise<T> {
    const pending = this.mutation.then(async () => {
      await mkdir(dirname(this.path), { recursive: true, mode: 0o700 });
      const lock = `${this.path}.lock`;
      let acquired = false;
      for (let attempt = 0; attempt < 40; attempt++) {
        try {
          await mkdir(lock, { mode: 0o700 });
          acquired = true;
          break;
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
          await new Promise((resolve) => setTimeout(resolve, 25));
        }
      }
      if (!acquired)
        throw new Error(
          "Host configuration is locked by another writer. Finish that command; a stale .lock directory needs operator removal.",
        );
      try {
        await this.load();
        return await operation();
      } finally {
        await rm(lock, { recursive: true });
      }
    });
    this.mutation = pending.catch(() => undefined);
    return pending;
  }
  private async persist(hosts: HostConfiguration[]) {
    const temporary = `${this.path}.${crypto.randomUUID()}.tmp`;
    try {
      await Bun.write(temporary, `${JSON.stringify(hosts, null, 2)}\n`, { mode: 0o600 });
      await rename(temporary, this.path);
      this.hosts = hosts;
    } finally {
      await rm(temporary, { force: true });
    }
  }
}
export async function readCredential(path: string) {
  const information = await stat(path);
  if (!information.isFile() || information.size > 16384 || information.size === 0)
    throw new Error("Credential file must be a nonempty regular file, at most 16 KiB");
  if (process.platform !== "win32" && (information.mode & 0o077) !== 0)
    throw new Error("Credential file must be private (chmod 600)");
  const token = (await Bun.file(path).text()).trim();
  if (!token || /[\r\n]/.test(token)) throw new Error("Credential file must contain one bearer token");
  return token;
}
