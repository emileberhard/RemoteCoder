import { foldSearchText } from "./search-text";
export type CommandPaletteCandidate<ID> = { id: ID; title: string; detail: string };

type SearchText = { characters: string[]; wordStarts: boolean[] };
const preparedCandidates = new WeakMap<
  readonly CommandPaletteCandidate<unknown>[],
  readonly { title: SearchText; detail: SearchText }[]
>();
const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });

function characters(value: string): string[] {
  return Array.from(segmenter.segment(value), ({ segment }) => segment);
}
function searchText(value: string): SearchText {
  const folded = characters(foldSearchText(value)).slice(0, 256);
  return {
    characters: folded,
    wordStarts: folded.map((_, index) => index === 0 || !/[\p{L}\p{N}]/u.test(folded[index - 1] ?? "")),
  };
}
function occurrenceScore(
  token: readonly string[],
  text: SearchText,
  prefix: number,
  wordStart: number,
  anywhere: number,
): number | undefined {
  let best: number | undefined;
  for (let start = 0; start <= text.characters.length - token.length; start++) {
    if (!token.every((character, index) => character === text.characters[start + index])) continue;
    if (start === 0) return prefix;
    best = Math.max(best ?? anywhere, text.wordStarts[start] ? wordStart : anywhere);
  }
  return best;
}
function subsequenceScore(token: readonly string[], text: SearchText): number | undefined {
  let first: number | undefined;
  let matched = 0;
  for (const [index, character] of text.characters.entries()) {
    if (character !== token[matched]) continue;
    first ??= index;
    matched++;
    if (matched === token.length) return Math.max(100, 300 - (index - first + 1 - token.length) * 10);
  }
  return undefined;
}
export function commandPaletteResults<ID>(
  query: string,
  candidates: readonly CommandPaletteCandidate<ID>[],
  limit: number,
): ID[] {
  if (!Number.isSafeInteger(limit) || limit < 0)
    throw new Error("The command search limit must be a nonnegative safe integer");
  if (limit === 0) return [];
  const tokens = foldSearchText(query)
    .split(/\p{White_Space}+/u)
    .filter(Boolean)
    .map(characters);
  if (!tokens.length) return candidates.slice(0, limit).map(({ id }) => id);
  let prepared = preparedCandidates.get(candidates);
  if (!prepared) {
    prepared = candidates.map((candidate) => ({
      title: searchText(candidate.title),
      detail: searchText(candidate.detail),
    }));
    preparedCandidates.set(candidates, prepared);
  }
  const ranked: { id: ID; score: number; index: number }[] = [];
  for (const [index, { title, detail }] of prepared.entries()) {
    let total = 0;
    let matches = true;
    for (const token of tokens) {
      const scores = [
        occurrenceScore(token, title, 1000, 800, 600),
        subsequenceScore(token, title),
        occurrenceScore(token, detail, 400, 400, 250),
      ].filter((score): score is number => score !== undefined);
      if (!scores.length) {
        matches = false;
        break;
      }
      total += Math.max(...scores);
    }
    if (matches)
      ranked.push({ id: (candidates[index] as CommandPaletteCandidate<ID>).id, score: total, index });
  }
  return ranked
    .sort((left, right) => right.score - left.score || left.index - right.index)
    .slice(0, limit)
    .map(({ id }) => id);
}
