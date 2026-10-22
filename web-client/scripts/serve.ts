import { parseArgs } from "node:util";

const { values } = parseArgs({
  options: {
    port: { type: "string" },
    origin: { type: "string" },
    bind: { type: "string" },
    config: { type: "string" },
    "static-dir": { type: "string" },
    "access-key-file": { type: "string" },
    "tailnet-http": { type: "boolean" },
    fixtures: { type: "boolean" },
  },
  strict: true,
});
for (const [argument, environment] of Object.entries({
  port: "RC_WEB_PORT",
  origin: "RC_WEB_ORIGIN",
  bind: "RC_WEB_BIND",
  config: "RC_WEB_CONFIG",
  "static-dir": "RC_WEB_STATIC_DIR",
  "access-key-file": "RC_WEB_ACCESS_KEY_FILE",
})) {
  const value = values[argument as keyof typeof values];
  if (typeof value === "string") process.env[environment] = value;
}
if (values["tailnet-http"]) process.env.RC_WEB_ALLOW_TAILNET_HTTP = "1";
if (values.fixtures) process.env.RC_WEB_FIXTURE = "1";
await import("../server/index");
