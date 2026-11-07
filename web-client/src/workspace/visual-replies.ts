type Block = { start: string; header: RegExp; end: string; maximumBytes: number; nonblank: boolean };

const length = '([1-9][0-9]{0,9})">\\n';
const reply: Block = {
  start: '<remotecoder_visual_reply_v1 turn="',
  header: new RegExp(`^[!#-;=?-~]{1,128}" visual="[0-9a-f]{64}" bytes="${length}`),
  end: "\n</remotecoder_visual_reply_v1>",
  maximumBytes: 16 * 1024,
  nonblank: true,
};
const opaqueBlocks: Block[] = [
  {
    start: '<remotecoder_literal_text_v2 bytes="',
    header: new RegExp(`^${length}`),
    end: "\n</remotecoder_literal_text_v2>",
    maximumBytes: Number.MAX_SAFE_INTEGER,
    nonblank: false,
  },
  {
    start: '<remotecoder_pasted_text_v2 id="',
    header: new RegExp(
      `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}" bytes="${length}`,
      "i",
    ),
    end: "\n</remotecoder_pasted_text_v2>",
    maximumBytes: Number.MAX_SAFE_INTEGER,
    nonblank: true,
  },
];
const blocks = [reply, ...opaqueBlocks];
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

export function visualReplyText(text: string) {
  let result = "";
  let cursor = 0;
  let found = nextBlock(text, 0);
  while (found) {
    const parsed = parseBlock(text, found.index, found.block);
    if (parsed && found.block === reply) {
      result += text.slice(cursor, found.index) + parsed.text;
      cursor = parsed.next;
    }
    found = nextBlock(text, parsed ? parsed.next : found.index + 1);
  }
  return result + text.slice(cursor);
}

function nextBlock(text: string, from: number) {
  let found: { index: number; block: Block } | undefined;
  for (const block of blocks) {
    const index = text.indexOf(block.start, from);
    if (index >= 0 && (!found || index < found.index)) found = { index, block };
  }
  return found;
}

function parseBlock(text: string, index: number, block: Block) {
  const headerStart = index + block.start.length;
  const match = block.header.exec(text.slice(headerStart, headerStart + 256));
  if (!match) return undefined;
  const length = Number(match[1]);
  if (length > block.maximumBytes) return undefined;
  const payloadStart = headerStart + match[0].length;
  const endBytes = encoder.encode(block.end);
  const window = encoder.encode(text.slice(payloadStart, payloadStart + length + block.end.length));
  if (
    window.length < length + endBytes.length ||
    endBytes.some((byte, offset) => window[length + offset] !== byte)
  )
    return undefined;
  let payload: string;
  try {
    payload = decoder.decode(window.subarray(0, length));
  } catch {
    return undefined;
  }
  if (block.nonblank && !payload.trim()) return undefined;
  return { text: payload, next: payloadStart + payload.length + block.end.length };
}
