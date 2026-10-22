import { timingSafeEqual } from "node:crypto";

export function validateBrowserAccess(
  bind: string,
  origin: string,
  accessFile: string | undefined,
  trustPrivateProxy: string | undefined,
) {
  const url = new URL(origin);
  if (url.origin !== origin || !["http:", "https:"].includes(url.protocol))
    throw new Error("RC_WEB_ORIGIN must be an HTTP(S) origin without a path or credentials");
  if (trustPrivateProxy !== undefined && !["true", "false"].includes(trustPrivateProxy))
    throw new Error("RC_WEB_TRUST_PRIVATE_PROXY must be true or false");
  const localBind = ["localhost", "127.0.0.1", "::1"].includes(bind);
  const localOrigin = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if (!localBind && (!accessFile || url.protocol !== "https:"))
    throw new Error("Network hosting requires RC_WEB_ACCESS_KEY_FILE and an HTTPS RC_WEB_ORIGIN");
  if (
    !localOrigin &&
    !accessFile &&
    !(localBind && url.protocol === "https:" && trustPrivateProxy === "true")
  )
    throw new Error(
      "Remote browser origins require RC_WEB_ACCESS_KEY_FILE; a loopback bridge behind an authenticated private proxy may explicitly set RC_WEB_TRUST_PRIVATE_PROXY=true",
    );
}

export class Sessions {
  private readonly entries = new Map<string, { expires: number; connections: Set<() => void> }>();
  private expiration?: ReturnType<typeof setTimeout>;
  constructor(
    private readonly lifetime = 12 * 60 * 60 * 1000,
    private readonly cookieName = "rc_session",
  ) {}
  create() {
    this.expire();
    if (this.entries.size >= 32) this.remove(this.entries.keys().next().value ?? "");
    const id = crypto.randomUUID();
    this.entries.set(id, { expires: Date.now() + this.lifetime, connections: new Set() });
    this.scheduleExpiration();
    return id;
  }
  session(request: Request) {
    const id = request.headers
      .get("cookie")
      ?.split(";")
      .map((part) => part.trim())
      .find((part) => part.startsWith(`${this.cookieName}=`))
      ?.slice(this.cookieName.length + 1);
    return id && this.valid(id) ? id : undefined;
  }
  authorized(request: Request) {
    return this.session(request) !== undefined;
  }
  valid(id: string) {
    const entry = this.entries.get(id);
    if (!entry) return false;
    if (entry.expires <= Date.now()) {
      this.remove(id);
      this.scheduleExpiration();
      return false;
    }
    return true;
  }
  attach(id: string, close: () => void) {
    if (!this.valid(id)) return undefined;
    const entry = this.entries.get(id);
    if (!entry) return undefined;
    entry.connections.add(close);
    return () => {
      entry.connections.delete(close);
    };
  }
  revoke(request: Request) {
    const id = this.session(request);
    if (id) {
      this.remove(id);
      this.scheduleExpiration();
    }
  }
  dispose() {
    clearTimeout(this.expiration);
    this.expiration = undefined;
    for (const id of this.entries.keys()) this.remove(id);
  }
  private remove(id: string) {
    const entry = this.entries.get(id);
    if (!entry) return;
    this.entries.delete(id);
    const connections = [...entry.connections];
    entry.connections.clear();
    for (const close of connections) close();
  }
  private expire() {
    const now = Date.now();
    for (const [id, entry] of this.entries) if (entry.expires <= now) this.remove(id);
  }
  private scheduleExpiration() {
    clearTimeout(this.expiration);
    this.expiration = undefined;
    const next = Math.min(...[...this.entries.values()].map((entry) => entry.expires));
    if (!Number.isFinite(next)) return;
    this.expiration = setTimeout(
      () => {
        this.expiration = undefined;
        this.expire();
        this.scheduleExpiration();
      },
      Math.max(0, next - Date.now()),
    );
    this.expiration.unref();
  }
}

export function sameOrigin(request: Request, origin: string, requireOrigin: boolean) {
  const target = new URL(request.url);
  if (target.host !== new URL(origin).host) return false;
  const supplied = request.headers.get("origin");
  if (supplied && supplied !== origin) return false;
  if (requireOrigin && !supplied) return false;
  const site = request.headers.get("sec-fetch-site");
  const navigation =
    request.method === "GET" &&
    !target.pathname.startsWith("/api/") &&
    request.headers.get("sec-fetch-mode") === "navigate" &&
    request.headers.get("sec-fetch-dest") === "document";
  return !site || site === "same-origin" || site === "none" || navigation;
}

export function matchesSecret(received: string, expected: string) {
  const left = Buffer.from(received);
  const right = Buffer.from(expected);
  return left.length === right.length && timingSafeEqual(left, right);
}
