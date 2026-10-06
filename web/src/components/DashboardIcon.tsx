export function DashboardIcon({ type = "cpu" }: { type?: string }) {
  const paths: Record<string, string> = {
    cpu: "M7 7h10v10H7z M10 10h4v4h-4z M8 3v4m4-4v4m4-4v4M8 17v4m4-4v4m4-4v4M3 8h4m-4 4h4m-4 4h4m10-8h4m-4 4h4m-4 4h4",
    memory: "M3 6h18v12H3z M7 9v5m5-5v5m5-5v5M6 18v3m4-3v3m4-3v3m4-3v3",
    disk: "M6 3h12l3 14H3z M3 17v4h18v-4M7 17h.1m4 0h.1",
    gpu: "M3 6h18v12H3z M7 10h4v4H7z M15 10h3v4h-3z M7 18v3m4-3v3m4-3v3",
    temperature: "M10 14V5a2 2 0 0 1 4 0v9a5 5 0 1 1-4 0 M12 8v10",
    layers: "m12 3 10 5-10 5L2 8z M2 12l10 5 10-5M2 16l10 5 10-5",
    overhead: "M12 3v5m0 8v5M3 12h5m8 0h5 M8 8l-3-3m11 3 3-3m-3 11 3 3m-11-3-3 3 M8 12a4 4 0 1 0 8 0 4 4 0 0 0-8 0",
  };
  return <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={paths[type] ?? paths.cpu}/></svg>;
}
