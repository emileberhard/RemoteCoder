import { identifier, object, string } from "../../protocol/boundary";
import { AutomationsPanel } from "../automations/automations-panel";
import { ReadStatus, useRead } from "../remote-operations";
import { useSnapshot, useWorkspace } from "../workspace-context";

export function automationHostInfo(value: unknown) {
  const info = object(value);
  const homeDirectory = string(info.homeDirectory);
  if (!homeDirectory.startsWith("/") || homeDirectory.length > 4096 || /\p{Cc}/u.test(homeDirectory))
    throw new Error("The gateway reported an invalid home directory");
  return {
    hostname: identifier(info.hostname),
    authority: info.automationsAuthority == null ? undefined : identifier(info.automationsAuthority),
    homeDirectory,
  };
}
export function automationOwner<T extends { info: ReturnType<typeof automationHostInfo> }>(hosts: T[]) {
  const authorities = new Set(hosts.map(({ info }) => info.authority).filter(Boolean));
  const owners = hosts.filter(({ info }) => info.authority === info.hostname);
  if (authorities.size > 1 || owners.length > 1)
    throw new Error("The configured gateways disagree about the automations owner");
  return owners[0];
}
export function AutomationsSettings() {
  const workspace = useWorkspace();
  const { hosts } = useSnapshot();
  const owner = useRead(
    `automations-owner:${hosts.map((state) => `${state.host.id}:${state.status}`).join(",")}`,
    async (signal) => {
      if (hosts.length > 32) throw new Error("Too many gateways for automations discovery");
      return automationOwner(
        await Promise.all(
          hosts.map(async (host) => {
            const transport = workspace.featureTransport(host.target);
            const info = automationHostInfo(
              await transport.request("host/info", {}, { signal, timeout: 15000 }),
            );
            return { transport, info };
          }),
        ),
      );
    },
  );
  if (owner.loading || owner.error) return <ReadStatus {...owner} />;
  if (!owner.value)
    return (
      <p className="subtle">
        Automations are unavailable. Configure an automations owner on a connected gateway.
      </p>
    );
  return <AutomationsPanel transport={owner.value.transport} defaults={owner.value.info} />;
}
