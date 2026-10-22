import { AccountsOverview } from "../accounts/accounts-overview";
import { ExecutionPicker } from "../accounts/execution-picker";

export function AccountsSettings() {
  return (
    <>
      <ExecutionPicker />
      <AccountsOverview />
    </>
  );
}
