import { test, expect } from "@playwright/test";
import { spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { createConnection } from "node:net";
import path from "node:path";
let process: ChildProcess, base: string, root: string;
async function control(command: string): Promise<any> {
  return new Promise((resolve, reject) => {
    const socket = createConnection(root + "/run/control.sock");
    let data = "";
    socket.on("connect", () =>
      socket.write(JSON.stringify({ command }) + "\n"),
    );
    socket.on("data", (chunk) => {
      data += chunk;
      if (data.endsWith("\n")) {
        socket.end();
        resolve(JSON.parse(data));
      }
    });
    socket.on("error", reject);
  });
}
test.beforeAll(async () => {
  root = mkdtempSync("/private/tmp/cmm-browser.");
  const project = path.resolve("..");
  process = spawn(project + "/.build/debug/MonitorAgent", [
    "--data-root",
    root,
    "--web-root",
    project + "/web/dist",
    "--port",
    "0",
  ]);
  base = await new Promise((resolve, reject) => {
    process.stderr!.on("data", (data) => {
      const match = String(data).match(/ready at (http:\/\/[^\s]+)/);
      if (match) resolve(match[1]);
    });
    process.on("exit", (code) => reject(Error("Agent exited " + code)));
  });
});
test.afterAll(async () => {
  if (process) {
    process.kill("SIGTERM");
    await new Promise((resolve) => process.on("exit", resolve));
  }
  rmSync(root, { recursive: true, force: true });
});
test("three languages preserve credentials and use one event stream", async ({
  page,
}) => {
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const streams = new Set<string>();
  page.on("request", (request) => {
    if (request.url().includes("/events?")) streams.add(request.url());
  });
  const ticket = await control("setup");
  await page.goto(ticket.url);
  await page.getByLabel("Username", { exact: true }).fill("browser-owner");
  await page
    .getByLabel("Password (12–128 characters)", { exact: true })
    .fill("browser-password-12345");
  await page.locator("header select").selectOption("zh-Hans");
  await expect(page.getByLabel("用户名", { exact: true })).toHaveValue(
    "browser-owner",
  );
  await expect(
    page.getByLabel("密码（12–128 字符）", { exact: true }),
  ).toHaveValue("browser-password-12345");
  await page.getByRole("button", { name: "继续", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "概览", exact: true }),
  ).toBeVisible();
  await expect(page.locator(".metric strong").first()).not.toHaveText(
    "不可用",
    { timeout: 10000 },
  );
  await page.locator("header select").selectOption("zh-Hant");
  await expect(
    page.getByRole("button", { name: "概覽", exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "應用", exact: true }).click();
  await expect(page.locator("tbody tr").first()).toBeVisible();
  await page.getByRole("button", { name: "歷史", exact: true }).click();
  await expect(page.locator("canvas").first()).toBeVisible();
  await page.locator("header select").selectOption("en");
  await expect(
    page.getByRole("button", { name: "Overview", exact: true }),
  ).toBeVisible();
  expect(streams.size).toBe(1);
  expect(errors).toEqual([]);
  await page.reload();
  await expect(
    page.getByRole("button", { name: "Overview", exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Sign out", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Sign in", exact: true }),
  ).toBeVisible();
});
