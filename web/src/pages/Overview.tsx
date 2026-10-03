import { useEffect, useState } from "react";
import { useI18n, errorMessage } from "../i18n";
import { useMetrics } from "../store/metrics";
import { api, APIError } from "../store/api";
import { Temperatures } from "../components/Temperatures";
import { TimeSeries, type Point } from "../components/TimeSeries";
export function Overview() {
  const { t, number, date } = useI18n(),
    { snapshot, receivedAt } = useMetrics(),
    [points, setPoints] = useState<Point[]>([]),
    [error, setError] = useState("");
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
        if (alive) setPoints(result.series["cpu.total"]);
      } catch (e) {
        if (alive)
          setError(e instanceof APIError ? e.code : "serviceUnavailable");
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
  const metrics = [
    ["dashboard:cpu", "cpu", "%"],
    ["dashboard:memory", "nonIdlePercent", "%"],
    ["dashboard:swap", "swapUsedBytes", "bytes"],
    ["dashboard:gpu", "gpu", "%"],
  ] as const;
  return (
    <>
      <div className="grid">
        {metrics.map(([label, key, unit]) => {
          const metric = snapshot[key], value = metric?.value;
          return (
            <section className="card metric" key={key}>
              <h2>{t(label)}</h2>
              <strong>
                {typeof value === "number"
                  ? unit === "bytes"
                    ? number(value / 1048576, { maximumFractionDigits: 1 }) +
                      " MiB"
                    : number(value, { maximumFractionDigits: 1 }) + unit
                  : t("common:unknown")}
              </strong>
              <small>
                {metric?.status
                  ? t(("common:" + metric.status) as "common:ok")
                  : ""}
              </small>
            </section>
          );
        })}
      </div>
      <Temperatures sensors={snapshot.sensors} />
      <section className="card">
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
      <section className="card">
        <h2>{t("dashboard:memoryDetails")}</h2>
        <div className="grid">
          {(
            [
              "physicalMemoryBytes",
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
      <section className="card">
        <h2>{t("dashboard:io")}</h2>
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
        {snapshot.networkInterfaces?.map((network: Record<string, any>) => (
          <p key={network.id}>
            {network.id} · ↓{" "}
            {typeof network.receivedBytesPerSecond.value === "number"
              ? number(network.receivedBytesPerSecond.value / 1048576, {
                  maximumFractionDigits: 2,
                })
              : t("common:unknown")}{" "}
            MiB/s · ↑{" "}
            {typeof network.sentBytesPerSecond.value === "number"
              ? number(network.sentBytesPerSecond.value / 1048576, {
                  maximumFractionDigits: 2,
                })
              : t("common:unknown")}{" "}
            MiB/s
          </p>
        ))}
      </section>
      <section className="card">
        <h2>{t("dashboard:overhead")}</h2>
        <p>
          {typeof snapshot.serviceOverhead?.cpuPercentCore === "number"
            ? number(snapshot.serviceOverhead.cpuPercentCore, {
                maximumFractionDigits: 2,
              }) + " %"
            : t("common:unknown")}{" "}
          ·{" "}
          {typeof snapshot.serviceOverhead?.physicalFootprintBytes === "number"
            ? number(
                snapshot.serviceOverhead.physicalFootprintBytes / 1048576,
                { maximumFractionDigits: 1 },
              ) + " MiB"
            : t("common:unknown")}
        </p>
      </section>
      <section className="card">
        <h2>{t("dashboard:recent")}</h2>
        <TimeSeries points={points} label={t("dashboard:cpu")} />
        {snapshot.sampledAt && (
          <p>{t("dashboard:sampled", { time: date(snapshot.sampledAt) })}</p>
        )}
        {receivedAt === 0 && <p>{t("common:loading")}</p>}
        {error && <p role="alert">{errorMessage(error)}</p>}
      </section>
    </>
  );
}
