import { expect, test } from "bun:test";
import { verifiedVisual, visualDocument, visualHeaders } from "../server/visuals";

const sha256 = (text: string) => new Bun.CryptoHasher("sha256").update(text).digest("hex");

test("visual documents run sandboxed without the bridge origin", () => {
  const policy = visualHeaders["Content-Security-Policy"];
  expect(policy).toStartWith("sandbox allow-scripts ");
  expect(policy).not.toContain("allow-same-origin");
  expect(policy).toContain("frame-ancestors 'self'");
});

test("the prelude leads every visual so the visual's own markup cannot hide it", () => {
  const html = "<!-- template: <head> --><section>Chart</section>";
  const document = visualDocument(html);
  expect(document).toStartWith("<!doctype html><style>:root{color-scheme");
  expect(document).toEndWith(`</script>${html}`);
});

test("a visual is served only when its bytes match the reference", async () => {
  const html = "<p>Chart</p>";
  expect(await verifiedVisual(new Response(html), sha256(html))).toBe(html);
  await expect(verifiedVisual(new Response(html), sha256("<p>Other</p>"))).rejects.toThrow("reference");
  const oversized = "x".repeat(2 * 1024 * 1024 + 1);
  await expect(verifiedVisual(new Response(oversized), sha256(oversized))).rejects.toThrow("2 MiB");
});
