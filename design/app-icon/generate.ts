import { execFile } from "node:child_process";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const SIZE = 1024;

type Point = readonly [x: number, y: number];
type Stop = readonly [offset: number, color: string];

type Background =
  | { readonly kind: "solid"; readonly color: string }
  | { readonly kind: "linear"; readonly from: Point; readonly to: Point; readonly stops: readonly Stop[] };

interface Layer {
  readonly name: string;
  readonly markup: string;
  readonly group?: number;
  readonly blend?: "screen" | "plus-lighter" | "multiply";
  readonly glass?: boolean;
  readonly fill?: Background;
}

interface GroupStyle {
  readonly translucency?: number;
  readonly shadow?: number;
}

interface Variant {
  readonly id: string;
  readonly title: string;
  readonly idea: string;
  readonly background: Background;
  readonly layers: readonly Layer[];
  readonly groups?: readonly GroupStyle[];
}

const palette = {
  falu: "#B3282D",
  faluDeep: "#7E171B",
  snow: "#F6F8FB",
  frost: "#D8E0EA",
  amber: "#FFC34D",
  ember: "#FF9F1C",
  nose: "#F2A88E",
  ink: "#22304F",
} as const;

const HAT_BODY =
  "M0 112 C10 80 28 34 54 6 C72 -4 96 12 104 50 C100 38 88 30 77 34 C86 58 95 86 100 112 Q50 124 0 112 Z";
const HAT_CUFF = "M2.5 98 Q50 111 97.5 98 L100 112 Q50 124 0 112 Z";
const HAT_ANCHOR: Point = [50, 116];
const HAT_TIP: Point = [104, 50];
const HAT_OUTLINE: readonly Point[] = [
  [0, 112], [54, 6], [104, 50], [77, 34], [100, 112], [50, 118],
];

interface HatPlacement {
  readonly at: Point;
  readonly scale: number;
  readonly rotate?: number;
}

const hatTransform = ({ at, scale, rotate = 0 }: HatPlacement) =>
  `translate(${at[0]} ${at[1]}) rotate(${rotate}) scale(${scale}) translate(${-HAT_ANCHOR[0]} ${-HAT_ANCHOR[1]})`;

const hatPoint = ({ at, scale, rotate = 0 }: HatPlacement, [x, y]: Point): Point => {
  const radians = (rotate * Math.PI) / 180;
  const dx = (x - HAT_ANCHOR[0]) * scale;
  const dy = (y - HAT_ANCHOR[1]) * scale;
  return [at[0] + dx * Math.cos(radians) - dy * Math.sin(radians), at[1] + dx * Math.sin(radians) + dy * Math.cos(radians)];
};

const hat = (placement: HatPlacement, fill: string, cuff?: string) => {
  const rounding = 12 / placement.scale;
  const body = `<path d="${HAT_BODY}" fill="${fill}" stroke="${fill}" stroke-width="${rounding}" stroke-linejoin="round"/>`;
  const band = cuff
    ? `<path d="${HAT_CUFF}" fill="${cuff}" stroke="${cuff}" stroke-width="${rounding}" stroke-linejoin="round"/>`
    : "";
  return `<g transform="${hatTransform(placement)}">${body}${band}</g>`;
};

const circle = ([cx, cy]: Point, r: number, fill: string, extra = "") =>
  `<circle cx="${round(cx)}" cy="${round(cy)}" r="${round(r)}" fill="${fill}"${extra}/>`;

const sparkle = ([cx, cy]: Point, r: number, fill: string) =>
  `<path d="M${cx} ${cy - r} Q${cx} ${cy} ${cx + r} ${cy} Q${cx} ${cy} ${cx} ${cy + r} Q${cx} ${cy} ${cx - r} ${cy} Q${cx} ${cy} ${cx} ${cy - r} Z" fill="${fill}" stroke="${fill}" stroke-width="${r * 0.12}" stroke-linejoin="round"/>`;

const round = (value: number) => Math.round(value * 10) / 10;

const pointsPath = (points: readonly Point[]) =>
  `M${points.map(([x, y]) => `${round(x)} ${round(y)}`).join(" L")} Z`;

const vertical = (top: string, bottom: string): Background => ({
  kind: "linear", from: [0, 0], to: [0, 1], stops: [[0, top], [1, bottom]],
});

const diagonal = (start: string, end: string): Background => ({
  kind: "linear", from: [0, 0], to: [1, 1], stops: [[0, start], [1, end]],
});

const klassisk = (): Variant => ({
  id: "a-klassisk",
  title: "A · Klassisk",
  idea: "The tomte himself: hat over the eyes, beard, nose. Instantly readable, a bit storybook.",
  background: vertical("#1F3467", "#0B142D"),
  layers: [
    { name: "beard", markup: `<path d="M300 572 C300 740 420 856 512 878 C604 856 724 740 724 572 Z" fill="${palette.snow}"/>` },
    { name: "hat", markup: hat({ at: [512, 612], scale: 4.3 }, palette.falu) },
    { name: "nose", markup: circle([512, 612], 58, palette.nose) },
  ],
});

