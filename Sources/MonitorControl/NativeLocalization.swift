import Foundation
import MonitorCore

enum NativeLocalization {
  static let resources: [JSONValue] = {
    let packaged = Bundle.main.url(
      forResource: "MacMonitor_MonitorControl", withExtension: "bundle"
    ).flatMap(Bundle.init(url:))
    let bundle = packaged ?? Bundle.module
    guard let url = bundle.url(forResource: "native-languages", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let value = try? JSONDecoder().decode(JSONValue.self, from: data)
    else { return [] }
    return value.array
  }()
  static var languages: [JSONValue] { resources.map { $0["meta"] } }
  static func text(_ key: String, parameters: [String: String] = [:]) -> String {
    let preference =
      UserDefaults.standard.string(forKey: "language") ?? Locale.preferredLanguages.first ?? "en"
    let english = resources.first { $0["meta"]["tag"].string == "en" }
    let selected =
      resources.first { value in
        value["meta"]["tag"].string == preference
          || value["meta"]["aliases"].array.contains(.string(preference))
      } ?? english
    var message = selected?["messages"][key] ?? .null
    if message == .null { message = english?["messages"][key] ?? .null }
    var result = message.string ?? "Could not complete this action."
    if let argument = message["argument"].string, let count = Int32(parameters[argument] ?? ""),
      count >= 0
    {
      let forms = message["forms"]
      let rules = selected?["pluralRules"] ?? .null
      let small = rules["small"].array
      let index = count <= 200 ? Int(count) : 100 + Int(count % 100)
      let category =
        count > 200 && count % 1_000_000 == 0
        ? rules["million"].string : index < small.count ? small[index].string : "other"
      result = forms[category ?? "other"].string ?? forms["other"].string ?? result
    }
    result = result.replacingOccurrences(of: "{{", with: "\u{1}").replacingOccurrences(
      of: "}}", with: "\u{2}")
    // Replace once so an inserted string containing another placeholder stays literal.
    let expression = try! NSRegularExpression(pattern: "\\{([A-Za-z][A-Za-z0-9_]*)\\}")
    let original = result as NSString
    for match in expression.matches(
      in: result, range: NSRange(location: 0, length: original.length)
    ).reversed() {
      let name = original.substring(with: match.range(at: 1))
      result = (result as NSString).replacingCharacters(
        in: match.range, with: parameters[name] ?? "")
    }
    return result.replacingOccurrences(of: "\u{1}", with: "{").replacingOccurrences(
      of: "\u{2}", with: "}")
  }
}
