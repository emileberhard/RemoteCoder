import { afterEach, expect, test } from "bun:test";
import { cleanupWorkspaces, header, setup } from "./fixtures/workspace";

afterEach(cleanupWorkspaces);

test("forking a reply uses its exact completed turn and opens the returned conversation", async () => {
  const { workspace, harness } = await setup();
  await workspace.selectConversation({ hostId: "mini", threadId: "shared" });
  harness.handler = (method) =>
    method === "thread/turns/list"
      ? { data: [{ id: "old", status: "completed" }], nextCursor: null }
      : method === "thread/fork"
        ? { thread: header("forked") }
        : undefined;
  await workspace.forkFrom({ hostId: "mini", threadId: "shared" }, "old");
  expect(harness.calls.find((call) => call.method === "thread/fork")?.params).toEqual({
    threadId: "shared",
    lastTurnId: "old",
  });
  expect(workspace.selectedConversation?.address).toMatchObject({ hostId: "mini", threadId: "forked" });
});

test("failed, active and unavailable turn cutoffs do not create a fork", async () => {
  for (const status of ["failed", "inProgress", "interrupted", "unknown"]) {
    const { workspace, harness } = await setup();
    await workspace.selectConversation({ hostId: "mini", threadId: "shared" });
    harness.handler = (method) =>
      method === "thread/turns/list" ? { data: [{ id: "old", status }], nextCursor: null } : undefined;
    await expect(workspace.forkFrom({ hostId: "mini", threadId: "shared" }, "old")).rejects.toThrow(
      "Only a completed turn",
    );
    expect(harness.calls.some((call) => call.method === "thread/fork")).toBe(false);
  }
});
