export const visualDigestPattern = /^[0-9a-f]{64}$/;
export const maximumVisualBytes = 2 * 1024 * 1024;

export const visualHeaders = {
  "Content-Type": "text/html; charset=utf-8",
  "Cache-Control": "private, max-age=31536000, immutable",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "Content-Security-Policy": [
    "sandbox allow-scripts allow-popups allow-popups-to-escape-sandbox",
    "default-src https: data: blob: 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval'",
    "connect-src https: wss: data: blob:",
    "object-src 'none'",
    "base-uri 'none'",
    "form-action 'none'",
    "frame-ancestors 'self'",
  ].join("; "),
  "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
};

const prelude = `<style>:root{color-scheme:var(--rc-color-scheme,light);font-family:var(--rc-font-family,system-ui,sans-serif);font-size:var(--rc-font-size,16px);color:var(--rc-text,CanvasText);-webkit-text-size-adjust:100%}html,body{margin:0;background:transparent}*,*::before,*::after{box-sizing:border-box}button,input,select,textarea{font:inherit;accent-color:var(--rc-accent)}img,video,svg,canvas{max-width:100%}</style><script>(()=>{const root=document.documentElement;const themeStyle=document.createElement("style");document.head.append(themeStyle);const variables={};const apply=(theme)=>{if(!theme||typeof theme!=="object")return;for(const[name,value]of Object.entries(theme))if(/^--rc-[a-z-]+$/.test(name)&&typeof value==="string"&&!/[;{}<>\\\\]/.test(value))variables[name]=value;themeStyle.textContent=":root{"+Object.entries(variables).map(([name,value])=>name+":"+value).join(";")+"}"};try{apply(JSON.parse(new URLSearchParams(location.search).get("theme")??"{}"))}catch{}addEventListener("message",(event)=>{if(event.source===parent)apply(event.data?.rcVisualTheme)});let last=0;const report=()=>{const height=Math.ceil(Math.max(root.getBoundingClientRect().height,document.body?.scrollHeight??0));if(height!==last){last=height;parent.postMessage({rcVisualHeight:height},"*")}};const resize=new ResizeObserver(report);resize.observe(root);document.addEventListener("DOMContentLoaded",()=>{if(document.body)resize.observe(document.body);report()});addEventListener("load",report);document.addEventListener("click",(event)=>{const link=event.target instanceof Element?event.target.closest("a[href]"):null;if(!link||event.defaultPrevented)return;const href=link.getAttribute("href")??"";if(href.startsWith("#"))return;let url;try{url=new URL(href,location.href)}catch{return}if(!["https:","http:","mailto:"].includes(url.protocol))return;event.preventDefault();open(url.href,"_blank","noopener,noreferrer")})})();</script>`;

export function visualDocument(html: string): string {
  return `<!doctype html>${prelude}${html}`;
}

export const unavailableVisualHeaders = { ...visualHeaders, "Cache-Control": "no-store" };

export function unavailableVisual(reason: string): string {
  return visualDocument(
    `<p style="margin:0;padding:14px 16px;border-radius:14px;background:var(--rc-surface);color:var(--rc-secondary-text)">${reason}</p>`,
  );
}

export async function verifiedVisual(response: Response, digest: string): Promise<string> {
  const declared = Number(response.headers.get("content-length") ?? 0);
  if (declared > maximumVisualBytes) throw new Error("Visual exceeds 2 MiB");
  const reader = response.body?.getReader();
  if (!reader) throw new Error("Visual has no content");
  const chunks: Uint8Array[] = [];
  let length = 0;
  for (;;) {
    const chunk = await reader.read();
    if (chunk.done) break;
    length += chunk.value.byteLength;
    if (length > maximumVisualBytes) {
      await reader.cancel();
      throw new Error("Visual exceeds 2 MiB");
    }
    chunks.push(chunk.value);
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  if (new Bun.CryptoHasher("sha256").update(bytes).digest("hex") !== digest)
    throw new Error("Visual does not match its reference");
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}
