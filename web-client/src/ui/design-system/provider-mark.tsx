import { useId } from "react";
import { providerMarks } from "./provider-marks";

export function ProviderMark({ provider }: { provider: "claude" | "codex" }) {
  const gradient = useId();
  return (
    <svg
      className={`provider-mark ${provider}`}
      viewBox="0 0 24 24"
      role="img"
      aria-label={provider === "claude" ? "Claude conversation" : "Codex conversation"}
    >
      {provider === "codex" && (
        <defs>
          <linearGradient id={gradient} x1="0" y1="0" x2="1" y2="1">
            <stop offset="0" stopColor="#f4f6ff" />
            <stop offset="0.5" stopColor="#c4d3ff" />
            <stop offset="1" stopColor="#7a9dff" />
          </linearGradient>
        </defs>
      )}
      <path
        fillRule="evenodd"
        fill={provider === "codex" ? `url(#${gradient})` : "#d97757"}
        d={providerMarks[provider]}
      />
    </svg>
  );
}
