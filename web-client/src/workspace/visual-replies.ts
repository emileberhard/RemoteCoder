const start = '<remotecoder_visual_reply_v1 turn="';
const end = "\n</remotecoder_visual_reply_v1>";
const header = /^[!#-;=?-~]{1,128}" visual="[0-9a-f]{64}" bytes="([1-9][0-9]{0,9})">\n/;
const maximumBytes = 16 * 1024;
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });
const endBytes = encoder.encode(end);

export function visualReplyText(text: string) {
  let result = "";
  let cursor = 0;
  let search = text.indexOf(start);
  while (search >= 0) {
    const reply = parseReply(text, search + start.length);
    if (reply) {
      result += text.slice(cursor, search) + reply.text;
      cursor = reply.next;
    }
    search = text.indexOf(start, reply ? reply.next : search + 1);
  }
  return result + text.slice(cursor);
}

function parseReply(text: string, headerStart: number) {
  const match = header.exec(text.slice(headerStart, headerStart + 256));
  if (!match) return undefined;
  const length = Number(match[1]);
  if (length > maximumBytes) return undefined;
  const payloadStart = headerStart + match[0].length;
  const window = encoder.encode(text.slice(payloadStart, payloadStart + length + end.length));
  if (
    window.length < length + endBytes.length ||
    endBytes.some((byte, index) => window[length + index] !== byte)
  )
    return undefined;
  let payload: string;
  try {
    payload = decoder.decode(window.subarray(0, length));
  } catch {
    return undefined;
  }
  return payload.trim() ? { text: payload, next: payloadStart + payload.length + end.length } : undefined;
}
