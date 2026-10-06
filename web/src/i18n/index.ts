import { useSyncExternalStore } from "react";
import { languages, type Language } from "./generated/registry";
import type { MessageKey, MessageParameters } from "./generated/types";
export { languages };
type Plural = {
  type: "plural";
  argument: string;
  forms: Record<string, string>;
};
type Dictionary = Record<string, string | Plural>;
let current: Language = "en",
  requestedLanguage: Language = "en",
  generation = 0,
  resourceRevision = 0;
let dictionaries: Record<string, Dictionary> = {},
  english: Record<string, Dictionary> = {};
const subscribers = new Set<() => void>();
const inflight = new Map<string, Promise<Dictionary>>();
const requiredNamespaces = new Set(["common", "errors"]);
const notify = () => subscribers.forEach((fn) => fn());
function match(value: string): Language | undefined {
  const lower = value.toLowerCase();
  const exact = languages.find(
    (l) =>
      l.tag.toLowerCase() === lower ||
      l.aliases.some((a) => a.toLowerCase() === lower),
  );
  if (exact) return exact.tag;
  if (lower.startsWith("zh-"))
    return lower.includes("hant") ? "zh-Hant" : "zh-Hans";
  return languages.find((l) => l.tag === value.split("-")[0])?.tag;
}
export function preferredLanguage(): Language {
  let stored: string | null = null;
  try {
    stored = localStorage.getItem("language");
  } catch {}
  return (
    (stored && match(stored)) ||
    navigator.languages.map(match).find(Boolean) ||
    "en"
  );
}
async function load(tag: Language, namespace: string): Promise<Dictionary> {
  const cache = tag === "en" ? english : tag === current ? dictionaries : {};
  if (cache[namespace]) return cache[namespace];
  const key = tag + ":" + namespace;
  if (inflight.has(key)) return inflight.get(key)!;
  const language = languages.find((l) => l.tag === tag)!;
  const url = language.resources[namespace as keyof typeof language.resources];
  if (!url) throw Error("Unknown namespace");
  const promise = fetch(url)
    .then(async (r) => {
      if (!r.ok) throw Error("Language unavailable");
      return (await r.json()) as Dictionary;
    })
    .finally(() => inflight.delete(key));
  inflight.set(key, promise);
  return promise;
}
export async function selectLanguage(
  tag: Language,
  namespaces: string[] = ["common", "auth", "errors"],
) {
  requestedLanguage = tag;
  namespaces.forEach((ns) => requiredNamespaces.add(ns));
  const revision = ++generation;
  const needed = [
    ...new Set([
      ...requiredNamespaces,
      ...Object.keys(dictionaries),
    ]),
  ];
  const fallback = await Promise.all(needed.map((ns) => load("en", ns)));
  const translated =
    tag === "en"
      ? fallback
      : await Promise.all(needed.map((ns) => load(tag, ns)));
  if (revision !== generation) return;
  english = Object.fromEntries(needed.map((ns, i) => [ns, fallback[i]]));
  dictionaries = Object.fromEntries(needed.map((ns, i) => [ns, translated[i]]));
  current = tag;
  const meta = languages.find((l) => l.tag === tag)!;
  document.documentElement.lang = tag;
  document.documentElement.dir = meta.direction;
  try {
    localStorage.setItem("language", tag);
  } catch {}
  resourceRevision++;
  notify();
}
export async function ensureNamespaces(namespaces: string[]) {
  return selectLanguage(requestedLanguage, namespaces);
}
export function translate<K extends MessageKey>(
  key: K,
  ...args: keyof MessageParameters[K] extends never
    ? []
    : [MessageParameters[K]]
): string {
  const [ns, name] = key.split(":");
  if (!dictionaries[ns] && !english[ns])
    return (dictionaries.common?.loading as string) || "Loading…";
  const message = dictionaries[ns]?.[name] ?? english[ns]?.[name];
  const parameters = (args[0] ?? {}) as Record<string, string | number>;
  let text = typeof message === "string" ? message : undefined;
  if (message && typeof message === "object") {
    const count = parameters[message.argument];
    if (
      typeof count !== "number" ||
      !Number.isInteger(count) ||
      count < 0 ||
      count > 2147483647
    )
      throw Error("Invalid plural count");
    text =
      message.forms[new Intl.PluralRules(current).select(count)] ??
      message.forms.other;
  }
  if (!text)
    return (
      (dictionaries.common?.error as string) ||
      "Something went wrong. Please retry."
    );
  return text
    .replaceAll("{{", "\u0001")
    .replaceAll("}}", "\u0002")
    .replace(/\{(\w+)\}/g, (_, p) => {
      const value = parameters[p];
      if (
        typeof value !== "string" &&
        !(
          typeof message === "object" &&
          message.argument === p &&
          typeof value === "number"
        )
      )
        throw Error("Invalid translation parameter");
      return String(value);
    })
    .replaceAll("\u0001", "{")
    .replaceAll("\u0002", "}");
}
export function useI18n() {
  useSyncExternalStore(
    (fn) => {
      subscribers.add(fn);
      return () => {
        subscribers.delete(fn);
      };
    },
    () => resourceRevision,
  );
  const language = current;
  return {
    t: translate,
    language,
    number: (value: number, options?: Intl.NumberFormatOptions) =>
      new Intl.NumberFormat(language, options).format(value),
    date: (value: string | number) =>
      new Intl.DateTimeFormat(language, {
        dateStyle: "short",
        timeStyle: "medium",
      }).format(new Date(value)),
  };
}
export function errorMessage(code: string) {
  const key = "errors:" + code;
  const [ns, name] = key.split(":");
  return (dictionaries[ns]?.[name] ??
    english[ns]?.[name] ??
    dictionaries.common?.error ??
    "Something went wrong. Please retry.") as string;
}