const mossan = (): Variant => ({
  id: "b-mossan",
  title: "B · Mössan",
  idea: "Just the hat, as a logo mark. Strongest at small sizes; says nothing about agents.",
  background: vertical("#FFFFFF", "#DCE5EF"),
  layers: [{ name: "hat", markup: hat({ at: [496, 809], scale: 5.4 }, palette.falu, palette.faluDeep) }],
});

const prompt = (): Variant => ({
  id: "c-prompt",
  title: "C · Prompt",
  idea: "The tomte as a terminal prompt, in today's black and orange. Carries the old icon over.",
  background: { kind: "solid", color: "#000000" },
  layers: [
    { name: "hat", markup: hat({ at: [512, 640], scale: 3.8 }, palette.ember) },
    { name: "cursor", markup: `<rect x="372" y="744" width="280" height="58" rx="29" fill="${palette.ember}"/>` },
  ],
});

const stugan = (): Variant => {
  const stars: readonly (readonly [Point, number])[] = [
    [[206, 214], 13], [[318, 138], 8], [[812, 168], 11], [[892, 306], 7], [[712, 248], 6], [[132, 380], 6],
  ];
  return {
    id: "d-stugan",
    title: "D · Stugan",
    idea: "“Tomten är vaken”: a falu-red cottage, one window lit at night. Someone is working.",
    background: vertical("#141240", "#2D4392"),
    layers: [
      { name: "stars", markup: stars.map(([at, r]) => circle(at, r, palette.snow)).join("") },
      {
        name: "house",
        markup: [
          `<rect x="626" y="380" width="52" height="130" fill="${palette.falu}"/>`,
          `<rect x="616" y="366" width="72" height="26" rx="13" fill="${palette.snow}"/>`,
          `<rect x="330" y="530" width="364" height="290" fill="${palette.falu}"/>`,
          `<rect x="330" y="560" width="24" height="260" fill="${palette.snow}"/>`,
          `<rect x="670" y="560" width="24" height="260" fill="${palette.snow}"/>`,
        ].join(""),
      },
      {
        name: "roof",
        markup: `<path d="M512 344 L748 548 Q756 568 734 568 L290 568 Q268 568 276 548 Z" fill="${palette.snow}" stroke="${palette.snow}" stroke-width="16" stroke-linejoin="round"/>`,
      },
      {
        name: "window",
        markup: [
          `<rect x="446" y="620" width="132" height="132" rx="12" fill="${palette.amber}" stroke="${palette.snow}" stroke-width="16"/>`,
          `<path d="M512 620 V752 M446 686 H578" stroke="${palette.snow}" stroke-width="14"/>`,
        ].join(""),
      },
      { name: "snow", markup: `<path d="M0 786 C262 730 560 756 1024 712 L1024 1024 L0 1024 Z" fill="#EDF2F9"/>` },
    ],
  };
};

const pratbubbla = (): Variant => ({
  id: "e-pratbubbla",
  title: "E · Pratbubbla",
  idea: "A chat bubble wearing the hat. Says “a chat app” first, warm and friendly.",
  background: diagonal("#FFCB5C", "#FF7E3A"),
  layers: [
    {
      name: "bubble",
      markup: `<path d="M390 372 H634 A170 170 0 0 1 804 542 V586 A170 170 0 0 1 634 756 H440 L268 846 L270 706 A170 170 0 0 1 220 586 V542 A170 170 0 0 1 390 372 Z" fill="${palette.snow}" stroke="${palette.snow}" stroke-width="18" stroke-linejoin="round"/>`,
    },
    { name: "dots", markup: [392, 512, 632].map((x) => circle([x, 564], 34, palette.ink)).join("") },
    { name: "hat", markup: hat({ at: [690, 410], scale: 2.9, rotate: 14 }, palette.falu) },
  ],
});

const rost = (): Variant => {
  const heights = [150, 240, 200, 320, 250, 290, 180];
  const width = 42;
  const gap = 16;
  const left = SIZE / 2 - (heights.length * width + (heights.length - 1) * gap) / 2;
  const bars = heights
    .map((height, index) => `<rect x="${left + index * (width + gap)}" y="540" width="${width}" height="${height}" rx="${width / 2}" fill="${palette.snow}"/>`)
    .join("");
  return {
    id: "f-rost",
    title: "F · Röst",
    idea: "The beard is a voice waveform. Tomte plus talking to your agents.",
    background: vertical("#17594A", "#0A2B23"),
    layers: [
      { name: "beard", markup: bars },
      { name: "hat", markup: hat({ at: [512, 580], scale: 3.9 }, palette.falu) },
      { name: "nose", markup: circle([512, 584], 52, palette.nose) },
    ],
  };
};

