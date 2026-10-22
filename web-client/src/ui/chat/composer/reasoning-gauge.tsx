const center = { x: 12, y: 13.5 };
const radius = 9;
const point = (degrees: number, distance = radius) => {
  const radians = (degrees * Math.PI) / 180;
  return { x: center.x + distance * Math.sin(radians), y: center.y - distance * Math.cos(radians) };
};
const arc = (from: number, to: number) => {
  const start = point(from);
  const end = point(to);
  return `M ${start.x} ${start.y} A ${radius} ${radius} 0 ${to - from > 180 ? 1 : 0} 1 ${end.x} ${end.y}`;
};

export function gaugeFraction(efforts: readonly string[], effort: string): number | null {
  const index = effort ? efforts.indexOf(effort) : -1;
  if (index < 0) return null;
  return efforts.length === 1 ? 1 : 0.25 + (0.75 * index) / (efforts.length - 1);
}

export function ReasoningGauge({ efforts, effort }: { efforts: readonly string[]; effort: string }) {
  const fraction = gaugeFraction(efforts, effort);
  const angle = -120 + 240 * (fraction ?? 1);
  const needleStart = point(angle, radius * 0.25);
  const needleEnd = point(angle, radius * 0.72);
  return (
    <svg className="reasoning-gauge" viewBox="0 0 24 24" width="22" height="22" aria-hidden="true">
      <path d={arc(-120, 120)} className="reasoning-gauge-track" />
      <path d={arc(-120, angle)} className="reasoning-gauge-level" />
      {fraction === null ? (
        <text x={center.x} y={center.y + 3.2} textAnchor="middle">
          A
        </text>
      ) : (
        <>
          <line x1={needleStart.x} y1={needleStart.y} x2={needleEnd.x} y2={needleEnd.y} />
          <circle cx={center.x} cy={center.y} r={radius * 0.2} />
        </>
      )}
    </svg>
  );
}
