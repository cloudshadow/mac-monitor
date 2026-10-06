import { useId } from "react";
export type ChartSample = { time: number; value: number };
export function MetricChart({ samples, color = "#0099FF", compact = false, percent = false, secondary = [], label }: { samples: ChartSample[]; color?: string; compact?: boolean; percent?: boolean; secondary?: ChartSample[]; label: string }) {
  const id = useId().replaceAll(":", "");
  const width = 400, height = compact ? 64 : 140;
  const left = compact ? 0 : 36, bottom = compact ? height : height - 24;
  const max = percent ? 100 : Math.max(1, ...[...samples, ...secondary].map(p => p.value)) * 1.15;
  const first = Math.min(samples[0]?.time ?? Infinity, secondary[0]?.time ?? Infinity), last = Math.max(samples.at(-1)?.time ?? 0, secondary.at(-1)?.time ?? 0);
  const coords = samples.map(p => `${left + (p.time - first) / Math.max(1, last - first) * (width - left - 8)},${bottom - Math.min(max, Math.max(0, p.value)) / max * (bottom - 10)}`);
  const secondaryCoords = secondary.map(p => `${left + (p.time - first) / Math.max(1, last - first) * (width - left - 8)},${bottom - Math.min(max, Math.max(0, p.value)) / max * (bottom - 10)}`);
  const line = coords.length > 1 ? `M${coords.join(" L")}` : "";
  return <svg className={compact ? "metric-spark" : "metric-chart"} viewBox={`0 0 ${width} ${height}`} role="img" aria-label={label} preserveAspectRatio="none">
    <defs><linearGradient id={id} x1="0" y1="0" x2="0" y2="1"><stop stopColor={color} stopOpacity=".3"/><stop offset="1" stopColor={color} stopOpacity="0"/></linearGradient></defs>
    {!compact && <g className="chart-grid">{[0, .5, 1].map(r => <g key={r}><path d={`M${left} ${bottom - r * (bottom - 10)}H${width}`}/><text x="0" y={bottom - r * (bottom - 10) + 4}>{percent ? `${r * 100}%` : (r * max).toFixed(1)}</text></g>)}{[0, .2, .4, .6, .8, 1].map(r => <path key={r} d={`M${left + r * (width - left - 8)} 10V${bottom}`}/>)}
      {samples.length > 1 && <><text x={left} y={height - 3}>{new Date(first * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</text><text textAnchor="end" x={width - 8} y={height - 3}>{new Date(last * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</text></>}
    </g>}
    {line && <><path d={`${line} L${coords.at(-1)!.split(",")[0]},${bottom} L${left},${bottom} Z`} fill={`url(#${id})`}/><path d={line} fill="none" stroke={color} strokeWidth="2.5" vectorEffect="non-scaling-stroke"/></>}
    {secondaryCoords.length > 1 && <path d={`M${secondaryCoords.join(" L")}`} fill="none" stroke="#10c99a" strokeWidth="2" vectorEffect="non-scaling-stroke" />}
  </svg>;
}
