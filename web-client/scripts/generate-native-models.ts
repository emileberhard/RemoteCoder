import { join } from "node:path";

const path = join(import.meta.dir, "../../Core/Sources/RemoteCoderCore/Models/ModelOptions.swift");
const source = (await Bun.file(path).text()).split("enum ClaudeModelCatalog {")[1];
if (!source) throw new Error("ClaudeModelCatalog was not found");
const identifiers = new Map(
  [...source.matchAll(/static let (\w+)ModelID = "([^"]+)"/g)].map((match) => [match[1], match[2]]),
);
const defaultKey = source.match(/static let defaultModel = model\(id: (\w+)ModelID/)?.[1];
const listed = source.split("static let models: [ModelOption] = [")[1]?.split("]")[0] ?? "";
const declarations = new Map(
  [
    ...source.matchAll(/model\(id: (\w+)ModelID, displayName: "([^"]+)", supportsFastMode: (true|false)\)/g),
  ].map((match) => [match[1] ?? "", { name: match[2], fast: match[3] === "true" }]),
);
const models = [...listed.matchAll(/(\w+)ModelID|defaultModel/g)].map((match) => {
  const key = match[1] ?? defaultKey ?? "";
  const declaration = declarations.get(key);
  return {
    id: identifiers.get(key),
    name: declaration?.name,
    provider: "claude",
    efforts: ["low", "medium", "high", "xhigh", "max"],
    defaultEffort: "high",
    fast: declaration?.fast,
    images: true,
  };
});
if (models.length !== 4 || models.some((model) => !model.id || !model.name || model.fast === undefined))
  throw new Error("Claude catalog shape changed; inspect its owning source before regeneration");
await Bun.write(
  join(import.meta.dir, "../src/protocol/claude-models.json"),
  `${JSON.stringify(models, null, 2)}\n`,
);
const defaultsSource = await Bun.file(
  join(import.meta.dir, "../../Core/Sources/RemoteCoderCore/Models/NewChatDefaults.swift"),
).text();
const initialCodexModelID = defaultsSource.match(/static let initialCodexModelID = "([^"]+)"/)?.[1];
if (!initialCodexModelID) throw new Error("NewChatDefaults.initialCodexModelID was not found");
await Bun.write(
  join(import.meta.dir, "../src/protocol/native-model-defaults.json"),
  `${JSON.stringify({ initialCodexModelID }, null, 2)}\n`,
);
