import { afterEach, expect, test } from "bun:test";
import { cleanupWorkspaces, deferred, header, setup } from "./fixtures/workspace";

afterEach(cleanupWorkspaces);
const parent = { hostId: "mini", threadId: "shared" };
const child = { hostId: "mini", threadId: "child" };

test("agent navigation returns to the exact parent and ordinary selection clears it", async () => {
  const { workspace, harness } = await setup();
  harness.handler = (method, params) =>
    method === "thread/read" ? { thread: header(String(params.threadId)) } : undefined;
  await workspace.selectConversation(parent);
  await workspace.openAgentConversation(child, parent);
  expect(workspace.getSnapshot().agentNavigation).toEqual({ parent, child });
  expect(workspace.getSnapshot().selected).toEqual(child);
  await workspace.returnToAgentParent();
  expect(workspace.getSnapshot().selected).toEqual(parent);
  expect(workspace.getSnapshot().agentNavigation).toBeUndefined();
  await workspace.openAgentConversation(child, parent);
  await workspace.selectConversation(child);
  expect(workspace.getSnapshot().agentNavigation).toBeUndefined();
  await workspace.returnToAgentParent();
  expect(workspace.getSnapshot().selected).toEqual(child);
  await workspace.openAgentConversation(child, parent);
  workspace.newConversation();
  expect(workspace.getSnapshot().agentNavigation).toBeUndefined();
});

test("a failed nested agent open preserves the established parent route until a successful replacement", async () => {
  const { workspace, harness } = await setup();
  const nested = { hostId: "mini", threadId: "nested" };
  harness.handler = (method, params) =>
    method === "thread/read" ? { thread: header(String(params.threadId)) } : undefined;
  await workspace.selectConversation(parent);
  await workspace.openAgentConversation(child, parent);
  const read = deferred<unknown>();
  const requested = deferred<void>();
  harness.handler = (method) => {
    if (method === "thread/read") {
      requested.resolve();
      return read.promise;
    }
    return undefined;
  };
  const opening = workspace.openAgentConversation(nested, child);
  await requested.promise;
  expect(workspace.getSnapshot().agentNavigation).toEqual({ parent, child });
  read.resolve({ thread: header("wrong-identity") });
  await expect(opening).rejects.toThrow("identity changed");
  expect(workspace.getSnapshot().agentNavigation).toEqual({ parent, child });
  await workspace.returnToAgentParent();
  expect(workspace.getSnapshot().selected).toEqual(parent);
  harness.handler = (method, params) =>
    method === "thread/read" ? { thread: header(String(params.threadId)) } : undefined;
  await workspace.openAgentConversation(child, parent);
  await workspace.openAgentConversation(nested, child);
  expect(workspace.getSnapshot().agentNavigation).toEqual({ parent: child, child: nested });
});

test("a failed or superseded agent open leaves the current selection alone", async () => {
  const { workspace, harness } = await setup();
  await workspace.selectConversation(parent);
  harness.handler = (method) => {
    if (method === "thread/read") throw new Error("Child unavailable");
    return undefined;
  };
  await expect(workspace.openAgentConversation(child, parent)).rejects.toThrow("Child unavailable");
  expect(workspace.getSnapshot().selected).toEqual(parent);
  const read = deferred<unknown>();
  const requested = deferred<void>();
  harness.handler = (method) => {
    if (method === "thread/read") {
      requested.resolve();
      return read.promise;
    }
    return undefined;
  };
  const opening = workspace.openAgentConversation(child, parent);
  await requested.promise;
  expect(workspace.getSnapshot().selected).toEqual(parent);
  workspace.newConversation();
  read.resolve({ thread: header(child.threadId) });
  await opening;
  expect(workspace.getSnapshot().selected).toBeUndefined();
  expect(workspace.getSnapshot().agentNavigation).toBeUndefined();
});

test("a pending return cannot supersede a later host selection", async () => {
  const { workspace, harness } = await setup(["mini", "book"]);
  harness.handler = (method, params) =>
    method === "thread/read" ? { thread: header(String(params.threadId)) } : undefined;
  await workspace.selectConversation(parent);
  await workspace.openAgentConversation(child, parent);
  const subscription = deferred<unknown>();
  const requested = deferred<void>();
  harness.handler = (method, params) => {
    if (method === "thread/subscribe" && params.threadId === parent.threadId) {
      requested.resolve();
      return subscription.promise;
    }
    return undefined;
  };
  const returning = workspace.returnToAgentParent();
  await requested.promise;
  workspace.selectHost("book");
  subscription.resolve({
    status: "subscribed",
    subscriptionId: "s",
    thread: header(),
    checkpoint: { itemsBackwardsCursor: null, liveItems: [] },
  });
  await returning;
  expect(workspace.selectedHost?.host.id).toBe("book");
  expect(workspace.getSnapshot().selected).toBeUndefined();
  expect(workspace.getSnapshot().agentNavigation).toBeUndefined();
});

test("agent navigation rechecks the selection at the load-to-commit handoff", async () => {
  const { workspace, harness } = await setup();
  harness.handler = (method, params) =>
    method === "thread/read" ? { thread: header(String(params.threadId)) } : undefined;
  await workspace.selectConversation(parent);
  await workspace.loadConversation(child);
  const load = workspace.loadConversation.bind(workspace);
  workspace.loadConversation = (address) =>
    load(address).then(() => {
      queueMicrotask(() => queueMicrotask(() => workspace.newConversation()));
    });
  await workspace.openAgentConversation(child, parent);
  expect(workspace.getSnapshot().selected).toBeUndefined();
  expect(workspace.getSnapshot().agentNavigation).toBeUndefined();
});

test("a newer nested open supersedes a parent return at the load-to-commit handoff", async () => {
  const { workspace, harness } = await setup();
  const nested = { hostId: "mini", threadId: "nested" };
  harness.handler = (method, params) =>
    method === "thread/read" ? { thread: header(String(params.threadId)) } : undefined;
  await workspace.selectConversation(parent);
  await workspace.openAgentConversation(child, parent);
  const read = deferred<unknown>();
  const requested = deferred<void>();
  harness.handler = (method, params) => {
    if (method === "thread/read" && params.threadId === nested.threadId) {
      requested.resolve();
      return read.promise;
    }
    return undefined;
  };
  const load = workspace.loadConversation.bind(workspace);
  let opening: Promise<void> | undefined;
  workspace.loadConversation = (address) =>
    load(address).then(() => {
      if (address.threadId === parent.threadId)
        queueMicrotask(() =>
          queueMicrotask(() => {
            opening = workspace.openAgentConversation(nested, child);
          }),
        );
    });
  await workspace.returnToAgentParent();
  await requested.promise;
  expect(workspace.getSnapshot().selected).toEqual(child);
  expect(workspace.getSnapshot().agentNavigation).toEqual({ parent, child });
  read.resolve({ thread: header(nested.threadId) });
  await opening;
  expect(workspace.getSnapshot().selected).toEqual(nested);
  expect(workspace.getSnapshot().agentNavigation).toEqual({ parent: child, child: nested });
});
