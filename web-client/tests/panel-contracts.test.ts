import { describe, expect, test } from "bun:test";
import { RpcError } from "../src/gateway";
import { parseAgents } from "../src/ui/agents/agents-panel";
import { parseAutomationDetail, setDefinitionField } from "../src/ui/automations/automations-panel";
import { acknowledgementUnknown, automationResult, ServiceRejection } from "../src/ui/remote-operations";

const agent = {
  id: "child",
  title: "Worker",
  provider: "future-provider",
  ownerThreadId: "parent",
  source: "launcher",
  state: "future-state",
  capabilities: {
    inspect: true,
    openConversation: false,
    message: false,
    continueWork: false,
    stop: false,
    askParent: true,
  },
};
describe("panel contract boundaries", () => {
  test("definition edits retain unknown settings, explicit nulls, and untouched branches", () => {
    const prior = {
      id: "daily",
      future: null,
      run: { agent: { provider: "codex", account: "enrolled", future: { access: "custom" } } },
      when: [{ every: "1h" }, { event: "message" }],
    };
    const changed = setDefinitionField(prior, ["run", "agent", "provider"], "claude");
    const result = setDefinitionField(changed, ["run", "agent", "account"], undefined);
    expect(result).toEqual({
      ...prior,
      run: { agent: { provider: "claude", future: { access: "custom" } } },
    });
    expect(prior.run.agent.provider).toBe("codex");
    expect(result.when).toBe(prior.when);
  });
  test("unknown agents retain their provider and have unknown state", () => {
    expect(parseAgents({ revision: "one", warnings: [], agents: [agent] }).agents[0]?.state).toBe("unknown");
    expect(parseAgents({ revision: "one", warnings: [], agents: [agent] }).agents[0]?.provider).toBe(
      "future-provider",
    );
    expect(() => parseAgents({ revision: "one", warnings: [], agents: [agent, agent] })).toThrow("duplicate");
  });
  test("malformed acknowledgements remain uncertain while service rejection is definitive", () => {
    expect(automationResult({ ok: true, data: null })).toBeNull();
    expect(() => automationResult({ ok: true })).toThrow("missing its result");
    expect(acknowledgementUnknown(new Error("Socket closed"), "automations/set")).toBe(true);
    expect(acknowledgementUnknown(new ServiceRejection("Revision conflict"), "automations/set")).toBe(false);
    expect(
      acknowledgementUnknown(
        new RpcError("Response lost", -32603, { kind: "automationAcknowledgementUnknown" }),
        "automations/run",
      ),
    ).toBe(true);
    expect(
      acknowledgementUnknown(
        new RpcError("Unavailable", -32003, { kind: "automationUnavailable" }),
        "automations/run",
      ),
    ).toBe(false);
    expect(
      acknowledgementUnknown(
        new RpcError("Agent execution changed; refresh before acting", -32603),
        "conversation/agents/action",
      ),
    ).toBe(false);
  });
  test("automation details cannot replace the selected definition identity", () => {
    expect(() =>
      parseAutomationDetail({
        ok: true,
        data: { id: "selected", revision: 1, definition: { id: "another" } },
      }),
    ).toThrow("identity");
  });
});
