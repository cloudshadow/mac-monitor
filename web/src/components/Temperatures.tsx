import { useI18n } from "../i18n";
import type { MessageKey } from "../i18n/generated/types";
type Sensor = { id: string; label: string; category?: string; family?: string; mappingReference?: string; external?: boolean; metric?: { value?: number; status?: string; source?: string } };
// Group only descriptive names reported by the provider; opaque SMC keys stay unassigned.
function group(sensor: Sensor): string {
  if (["storage", "cpu", "graphics"].includes(sensor.category ?? "")) return sensor.category!;
  const label = sensor.label.toLowerCase();
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
export function Temperatures({ sensors = [] }: { sensors?: Sensor[] }) {
  const { t, number } = useI18n();
  const valueText = (value?: number) => typeof value === "number" ? `${number(value, { maximumFractionDigits: 1 })} °C` : t("common:unknown");
  const readable = (sensor: Sensor) => sensor.mappingReference && sensorNames[sensor.label] ? t(sensorNames[sensor.label]) : !sensor.id.startsWith("smc:") ? sensor.label : t("dashboard:rawSensor", { id: sensor.label });
  const displayed = new Map<string, Sensor>();
  for (const sensor of sensors) {
    const key = sensor.family ? `family:${sensor.family}` : sensor.id;
    const previous = displayed.get(key);
    if (!previous || (sensor.metric?.value ?? -Infinity) > (previous.metric?.value ?? -Infinity)) displayed.set(key, sensor);
  }
  const categories = [["cpu", "dashboard:cpuTemperature"], ["graphics", "dashboard:gpuTemperature"], ["storage", "dashboard:storageTemperature"]] as const;
  return <section className="card temperature-panel">
    <h2>{t("dashboard:temperature")}</h2>
    <div className="temperature-summary">
      {categories.map(([category, key]) => {
        const values = sensors.filter(s => group(s) === category && typeof s.metric?.value === "number").map(s => s.metric!.value!);
        const peak = values.length ? Math.max(...values) : undefined;
        return <Ring key={category} value={peak}><span>{t(key)}</span><strong>{valueText(peak)}</strong><small>{t("dashboard:highestReading")}</small></Ring>;
      })}
    </div>
    <p className="temperature-caption">{t("dashboard:ringScale")}</p>
    <ul className="temperature-list">
      {Array.from(displayed.values()).map(sensor => <li key={sensor.id}>
        <div className="temperature-name"><span>{readable(sensor)}</span>
          {sensor.id.startsWith("disk:") && <small>{t(sensor.external ? "dashboard:externalDrive" : "dashboard:internalDrive")}</small>}
          {typeof sensor.metric?.value !== "number" && <small>{sensor.metric?.status === "permissionDenied" ? t("common:permissionDenied") : t("dashboard:driveUnavailable")}</small>}
        </div>
        <strong>{valueText(sensor.metric?.value)}</strong><Ring value={sensor.metric?.value} />
      </li>)}
    </ul>
    {!sensors.length && <p>{t("dashboard:noSensors")}</p>}
    <details><summary>{t("dashboard:sensorDetails")}</summary>
      <p>{t("dashboard:sensorBoundary")}</p>
      <p><a href="https://github.com/ryyansafar/MacMonitor/blob/main/SENSORS.md" target="_blank" rel="noreferrer">{t("dashboard:sensorReference")}</a></p>
      {sensors.map(sensor => <p key={sensor.id}>{readable(sensor)} · {sensor.id} · {sensor.metric?.source} · {sensor.metric?.status ? t(("common:" + sensor.metric.status) as MessageKey) : ""}</p>)}
    </details>
  </section>;
}