const spar = (): Variant => {
  const route = `<path d="M150 1010 C170 740 330 640 540 676 C690 702 708 600 670 536" fill="none" stroke="${palette.snow}" stroke-width="34" stroke-linecap="round" stroke-dasharray="46 54"/>`;
  return {
    id: "g-spar",
    title: "G · Spår",
    idea: "A trail through the snow up to the hat: he went out, did the errand, came back.",
    background: vertical("#3E5F9C", "#9FBAE2"),
    layers: [
      { name: "trail", markup: route },
      { name: "hat", markup: hat({ at: [688, 470], scale: 3.0, rotate: -6 }, palette.falu) },
    ],
  };
};

const manskara = (): Variant => {
  const outer = { c: [470, 600] as Point, r: 296 };
  const inner = { c: [598, 520] as Point, r: 262 };
  const inside = ([x, y]: Point, { c, r }: { c: Point; r: number }) => Math.hypot(x - c[0], y - c[1]) < r;
  const onCircle = ({ c, r }: { c: Point; r: number }, a: number): Point => [c[0] + r * Math.cos(a), c[1] + r * Math.sin(a)];
  const samples = 720;
  const angles = Array.from({ length: samples }, (_, i) => (i / samples) * Math.PI * 2);
  const outerArc = angles.map((a) => onCircle(outer, a)).filter((p) => !inside(p, inner));
  const innerArc = angles.map((a) => onCircle(inner, a)).filter((p) => inside(p, outer));
  const fromGap = (arc: Point[]) => {
    const gaps = arc.map((p, i) => Math.hypot(p[0] - arc[(i + 1) % arc.length]![0], p[1] - arc[(i + 1) % arc.length]![1]));
    const jump = gaps.indexOf(Math.max(...gaps));
    return arc.slice(jump + 1).concat(arc.slice(0, jump + 1));
  };
  const outerOrdered = fromGap(outerArc);
  const innerOrdered = fromGap(innerArc).reverse();
  const crescent = pointsPath([...outerOrdered, ...innerOrdered]);
  const tips = [outerOrdered[0]!, outerOrdered[outerOrdered.length - 1]!].sort((a, b) => a[1] - b[1]);
  const top = tips[0]!;
  return {
    id: "h-manskara",
    title: "H · Månskära",
    idea: "The crescent moon wearing the hat: the night shift. Calm, a bit dreamy.",
    background: vertical("#1C1550", "#4F3494"),
    layers: [
      { name: "stars", markup: [[[764, 226], 12], [[856, 404], 8], [[690, 132], 7], [[862, 690], 9]].map(([at, r]) => circle(at as Point, r as number, palette.snow)).join("") },
      { name: "moon", markup: `<path d="${crescent}" fill="${palette.amber}"/>` },
      { name: "hat", markup: hat({ at: [top[0] + 4, top[1] + 34], scale: 2.3, rotate: -18 }, palette.falu) },
    ],
  };
};

const stjarnbild = (): Variant => {
  const placement: HatPlacement = { at: [500, 800], scale: 5.0 };
  const points = HAT_OUTLINE.map((p) => hatPoint(placement, p));
  const silhouette = `<g opacity="0.14">${hat(placement, palette.snow)}</g>`;
  const lines = `<path d="${pointsPath(points)}" fill="none" stroke="${palette.snow}" stroke-opacity="0.6" stroke-width="16" stroke-linejoin="round"/>`;
  const crown = points[1]!;
  const tip = points[2]!;
  const stars = points
    .filter((p) => p !== crown && p !== tip)
    .map((p, i) => circle(p, i % 2 === 0 ? 26 : 20, palette.snow))
    .join("");
  return {
    id: "i-stjarnbild",
    title: "I · Stjärnbild",
    idea: "The hat as a constellation. Space-flavoured and elegant; thin lines fade when small.",
    background: vertical("#06303C", "#02131A"),
    layers: [
      { name: "silhouette", markup: silhouette },
      { name: "lines", markup: lines },
      { name: "stars", markup: stars + sparkle(crown, 64, palette.snow) + sparkle(tip, 84, palette.amber) },
    ],
  };
};

const gnista = (): Variant => {
  const placement: HatPlacement = { at: [488, 812], scale: 4.8 };
  return {
    id: "j-gnista",
    title: "J · Gnista",
    idea: "A snow-white hat whose tip ends in a spark: the tomte as an AI helper.",
    background: vertical("#C2302F", "#7A1418"),
    layers: [
      { name: "hat", markup: hat(placement, palette.snow, palette.frost) },
      { name: "spark", markup: sparkle(hatPoint(placement, HAT_TIP), 104, palette.amber) },
    ],
  };
};

