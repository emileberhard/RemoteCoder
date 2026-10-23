import { conversationAddress, type ExecutionTarget } from "../execution-context";
import { type Address, addressKey } from "../protocol/boundary";
import type { Draft } from "./composer-draft-store";
import type { ConversationActivityState } from "./conversation-activity";
import type { ConversationDrawerArrangement } from "./conversation-drawer-preferences";
import { type ConversationHeader, isDelegatedAgent, latestActivityAt } from "./conversation-header";
import {
  type ConversationMarks,
  coversRequest,
  isProbablyDone,
  isSettled,
  isUnread,
  isUnseenQuestion,
} from "./conversation-marks";
import type { ProjectIdentity } from "./conversation-projects";
import { foldSearchText } from "./search-text";
import { condensedPath } from "./working-directory-path";

export type ConversationSidebarHostInput = Readonly<{
  target: ExecutionTarget;
  hostName: string;
  threads: readonly ConversationHeader[];
  marks: ConversationMarks | undefined;
  homePath: string | undefined;
  activity: ReadonlyMap<string, ConversationActivityState>;
  waitingSince: ReadonlyMap<string, number>;
  questionAskTimes: ReadonlyMap<string, readonly number[] | undefined>;
  projects: ReadonlyMap<string, ProjectIdentity>;
  settlementEdits?: ReadonlyMap<string, number>;
  loadingThreadId?: string;
  isLoading: boolean;
  history: "unread" | "loading" | "ready" | "failed";
  errors: readonly string[];
  canLoadMore: boolean;
  marksStatus: "unread" | "loading" | "ready" | "failed";
}>;
export type ConversationSidebarRow = Readonly<{
  id: string;
  address: Address;
  hostName: string;
  showsHostLabel: boolean;
  title: string;
  preview: string;
  timestamp: number | null;
  workingDirectory: string;
  isPinned: boolean | null;
  isAutomation: boolean;
  isUnread: boolean | null;
  isSelected: boolean;
  isLoading: boolean;
  activity: ConversationActivityState;
  questionCount: number | null;
  settlement: "unknown" | "unavailable" | "unsettled" | "settled";
  isProbablyDone: boolean | null;
  needsInput: boolean;
  canSettle: boolean;
}>;
export type ConversationSectionSummary = Readonly<{
  fold: "expanded" | "folded" | "searching";
  rowCount: number;
  unreadCount: number | null;
  liveActivity: ConversationActivityState | null;
}>;
export type ConversationSidebarSection = Readonly<{
  id: string;
  kind: "pinned" | "chats" | "project" | "automations" | "settled";
  title: string;
  hostName?: string;
  summary: ConversationSectionSummary;
  rows: readonly ConversationSidebarRow[];
  hiddenCount: number;
}>;
export type UnsentDraftRow = Readonly<{
  key: string;
  text: string;
  cwd: string;
  workingDirectory: string;
  attachmentCount: number;
}>;
export type ConversationSidebarSnapshot = Readonly<{
  sections: readonly ConversationSidebarSection[];
  drafts: readonly UnsentDraftRow[];
  hostStates: readonly Readonly<{
    target: ExecutionTarget;
    hostName: string;
    isLoading: boolean;
    history: ConversationSidebarHostInput["history"];
    errors: readonly string[];
    rowCount: number;
    canLoadMore: boolean;
    marksStatus: ConversationSidebarHostInput["marksStatus"];
  }>[];
}>;
type Rank = Readonly<{
  tier: number;
  recency: number | null;
  isUnread: boolean | null;
  isSettled: boolean;
  settlementMark: string;
}>;
export type ConversationDrawerLayout = ReadonlyMap<string, Rank>;
type RankInput = Pick<
  ConversationSidebarHostInput,
  "marks" | "activity" | "waitingSince" | "questionAskTimes" | "settlementEdits"
>;
export type ConversationRowMarkState = Pick<
  ConversationSidebarRow,
  "title" | "isPinned" | "isUnread" | "settlement" | "canSettle"
>;
const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });
const marked = (thread: ConversationHeader) => ({
  id: thread.id,
  latestActivityAt: latestActivityAt(thread),
  lastTurnCompletedAt: thread.lastTurnCompletedAt,
});

