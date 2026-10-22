import { record } from "./contracts";

export type SpeechFetch = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

export class SpeechRelayError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly kind?: string,
  ) {
    super(message);
  }
}

export function speechURL(hostId: string, provider: "openai" | "gemini", path: string): string {
  return `/api/hosts/${encodeURIComponent(hostId)}/speech/${provider}/${path}`;
}

export async function readBoundedBody(response: Response, limit: number): Promise<Uint8Array<ArrayBuffer>> {
  const declared = response.headers.get("content-length");
  if (declared && Number(declared) > limit) {
    await response.body?.cancel();
    throw new Error("Speech response exceeds browser capacity");
  }
  if (!response.body) throw new Error("Speech response has no body");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      bytes += next.value.byteLength;
      if (bytes > limit) {
        await reader.cancel();
        throw new Error("Speech response exceeds browser capacity");
      }
      chunks.push(next.value);
    }
  } finally {
    reader.releaseLock();
  }
  const result = new Uint8Array(bytes);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
}

export async function relayJSON(response: Response, limit: number): Promise<Record<string, unknown>> {
  const bytes = await readBoundedBody(response, response.ok ? limit : 64 * 1024);
  let body: Record<string, unknown>;
  try {
    body = record(JSON.parse(new TextDecoder().decode(bytes)));
  } catch {
    if (!response.ok)
      throw new SpeechRelayError(`Speech request returned HTTP ${response.status}`, response.status);
    throw new Error("Speech provider returned unreadable JSON");
  }
  if (!response.ok) {
    const kind = response.headers.get("x-speech-relay-rejection") ?? undefined;
    const error = body.remoteCoderSpeechError ?? body.error;
    const message =
      typeof error === "string"
        ? error
        : error && typeof error === "object"
          ? record(error).message
          : body.message;
    throw new SpeechRelayError(
      typeof message === "string" ? message : `Speech request returned HTTP ${response.status}`,
      response.status,
      kind,
    );
  }
  return body;
}