const fonstret = (): Variant => {
  const pane = (x: number, y: number, fill: string) => `<rect x="${x}" y="${y}" width="170" height="210" rx="14" fill="${fill}"/>`;
  return {
    id: "k-fonstret",
    title: "K · Fönstret",
    idea: "One window lit in a dark house: someone is awake and working. No character at all.",
    background: vertical("#14234D", "#0A1430"),
    layers: [
      {
        name: "frame",
        markup: `<rect x="292" y="252" width="440" height="520" rx="36" fill="#E9EEF7"/><rect x="252" y="772" width="520" height="44" rx="22" fill="#E9EEF7"/>`,
      },
      { name: "panes", markup: [pane(328, 288, "#24386F"), pane(526, 288, "#24386F"), pane(328, 526, "#24386F")].join("") },
      { name: "light", markup: pane(526, 526, palette.amber) },
    ],
  };
};

const taket = (): Variant => ({
  id: "l-taket",
  title: "L · Taket",
  idea: "A roof over a prompt: a home for your agents. Developer DNA, no folklore.",
  background: vertical("#11493A", "#0A2D24"),
  layers: [
    { name: "roof", markup: `<path d="M262 476 L512 266 L762 476" fill="none" stroke="#BFF0D6" stroke-width="66" stroke-linecap="round" stroke-linejoin="round"/>` },
    {
      name: "prompt",
      markup: `<path d="M360 566 L452 648 L360 730" fill="none" stroke="#BFF0D6" stroke-width="54" stroke-linecap="round" stroke-linejoin="round"/><rect x="502" y="704" width="170" height="54" rx="27" fill="#BFF0D6"/>`,
    },
  ],
});

const viska = (): Variant => ({
  id: "m-viska",
  title: "M · Viska",
  idea: "One shape: a chat bubble whose top is the tomte's pointed hood. Chat first, tomte second.",
  background: vertical("#F1ECFF", "#D7C9FF"),
  layers: [
    {
      name: "bubble",
      markup: `<path d="M270 860 L330 770 C282 740 262 692 262 640 L262 560 C262 470 330 330 470 222 C540 166 640 160 700 222 C730 252 746 288 750 326 C722 304 692 294 668 300 C722 382 764 470 764 560 L764 640 C764 730 690 800 600 800 L420 800 Z" fill="#5B3FD9" stroke="#5B3FD9" stroke-width="20" stroke-linejoin="round"/>`,
    },
    { name: "dots", markup: [420, 512, 604].map((x) => circle([x, 620], 30, palette.snow)).join("") },
  ],
});

const dorren = (): Variant => ({
  id: "n-dorren",
  title: "N · Dörren",
  idea: "A little door left ajar with warm light inside: the helper's home, open for you.",
  background: vertical("#4C6E3D", "#22371B"),
  layers: [
    { name: "spill", markup: `<path d="M372 800 L652 800 L780 1024 L244 1024 Z" fill="${palette.amber}" opacity="0.28"/>` },
    { name: "doorway", markup: `<path d="M372 800 V470 A140 140 0 0 1 652 470 V800 Z" fill="${palette.amber}"/>` },
    {
      name: "door",
      markup: `<path d="M652 800 L652 470 Q676 384 752 394 L752 852 Z" fill="#6B4226" stroke="#6B4226" stroke-width="14" stroke-linejoin="round"/>${circle([726, 640], 16, palette.amber)}`,
    },
  ],
});

const klotet = (): Variant => ({
  id: "o-klotet",
  title: "O · Klotet",
  idea: "A glowing AI orb wearing a tiny dark hat. Modern and playful, wink-level folklore.",
  background: vertical("#F6F8FC", "#E0E6F3"),
  layers: [
    {
      name: "orb",
      markup: `<defs><radialGradient id="orb" cx="0.36" cy="0.3" r="0.85"><stop offset="0" stop-color="#A6ECFF"/><stop offset="0.5" stop-color="#6E6BFF"/><stop offset="1" stop-color="#D86BFF"/></radialGradient></defs>${circle([512, 560], 300, "url(#orb)")}`,
    },
    { name: "hat", markup: hat({ at: [560, 322], scale: 1.8, rotate: 16 }, "#1F2436") },
  ],
});

const lillaT = (): Variant => ({
  id: "p-lilla-t",
  title: "P · Lilla t",
  idea: "A lowercase t whose top comes to a point, a quiet hat nod. A wordmark-grade logo.",
  background: diagonal("#3C66FF", "#1634C4"),
  layers: [
    {
      name: "t",
      markup: `<path d="M512 176 L572 292 L572 650 C572 700 596 716 640 716 L676 716 L676 822 L630 822 C520 822 452 772 452 662 L452 292 Z" fill="${palette.snow}" stroke="${palette.snow}" stroke-width="24" stroke-linejoin="round"/><rect x="346" y="392" width="332" height="104" rx="52" fill="${palette.snow}"/>`,
    },
  ],
});

