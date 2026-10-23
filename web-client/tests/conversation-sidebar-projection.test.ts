import { describe, expect, test } from "bun:test";
import { blank } from "../src/workspace/composer-draft-store";
import type { ConversationDrawerArrangement } from "../src/workspace/conversation-drawer-preferences";
import { conversationHeader } from "../src/workspace/conversation-header";
import type { ConversationMarks } from "../src/workspace/conversation-marks";
import {
  type ConversationSidebarHostInput,
  captureDrawerLayout,
  projectConversationSidebar,
} from "../src/workspace/conversation-sidebar-projection";
import { header } from "./fixtures/workspace";

const now = 1700000000;
const marks: ConversationMarks = { schemaVersion: 3, revision: 1, readBaseline: now - 1000, threads: {} };
const arrangement: ConversationDrawerArrangement = {
  mode: "priority",
  unreadOnly: false,
  isPinnedFolded: false,
  isAutomationsFolded: false,
  isSettledFolded: true,
  foldedProjects: new Set(),
  revealedProjects: new Set(),
  projectRowLimit: 5,
  automationRowLimit: 5,
  settledRowLimit: 10,
  query: "",
};
const thread = (id: string, recency = now - 10) =>
  conversationHeader(
    { ...header(id), createdAt: recency, recencyAt: recency, lastTurnCompletedAt: null },
    "codex",
  );
const host = (
  threads: ConversationSidebarHostInput["threads"],
  change: Partial<ConversationSidebarHostInput> = {},
): ConversationSidebarHostInput => ({
  target: { hostId: "mini" },
  hostName: "Mini",
  threads,
  marks,
  homePath: "/workspace",
  activity: new Map(),
  waitingSince: new Map(),
  questionAskTimes: new Map(),
  projects: new Map(),
  isLoading: false,
  history: "ready",
  errors: [],
  canLoadMore: false,
  marksStatus: "ready",
  ...change,
});
const project = (
  hosts: ConversationSidebarHostInput[],
  change: Partial<ConversationDrawerArrangement> = {},
) => projectConversationSidebar(hosts, undefined, new Map(), { ...arrangement, ...change }, now);
const ids = (snapshot: ReturnType<typeof project>) =>
  snapshot.sections.flatMap((section) => section.rows.map((row) => row.address.threadId));

