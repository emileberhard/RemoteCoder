import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SIZE = 1024;

type Point = readonly [x: number, y: number];
type Stop = readonly [offset: number, color: string];

type Background =
  | { readonly kind: "solid"; readonly color: string }
  | { readonly kind: "linear"; readonly from: Point; readonly to: Point; readonly stops: readonly Stop[] };

interface Layer {
  readonly name: string;
  readonly markup: string;
}

interface Variant {
  readonly id: string;
  readonly title: string;
  readonly idea: string;
  readonly background: Background;
  readonly layers: readonly Layer[];
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

const variants: readonly Variant[] = [
  klassisk(), mossan(), prompt(), stugan(), pratbubbla(), rost(), spar(), manskara(), stjarnbild(), gnista(),
];

const backgroundMarkup = (background: Background) => {
  if (background.kind === "solid") {
    return { defs: "", fill: `<rect width="${SIZE}" height="${SIZE}" fill="${background.color}"/>` };
  }
  const stops = background.stops.map(([offset, color]) => `<stop offset="${offset}" stop-color="${color}"/>`).join("");
  const [x1, y1] = background.from;
  const [x2, y2] = background.to;
  return {
    defs: `<linearGradient id="bg" x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}">${stops}</linearGradient>`,
    fill: `<rect width="${SIZE}" height="${SIZE}" fill="url(#bg)"/>`,
  };
};

const svgDocument = (defs: string, body: string) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${SIZE}" height="${SIZE}" viewBox="0 0 ${SIZE} ${SIZE}">${defs ? `<defs>${defs}</defs>` : ""}${body}</svg>\n`;

const composite = (variant: Variant) => {
  const background = backgroundMarkup(variant.background);
  return svgDocument(background.defs, background.fill + variant.layers.map((layer) => layer.markup).join(""));
};

const dataURI = (svg: string) => `data:image/svg+xml;base64,${Buffer.from(svg).toString("base64")}`;

const page = (icons: readonly { variant: Variant; uri: string }[]) => {
  const cards = icons
    .map(({ variant, uri }) => `<figure><img class="icon" src="${uri}" alt=""><figcaption><b>${variant.title}</b><span>${variant.idea}</span></figcaption></figure>`)
    .join("");
  const home = icons
    .map(({ variant, uri }) => `<div class="app"><img src="${uri}" alt="${variant.title}"><span>${variant.title.slice(0, 1)}</span></div>`)
    .join("");
  const tiny = icons.map(({ variant, uri }) => `<img src="${uri}" alt="${variant.title}">`).join("");
  return `<style>
.w{font-family:var(--rc-font-family);color:var(--rc-text);color-scheme:var(--rc-color-scheme);font-size:var(--rc-font-size,1em);line-height:1.35}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:1.1em .8em}
figure{margin:0}
.icon{width:100%;max-width:180px;aspect-ratio:1;border-radius:22.4%;display:block;box-shadow:0 0 0 .5px color-mix(in srgb,var(--rc-text) 14%,transparent)}
figcaption{margin-top:.5em;font-size:.86em}
figcaption b{display:block;font-size:1.05em;margin-bottom:.15em}
figcaption span{color:var(--rc-secondary-text)}
h3{font-size:.95em;margin:1.6em 0 .6em}
.home{border-radius:18px;padding:16px 10px;display:grid;grid-template-columns:repeat(5,1fr);gap:14px 6px;background:linear-gradient(160deg,#5B6FA8,#C98BA8 55%,#F2C29B)}
.app{display:flex;flex-direction:column;align-items:center;gap:4px}
.app img{width:58px;height:58px;border-radius:13px}
.app span{font-size:11px;color:#fff;text-shadow:0 1px 2px rgba(0,0,0,.35)}
.tiny{display:flex;flex-wrap:wrap;gap:10px;align-items:center;background:var(--rc-surface);border-radius:12px;padding:10px}
.tiny img{width:29px;height:29px;border-radius:7px}
</style>
<div class="w">
<div class="grid">${cards}</div>
<h3>Home Screen size</h3>
<div class="home">${home}</div>
<h3>Settings and Spotlight size</h3>
<div class="tiny">${tiny}</div>
</div>
`;
};

const root = dirname(fileURLToPath(import.meta.url));
const out = join(root, "out");
rmSync(out, { recursive: true, force: true });

const icons = variants.map((variant) => {
  const dir = join(out, variant.id);
  mkdirSync(join(dir, "layers"), { recursive: true });
  const svg = composite(variant);
  writeFileSync(join(dir, "icon.svg"), svg);
  const background = backgroundMarkup(variant.background);
  writeFileSync(join(dir, "layers", "0-background.svg"), svgDocument(background.defs, background.fill));
  variant.layers.forEach((layer, index) => {
    writeFileSync(join(dir, "layers", `${index + 1}-${layer.name}.svg`), svgDocument("", layer.markup));
  });
  return { variant, uri: dataURI(svg) };
});

writeFileSync(join(out, "index.html"), page(icons));
console.log(`${icons.length} variants → ${out}`);