const svarm = (): Variant => {
  const center: Point = [512, 540];
  const orbit = (degrees: number): Point => [center[0] + 300 * Math.cos((degrees * Math.PI) / 180), center[1] + 300 * Math.sin((degrees * Math.PI) / 180)];
  return {
    id: "q-svarm",
    title: "Q · Svärm",
    idea: "Your agents orbiting home base. The product in one picture: many workers, one place.",
    background: vertical("#0D4A58", "#06222A"),
    layers: [
      { name: "orbit", markup: `<circle cx="${center[0]}" cy="${center[1]}" r="300" fill="none" stroke="#7EE0D2" stroke-opacity="0.35" stroke-width="18"/>` },
      { name: "home", markup: `<path d="M512 388 L640 488 L640 670 L384 670 L384 488 Z" fill="${palette.snow}" stroke="${palette.snow}" stroke-width="36" stroke-linejoin="round"/><rect x="482" y="560" width="60" height="110" rx="10" fill="${palette.amber}"/>` },
      { name: "agents", markup: [circle(orbit(-58), 48, palette.amber), circle(orbit(162), 38, "#7EE0D2"), circle(orbit(62), 30, palette.snow)].join("") },
    ],
  };
};

const vasen = (): Variant => ({
  id: "r-vasen",
  title: "R · Väsen",
  idea: "A round little helper with a floppy cap: a mascot, not a tomte portrait.",
  background: vertical("#FFE6CF", "#FFC79E"),
  layers: [
    {
      name: "body",
      markup: `<path d="M512 400 C680 400 772 520 772 668 C772 790 690 836 512 836 C334 836 252 790 252 668 C252 520 344 400 512 400 Z" fill="#3B3F99"/>`,
    },
    { name: "cap", markup: hat({ at: [520, 452], scale: 2.6, rotate: 6 }, palette.ember) },
    {
      name: "face",
      markup: `<ellipse cx="440" cy="640" rx="34" ry="44" fill="${palette.snow}"/><ellipse cx="584" cy="640" rx="34" ry="44" fill="${palette.snow}"/>${circle([448, 652], 17, "#1A1C47")}${circle([592, 652], 17, "#1A1C47")}${circle([382, 724], 26, "#F59AA8", ' opacity="0.8"')}${circle([642, 724], 26, "#F59AA8", ' opacity="0.8"')}`,
    },
  ],
});

const streck = (): Variant => ({
  id: "s-streck",
  title: "S · Streck",
  idea: "C drawn as line art in the old icon's rounded-stroke style. Lighter, more \"developer tool\".",
  background: { kind: "solid", color: "#000000" },
  layers: [
    {
      name: "hat",
      markup: `<g transform="${hatTransform({ at: [512, 612], scale: 3.7 })}"><path d="M0 112 C10 80 28 34 54 6 C72 -4 96 12 104 50 M77 34 C86 58 95 86 100 112 Q50 124 0 112" fill="none" stroke="${palette.ember}" stroke-width="${60 / 3.7}" stroke-linecap="round" stroke-linejoin="round"/></g>`,
    },
    { name: "cursor", markup: `<rect x="372" y="728" width="280" height="62" rx="31" fill="${palette.ember}"/>` },
  ],
});

const roundedPolygon = (points: readonly Point[], fill: string, radius: number) =>
  `<path d="${pointsPath(points)}" fill="${fill}" stroke="${fill}" stroke-width="${radius}" stroke-linejoin="round"/>`;

const solid = (color: string): Background => ({ kind: "solid", color });

const primitiv = (): Variant => ({
  id: "3-01-primitiv",
  title: "1 · Primitiv",
  idea: "The tomte from three primitive shapes: cone, glass nose, beard. Lykta's geometry, on black.",
  background: solid("#000000"),
  groups: [{ shadow: 0.5 }, { shadow: 0.5 }],
  layers: [
    { name: "beard", group: 1, fill: vertical("#FFFFFF", "#D9E2EE"), markup: `<path d="M300 596 H724 C724 768 626 868 512 868 C398 868 300 768 300 596 Z" fill="#E6ECF5"/>` },
    { name: "cone", group: 1, fill: vertical("#FFB547", "#FF7A1A"), markup: roundedPolygon([[512, 176], [736, 604], [288, 604]], "#FF9F1C", 56) },
    { name: "nose", group: 0, glass: true, fill: solid("#FF4F8B"), markup: circle([512, 604], 86, "#FF4F8B") },
  ],
});

const promptGlas = (): Variant => ({
  id: "3-02-prompt-glas",
  title: "2 · Prompt i glas",
  idea: "Your favourite C, rebuilt in Liquid Glass with a warm gradient hat.",
  background: solid("#000000"),
  groups: [{ shadow: 0.4 }, { translucency: 0.12, shadow: 0.5 }],
  layers: [
    { name: "hat", group: 1, glass: true, fill: vertical("#FFC85A", "#FF6A1A"), markup: hat({ at: [512, 640], scale: 3.8 }, palette.ember) },
    { name: "cursor", group: 0, fill: solid("#FF9F1C"), markup: `<rect x="372" y="744" width="280" height="58" rx="29" fill="${palette.ember}"/>` },
  ],
});

