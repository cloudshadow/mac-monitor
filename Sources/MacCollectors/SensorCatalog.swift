import Foundation

/// Reference names from ryyansafar/MacMonitor SENSORS.md (M2). These are reference
/// attributions, not a claim that this project's target hardware has been validated.
public struct SensorDefinition: Sendable {
  public let key: String, label: String, category: String, family: String?
  public init(_ key: String, _ label: String, _ category: String, family: String? = nil) {
    self.key = key; self.label = label; self.category = category; self.family = family
  }
}
public enum SensorCatalog {
  public static let reference = "https://raw.githubusercontent.com/ryyansafar/MacMonitor/main/SENSORS.md"
  public static let definitions: [SensorDefinition] = {
    var values = [
      SensorDefinition("TCMz", "CPU die hotspot", "cpu"),
      SensorDefinition("TCMb", "CPU die core maximum", "cpu"),
      SensorDefinition("TCHP", "CPU / charger proximity", "system"),
      SensorDefinition("TRDX", "GPU die hotspot", "graphics"),
      SensorDefinition("TVm0", "Unified memory", "memory"),
      SensorDefinition("Tm0B", "Unified memory", "memory"),
      SensorDefinition("TMVR", "Memory voltage regulator", "vrm"),
      SensorDefinition("T5SP", "SSD controller", "storage"),
      SensorDefinition("Ts1P", "SSD proximity", "storage"),
      SensorDefinition("TsOP", "SSD proximity", "storage"),
      SensorDefinition("TH0T", "NAND flash", "storage"),
      SensorDefinition("TH0x", "NAND flash", "storage"),
      SensorDefinition("TPMP", "SoC package", "system"),
      SensorDefinition("TPSP", "SoC surface", "system"),
      SensorDefinition("TAOL", "Airflow", "ambient"),
      SensorDefinition("Ta09", "Ambient", "ambient"),
      SensorDefinition("TW0P", "Wi-Fi", "wireless"),
      SensorDefinition("TIOP", "Thunderbolt controller", "system"),
      SensorDefinition("TDBP", "Display backlight proximity", "system"),
      SensorDefinition("TDeL", "Display panel", "system"),
      SensorDefinition("TVD0", "Display / SoC voltage regulator", "vrm"),
      SensorDefinition("TVM0", "Memory rail voltage regulator", "vrm"),
      SensorDefinition("TVMr", "Memory voltage regulator", "vrm"),
      SensorDefinition("TVMC", "Memory voltage regulator controller", "vrm"),
      SensorDefinition("TVA0", "Auxiliary voltage regulator", "vrm"),
    ]
    for suffix in "0123456789abcdefghijklmnopqrs" {
      values.append(SensorDefinition("Tp0" + String(suffix), "CPU performance cores", "cpu", family: "performance"))
    }
    for suffix in "456" { values.append(SensorDefinition("Te0" + String(suffix), "CPU efficiency cores", "cpu", family: "efficiency")) }
    // Ts0* is SoC, not the SSD proximity family Ts1P/TsOP.
    for suffix in "KLMNOPQRSTUVWXYZabc" {
      values.append(SensorDefinition("Ts0" + String(suffix), "SoC thermal array", "system", family: "soc"))
    }
    for suffix in "efghijklmnopqr" { values.append(SensorDefinition("Tg0" + String(suffix), "GPU cores", "graphics", family: "graphics")) }
    for suffix in "012" { values.append(SensorDefinition("TB" + String(suffix) + "T", "Battery", "battery", family: "battery")) }
    // Existing discovery keys remain visible if the reference does not assign them a role.
    for key in ["TC0D", "TC0P", "Tp0T", "Tp0P", "Tp1P", "Tg0P", "TG0D"] where !values.contains(where: { $0.key == key }) {
      values.append(SensorDefinition(key, key, "unknown"))
    }
    return values
  }()
  public static func definition(_ key: String) -> SensorDefinition? { definitions.first { $0.key == key } }
}