function rank(thread: ConversationHeader, host: RankInput, now: number): Rank {
  const marks = host.marks;
  const value = marked(thread);
  const activity = host.activity.get(thread.id) ?? "unknown";
  const asks = host.questionAskTimes.get(thread.id);
  const needsYou =
    (activity === "waiting" &&
      (!marks || !coversRequest(marks, host.waitingSince.get(thread.id) ?? null, value, now))) ||
    asks?.some(
      (asked) =>
        (!marks || isUnseenQuestion(marks, asked, thread.id)) &&
        (!marks || !coversRequest(marks, Math.trunc(asked / 1000), value, now)),
    ) === true;
  const unread = marks ? isUnread(marks, value) : null;
  const isLive = needsYou || activity === "working";
  const settlement = marks?.threads[thread.id]?.settlement;
  return {
    tier: needsYou ? 0 : activity === "working" ? 1 : unread === true ? 2 : 3,
    recency: latestActivityAt(thread),
    isUnread: unread,
    isSettled: marks ? isSettled(marks, value, isLive, now) : false,
    settlementMark: JSON.stringify([
      marks ? marks.schemaVersion >= 2 : null,
      settlement,
      settlement?.state === "settled" ? marks?.threads[thread.id]?.pinName : undefined,
      host.settlementEdits?.get(thread.id),
    ]),
  };
}
function rowMarkState(
  marks: ConversationMarks | undefined,
  pin: string | undefined,
  settled: boolean,
  unread: boolean | null,
  activity: ConversationActivityState,
): Omit<ConversationRowMarkState, "title"> {
  const settlement =
    marks === undefined
      ? "unknown"
      : marks.schemaVersion < 2
        ? "unavailable"
        : settled
          ? "settled"
          : "unsettled";
  return {
    isPinned: marks ? pin !== undefined : null,
    isUnread: unread,
    settlement,
    canSettle: settlement === "unsettled" && activity !== "working",
  };
}
function conversationTitle(thread: ConversationHeader, pinName: string | undefined) {
  return pinName ?? (thread.name?.trim() ? thread.name : thread.preview.trim() || "(untitled)");
}
export function conversationRowMarkState(
  thread: ConversationHeader,
  host: RankInput,
  now: number,
  captured?: Rank,
): ConversationRowMarkState {
  const live = rank(thread, host, now);
  const held = captured?.settlementMark === live.settlementMark ? captured : live;
  const pin = host.marks?.threads[thread.id]?.pinName;
  return {
    title: conversationTitle(thread, pin),
    ...rowMarkState(
      host.marks,
      pin,
      pin === undefined && held.isSettled,
      live.isUnread,
      host.activity.get(thread.id) ?? "unknown",
    ),
  };
}
export function captureDrawerLayout(
  hosts: readonly ConversationSidebarHostInput[],
  now: number,
): ConversationDrawerLayout {
  const layout = new Map<string, Rank>();
  for (const host of hosts)
    for (const thread of host.threads)
      if (!isDelegatedAgent(thread))
        layout.set(addressKey(conversationAddress(host.target, thread.id)), rank(thread, host, now));
  return layout;
}
export function admitDrawerLayout(
  previous: ConversationDrawerLayout,
  hosts: readonly ConversationSidebarHostInput[],
  now: number,
): ConversationDrawerLayout {
  const next = new Map<string, Rank>();
  for (const host of hosts)
    for (const thread of host.threads) {
      const key = addressKey(conversationAddress(host.target, thread.id));
      const live = rank(thread, host, now);
      const held = previous.get(key);
      next.set(key, held?.settlementMark === live.settlementMark ? held : live);
    }
  return next;
}
function summary(
  rows: readonly ConversationSidebarRow[],
  fold: ConversationSectionSummary["fold"],
): ConversationSectionSummary {
  return {
    fold,
    rowCount: rows.length,
    unreadCount: rows.some((row) => row.isUnread === null) ? null : rows.filter((row) => row.isUnread).length,
    liveActivity: rows.some((row) => row.needsInput)
      ? "waiting"
      : rows.some((row) => row.activity === "working")
        ? "working"
        : rows.some((row) => row.activity === "unknown")
          ? "unknown"
          : null,
  };
}
function project(thread: ConversationHeader, host: ConversationSidebarHostInput) {
  const identity = host.projects.get(thread.cwd);
  if (identity?.kind === "remote") return { key: `remote|${identity.key}`, title: identity.name };
  return {
    key: `${host.target.hostId}|${identity?.kind ?? "directory"}|${identity?.key ?? thread.cwd}`,
    title:
      identity?.kind === "repository"
        ? identity.name
        : condensedPath(identity?.root ?? thread.cwd, host.homePath),
    hostName: host.hostName,
  };
}
function matches(title: string, directory: string, hostName: string, terms: readonly string[]) {
  return terms.every((term) =>
    [title, directory, hostName].some((text) => foldSearchText(text).includes(term)),
  );
}
export function projectConversationSidebar(
  hosts: readonly ConversationSidebarHostInput[],
  selected: Address | undefined,
  drafts: ReadonlyMap<string, Draft>,
  arrangement: ConversationDrawerArrangement,
  now: number,
  layout?: ConversationDrawerLayout,
): ConversationSidebarSnapshot {
  const terms = foldSearchText(arrangement.query).trim().split(/\s+/).filter(Boolean);
  const searching = terms.length > 0;
  const showsHostLabel = new Set(hosts.map((host) => host.target.hostId)).size > 1;
  const slots: {
    row: ConversationSidebarRow;
    rank: Rank;
    pin?: string;
    project: ReturnType<typeof project>;
  }[] = [];
  const ids = new Set<string>();
  for (const host of hosts)
    for (const thread of host.threads) {
      if (isDelegatedAgent(thread)) continue;
      const address = conversationAddress(host.target, thread.id);
      const id = addressKey(address);
      if (ids.has(id)) continue;
      ids.add(id);
      const live = rank(thread, host, now);
      const captured = layout?.get(id);
      const held = captured?.settlementMark === live.settlementMark ? captured : live;
      const marks = host.marks;
      const pin = marks?.threads[thread.id]?.pinName;
      const isSelected = selected !== undefined && addressKey(selected) === id;
      if (marks?.threads[thread.id]?.purpose === "probe" && live.tier > 1 && !isSelected) continue;
      const settled =
        pin === undefined && held.isSettled && !(arrangement.unreadOnly && live.isUnread === true);
      if (
        arrangement.unreadOnly &&
        !isSelected &&
        (settled || (live.isUnread !== true && held.isUnread !== true))
      )
        continue;
      const asks = host.questionAskTimes.get(thread.id);
      const activity = host.activity.get(thread.id) ?? "unknown";
      const markState = rowMarkState(marks, pin, settled, live.isUnread, activity);
      const row: ConversationSidebarRow = {
        id,
        address,
        hostName: host.hostName,
        showsHostLabel,
        title: conversationTitle(thread, pin),
        preview: thread.preview,
        timestamp: live.recency,
        workingDirectory: condensedPath(thread.cwd, host.homePath),
        ...markState,
        isAutomation: marks?.threads[thread.id]?.purpose === "automation",
        isSelected,
        isLoading: host.loadingThreadId === thread.id,
        activity,
        questionCount:
          asks === undefined || marks === undefined
            ? null
            : asks.filter(
                (asked) =>
                  isUnseenQuestion(marks, asked, thread.id) &&
                  !coversRequest(marks, Math.trunc(asked / 1000), marked(thread), now),
              ).length,
        isProbablyDone: marks ? live.tier > 1 && !settled && isProbablyDone(marks, marked(thread)) : null,
        needsInput: live.tier === 0,
      };
      if (!matches(row.title, row.workingDirectory, showsHostLabel ? row.hostName : "", terms)) continue;
      slots.push({ row, rank: held, pin, project: project(thread, host) });
    }
  slots.sort((a, b) => {
    if (a.pin !== undefined && b.pin !== undefined)
      return collator.compare(a.pin, b.pin) || a.row.id.localeCompare(b.row.id);
    if (a.pin !== undefined || b.pin !== undefined) return a.pin !== undefined ? -1 : 1;
    const sectionOrder = (row: ConversationSidebarRow) =>
      row.isAutomation ? 0 : row.settlement === "settled" ? 2 : 1;
    return (
      sectionOrder(a.row) - sectionOrder(b.row) ||
      (sectionOrder(a.row) === 2 ? 0 : a.rank.tier - b.rank.tier) ||
      (b.rank.recency ?? -Infinity) - (a.rank.recency ?? -Infinity) ||
      a.row.id.localeCompare(b.row.id)
    );
  });
  const sections: ConversationSidebarSection[] = [];
  const fold = (folded: boolean) =>
    searching ? ("searching" as const) : folded ? ("folded" as const) : ("expanded" as const);
  const add = (
    kind: ConversationSidebarSection["kind"],
    id: string,
    title: string,
    rows: ConversationSidebarRow[],
    folded: boolean,
    limit = rows.length,
    hostName?: string,
  ) => {
    if (!rows.length) return;
    const state = fold(folded);
    const visible = rows.filter(
      (row, index) =>
        state === "searching" ||
        (state === "expanded" && index < limit) ||
        (row.isSelected && (kind === "settled" || (kind === "automations" && state === "expanded"))),
    );
    sections.push({
      id,
      kind,
      title,
      ...(hostName && showsHostLabel ? { hostName } : {}),
      summary: summary(rows, state),
      rows: visible,
      hiddenCount: state === "expanded" ? rows.length - visible.length : 0,
    });
  };
  add(
    "pinned",
    "pinned",
    "Pinned",
    slots.filter((slot) => slot.pin !== undefined).map((slot) => slot.row),
    arrangement.isPinnedFolded,
  );
  add(
    "automations",
    "automations",
    "Automations",
    slots.filter((slot) => slot.pin === undefined && slot.row.isAutomation).map((slot) => slot.row),
    arrangement.isAutomationsFolded,
    arrangement.automationRowLimit,
  );
  const chats = slots.filter(
    (slot) => slot.pin === undefined && !slot.row.isAutomation && slot.row.settlement !== "settled",
  );
  if (arrangement.mode === "priority")
    add(
      "chats",
      "chats",
      "Chats",
      chats.map((slot) => slot.row),
      false,
    );
  else {
    const groups = new Map<string, typeof slots>();
    for (const slot of chats) groups.set(slot.project.key, [...(groups.get(slot.project.key) ?? []), slot]);
    const ordered = [...groups].sort(
      ([a, left], [b, right]) =>
        Math.max(...right.map((slot) => slot.rank.recency ?? -Infinity)) -
          Math.max(...left.map((slot) => slot.rank.recency ?? -Infinity)) || a.localeCompare(b),
    );
    for (const [key, group] of ordered) {
      const identity = group[0]?.project;
      if (identity)
        add(
          "project",
          key,
          identity.title,
          group.map((slot) => slot.row),
          arrangement.foldedProjects.has(key),
          arrangement.revealedProjects.has(key) ? group.length : arrangement.projectRowLimit,
          identity.hostName,
        );
    }
  }
  add(
    "settled",
    "settled",
    "Settled",
    slots
      .filter((slot) => !slot.row.isAutomation && slot.row.settlement === "settled")
      .map((slot) => slot.row),
    arrangement.isSettledFolded,
    arrangement.settledRowLimit,
  );
  return {
    sections,
    drafts: [...drafts]
      .filter(([key, draft]) => key.startsWith("new:") && (draft.text.trim() || draft.attachments.length))
      .map(([key, draft]) => {
        const host = hosts.find((input) =>
          key.startsWith(`new:${encodeURIComponent(JSON.stringify(input.target))}:`),
        );
        return { key, draft, host, workingDirectory: condensedPath(draft.cwd, host?.homePath) };
      })
      .filter(({ draft, host, workingDirectory }) => {
        const title = draft.text
          .split(/\r?\n/)
          .find((line) => line.trim())
          ?.trim()
          .slice(0, 160);
        return matches(
          title ?? `${draft.attachments.length} attachment${draft.attachments.length === 1 ? "" : "s"}`,
          workingDirectory,
          showsHostLabel ? (host?.hostName ?? "") : "",
          terms,
        );
      })
      .sort(
        (left, right) =>
          (right.draft.modifiedAt ?? -Infinity) - (left.draft.modifiedAt ?? -Infinity) ||
          (left.key < right.key ? -1 : left.key > right.key ? 1 : 0),
      )
      .map(({ key, draft, workingDirectory }) => ({
        key,
        text: draft.text,
        cwd: draft.cwd,
        workingDirectory,
        attachmentCount: draft.attachments.length,
      })),
    hostStates: hosts.map((host) => ({
      target: host.target,
      hostName: host.hostName,
      isLoading: host.isLoading,
      history: host.history,
      errors: host.errors,
      canLoadMore: host.canLoadMore,
      marksStatus: host.marksStatus,
      rowCount: host.threads.filter((thread) => !isDelegatedAgent(thread)).length,
    })),
  };
}
