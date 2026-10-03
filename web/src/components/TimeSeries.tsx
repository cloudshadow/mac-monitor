import { useEffect, useRef } from "react";
export type Point = {
  bucketStartUtc: number;
  bucketEndUtc: number;
  avg: number;
  continuityId?: string;
  segmentId?: string;
};
export function TimeSeries({
  points,
  label,
}: {
  points: Point[];
  label: string;
}) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    function draw() {
      const width = canvas!.clientWidth,
        height = 180,
        dpr = window.devicePixelRatio || 1;
      canvas!.width = width * dpr;
      canvas!.height = height * dpr;
      const context = canvas!.getContext("2d")!;
      context.scale(dpr, dpr);
      context.clearRect(0, 0, width, height);
      context.strokeStyle = "#2e857a";
      context.lineWidth = 2;
      if (!points.length) return;
      const min = points[0].bucketStartUtc,
        max = points.at(-1)!.bucketEndUtc,
        top = Math.max(1, ...points.map((p) => p.avg));
      context.beginPath();
      let previous: Point | undefined;
      for (const p of points) {
        const x = ((p.bucketEndUtc - min) / Math.max(1, max - min)) * width,
          y = height - 12 - (p.avg / top) * (height - 24);
        if (
          !previous ||
          p.segmentId !== previous.segmentId ||
          p.continuityId !== previous.continuityId ||
          p.bucketStartUtc > previous.bucketEndUtc + 0.01
        )
          context.moveTo(x, y);
        else context.lineTo(x, y);
        previous = p;
      }
      context.stroke();
    }
    draw();
    const observer = new ResizeObserver(draw);
    observer.observe(canvas);
    return () => observer.disconnect();
  }, [points]);
  return <canvas ref={ref} aria-label={label} role="img" />;
}