const promptBla = (): Variant => ({
  id: "3-03-prompt-bla",
  title: "3 · Prompt, natt",
  idea: "C in a night colourway: amber glass hat, cyan cursor on deep blue. Same idea, calmer.",
  background: vertical("#122C6B", "#030A1F"),
  groups: [{ shadow: 0.4 }, { translucency: 0.12, shadow: 0.5 }],
  layers: [
    { name: "hat", group: 1, glass: true, fill: vertical("#FFD96E", "#FF9F1C"), markup: hat({ at: [512, 640], scale: 3.8 }, palette.amber) },
    { name: "cursor", group: 0, fill: solid("#5EE6FF"), markup: `<rect x="372" y="744" width="280" height="58" rx="29" fill="#5EE6FF"/>` },
  ],
});

const tomtar = (): Variant => ({
  id: "3-04-tomtar",
  title: "4 · Tomtar",
  idea: "Three hats overlapping: many agents, one household. Lykta's light-blending on black.",
  background: solid("#000000"),
  groups: [{ translucency: 0.35, shadow: 0.5 }],
  layers: [
    { name: "pink", blend: "screen", markup: hat({ at: [328, 776], scale: 2.6, rotate: -6 }, "#FF4F8B") },
    { name: "blue", blend: "screen", markup: hat({ at: [706, 770], scale: 2.9, rotate: 5 }, "#3D7BFF") },
    { name: "amber", blend: "screen", markup: hat({ at: [512, 824], scale: 4.0 }, "#FFB000") },
  ],
});

const duo = (): Variant => ({
  id: "3-05-duo",
  title: "5 · Duo",
  idea: "Two shapes, like Papo: the hat and a glass nose. As minimal as a tomte gets.",
  background: vertical("#43206E", "#1C0B36"),
  groups: [{ translucency: 0.3, shadow: 0.5 }, { shadow: 0.5 }],
  layers: [
    { name: "hat", group: 1, fill: vertical("#FF9A6B", "#FF5A4E"), markup: hat({ at: [512, 700], scale: 4.4 }, "#FF7A59") },
    { name: "nose", group: 0, glass: true, fill: solid("#FFE3D6"), markup: circle([512, 702], 112, "#FFE3D6") },
  ],
});

const pratskagg = (): Variant => ({
  id: "3-06-pratskagg",
  title: "6 · Pratskägg",
  idea: "The beard is a speech bubble pointing down. A tomte that talks, Mumla's sibling.",
  background: vertical("#4A86FF", "#1B2B8F"),
  groups: [{ shadow: 0.5 }, { translucency: 0.2, shadow: 0.5 }],
  layers: [
    {
      name: "bubble",
      group: 1,
      glass: true,
      fill: vertical("#FFFFFF", "#DCE6FF"),
      markup: `<path d="M318 520 H706 Q768 520 768 582 V694 Q768 772 690 772 H578 L512 872 L446 772 H334 Q256 772 256 694 V582 Q256 520 318 520 Z" fill="#FFFFFF" stroke="#FFFFFF" stroke-width="20" stroke-linejoin="round"/>`,
    },
    { name: "dots", group: 1, fill: solid("#3D6BFF"), markup: [422, 512, 602].map((x) => circle([x, 650], 30, "#3D6BFF")).join("") },
    { name: "hat", group: 0, glass: true, fill: vertical("#FFB547", "#FF4F7B"), markup: hat({ at: [512, 556], scale: 3.3 }, "#FF8A3D") },
  ],
});

const fonsterGlas = (): Variant => ({
  id: "3-07-fonster",
  title: "7 · Fönster",
  idea: "A tomte's silhouette in a glowing glass window. Night shift, two shapes.",
  background: vertical("#1C2756", "#070B1E"),
  groups: [{ shadow: 0.4 }, { translucency: 0.15, shadow: 0.5 }],
  layers: [
    { name: "window", group: 1, glass: true, fill: vertical("#FFD86E", "#FF9F1C"), markup: `<rect x="236" y="226" width="552" height="600" rx="96" fill="#FFC34D"/>` },
    { name: "tomte", group: 0, fill: solid("#151B45"), markup: hat({ at: [500, 828], scale: 3.3, rotate: -3 }, "#151B45") },
  ],
});

const fullmane = (): Variant => ({
  id: "3-08-fullmane",
  title: "8 · Fullmåne",
  idea: "The hat against a huge full moon. A poster silhouette: awake while everyone sleeps.",
  background: vertical("#16306A", "#050B1F"),
  groups: [{ shadow: 0.5 }, { translucency: 0.15, shadow: 0.4 }],
  layers: [
    { name: "moon", group: 1, glass: true, fill: vertical("#FFF3C9", "#FFCF66"), markup: circle([512, 452], 292, "#FFE7A8") },
    { name: "hat", group: 0, fill: vertical("#FF8A3D", "#FF4F5E"), markup: hat({ at: [512, 906], scale: 4.4 }, "#FF6A3D") },
  ],
});

