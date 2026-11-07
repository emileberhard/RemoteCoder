const replyStart = '<remotecoder_visual_reply_v1 turn="';
const replyHeader = /^[!#-;=?-~]{1,128}" visual="[0-9a-f]{64}" bytes="([1-9][0-9]{0,9})">\n/;
const replyEnd = "\n</remotecoder_visual_reply_v1>";
const literalStart = '<remotecoder_literal_text_v2 bytes="';
const literalHeader = /^([1-9][0-9]{0,9})">\n/;
const literalEnd = "\n</remotecoder_literal_text_v2>";
const maximumReplyBytes = 16 * 1024;
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

export function visualReplyText(text: string) {
  let result = "";
  let cursor = 0;
  let search = nextMarker(text, 0);
  while (search >= 0) {
    if (text.startsWith(literalStart, search)) {
      const literal = parsePayload(text, search + literalStart.length, literalHeader, literalEnd);
      search = nextMarker(text, literal ? literal.next : search + 1);
      continue;
    }
    const reply = parsePayload(text, search + replyStart.length, replyHeader, replyEnd, maximumReplyBytes);
    const accepted = reply?.text.trim() ? reply : undefined;
    if (accepted) {
      result += text.slice(cursor, search) + accepted.text;
      cursor = accepted.next;
    }
    search = nextMarker(text, accepted ? accepted.next : search + 1);
  }
  return result + text.slice(cursor);
}

function nextMarker(text: string, from: number) {
  const reply = text.indexOf(replyStart, from);
  const literal = text.indexOf(literalStart, from);
  if (reply < 0) return literal;
  return literal < 0 ? reply : Math.min(reply, literal);
}

function parsePayload(
  text: string,
  headerStart: number,
  header: RegExp,
  end: string,
  maximumBytes = Infinity,
) {
  const match = header.exec(text.slice(headerStart, headerStart + 256));
  if (!match) return undefined;
  const length = Number(match[1]);
  if (length > maximumBytes) return undefined;
  const payloadStart = headerStart + match[0].length;
  const endBytes = encoder.encode(end);
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
  return { text: payload, next: payloadStart + payload.length + end.length };
}
