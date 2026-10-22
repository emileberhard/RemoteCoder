import { afterEach, expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostRegistry, validateHost } from "../server/config";

const paths: string[] = [];
afterEach(async () => {
  for (const path of paths.splice(0)) await rm(path, { recursive: true, force: true });
});
const host = (id: string) => ({
  id,
  name: id,
  url: "https://example.com",
  tokenFile: "/private/token",
  cwd: "/workspace",
});
test("host configuration rejects URL credentials and insecure remote origins", () => {
  expect(() => validateHost({ ...host("one"), url: "https://user:secret@example.com" })).toThrow(
    "without credentials",
  );
  expect(() => validateHost({ ...host("one"), url: "http://example.com" })).toThrow("HTTPS");
});
test("concurrent registry owners preserve independently added host bindings", async () => {
  const directory = await mkdtemp(join(tmpdir(), "rc-web-hosts-"));
  paths.push(directory);
  const path = join(directory, "hosts.json");
  const first = new HostRegistry(path);
  const second = new HostRegistry(path);
  await Promise.all([first.save(host("one")), second.save(host("two"))]);
  await first.load();
  expect(
    first
      .list()
      .map((host) => host.id)
      .sort(),
  ).toEqual(["one", "two"]);
});
test("browser metadata edits retain a newer CLI-owned gateway and credential binding", async () => {
  const directory = await mkdtemp(join(tmpdir(), "rc-web-hosts-"));
  paths.push(directory);
  const path = join(directory, "hosts.json");
  const browser = new HostRegistry(path);
  const cli = new HostRegistry(path);
  await cli.save(host("one"));
  await browser.load();
  await cli.save({ ...host("one"), url: "https://new.example.com", tokenFile: "/private/new-token" });
  await browser.updateMetadata("one", "Renamed", "/new-workspace");
  await cli.load();
  expect(cli.get("one")).toEqual({
    ...host("one"),
    name: "Renamed",
    cwd: "/new-workspace",
    url: "https://new.example.com",
    tokenFile: "/private/new-token",
  });
  expect(browser.list()[0]).not.toHaveProperty("tokenFile");
  expect(browser.list()[0]?.credentialStatus).toBe("notChecked");
});
