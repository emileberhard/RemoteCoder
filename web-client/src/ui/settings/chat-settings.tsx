import { Check } from "lucide-react";
import { ProviderMark } from "../design-system/provider-mark";
import { useRun, useSnapshot, useWorkspace } from "../workspace-context";
import { themes } from "./themes";

export function ChatSettings() {
  const workspace = useWorkspace();
  const run = useRun();
  const { hosts, selectedHostId } = useSnapshot();
  const preferences = hosts.find((state) => state.host.id === selectedHostId)?.preferences;
  const theme = workspace.selectedThemeID;
  const models = workspace.modelVisibilityChoices();
  return (
    <>
      {preferences?.status === "failed" && (
        <p className="error sync-error">Settings sync failed: {preferences.error ?? "unknown error"}</p>
      )}
      <section className="settings-section">
        <h3>Appearance</h3>
        <div className="theme-grid">
          {themes.map((option) => (
            <button
              type="button"
              key={option.id}
              className={theme === option.id ? "selected" : ""}
              onClick={() =>
                run(async () => workspace.setPreference("appearance.selectedThemeID", option.id))
              }
            >
              <span style={{ backgroundColor: option.color }} />
              {option.name}
              {theme === option.id && <Check size={14} />}
            </button>
          ))}
        </div>
      </section>
      {(["codex", "claude"] as const).map((provider) => {
        const choices = models.filter((choice) => choice.provider === provider);
        if (!choices.length) return null;
        return (
          <section className="settings-section" key={provider}>
            <h3>{provider === "claude" ? "Claude models" : "Codex models"}</h3>
            <div className="model-toggles">
              {choices.map((choice) => (
                <label key={choice.id}>
                  <ProviderMark provider={provider} />
                  <span>{choice.name}</span>
                  <input
                    type="checkbox"
                    role="switch"
                    className="switch"
                    checked={choice.visible}
                    aria-checked={choice.visible}
                    onChange={(event) =>
                      run(async () => workspace.setModelVisible(provider, choice.id, event.target.checked))
                    }
                  />
                </label>
              ))}
            </div>
          </section>
        );
      })}
    </>
  );
}