const gnistaGlas = (): Variant => {
  const placement: HatPlacement = { at: [488, 812], scale: 4.8 };
  return {
    id: "3-09-gnista",
    title: "9 · Gnista",
    idea: "A glass hat whose drooping tip ends in a spark: tomte meets AI, on C's black.",
    background: solid("#000000"),
    groups: [{ shadow: 0.4 }, { translucency: 0.15, shadow: 0.5 }],
    layers: [
      { name: "hat", group: 1, glass: true, fill: vertical("#FFB547", "#FF4F7B"), markup: hat(placement, "#FF8A3D") },
      { name: "spark", group: 0, fill: solid("#FFE07A"), markup: sparkle(hatPoint(placement, HAT_TIP), 104, "#FFE07A") },
    ],
  };
};

const omlopp = (): Variant => {
  const center: Point = [512, 512];
  const orbit = (degrees: number): Point => [center[0] + 340 * Math.cos((degrees * Math.PI) / 180), center[1] + 340 * Math.sin((degrees * Math.PI) / 180)];
  return {
    id: "3-10-omlopp",
    title: "10 · Omlopp",
    idea: "C's glass hat with agents orbiting it: the tomte runs the fleet. Product and character at once.",
    background: solid("#000000"),
    groups: [{ shadow: 0.5 }, { translucency: 0.2, shadow: 0.5 }, { shadow: 0.3 }],
    layers: [
      { name: "ring", group: 2, fill: solid("#3A3F55"), markup: `<circle cx="${center[0]}" cy="${center[1]}" r="340" fill="none" stroke="#3A3F55" stroke-width="20"/>` },
      { name: "hat", group: 1, glass: true, fill: vertical("#FFC85A", "#FF6A1A"), markup: hat({ at: [512, 688], scale: 3.3 }, palette.ember) },
      { name: "agent-amber", group: 0, fill: solid("#FFC34D"), markup: circle(orbit(-50), 50, "#FFC34D") },
      { name: "agent-pink", group: 0, fill: solid("#FF4F8B"), markup: circle(orbit(165), 40, "#FF4F8B") },
      { name: "agent-blue", group: 0, fill: solid("#3D7BFF"), markup: circle(orbit(70), 32, "#3D7BFF") },
    ],
  };
};

const rounds: Readonly<Record<string, readonly Variant[]>> = {
  "round-3": [primitiv(), promptGlas(), promptBla(), tomtar(), duo(), pratskagg(), fonsterGlas(), fullmane(), gnistaGlas(), omlopp()],
  "round-1": [klassisk(), mossan(), prompt(), stugan(), pratbubbla(), rost(), spar(), manskara(), stjarnbild(), gnista()],
  "round-2": [prompt(), streck(), fonstret(), taket(), viska(), dorren(), klotet(), lillaT(), svarm(), vasen()],
};

const svgDocument = (defs: string, body: string) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${SIZE}" height="${SIZE}" viewBox="0 0 ${SIZE} ${SIZE}">${defs ? `<defs>${defs}</defs>` : ""}${body}</svg>\n`;

const srgb = (hex: string) => {
  const value = Number.parseInt(hex.slice(1), 16);
  const channel = (shift: number) => (((value >> shift) & 255) / 255).toFixed(5);
  return `srgb:${channel(16)},${channel(8)},${channel(0)},1.00000`;
};

const fillValue = (background: Background) =>
  background.kind === "solid"
    ? { solid: srgb(background.color) }
    : {
        "linear-gradient": background.stops.map(([, color]) => srgb(color)),
        orientation: {
          start: { x: background.from[0], y: background.from[1] },
          stop: { x: background.to[0], y: background.to[1] },
        },
      };

const writeIconBundle = (variant: Variant, bundle: string) => {
  mkdirSync(join(bundle, "Assets"), { recursive: true });
  const files = variant.layers.map((layer, index) => {
    const file = `${index + 1}-${layer.name}.svg`;
    writeFileSync(join(bundle, "Assets", file), svgDocument("", layer.markup));
    return file;
  });
  const groupCount = Math.max(0, ...variant.layers.map((layer) => layer.group ?? 0)) + 1;
  const groups = Array.from({ length: groupCount }, (_, group) => {
    const style = variant.groups?.[group] ?? {};
    const layers = variant.layers
      .map((layer, index) => ({ layer, file: files[index]! }))
      .filter(({ layer }) => (layer.group ?? 0) === group)
      .reverse()
      .map(({ layer, file }) => ({
        "image-name": file,
        name: layer.name,
        ...(layer.blend ? { "blend-mode": layer.blend } : {}),
        ...(layer.glass ? { glass: true } : {}),
        ...(layer.fill ? { "fill-specializations": [{ value: fillValue(layer.fill) }] } : {}),
      }));
    return {
      layers,
      shadow: { kind: "neutral", opacity: style.shadow ?? 0.5 },
      translucency: { enabled: style.translucency !== undefined, value: style.translucency ?? 0.5 },
    };
  });
  const document = {
    "fill-specializations": [{ value: fillValue(variant.background) }],
    groups,
    "supported-platforms": { squares: "shared" },
  };
  writeFileSync(join(bundle, "icon.json"), `${JSON.stringify(document, null, 2)}\n`);
};

