import { expect, test } from "bun:test";
import { newAutomation } from "../src/ui/automations/automations-panel";
import { automationHostInfo, automationOwner } from "../src/ui/settings/automations-settings";

test("new automation uses the discovered authority's physical hostname and home", () => {
  const secondary = {
    info: automationHostInfo({
      hostname: "gateway-secondary",
      automationsAuthority: "gateway-primary",
      homeDirectory: "/home/secondary",
    }),
  };
  const primary = {
    info: automationHostInfo({
      hostname: "gateway-primary",
      automationsAuthority: "gateway-primary",
      homeDirectory: "/home/operator",
    }),
  };
  const owner = automationOwner([secondary, primary]);
  expect(owner).toBe(primary);
  expect(newAutomation(owner!.info)).toMatchObject({
    cwd: "/home/operator",
    run: { agent: { gateway_host: "gateway-primary" } },
  });
});

test("missing owner is unavailable and ambiguous or inconsistent owners fail", () => {
  const none = {
    info: automationHostInfo({
      hostname: "gateway-secondary",
      automationsAuthority: null,
      homeDirectory: "/home/secondary",
    }),
  };
  const owner = {
    info: automationHostInfo({
      hostname: "gateway-primary",
      automationsAuthority: "gateway-primary",
      homeDirectory: "/home/operator",
    }),
  };
  expect(automationOwner([none])).toBeUndefined();
  expect(
    automationOwner([{ ...none, info: { ...none.info, authority: "gateway-primary" } }]),
  ).toBeUndefined();
  expect(() => automationOwner([owner, owner])).toThrow("disagree");
  expect(() => automationOwner([owner, { info: { ...none.info, authority: "gateway-other" } }])).toThrow(
    "disagree",
  );
  expect(() => automationHostInfo({ hostname: "gateway", homeDirectory: "relative" })).toThrow(
    "home directory",
  );
});
