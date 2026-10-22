export function foldSearchText(value: string): string {
  return value
    .normalize("NFD")
    .replace(/(?=\p{M})\p{Diacritic}/gu, "")
    .replace(/[^ı]+/gu, (part) => part.toUpperCase().toLowerCase())
    .replace(/ß/gu, "ss")
    .replace(/ς/gu, "σ");
}