describe("native conversation sidebar projection", () => {
  test("unsent drafts match folded title, condensed directory and visible host labels", () => {
    const mini = host([]);
    const book = host([], { target: { hostId: "book" }, hostName: "MacBook" });
    const key = (input: ConversationSidebarHostInput, id: string) =>
      `new:${encodeURIComponent(JSON.stringify(input.target))}:${id}`;
    const fix = key(mini, "fix");
    const release = key(book, "release");
    const attachment = key(book, "attachment");
    const drafts = new Map([
      [
        fix,
        { ...blank(), text: "\n  Fíx the dráwer\nUnsearchable later line", cwd: "/workspace/RemoteCoder" },
      ],
      [release, { ...blank(), text: "Plan release", cwd: "/tmp" }],
      [
        attachment,
        {
          ...blank(),
          attachments: [
            { id: "file", name: "file", bytes: 1, type: "text/plain", path: "/file", sha256: "digest" },
          ],
        },
      ],
    ]);
    const result = (query: string, inputs = [mini, book]) =>
      projectConversationSidebar(inputs, undefined, drafts, { ...arrangement, query }, now).drafts.map(
        (draft) => draft.key,
      );
    expect(result("MINI drawer remotecoder")).toEqual([fix]);
    expect(result("~/RemoteCoder")).toEqual([fix]);
    expect(result("macbook release")).toEqual([release]);
    expect(result("attachment")).toEqual([attachment]);
    expect(result("Unsearchable")).toEqual([]);
    expect(result("Mini", [mini])).toEqual([]);
    expect(result("not present")).toEqual([]);
  });
  test("pins by natural name then needs input, running, unread and recent; unknown marks remain null", () => {
    const rows = [
      thread("recent"),
      thread("unread"),
      thread("running"),
      thread("question"),
      thread("pin10"),
      thread("pin2"),
      thread("waiting"),
    ];
    const state = host(rows, {
      marks: {
        ...marks,
        threads: {
          pin10: { revision: 1, markedUnread: false, pinName: "Task 10" },
          pin2: { revision: 1, markedUnread: false, pinName: "Task 2" },
          unread: { revision: 1, markedUnread: true },
        },
      },
      activity: new Map([
        ["running", "working"],
        ["waiting", "waiting"],
      ]),
      questionAskTimes: new Map([["question", [now * 1000]]]),
    });
    expect(ids(project([state]))).toEqual([
      "pin2",
      "pin10",
      "question",
      "waiting",
      "running",
      "unread",
      "recent",
    ]);
    const unknown = project([host([thread("unknown")], { marks: undefined, marksStatus: "unread" })])
      .sections[0]?.rows[0];
    expect(unknown?.isPinned).toBeNull();
    expect(unknown?.isUnread).toBeNull();
    expect(unknown?.isProbablyDone).toBeNull();
    expect(unknown?.settlement).toBe("unknown");
  });
  test("covered old requests do not need input; question read watermark clears attention", () => {
    const old = thread("old", now - 4 * 86400);
    const state = host([old, thread("seen")], {
      activity: new Map([["old", "waiting"]]),
      waitingSince: new Map([["old", now - 4 * 86400]]),
      questionAskTimes: new Map([["seen", [(now - 100) * 1000]]]),
      marks: { ...marks, threads: { seen: { revision: 1, markedUnread: false, seenThrough: now } } },
    });
    const result = project([state], { isSettledFolded: false });
    expect(result.sections.find((section) => section.kind === "settled")?.rows[0]?.address.threadId).toBe(
      "old",
    );
    expect(result.sections.flatMap((section) => section.rows).every((row) => !row.needsInput)).toBe(true);
    expect(result.sections[0]?.rows[0]?.questionCount).toBe(0);
  });
  test("remote project identity groups across hosts and caps five; reveal, fold and search are independent", () => {
    const first = host(
      Array.from({ length: 6 }, (_, i) => ({ ...thread(`m${i}`, now - i), cwd: "/workspace/repo" })),
      {
        projects: new Map([
          [
            "/workspace/repo",
            {
              cwd: "/workspace/repo",
              kind: "remote",
              key: "github.com/team/repo",
              name: "repo",
              root: "/workspace/repo",
            },
          ],
        ]),
      },
    );
    const second = host([{ ...thread("b"), cwd: "/other/repo" }], {
      target: { hostId: "book" },
      hostName: "Book",
      projects: new Map([
        [
          "/other/repo",
          {
            cwd: "/other/repo",
            kind: "remote",
            key: "github.com/team/repo",
            name: "repo",
            root: "/other/repo",
          },
        ],
      ]),
    });
    const key = "remote|github.com/team/repo";
    const section = project([first, second], { mode: "projects" }).sections[0];
    expect(section?.summary.rowCount).toBe(7);
    expect(section?.rows).toHaveLength(5);
    expect(section?.hiddenCount).toBe(2);
    expect(section?.hostName).toBeUndefined();
    expect(
      ids(project([first, second], { mode: "projects", revealedProjects: new Set([key]) })),
    ).toHaveLength(7);
    expect(ids(project([first, second], { mode: "projects", foldedProjects: new Set([key]) }))).toHaveLength(
      0,
    );
    expect(
      ids(project([first, second], { mode: "projects", foldedProjects: new Set([key]), query: "Mini repo" })),
    ).toHaveLength(6);
  });
  test("hides delegated agents and idle probes, preserves unresolved roots and selected settled row", () => {
    const delegated = { ...thread("child"), nativeParentThreadId: "root" };
    const probe = thread("probe");
    const settled = thread("settled", now - 5 * 86400);
    const state = host([delegated, thread("root"), probe, settled], {
      marks: { ...marks, threads: { probe: { revision: 1, markedUnread: false, purpose: "probe" } } },
    });
    expect(ids(project([state]))).toEqual(["root"]);
    const selected = projectConversationSidebar(
      [state],
      { hostId: "mini", threadId: "settled" },
      new Map(),
      arrangement,
      now,
    );
    expect(ids(selected)).toEqual(["root", "settled"]);
    expect(selected.sections.at(-1)?.summary.fold).toBe("folded");
  });
  test("automation purpose groups between Pinned and chats in both modes, while pins retain one marked row", () => {
    const state = host(
      [
        thread("user"),
        thread("automatic"),
        thread("pinned"),
        thread("selected"),
        thread("old-automatic", now - 5 * 86400),
        thread("old-user", now - 5 * 86400),
      ],
      {
        activity: new Map([["automatic", "working"]]),
        marks: {
          ...marks,
          threads: {
            automatic: { revision: 1, markedUnread: false, purpose: "automation" },
            pinned: { revision: 1, markedUnread: false, purpose: "automation", pinName: "Keep" },
            selected: { revision: 1, markedUnread: false, purpose: "automation" },
            "old-automatic": { revision: 1, markedUnread: false, purpose: "automation" },
          },
        },
      },
    );
    for (const mode of ["priority", "projects"] as const) {
      const snapshot = projectConversationSidebar(
        [state],
        { hostId: "mini", threadId: "selected" },
        new Map(),
        { ...arrangement, mode, isSettledFolded: false },
        now,
      );
      expect(snapshot.sections.map((section) => section.kind)).toEqual([
        "pinned",
        "automations",
        mode === "priority" ? "chats" : "project",
        "settled",
      ]);
      expect(ids(snapshot)).toEqual(["pinned", "automatic", "selected", "old-automatic", "user", "old-user"]);
      const automationRows = snapshot.sections.find((section) => section.kind === "automations")?.rows;
      expect(automationRows?.every((row) => row.isAutomation)).toBe(true);
      expect(automationRows?.find((row) => row.address.threadId === "selected")?.isSelected).toBe(true);
      expect(automationRows?.find((row) => row.address.threadId === "old-automatic")?.settlement).toBe(
        "settled",
      );
      expect(snapshot.sections[0]?.rows[0]?.isAutomation).toBe(true);
      expect(snapshot.sections[2]?.rows[0]?.isAutomation).toBe(false);
    }
  });
  test("automations show the five most recent and the selected row until revealed", () => {
    const automations = [1, 2, 3, 4, 5, 6, 7].map((index) => thread(`auto-${index}`, now - index));
    const state = host(automations, {
      marks: {
        ...marks,
        threads: Object.fromEntries(
          automations.map((automation) => [
            automation.id,
            { revision: 1, markedUnread: false, purpose: "automation" as const },
          ]),
        ),
      },
    });
    const limited = projectConversationSidebar(
      [state],
      { hostId: "mini", threadId: "auto-7" },
      new Map(),
      { ...arrangement, automationRowLimit: 5 },
      now,
    ).sections[0];
    expect(limited?.rows.map((row) => row.address.threadId)).toEqual([
      "auto-1",
      "auto-2",
      "auto-3",
      "auto-4",
      "auto-5",
      "auto-7",
    ]);
    expect(limited?.hiddenCount).toBe(1);
    const revealed = project([state], { automationRowLimit: Number.MAX_SAFE_INTEGER }).sections[0];
    expect(revealed?.rows).toHaveLength(7);
    expect(revealed?.hiddenCount).toBe(0);
  });
  test("folded automations retain summaries and search reveals matching rows without changing identity", () => {
    const state = host([{ ...thread("automatic"), name: "Automatic" }, thread("quiet")], {
      activity: new Map([
        ["automatic", "working"],
        ["quiet", "idle"],
      ]),
      marks: {
        ...marks,
        threads: {
          automatic: { revision: 1, markedUnread: true, purpose: "automation" },
          quiet: { revision: 1, markedUnread: false, purpose: "automation" },
        },
      },
    });
    const expanded = project([state]).sections[0];
    const folded = project([state], { isAutomationsFolded: true }).sections[0];
    expect(folded?.rows).toEqual([]);
    expect(folded?.summary).toEqual({ fold: "folded", rowCount: 2, unreadCount: 1, liveActivity: "working" });
    const searched = project([state], { isAutomationsFolded: true, query: "automatic" }).sections[0];
    expect(searched?.summary.fold).toBe("searching");
    expect(searched?.rows).toHaveLength(1);
    expect(searched?.rows[0]?.id).toBe(expanded?.rows[0]?.id);
    expect(ids(project([state], { unreadOnly: true }))).toEqual(["automatic"]);
  });
  test("captured drawer rank is stable while unread and query values stay live", () => {
    const a = thread("a", now - 50),
      b = thread("b", now - 5);
    const input = host([a, b]);
    const layout = captureDrawerLayout([input], now);
    const changed = host([a, b], {
      activity: new Map([["a", "working"]]),
      marks: { ...marks, threads: { a: { revision: 2, markedUnread: true } } },
    });
    const held = projectConversationSidebar([changed], undefined, new Map(), arrangement, now, layout);
    expect(ids(held)).toEqual(["b", "a"]);
    expect(held.sections[0]?.rows[1]?.isUnread).toBe(true);
    expect(
      ids(
        projectConversationSidebar(
          [changed],
          undefined,
          new Map(),
          { ...arrangement, unreadOnly: true },
          now,
          layout,
        ),
      ),
    ).toEqual(["a"]);
  });
  test("folder fallback is scoped to host; settled shelf cap and more count match native", () => {
    const rows = Array.from({ length: 14 }, (_, i) => thread(`old${i}`, now - 4 * 86400 - i));
    const result = project([host(rows)], { isSettledFolded: false });
    expect(result.sections[0]?.rows).toHaveLength(10);
    expect(result.sections[0]?.hiddenCount).toBe(4);
    const folders = project(
      [host([thread("a")]), host([thread("b")], { target: { hostId: "book" }, hostName: "Book" })],
      { mode: "projects" },
    );
    expect(folders.sections.map((section) => section.id)).toEqual([
      "book|directory|/workspace",
      "mini|directory|/workspace",
    ]);
  });
});

