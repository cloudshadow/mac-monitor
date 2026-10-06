import { DashboardIcon } from "./DashboardIcon";
import { useI18n, type translate } from "../i18n";
import type { MessageKey } from "../i18n/generated/types";
type Sensor = { id: string; label: string; category?: string; family?: string; mappingReference?: string; external?: boolean; metric?: { value?: number; status?: string; source?: string } };
// Group only descriptive names reported by the provider; opaque SMC keys stay unassigned.
function group(sensor: Sensor): string {
  if (isPMU(sensor)) return "other";
  if (sensor.category) return ["storage", "cpu", "graphics"].includes(sensor.category) ? sensor.category : "other";
  const label = sensor.label.toLowerCase();
  if (/proximity|voltage|regulator|vrm|pmu|charger|calibration/.test(label)) return "other";
  if (/cpu|efficiency core|performance core/.test(label)) return "cpu";
  if (/gpu|graphics/.test(label)) return "graphics";
  return "other";
}
function Ring({ value, children }: { value?: number; children?: React.ReactNode }) {
  const progress = typeof value === "number" ? Math.max(0, Math.min(100, value)) : 0;
  return <div className={children ? "temperature-dial" : "temperature-mini"}>
    <svg viewBox="0 0 100 100" aria-hidden="true"><circle cx="50" cy="50" r="44" /><circle className="temperature-progress" cx="50" cy="50" r="44" pathLength="100" strokeDasharray={`${progress} 100`} /></svg>
    {children && <div>{children}</div>}
  </div>;
}
const sensorNames: Record<string, MessageKey> = {
  "CPU die hotspot": "dashboard:cpuHotspot",
  "CPU die core maximum": "dashboard:cpuCoreMaximum",
  "CPU / charger proximity": "dashboard:chargerProximity",
  "GPU die hotspot": "dashboard:gpuHotspot",
  "Unified memory": "dashboard:memoryTemperature",
  "Memory voltage regulator": "dashboard:memoryVRM",
  "SSD controller": "dashboard:ssdController",
  "SSD proximity": "dashboard:ssdProximity",
  "NAND flash": "dashboard:nandTemperature",
  "SoC package": "dashboard:socPackage",
  "SoC surface": "dashboard:socSurface",
  "Airflow": "dashboard:airflowTemperature",
  "Ambient": "dashboard:ambientTemperature",
  "Wi-Fi": "dashboard:wifiTemperature",
  "Thunderbolt controller": "dashboard:thunderboltTemperature",
  "Display backlight proximity": "dashboard:displayBacklight",
  "Display panel": "dashboard:displayPanel",
  "Display / SoC voltage regulator": "dashboard:displayVRM",
  "Memory rail voltage regulator": "dashboard:memoryRailVRM",
  "Memory voltage regulator controller": "dashboard:memoryVRMController",
  "Auxiliary voltage regulator": "dashboard:auxiliaryVRM",
  "CPU performance cores": "dashboard:performanceCoresTemperature",
  "CPU efficiency cores": "dashboard:efficiencyCoresTemperature",
  "SoC thermal array": "dashboard:socArrayTemperature",
  "GPU cores": "dashboard:graphicsCoresTemperature",
  "Battery": "dashboard:batteryTemperature"
};
export function showSensor(sensor: Sensor) {
  return !(sensor.id.startsWith("disk:") && sensor.external !== true && typeof sensor.metric?.value !== "number");
}
function isSecondary(sensor: Sensor) {
  return sensor.id === "smc:Tg0P" || [
    "Display / SoC voltage regulator", "Auxiliary voltage regulator", "Ambient",
    "NAND CH0 temp", "NAND flash",
  ].includes(sensor.label);
}
function isPMU(sensor: Sensor) {
  return /^PMU\d*\b/i.test(sensor.label);
}
export function sensorName(sensor: Sensor, t: typeof translate): string {
  const pmu = sensor.label.match(/^(PMU\d*)\s+(tdie|tdev|tcal)(\d*)$/i);
  if (pmu) {
    const domain = pmu[1].toUpperCase(), index = pmu[3];
    if (pmu[2].toLowerCase() === "tcal") return t("dashboard:pmuCalibration", { domain });
    if (index) return t(pmu[2].toLowerCase() === "tdie" ? "dashboard:pmuDie" : "dashboard:pmuDevice", { domain, index });
  }
  return sensor.mappingReference && sensorNames[sensor.label]
    ? t(sensorNames[sensor.label])
    : !sensor.id.startsWith("smc:") ? sensor.label : t("dashboard:rawSensor", { id: sensor.label });
}
export function Temperatures({ sensors = [] }: { sensors?: Sensor[] | null }) {
  const { t, number } = useI18n();
  const valueText = (value?: number) => typeof value === "number" ? `${number(value, { maximumFractionDigits: 1 })} °C` : t("common:unknown");
  const readable = (sensor: Sensor) => sensorName(sensor, t);
  const visibleSensors = (sensors ?? []).filter(showSensor);
  const displayed = new Map<string, Sensor>();
  for (const sensor of visibleSensors) {
    const key = sensor.family ? `family:${sensor.family}` : sensor.id;
    const previous = displayed.get(key);
    if (!previous || (sensor.metric?.value ?? -Infinity) > (previous.metric?.value ?? -Infinity)) displayed.set(key, sensor);
  }
  const primary = Array.from(displayed.values()).filter(sensor => !isPMU(sensor) && !isSecondary(sensor));
  const secondary = Array.from(displayed.values()).filter(isSecondary);
  const pmu = Array.from(displayed.values()).filter(isPMU);
  const rows = (items: Sensor[]) => items.map(sensor => <li key={sensor.id}>
    <div className="temperature-name"><span>{readable(sensor)}</span>
      {isPMU(sensor) && <small>{sensor.label}</small>}
      {sensor.id.startsWith("disk:") && <small>{t(sensor.external ? "dashboard:externalDrive" : "dashboard:internalDrive")}</small>}
      {typeof sensor.metric?.value !== "number" && <small>{sensor.metric?.status === "permissionDenied" ? t("common:permissionDenied") : t(sensor.id.startsWith("disk:") ? "dashboard:driveUnavailable" : "common:unknown")}</small>}
    </div>
    <strong>{valueText(sensor.metric?.value)}</strong><Ring value={sensor.metric?.value} />
  </li>);
  const categories = [["cpu", "dashboard:cpuTemperature"], ["graphics", "dashboard:gpuTemperature"], ["storage", "dashboard:storageTemperature"]] as const;
  return <section className="card temperature-panel">
    <h2><DashboardIcon type="temperature" />{t("dashboard:temperature")}</h2>
    <div className="temperature-summary">
      {categories.map(([category, key]) => {
        const values = visibleSensors.filter(s => group(s) === category && typeof s.metric?.value === "number").map(s => s.metric!.value!);
        const peak = values.length ? Math.max(...values) : undefined;
        return <Ring key={category} value={peak}><span>{t(key)}</span><strong>{valueText(peak)}</strong><small>{t("dashboard:highestReading")}</small></Ring>;
      })}
    </div>
    <p className="temperature-caption">{t("dashboard:ringScale")}</p>
    <ul className="temperature-list">{rows(primary)}</ul>
    <div className="sensor-foldouts">
    {secondary.length > 0 && <details className="secondary-sensors">
      <summary>{t("dashboard:otherTemperatures", { count: number(secondary.length) })}</summary>
      <ul className="temperature-list">{rows(secondary)}</ul>
    </details>}
    {pmu.length > 0 && <details className="pmu-panel">
      <summary>{t("dashboard:pmuReadings", { count: number(pmu.length) })}</summary>
      <p className="pmu-caption">{t("dashboard:pmuIntro")}</p>
      <dl className="pmu-guide">
        <dt>tdie</dt><dd>{t("dashboard:pmuDieHelp")}</dd>
        <dt>tdev</dt><dd>{t("dashboard:pmuDeviceHelp")}</dd>
        <dt>tcal</dt><dd>{t("dashboard:pmuCalibrationHelp")}</dd>
      </dl>
      <p className="pmu-caption">{t("dashboard:pmuReadingHelp")}</p>
      <ul className="temperature-list">{rows(pmu)}</ul>
      <div className="sensor-references">
        <a href="https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift" target="_blank" rel="noreferrer">{t("dashboard:pmuReference")}</a>
        <a href="https://github.com/ryyansafar/MacMonitor/blob/main/SENSORS.md" target="_blank" rel="noreferrer">{t("dashboard:sensorReference")}</a>
      </div>
    </details>}
    {!visibleSensors.length && <p>{t("dashboard:noSensors")}</p>}
    <details><summary>{t("dashboard:sensorDetails")}</summary>
      <p>{t("dashboard:sensorBoundary")}</p>
      <p><a href="https://github.com/ryyansafar/MacMonitor/blob/main/SENSORS.md" target="_blank" rel="noreferrer">{t("dashboard:sensorReference")}</a></p>
      {visibleSensors.map(sensor => <p key={sensor.id}>{readable(sensor)} · {sensor.id} · {sensor.metric?.source} · {sensor.metric?.status ? t(("common:" + sensor.metric.status) as MessageKey) : ""}</p>)}
    </details>
    </div>
  </section>;
}
