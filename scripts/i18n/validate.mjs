import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
export const root = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
export function parseJSON(text) {
  const tokens =
    text.match(
      /"(?:\\.|[^"\\])*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null|[{}\[\],:]/g,
    ) ?? [];
  let index = 0;
  function value() {
    const t = tokens[index++];
    if (t === "{" || t === "[") {
      const end = t === "{" ? "}" : "]",
        keys = new Set();
      if (tokens[index] === end) {
        index++;
        return;
      }
      while (index < tokens.length) {
        if (t === "{") {
          const key = JSON.parse(tokens[index++]);
          if (keys.has(key)) throw Error(`Duplicate key: ${key}`);
          keys.add(key);
          if (tokens[index++] !== ":") throw Error("Invalid JSON");
        }
        value();
        if (tokens[index] === end) {
          index++;
          return;
        }
        if (tokens[index++] !== ",") throw Error("Invalid JSON");
      }
      throw Error("Invalid JSON");
    }
  }
  value();
  return JSON.parse(text);
}
export function params(text) {
  return [
    ...new Set(
      [
        ...text
          .replaceAll("{{", "")
          .replaceAll("}}", "")
          .matchAll(/\{([A-Za-z][A-Za-z0-9_]*)\}/g),
      ].map((m) => m[1]),
    ),
  ].sort();
}
export function signature(message) {
  if (typeof message === "string" && message.trim())
    return { params: params(message) };
  if (
    message?.type === "plural" &&
    typeof message.argument === "string" &&
    message.forms?.other
  ) {
    const sets = Object.values(message.forms).map(params);
    if (
      sets.some((s) => s.join() !== sets[0].join()) ||
      !sets[0].includes(message.argument)
    )
      throw Error("Plural parameters differ");
    return { params: sets[0], count: message.argument };
  }
  throw Error("Invalid message");
}
export function validate(directory = path.join(root, "locales")) {
  const tags = fs
    .readdirSync(directory)
    .filter((tag) => fs.existsSync(path.join(directory, tag, "locale.json")))
    .sort();
  const namespaces = fs
      .readdirSync(path.join(directory, "en"))
      .filter((x) => x.endsWith(".json") && x !== "locale.json")
      .sort(),
    aliases = new Set(),
    result = [];
  const read = (tag, file) =>
    parseJSON(fs.readFileSync(path.join(directory, tag, file), "utf8"));
  const base = Object.fromEntries(
    namespaces.map((file) => [file, read("en", file)]),
  );
  for (const tag of tags) {
    const meta = read(tag, "locale.json");
    if (
      meta.tag !== tag ||
      Intl.getCanonicalLocales(tag)[0] !== tag ||
      !["published", "draft"].includes(meta.status) ||
      !["ltr", "rtl"].includes(meta.direction) ||
      !meta.nativeName ||
      !meta.englishName ||
      !Array.isArray(meta.aliases)
    )
      throw Error(`Invalid metadata: ${tag}`);
    for (const alias of [tag, ...meta.aliases]) {
      const canonical = Intl.getCanonicalLocales(alias)[0].toLowerCase();
      if (aliases.has(canonical)) throw Error(`Duplicate alias ${alias}`);
      aliases.add(canonical);
    }
    const data = {};
    for (const file of namespaces) {
      const resource = read(tag, file);
      for (const key of Object.keys(resource)) {
        if (!(key in base[file]))
          throw Error(`Unknown key ${tag}/${file}:${key}`);
        const a = signature(base[file][key]),
          b = signature(resource[key]);
        if (JSON.stringify(a) !== JSON.stringify(b))
          throw Error(`Parameter mismatch ${tag}/${file}:${key}`);
        if (b.count) {
          const categories = new Intl.PluralRules(tag).resolvedOptions()
            .pluralCategories;
          for (const category of categories)
            if (!resource[key].forms[category])
              throw Error(`Missing plural ${category}`);
        }
      }
      if (meta.status === "published")
        for (const key of Object.keys(base[file]))
          if (!(key in resource)) throw Error(`Missing ${tag}/${file}:${key}`);
      data[file.slice(0, -5)] = resource;
    }
    result.push({ meta, data });
  }
  return {
    languages: result,
    namespaces: namespaces.map((x) => x.slice(0, -5)),
    base,
  };
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const result = validate();
  console.log(`Validated ${result.languages.length} languages`);
}