const root = dirname(fileURLToPath(import.meta.url));
const xcodeVersion = readFileSync(join(root, "..", "..", ".xcode-version"), "utf8").trim();
const ictool = `/Applications/Xcode-${xcodeVersion}.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool`;
const run = promisify(execFile);

const renderBundle = async (bundle: string, output: string, rendition: "Default" | "Dark", size: number) => {
  await run(ictool, [bundle, "--export-image", "--output-file", output, "--platform", "iOS", "--rendition", rendition, "--width", `${size}`, "--height", `${size}`, "--scale", "1"]);
  const preview = output.replace(/\.png$/, ".webp");
  await run("magick", [output, "-quality", "88", preview]);
  return `data:image/webp;base64,${readFileSync(preview).toString("base64")}`;
};

interface RenderedIcon {
  readonly variant: Variant;
  readonly uri: string;
  readonly dark: string;
}

const page = (icons: readonly RenderedIcon[]) => {
  const cards = icons
    .map(({ variant, uri }) => `<figure><img class="icon" src="${uri}" alt=""><figcaption><b>${variant.title}</b><span>${variant.idea}</span></figcaption></figure>`)
    .join("");
  const label = (variant: Variant) => variant.title.split(" · ")[0];
  const home = icons
    .map(({ variant, uri }) => `<div class="app"><img src="${uri}" alt="${variant.title}"><span>${label(variant)}</span></div>`)
    .join("");
  const darkHome = icons
    .map(({ variant, dark }) => `<div class="app"><img src="${dark}" alt="${variant.title}"><span>${label(variant)}</span></div>`)
    .join("");
  const tiny = icons.map(({ variant, uri }) => `<img src="${uri}" alt="${variant.title}">`).join("");
  return `<style>
.w{font-family:var(--rc-font-family);color:var(--rc-text);color-scheme:var(--rc-color-scheme);font-size:var(--rc-font-size,1em);line-height:1.35}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:1.1em .8em}
figure{margin:0}
.icon{width:100%;max-width:180px;aspect-ratio:1;display:block}
figcaption{margin-top:.5em;font-size:.86em}
figcaption b{display:block;font-size:1.05em;margin-bottom:.15em}
figcaption span{color:var(--rc-secondary-text)}
h3{font-size:.95em;margin:1.6em 0 .6em}
.home{border-radius:18px;padding:16px 10px;display:grid;grid-template-columns:repeat(5,1fr);gap:14px 6px;background:linear-gradient(160deg,#5B6FA8,#C98BA8 55%,#F2C29B)}
.app{display:flex;flex-direction:column;align-items:center;gap:4px}
.app img{width:58px;height:58px}
.app span{font-size:11px;color:#fff;text-shadow:0 1px 2px rgba(0,0,0,.35)}
.tiny{display:flex;flex-wrap:wrap;gap:10px;align-items:center;background:var(--rc-surface);border-radius:12px;padding:10px}
.tiny img{width:29px;height:29px}
.home.dark{background:linear-gradient(160deg,#1B2340,#3A2340 55%,#4A3226)}
</style>
<div class="w">
<div class="grid">${cards}</div>
<h3>Home Screen size</h3>
<div class="home">${home}</div>
<h3>Dark appearance</h3>
<div class="home dark">${darkHome}</div>
<h3>Settings and Spotlight size</h3>
<div class="tiny">${tiny}</div>
</div>
`;
};

const out = join(root, "out");

const render = async (variant: Variant): Promise<RenderedIcon> => {
  const dir = join(out, variant.id);
  rmSync(dir, { recursive: true, force: true });
  const bundle = join(dir, "AppIcon.icon");
  writeIconBundle(variant, bundle);
  const [uri, dark] = await Promise.all([
    renderBundle(bundle, join(dir, "default.png"), "Default", 320),
    renderBundle(bundle, join(dir, "dark.png"), "Dark", 120),
  ]);
  return { variant, uri, dark };
};

const requested = process.argv.slice(2);
for (const [round, variants] of Object.entries(rounds)) {
  if (requested.length > 0 && !requested.includes(round)) continue;
  mkdirSync(out, { recursive: true });
  writeFileSync(join(out, `${round}.html`), page(await Promise.all(variants.map(render))));
  console.log(`${round}: ${variants.length} variants`);
}
