import { cp, mkdir, rm } from "node:fs/promises";
import { join } from "node:path";

const root = join(import.meta.dir, "..");
const build = process.env.RC_WEB_REVISION || crypto.randomUUID();
await rm(join(root, "dist"), { recursive: true, force: true });
await mkdir(join(root, "dist"), { recursive: true });
const result = await Bun.build({
  entrypoints: [
    join(root, "src/main.tsx"),
    join(root, "src/markdown.worker.ts"),
    join(root, "src/platform/diagrams.ts"),
  ],
  outdir: join(root, "dist"),
  target: "browser",
  minify: true,
  sourcemap: "external",
  splitting: true,
  modulePreload: false,
  naming: "[name].[ext]",
  define: { "process.env.NODE_ENV": '"production"', RC_WEB_BUILD: JSON.stringify(build) },
});
if (!result.success) {
  for (const log of result.logs) console.error(log);
  process.exit(1);
}
await Bun.write(join(root, "dist/build-id.txt"), `${build}\n`);
await Bun.write(join(root, "dist/index.html"), await Bun.file(join(root, "index.html")).text());
for (const name of ["icon.svg", "manifest.webmanifest"])
  await Bun.write(join(root, "dist", name), Bun.file(join(root, name)));
console.log(
  result.outputs
    .filter((output) => !output.path.includes("chunk-") && !output.path.endsWith(".map"))
    .map((output) => `${output.path.split("/").at(-1)} ${(output.size / 1024).toFixed(1)} KiB`)
    .join("\n"),
);
const chunks = result.outputs.filter(
  (output) => output.path.includes("chunk-") && !output.path.endsWith(".map"),
);
console.log(
  `${chunks.length} split chunks ${(chunks.reduce((size, output) => size + output.size, 0) / 1024).toFixed(1)} KiB`,
);

await cp(join(root, "../THIRD_PARTY_NOTICES.md"), join(root, "dist/THIRD_PARTY_NOTICES.md"));
await cp(join(root, "../LICENSES"), join(root, "dist/LICENSES"), { recursive: true });