test("automatic settlement covers old unseen question badges", () => {
  const requested = now - 4 * 86400;
  const result = project(
    [
      host([thread("old", requested)], {
        marks: { ...marks, readBaseline: 0 },
        questionAskTimes: new Map([["old", [requested * 1000]]]),
      }),
    ],
    { isSettledFolded: false },
  );
  expect(result.sections[0]?.rows[0]).toMatchObject({
    questionCount: 0,
    needsInput: false,
    settlement: "settled",
  });
});

test("drawer text filtering folds case and diacritics with token AND semantics", () => {
  const candidate = { ...thread("folded"), name: "École Straße", cwd: "/workspace/project" };
  expect(ids(project([host([candidate])], { query: "ECOLE strasse project" }))).toEqual(["folded"]);
  expect(ids(project([host([candidate])], { query: "ECOLE missing" }))).toEqual([]);
});

test("unsent drafts sort newest first, known times before historical unknowns, with stable key ties", () => {
  const input = host([], { homePath: "/Users/developer" });
  const key = (id: string) => `new:${encodeURIComponent(JSON.stringify(input.target))}:${id}`;
  const drafts = new Map([
    [key("unknown-z"), { ...blank(), text: "Unknown last", cwd: "/Users/developer/repo" }],
    [key("older"), { ...blank(), text: "Older", modifiedAt: 1000, cwd: "/Users/developer/repo" }],
    [key("tie-z"), { ...blank(), text: "Recent Z", modifiedAt: 2000, cwd: "/Users/developer/repo" }],
    [key("unknown-a"), { ...blank(), text: "Unknown first", cwd: "/Users/developer/repo" }],
    [key("tie-a"), { ...blank(), text: "Recent A", modifiedAt: 2000, cwd: "/Users/developer/repo" }],
  ]);
  const result = projectConversationSidebar([input], undefined, drafts, arrangement, now).drafts;
  expect(result.map((row) => row.key)).toEqual([
    key("tie-a"),
    key("tie-z"),
    key("older"),
    key("unknown-a"),
    key("unknown-z"),
  ]);
  expect(result[0]).toMatchObject({ cwd: "/Users/developer/repo", workingDirectory: "~/repo" });
  expect(
    projectConversationSidebar(
      [input],
      undefined,
      drafts,
      { ...arrangement, query: "recent repo" },
      now,
    ).drafts.map((row) => row.key),
  ).toEqual([key("tie-a"), key("tie-z")]);
});
