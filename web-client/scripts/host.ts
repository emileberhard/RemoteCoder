import { join } from "node:path";
import { parseArgs } from "node:util";
import { HostRegistry, readCredential } from "../server/config";

const { values } = parseArgs({
  options: {
    id: { type: "string" },
    name: { type: "string" },
    url: { type: "string" },
    "token-file": { type: "string" },
    cwd: { type: "string" },
    remove: { type: "boolean" },
  },
  strict: true,
});
if (!values.id)
  throw new Error(
    "Use --id <stable-id> --name <name> --url <gateway-origin> --token-file <private-file> --cwd <directory>",
  );
const registry = new HostRegistry(process.env.RC_WEB_CONFIG ?? join(import.meta.dir, "../hosts.local.json"));
await registry.load();
if (values.remove) await registry.remove(values.id);
else {
  if (!values["token-file"])
    throw new Error("--token-file must reference the gateway's existing private credential file");
  await readCredential(values["token-file"]);
  await registry.save({
    id: values.id,
    name: values.name,
    url: values.url,
    tokenFile: values["token-file"],
    cwd: values.cwd ?? "",
  });
}
console.log(`Host ${values.id} ${values.remove ? "removed" : "registered"}. Refresh Hosts in the browser.`);
