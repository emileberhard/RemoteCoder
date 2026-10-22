import { expect, test } from "bun:test";
import {
  accountCatalog,
  conversationAddress,
  conversationKey,
  decodeAddress,
  decodeTarget,
  executionTarget,
  gatewayPath,
  initialCodexPreference,
  requireCurrentEnrollment,
  resolveCodexChoice,
  sameBinding,
  targetForProvider,
  targetKey,
} from "../src/execution-context";

const mini = "9F8C0E05-5F3B-4A0F-B55D-FAE0E2D70352";
const book = "6A71F6AF-4C5B-47F8-8A59-CFE189450A44";
const enrollment = "8dc8844a-15b0-4117-9c52-f61246c8012a";
const anotherEnrollment = "7df762a9-019b-478e-b8fd-25bf773c24d9";
const snapshot = (id: string, generation: number, identityKey: string | null = "workspace/verified") => ({
  id,
  generation,
  provider: "codex",
  label: "Subscription",
  enabled: true,
  isDefault: id === "default-codex",
  identity:
    identityKey === null ? null : { key: identityKey, email: "person@example.test", workspace: "workspace" },
  state: "ready",
  stale: true,
  windows: [],
  activeTurns: 0,
});
const directory = (accounts: unknown[]) => ({
  schemaVersion: 2,
  refreshing: false,
  accounts,
  retiredClaudeAccountIds: [],
});

test("colliding thread IDs remain distinct across physical hosts and enrollments", () => {
  const enrolled = executionTarget(mini, { accountId: enrollment, generation: 1 });
  const contexts = [
    executionTarget(mini),
    executionTarget(book),
    enrolled,
    executionTarget(mini, { accountId: anotherEnrollment, generation: 1 }),
  ];
  const keys = contexts.map((target) => conversationKey(conversationAddress(target, "same-thread")));
  expect(new Set(keys).size).toBe(4);
  const saved = decodeAddress(JSON.parse(JSON.stringify(conversationAddress(enrolled, "same-thread"))));
  const enrolledKey = keys[2];
  if (!enrolledKey) throw new Error("The enrolled key is unavailable");
  expect(conversationKey(saved)).toBe(enrolledKey);
  expect(saved.enrollment?.accountId).toBe(enrollment);
});

test("new generations retire a binding without changing persisted conversation identity", () => {
  const original = executionTarget(mini, { accountId: enrollment, generation: 2 });
  const replacement = executionTarget(mini, { accountId: enrollment, generation: 3 });
  const latest = accountCatalog(mini, directory([snapshot(enrollment, 3)]));
  expect(sameBinding(original, replacement)).toBe(false);
  expect(targetKey(original)).not.toBe(targetKey(replacement));
  expect(conversationKey(conversationAddress(original, "thread"))).toBe(
    conversationKey(conversationAddress(replacement, "thread")),
  );
  expect(() => requireCurrentEnrollment(original, latest)).toThrow("generation changed");
  expect(requireCurrentEnrollment(replacement, latest).enrollment?.generation).toBe(3);
  expect(original.enrollment?.generation).toBe(2);
});

test("the native UUID and generation pair is required before websocket routing", () => {
  const target = executionTarget(mini, { accountId: enrollment.toUpperCase(), generation: 7 });
  expect(gatewayPath(target)).toBe(`/api/hosts/${mini}/ws?accountId=${enrollment}&accountGeneration=7`);
  expect(gatewayPath(executionTarget(mini))).toBe(`/api/hosts/${mini}/ws`);
  for (const generation of [0, -1, Number.NaN, Number.POSITIVE_INFINITY, Number.MAX_SAFE_INTEGER + 1])
    expect(() => decodeTarget({ hostId: mini, enrollment: { accountId: enrollment, generation } })).toThrow(
      "generation",
    );
  expect(() => decodeTarget({ hostId: mini, enrollment: { accountId: enrollment } })).toThrow("generation");
  expect(() => decodeTarget({ hostId: mini, accountId: enrollment, accountGeneration: 7 })).toThrow(
    "provenance",
  );
  expect(() =>
    decodeTarget({ hostId: mini, enrollment: { accountId: "../default", generation: 7 } }),
  ).toThrow("UUID");
});

