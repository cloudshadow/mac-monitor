import { showError } from "../components/ErrorToast";
import { useEffect, useState } from "react";
import { useI18n } from "../i18n";
import { useMetrics } from "../store/metrics";
import { api } from "../store/api";
import { Temperatures } from "../components/Temperatures";
import { MetricChart, type ChartSample } from "../components/MetricChart";
import { DashboardIcon } from "../components/DashboardIcon";
export function Overview() {
  const { t, number, date } = useI18n(),
    { snapshot, receivedAt, appsSequence } = useMetrics(),
    [points, setPoints] = useState<ChartSample[]>([]),
    [live, setLive] = useState<Record<string, ChartSample[]>>({}),
    [topApps, setTopApps] = useState<Record<string, any>[][]>([[], []]);
  useEffect(() => {
    setPoints([]);
    let alive = true,
      inflight = false;
    const request = async () => {
      if (inflight || document.hidden) return;
      inflight = true;
      try {
        const now = Date.now() / 1000,
          result = await api(
            "/recent/system?seriesIds=cpu.total&from=" +
              (now - 300) +
              "&to=" +
              now +
              "&maxPoints=300",
          );
        if (alive) {
          setPoints((result.series?.["cpu.total"] ?? []).map((p: any) => ({ time: p.bucketEndUtc, value: p.avg })));
        }
      } catch (e) {
        if (alive)
          showError(e);
      } finally {
        inflight = false;
      }
    };
    void request();
    const timer = setInterval(() => void request(), 10000);
    return () => {
      alive = false;
      clearInterval(timer);
    };
  }, [snapshot.recordingEpoch]);
  useEffect(() => {
    if (!receivedAt) return;
    const time = Date.now() / 1000;
    setLive(previous => {
      const next = { ...previous };
      for (const key of ["cpu", "appWiredPercent", "gpu", "swapUsedBytes", "diskReadBytesPerSecond", "diskWriteBytesPerSecond", "networkReadBytesPerSecond", "networkWriteBytesPerSecond", "overhead"]) {
        const value = key === "overhead" ? snapshot.serviceOverhead?.cpuPercentCore : snapshot[key]?.value;
        if (typeof value === "number" && Number.isFinite(value)) next[key] = [...(previous[key] ?? []).filter(p => p.time > time - 300), { time, value }].slice(-300);
      }
      return next;
    });
  }, [receivedAt, snapshot]);
  useEffect(() => {
    setLive({});
  }, [snapshot.recordingEpoch]);
  useEffect(() => {
    let alive = true;
    const timer = setTimeout(() => {
      void Promise.all([api("/apps?sort=cpu&limit=5"), api("/apps?sort=memory&limit=5")]).then(results => {
        if (alive) { setTopApps(results.map(r => r.rows ?? [])); }
      }).catch(e => { if (alive) showError(e); });
    }, 300);
    return () => { alive = false; clearTimeout(timer); };
  }, [appsSequence]);
  const colors = ["#0099FF", "#a855f7", "#10c99a", "#ff8736"];
  const series = (key: string) => key === "cpu" ? (live.cpu?.length > 1 ? live.cpu : points) : live[key] ?? [];
  const bytes = (value: unknown) => typeof value === "number" ? number(value / 1048576, { maximumFractionDigits: 1 }) + " MiB" : t("common:unknown");
  const memoryParts = [snapshot.appMemoryBytes, snapshot.wiredBytes, snapshot.compressorBytes];
  const total = snapshot.physicalMemoryBytes;
  const compositionReady = typeof total === "number" && total > 0 && memoryParts.every(v => typeof v === "number" && Number.isFinite(v));
  const parts = compositionReady ? [...memoryParts, Math.max(0, total - memoryParts.reduce((a, b) => a + b, 0))] : [];
  const partTotal = parts.reduce((a, b) => a + b, 0);
  const metrics = [
    ["dashboard:cpu", "cpu", "%"],
    ["dashboard:memory", "appWiredPercent", "%"],
    ["dashboard:swap", "swapUsedBytes", "bytes"],
    ["dashboard:gpu", "gpu", "%"],
  ] as const;
  return (
    <div className="overview-grid">
      <div className="grid overview-metrics">
        {metrics.map(([label, key, unit], index) => {
          const metric = snapshot[key], value = metric?.value;
          return (
            <section className="card metric" key={key} style={{ "--metric-color": colors[index] } as React.CSSProperties}>
              <div className="metric-icon"><DashboardIcon type={["cpu", "memory", "disk", "gpu"][index]} /></div>
              <h2>{t(label)}</h2>
              <strong>
                {typeof value === "number"
                  ? unit === "bytes"
                    ? number(value / 1048576, { maximumFractionDigits: 1 }) +
                      " MiB"
                    : number(value, { maximumFractionDigits: 1 }) + unit
                  : t("common:unknown")}
              </strong>
              {key === "appWiredPercent" && <small className="memory-formula">{t("dashboard:memoryFormula")}</small>}
              <MetricChart samples={series(key)} color={colors[index]} compact label={t(label)} />
            </section>
          );
        })}
      <section className="card metric overhead-card">
        <div className="metric-icon"><DashboardIcon type="overhead" /></div>
        <h2>{t("dashboard:overhead")}</h2>
        <strong>
          {typeof snapshot.serviceOverhead?.cpuPercentCore === "number"
            ? number(snapshot.serviceOverhead.cpuPercentCore, {
                maximumFractionDigits: 2,
              }) + " %"
            : t("common:unknown")}{" "}
          <br />
          {typeof snapshot.serviceOverhead?.physicalFootprintBytes === "number"
            ? number(
                snapshot.serviceOverhead.physicalFootprintBytes / 1048576,
                { maximumFractionDigits: 1 },
              ) + " MiB"
            : t("common:unknown")}
        </strong>
        <MetricChart samples={series("overhead")} compact label={t("dashboard:overhead")} />
      </section>
      </div>
      <div className="overview-primary">
      <Temperatures sensors={snapshot.sensors} />
      <div className="trend-grid">
        {metrics.filter((_, i) => i !== 2).map(([label, key], index) => <section className="card trend-card" key={key} style={{ "--metric-color": colors[index === 2 ? 3 : index] } as React.CSSProperties}>
          <h2><DashboardIcon type={["cpu", "memory", "gpu"][index]} />{t(label)}<span>{typeof snapshot[key]?.value === "number" ? number(snapshot[key].value, { maximumFractionDigits: 1 }) + "%" : t("common:unknown")}</span></h2>
          <MetricChart samples={series(key)} color={colors[index === 2 ? 3 : index]} percent label={t(label)} />
          {series(key).length < 2 && <small>{t("dashboard:collectingTrend")}</small>}
        </section>)}
      </div>
      <div className="ranking-grid">
        {topApps.map((rows, index) => <section className="card ranking-card" key={index}>
          <h2><DashboardIcon type={index ? "memory" : "cpu"} />{t(index ? "dashboard:topMemory" : "dashboard:topCPU")}</h2>
          <div className="table-scroll"><table><thead><tr><th>#</th><th>{t("common:apps")}</th><th>{index ? "MiB" : "CPU %"}</th></tr></thead><tbody>
            {rows.map((row, rank) => <tr key={row.id}><td>{rank + 1}</td><td title={row.name}>{row.name}</td><td>{index ? bytes(row.physicalFootprintBytes) : typeof row.cpuPercentCore === "number" ? number(row.cpuPercentCore, { maximumFractionDigits: 1 }) + "%" : t("common:unknown")}</td></tr>)}
          </tbody></table></div>
          {!rows.length && <small>{t("dashboard:noApps")}</small>}
        </section>)}
      </div>
      <p className="dashboard-footnote">{t("dashboard:recent")} · {t("dashboard:liveTrendHelp")}{snapshot.sampledAt && <> · {t("dashboard:sampled", { time: date(snapshot.sampledAt) })}</>}{receivedAt === 0 && <> · {t("common:loading")}</>}</p>
      </div>
      <div className="overview-secondary">
      <section className="card memory-composition">
        <h2><DashboardIcon type="memory" />{t("dashboard:memoryComposition")}</h2>
        {compositionReady ? <>
          <div className="memory-bar" role="img" aria-label={t("dashboard:memoryComposition")}>
            {parts.map((value, i) => <span key={i} style={{ width: `${100 * value / partTotal}%`, background: [colors[1], colors[0], colors[2], "#667d96"][i] }} />)}
          </div>
          <div className="memory-legend">{(["appMemoryBytes", "wiredBytes", "compressorBytes", "remainingMemory"] as const).map((key, i) => <div key={key}><small><i style={{ background: [colors[1], colors[0], colors[2], "#667d96"][i] }}/>{t(("dashboard:" + key) as "dashboard:appMemoryBytes")}</small><strong>{bytes(parts[i])}</strong></div>)}</div>
        </> : <p>{t("common:loading")}</p>}
      </section>
      <section className="card thermal-card">
        <p>
          {t("dashboard:thermal")}:{" "}
          {t(
            ("dashboard:" +
              (["nominal", "fair", "serious", "critical"][
                snapshot.thermalState
              ] ?? "nominal")) as "dashboard:nominal",
          )}
        </p>
        {snapshot.samplingPolicy?.reason === "powerOrThermalConstraint" && (
          <p>{t("common:powerOrThermalConstraint")}</p>
        )}
      </section>
      <section className="card memory-card">
        <h2><DashboardIcon type="layers" />{t("dashboard:memoryDetails")}</h2>
        <div className="grid">
          {(
            [
              "physicalMemoryBytes",
              "appMemoryBytes",
              "freeBytes",
              "speculativeBytes",
              "activeBytes",
              "inactiveBytes",
              "wiredBytes",
              "compressorBytes",
            ] as const
          ).map((field) => (
            <p key={field}>
              {t(("dashboard:" + field) as "dashboard:freeBytes")}
              <br />
              <strong>
                {typeof snapshot[field] === "number"
                  ? number(snapshot[field] / 1048576, {
                      maximumFractionDigits: 1,
                    }) + " MiB"
                  : t("common:unknown")}
              </strong>
            </p>
          ))}
        </div>
      </section>
      <section className="card io-card">
        <h2><DashboardIcon type="disk" />{t("dashboard:io")}</h2>
        <div className="grid">
          {(
            [
              "diskReadBytesPerSecond",
              "diskWriteBytesPerSecond",
              "networkReadBytesPerSecond",
              "networkWriteBytesPerSecond",
            ] as const
          ).map((field) => (
            <p key={field}>
              {t(("dashboard:" + field) as "dashboard:diskReadBytesPerSecond")}
              <br />
              <strong>
                {typeof snapshot[field]?.value === "number"
                  ? number(snapshot[field].value / 1048576, {
                      maximumFractionDigits: 2,
                    }) + " MiB/s"
                  : t("common:unknown")}
              </strong>
            </p>
          ))}
        </div>
        <div className="io-trends">{["disk", "network"].map(domain => <div key={domain}>
          <MetricChart samples={(live[domain + "ReadBytesPerSecond"] ?? []).map(p => ({ ...p, value: p.value / 1048576 }))} secondary={(live[domain + "WriteBytesPerSecond"] ?? []).map(p => ({ ...p, value: p.value / 1048576 }))} label={t(domain === "disk" ? "dashboard:diskReadBytesPerSecond" : "dashboard:networkReadBytesPerSecond")} />
          <small><span className="read-key">{t(domain === "disk" ? "dashboard:diskReadBytesPerSecond" : "dashboard:networkReadBytesPerSecond")}</span> / <span className="write-key">{t(domain === "disk" ? "dashboard:diskWriteBytesPerSecond" : "dashboard:networkWriteBytesPerSecond")}</span> · MiB/s</small>
        </div>)}</div>
      </section>

      </div>
    </div>
  );
}
