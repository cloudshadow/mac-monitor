import { showError } from "../components/ErrorToast";
import { useEffect, useRef, useState } from "react";
import { useMetrics } from "../store/metrics";
import { useI18n } from "../i18n";
import { api } from "../store/api";
import { sensorName, showSensor } from "../components/Temperatures";
import { TimeSeries, type Point } from "../components/TimeSeries";
export function History() {
  const { t, number, date } = useI18n(),
    { snapshot } = useMetrics(),
    epoch = snapshot.recordingEpoch,
    [range, setRange] = useState(300),
    [seriesId, setSeriesId] = useState("cpu.total"),
    [result, setResult] = useState<Record<string, any>>(),
    [apps, setApps] = useState<Record<string, any>>(),
    [refresh, setRefresh] = useState(0),
    [systemLoading, setSystemLoading] = useState(false),
    [appsLoading, setAppsLoading] = useState(false),
    [systemFailed, setSystemFailed] = useState(false),
    [appsFailed, setAppsFailed] = useState(false);
  const currentEpoch = useRef(epoch),
    appRange = useRef({ from: 0, to: 0 }),
    requestRevision = useRef(0);
  const choices = [
    ["cpu.total", t("dashboard:cpu")],
    ["memory.nonIdle", t("dashboard:memoryNonIdle")],
    ["memory.swapUsedBytes", t("dashboard:swap")],
    ["gpu.total", t("dashboard:gpu")],
    ...["diskReadBytesPerSecond", "diskWriteBytesPerSecond", "networkReadBytesPerSecond", "networkWriteBytesPerSecond"].map(id => [id, t(("dashboard:" + id) as "dashboard:diskReadBytesPerSecond")]),
    ...(snapshot.sensors ?? []).filter(showSensor).map((sensor: Record<string, any>) => [sensor.seriesId, t("dashboard:temperature") + " · " + sensorName(sensor as { id: string; label: string }, t)]).filter((entry: string[]) => entry[0]),
  ];
  currentEpoch.current = epoch;
  useEffect(() => {
    requestRevision.current++;
    const controller = new AbortController();
    let alive = true;
    setResult(undefined);
    setApps(undefined);
    setSystemLoading(true);
    setAppsLoading(range <= 7 * 86400);
    setSystemFailed(false);
    setAppsFailed(false);
    const now = Math.floor(Date.now() / 1000),
      params = new URLSearchParams({
        from: String(now - range),
        to: String(now),
        seriesIds: seriesId,
        maxPoints: "600",
      });
    appRange.current = { from: now - range, to: now };
    void api("/history/system?" + params, { signal: controller.signal })
      .then((r) => {
        if (alive) setResult(r);
      })
      .catch((e) => {
        if (alive) { setSystemFailed(true); showError(e); }
      })
      .finally(() => { if (alive) setSystemLoading(false); });
    if (range <= 7 * 86400)
      void api(
        "/history/apps?from=" + (now - range) + "&to=" + now + "&limit=100",
        { signal: controller.signal },
      )
        .then((r) => {
          if (alive) setApps(r);
        })
        .catch(e => { if (alive) { setAppsFailed(true); showError(e); } })
        .finally(() => { if (alive) setAppsLoading(false); });
    return () => {
      alive = false;
      controller.abort();
    };
  }, [range, refresh, epoch, seriesId]);
  async function nextApplications() {
    if (!apps?.nextCursor) return;
    const revision = requestRevision.current;
    const params = new URLSearchParams({
      from: String(appRange.current.from),
      to: String(appRange.current.to),
      limit: "100",
      cursor: apps.nextCursor,
    });
    try {
      const page = await api("/history/apps?" + params);
      if (
        revision === requestRevision.current &&
        (!currentEpoch.current || page.recordingEpoch === currentEpoch.current)
      )
        setApps(page);
    } catch (error) {
      if (revision === requestRevision.current)
        showError(error);
    }
  }
  return (
    <section className="card">
      <div className="toolbar history-toolbar">
        <label>
          {t("history:range")}{" "}
          <select
            value={range}
            onChange={(e) => setRange(Number(e.target.value))}
          >
            {[
              [300, "fiveMinutes"],
              [86400, "day"],
              [7 * 86400, "week"],
              [30 * 86400, "month"],
            ].map(([value, label]) => (
              <option key={value} value={value}>
                {t(("history:" + label) as "history:day")}
              </option>
            ))}
          </select>
        </label>
        <label>{t("history:metric")}
        <select aria-label={t("history:metric")} value={seriesId} onChange={e => setSeriesId(e.target.value)}>
          {choices.map(([id, label]) => <option key={id} value={id}>{label}</option>)}
        </select>
        </label>
        <button onClick={() => setRefresh((v) => v + 1)}>
          {t("common:retry")}
        </button>
      </div>
      <p>{t("history:coverage")}</p>
      {systemLoading && <p role="status">{t("common:loading")}</p>}
      {systemFailed && <p>{t("common:error")}</p>}
      {result &&
        Object.entries(result.series).map(([id, value]) => {
          const points = value as Point[];
          const resolutions = [
            ...new Set(
              (value as any[]).map(
                (p) => p.resolutionSeconds + " / " + p.sourceResolutionSeconds,
              ),
            ),
          ];
          return (
            <section key={id}>
              <h2>
                {choices.find(([series]) => series === id)?.[1] ?? id}
              </h2>
              {points.length ? <TimeSeries points={points} label={id} /> : <p>{t("history:empty")}</p>}
              {resolutions.map((r) => (
                <small key={r}>
                  {t("history:precision", {
                    seconds: r.split(" / ")[0],
                    source: r.split(" / ")[1],
                  })}{" "}
                </small>
              ))}
            </section>
          );
        })}
      {result?.recordingStatus && <p>
        {result.recordingStatus.state === "error" || result.recordingStatus.error
          ? t("history:recordingError")
          : result.recordingStatus.state === "resetting"
            ? t("history:resetting")
            : result.recordingStatus.enabled ? t("history:recording") : t("history:paused")}
      </p>}
      <p>{t("history:summary")}</p>
      {range > 7 * 86400 && <p>{t("history:appRetention")}</p>}
      {appsLoading && <p role="status">{t("common:loading")}</p>}
      {appsFailed && <p>{t("common:error")}</p>}
      {apps && (apps.rows.length ? (
        <div className="table-scroll" tabIndex={0} role="region" aria-label={t("common:apps")}>
          <table>
            <thead><tr>
              <th>{t("common:apps")}</th><th>{t("history:window")}</th>
              <th>{t("history:cpuAverage")}</th><th>{t("history:memoryPeak")}</th>
              <th>{t("history:diskRead")}</th><th>{t("history:diskWrite")}</th>
              <th>{t("history:selectedBy")}</th>
            </tr></thead>
            <tbody>{apps.rows.map((row: Record<string, any>, i: number) => (
              <tr key={row.id + ":" + i}>
                <td>{row.name}</td>
                <td>{typeof row.bucketStartUtc === "number" && typeof row.bucketEndUtc === "number"
                  ? date(row.bucketStartUtc * 1000) + " – " + date(row.bucketEndUtc * 1000)
                  : t("common:unknown")}</td>
                {["cpuPercentCore", "physicalFootprintPeakBytes", "diskReadBytes", "diskWriteBytes"].map((field, index) => (
                  <td key={field}>{typeof row[field] === "number"
                    ? number(index === 0 ? row[field] : row[field] / 1048576, { maximumFractionDigits: 1 }) + (index === 0 ? " %" : " MiB")
                    : t("common:unknown")}</td>
                ))}
                <td>{(row.selectedBy ?? []).filter((by: string) => ["cpu", "memory", "disk"].includes(by))
                  .map((by: string) => t(("history:" + by) as "history:cpu")).join(", ")}</td>
              </tr>
            ))}</tbody>
          </table>
        </div>
      ) : <p>{t("history:empty")}</p>)}
      {apps?.nextCursor && (
        <button onClick={() => void nextApplications()}>
          {t("common:next")}
        </button>
      )}
    </section>
  );
}