test("Claude contexts and legacy Claude addresses always use their physical host default", () => {
  const enrolled = executionTarget(book, { accountId: enrollment, generation: 4 });
  const claude = targetForProvider(enrolled, "claude");
  expect(claude.hostId).toBe(book);
  expect(claude.enrollment).toBeUndefined();
  expect(conversationAddress(enrolled, "claude_known").enrollment).toBeUndefined();
  expect(conversationKey(conversationAddress(enrolled, "claude_known"))).toBe(
    conversationKey(conversationAddress(claude, "claude_known")),
  );
  expect(enrolled.enrollment?.generation).toBe(4);
});

test("a missing preferred subscription cannot silently choose a ready default", () => {
  const catalog = accountCatalog(mini, directory([snapshot("default-codex", 0, "workspace/other")]));
  expect(() => resolveCodexChoice([catalog], "codex:workspace/missing", mini)).toThrow(
    "preferred Codex account is missing",
  );
  expect(() => resolveCodexChoice([catalog], undefined, mini)).toThrow("Choose a verified");
  expect(() => resolveCodexChoice([accountCatalog(mini)], "codex:workspace/missing", mini)).toThrow(
    "membership is not available",
  );
  const unknownIdentity = accountCatalog(mini, directory([snapshot(enrollment, 2, null)]));
  expect(
    initialCodexPreference(unknownIdentity, executionTarget(mini, { accountId: enrollment, generation: 2 })),
  ).toBeUndefined();
  expect(unknownIdentity.choices[0]?.usable).toBe(false);
});

test("verified subscription resolution prefers this host's dedicated enrollment without moving existing owners", () => {
  const miniCatalog = accountCatalog(
    mini,
    directory([snapshot("default-codex", 0), snapshot(enrollment, 2)]),
  );
  const bookCatalog = accountCatalog(book, directory([snapshot(anotherEnrollment, 6)]));
  const existing = conversationAddress(
    executionTarget(book, { accountId: anotherEnrollment, generation: 6 }),
    "saved-thread",
  );
  const selected = resolveCodexChoice([bookCatalog, miniCatalog], "codex:workspace/verified", mini);
  expect(selected.target.enrollment?.accountId).toBe(enrollment);
  expect(selected.target.hostId).toBe(mini);
  expect(existing.hostId).toBe(book);
  expect(existing.enrollment?.accountId).toBe(anotherEnrollment);
});

test("unavailable and retired enrollment ownership fails closed", () => {
  const target = executionTarget(mini, { accountId: enrollment, generation: 2 });
  const unavailable = accountCatalog(
    mini,
    directory([{ ...snapshot(enrollment, 2), state: "authenticationRequired" }]),
  );
  expect(() => requireCurrentEnrollment(target, unavailable)).toThrow("cannot use another account");
  expect(() =>
    requireCurrentEnrollment(target, accountCatalog(mini, directory([snapshot("default-codex", 0)]))),
  ).toThrow("no longer present");
  expect(() =>
    requireCurrentEnrollment(target, accountCatalog(book, directory([snapshot(enrollment, 2)]))),
  ).toThrow("another physical host");
});

test("catalogs reject duplicate canonical enrollment identities and unknown readiness is unusable", () => {
  expect(() =>
    accountCatalog(mini, directory([snapshot(enrollment, 1), snapshot(enrollment.toUpperCase(), 1)])),
  ).toThrow("Duplicate");
  const future = accountCatalog(mini, directory([{ ...snapshot(enrollment, 1), state: "future-state" }]));
  expect(future.choices[0]?.state).toBe("unknown");
  expect(future.choices[0]?.usable).toBe(false);
});
