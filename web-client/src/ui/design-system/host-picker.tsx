import { useId } from "react";
import type { HostState } from "../../workspace/host-services";

export function HostPicker({
  hosts,
  value,
  choose,
}: {
  hosts: HostState[];
  value: string | undefined;
  choose(id: string): void;
}) {
  const name = useId();
  return (
    <fieldset className="host-picker">
      <legend className="visually-hidden">Host</legend>
      {hosts.map((state) => (
        <label key={state.host.id}>
          <input
            type="radio"
            name={name}
            checked={state.host.id === value}
            onChange={() => choose(state.host.id)}
          />
          <span className={`status-dot ${state.status}`} />
          {state.host.name}
        </label>
      ))}
    </fieldset>
  );
}
