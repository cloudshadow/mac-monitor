import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { parseJSON, signature, validate, root } from "./validate.mjs";
test("duplicate properties are rejected at any depth", () => {
  assert.throws(() => parseJSON('{"a":{"x":1,"x":2}}'));
  assert.deepEqual(parseJSON('{"a":"quoted \\\" key", "b":[1,2]}'), {
    a: 'quoted " key',
    b: [1, 2],
  });
});
test("ordinary parameter names do not infer numeric types", () => {
  assert.deepEqual(signature("Wait {seconds} seconds"), {
    params: ["seconds"],
  });
  assert.deepEqual(signature("{{escaped}} {name}"), { params: ["name"] });
  assert.throws(() =>
    signature({
      type: "plural",
      argument: "count",
      forms: { one: "{count} item", other: "items" },
    }),
  );
});
test("published language completeness and automatic fourth-language registration", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cmm-i18n-"));
  try {
    for (const tag of ["en", "zh-Hans", "zh-Hant"])
      fs.cpSync(path.join(root, "locales", tag), path.join(dir, tag), {
        recursive: true,
      });
    fs.cpSync(path.join(dir, "en"), path.join(dir, "ja"), { recursive: true });
    fs.writeFileSync(
      path.join(dir, "ja", "locale.json"),
      JSON.stringify({
        tag: "ja",
        nativeName: "日本語",
        englishName: "Japanese",
        aliases: [],
        direction: "ltr",
        status: "published",
      }),
    );
    assert.equal(validate(dir).languages.length, 4);
    fs.writeFileSync(path.join(dir, "ja", "auth.json"), "{}");
    assert.throws(() => validate(dir), /Missing/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
