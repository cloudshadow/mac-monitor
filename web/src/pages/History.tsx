import { useEffect, useRef, useState } from "react";
import { useMetrics } from "../store/metrics";
import { useI18n, errorMessage } from "../i18n";
import { api, APIError } from "../store/api";
import { sensorName, showSensor } from "../components/Temperatures";
import { TimeSeries, type Point } from "../components/TimeSeries";
export function History() {
  const { t, number } = useI18n(),
    { snapshot } = useMetrics(),
    epoch = snapshot.recordingEpoch,
    [range, setRange] = useState(300),
    [seriesId, setSeriesId] = useState("cpu.total"),
    [result, setResult] = useState<Record<string, any>>(),
    [apps, setApps] = useState<Record<string, any>>(),
    [error, setError] = useState(""),
    [refresh, setRefresh] = useState(0);
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
    setError("");
    const now = Date.now() / 1000,
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
        if (alive)
          setError(e instanceof APIError ? e.code : "serviceUnavailable");
      });
    if (range <= 7 * 86400)
      void api(
        "/history/apps?from=" + (now - range) + "&to=" + now + "&limit=100",
        { signal: controller.signal },
      )
        .then((r) => {
          if (alive) setApps(r);
        })
        .catch(() => {});
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
        setError(error instanceof APIError ? error.code : "serviceUnavailable");
    }
  }
  return (
    <section className="card">
      <div className="toolbar">
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
        <select aria-label={t("history:metric")} value={seriesId} onChange={e => setSeriesId(e.target.value)}>
          {choices.map(([id, label]) => <option key={id} value={id}>{label}</option>)}
        </select>
        <button onClick={() => setRefresh((v) => v + 1)}>
          {t("common:retry")}
        </button>
      </div>
      <p>{t("history:coverage")}</p>
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
              <TimeSeries points={points} label={id} />
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
      <p>
        {result?.recordingStatus?.enabled
          ? t("history:recording")
          : result
            ? t("history:paused")
            : t("common:loading")}
      </p>
      <p>{t("history:summary")}</p>
      {apps?.rows.map((row: Record<string, any>, i: number) => (
        <p key={row.id + ":" + i}>
          {row.name} ·{" "}
          {typeof row.cpuPercentCore === "number"
            ? number(row.cpuPercentCore, { maximumFractionDigits: 1 }) + " %"
            : t("common:unknown")}{" "}
          ·{" "}
          {row.selectedBy
            .map((by: string) =>
              t(("apps:" + (by === "disk" ? "diskRead" : by)) as "apps:cpu"),
            )
            .join(", ")}
        </p>
      ))}
      {apps?.nextCursor && (
        <button onClick={() => void nextApplications()}>
          {t("common:next")}
        </button>
      )}
      {error && <p role="alert">{errorMessage(error)}</p>}
    </section>
  );
}
