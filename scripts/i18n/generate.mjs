import fs from "node:fs";
import path from "node:path";
import { root, validate, signature } from "./validate.mjs";
const { languages, namespaces } = validate(),
  published = languages.filter((x) => x.meta.status === "published"),
  base = languages.find((x) => x.meta.tag === "en").data;
const out = path.join(root, "web/src/i18n/generated");
fs.mkdirSync(out, { recursive: true });
const registry = published.map(({ meta }) => ({
  ...meta,
  resources: Object.fromEntries(
    namespaces.map((ns) => [ns, `/locales/${meta.tag}/${ns}.json`]),
  ),
}));
fs.writeFileSync(
  path.join(out, "registry.ts"),
  `// Generated; edit locales instead.\nexport const languages = ${JSON.stringify(registry, null, 2)} as const;\nexport type Language = typeof languages[number]['tag'];\n`,
);
const keys = [];
for (const ns of namespaces)
  for (const [key, message] of Object.entries(base[ns])) {
    const s = signature(message);
    keys.push(
      `  ${JSON.stringify(ns + ":" + key)}: {${s.params.map((p) => `${JSON.stringify(p)}: ${p === s.count ? "number" : "string"}`).join(";")}};`,
    );
  }
fs.writeFileSync(
  path.join(out, "types.ts"),
  `export interface MessageParameters {\n${keys.join("\n")}\n}\nexport type MessageKey = keyof MessageParameters;\n`,
);
for (const language of published) {
  const dir = path.join(root, "web/public/locales", language.meta.tag);
  fs.mkdirSync(dir, { recursive: true });
  for (const ns of namespaces)
    fs.writeFileSync(
      path.join(dir, ns + ".json"),
      JSON.stringify(language.data[ns]),
    );
}
const nativeDir = path.join(root, "Sources/MonitorControl/Resources");
fs.mkdirSync(nativeDir, { recursive: true });
const catalog = { sourceLanguage: "en", strings: {}, version: "1.0" };
function format(text, s) {
  return text
    .replaceAll("%", "%%")
    .replaceAll("{{", "\u0001")
    .replaceAll("}}", "\u0002")
    .replace(
      /\{(\w+)\}/g,
      (_, p) => `%${s.params.indexOf(p) + 1}$${p === s.count ? "d" : "@"}`,
    )
    .replaceAll("\u0001", "{")
    .replaceAll("\u0002", "}");
}
for (const [key, message] of Object.entries(base.native)) {
  const s = signature(message),
    localizations = {};
  for (const language of published) {
    const m = language.data.native[key];
    localizations[language.meta.tag] =
      typeof m === "string"
        ? { stringUnit: { state: "translated", value: format(m, s) } }
        : {
            variations: {
              plural: Object.fromEntries(
                Object.entries(m.forms).map(([form, text]) => [
                  form,
                  {
                    stringUnit: { state: "translated", value: format(text, s) },
                  },
                ]),
              ),
            },
          };
  }
  catalog.strings[key] = { localizations };
}
fs.writeFileSync(
  path.join(nativeDir, "Localizable.xcstrings"),
  JSON.stringify(catalog, null, 2),
);
// JSON is usable by SwiftPM command-line builds without Xcode catalog compilation.
fs.writeFileSync(
  path.join(nativeDir, "native-languages.json"),
  JSON.stringify(
    published.map((x) => {
      const rules = new Intl.PluralRules(x.meta.tag),
        small = Array.from({ length: 201 }, (_, i) => rules.select(i)),
        million = rules.select(1000000);
      for (const n of [
        201, 999, 1000, 10000, 100000, 1000000, 2000000, 2147483647,
      ]) {
        const selected =
          n <= 200
            ? small[n]
            : n % 1000000 === 0
              ? million
              : small[100 + (n % 100)];
        if (selected !== rules.select(n))
          throw Error("Native plural rule is not representable: " + x.meta.tag);
      }
      return {
        meta: x.meta,
        messages: x.data.native,
        pluralRules: { small, million },
      };
    }),
  ),
);
let swift =
  "// Generated from locales/native.json.\nimport Foundation\nenum NativeKeys {\n";
for (const [key, m] of Object.entries(base.native)) {
  const s = signature(m),
    name = key.replaceAll(/[^A-Za-z0-9]/g, "_");
  swift += `    static func ${name}(${s.params.map((p) => `${p}: ${p === s.count ? "Int32" : "String"}`).join(", ")}) -> String { NativeLocalization.text(${JSON.stringify(key)}, parameters: [${s.params.length ? s.params.map((p) => `${JSON.stringify(p)}: ${p === s.count ? `String(${p})` : p}`).join(", ") : ":"}]) }\n`;
}
swift += "}\n";
fs.writeFileSync(
  path.join(root, "Sources/MonitorControl/NativeKeys.swift"),
  swift,
);
console.log(`Generated ${published.length} published languages`);
