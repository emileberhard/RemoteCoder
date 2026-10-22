import type { ThemeID } from "../../preferences";

export const themes: { id: ThemeID; name: string; color: string }[] = [
  { id: "paperLight", name: "Paper", color: "#2e333d" },
  { id: "night", name: "Neutral", color: "#ebedf2" },
  { id: "midnightOcean", name: "Midnight Ocean", color: "#33cce6" },
  { id: "forestDusk", name: "Forest Dusk", color: "#4de68c" },
  { id: "orchidNight", name: "Orchid Night", color: "#f259c7" },
  { id: "caribbeanSunset", name: "Caribbean Sunset", color: "#db592e" },
];
