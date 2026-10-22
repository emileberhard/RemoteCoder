import { createContext, useSyncExternalStore } from "react";

export const DiagramThemeContext = createContext(false);
export const darkAppearance = matchMedia("(prefers-color-scheme: dark)");
export const subscribeAppearance = (change: () => void) => {
  darkAppearance.addEventListener("change", change);
  return () => darkAppearance.removeEventListener("change", change);
};
export const useDarkAppearance = () =>
  useSyncExternalStore(subscribeAppearance, () => darkAppearance.matches);
export function visualTheme(dark: boolean) {
  const root = getComputedStyle(document.documentElement);
  const value = (name: string) => root.getPropertyValue(name).trim();
  return {
    "--rc-font-family": root.fontFamily,
    "--rc-font-size": root.fontSize,
    "--rc-text": value("--foreground"),
    "--rc-secondary-text": value("--muted"),
    "--rc-background": value("--bg"),
    "--rc-surface": value("--surface-solid"),
    "--rc-accent": value("--accent"),
    "--rc-color-scheme": dark ? "dark" : "light",
  };
}
