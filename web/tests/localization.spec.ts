import { test, expect } from "@playwright/test";
import { spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import path from "node:path";
let process: ChildProcess, base: string, root: string;
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
  await page.goto(base);
  await expect(page.getByRole("heading", { name: "Create your account", exact: true })).toBeVisible();
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
    { timeout: 20000 },
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

test("temperature readings and unavailable external drives fit a phone", async ({ page }) => {
  await page.setViewportSize({ width: 360, height: 800 });
  const sensors = [
    { id: "hid:CPU Performance Cores", label: "CPU Performance Cores", metric: { value: 58.3, status: "ok" } },
    { id: "hid:Graphics", label: "Graphics", metric: { value: 55.1, status: "ok" } },
    { id: "disk:internal", label: "APPLE SSD AP0512Z", category: "storage", external: false, metric: { value: 45, status: "ok" } },
    { id: "disk:external", label: "SOLIDIGM SSDPFKKW010X7", category: "storage", external: true, metric: { status: "unsupported" } },
    { id: "smc:Tp09", label: "Tp09", metric: { value: 59, status: "ok" } },
    { id: "smc:TCMz", label: "CPU die hotspot", category: "cpu", mappingReference: "M2", metric: { value: 58.4, status: "ok" } },
    { id: "hid:CPU proximity", label: "CPU proximity", metric: { value: 97, status: "ok" } },
    { id: "hid:Graphics VRM", label: "Graphics VRM", metric: { value: 98, status: "ok" } },
    { id: "smc:TCHP", label: "CPU / charger proximity", category: "system", mappingReference: "M2", metric: { value: 96, status: "ok" } },
    { id: "smc:TVM0", label: "Memory rail voltage regulator", category: "vrm", mappingReference: "M2", metric: { value: 95, status: "ok" } },
    { id: "smc:TVm0", label: "Unified memory", category: "memory", mappingReference: "M2", metric: { value: 55, status: "ok" } },
    { id: "smc:Tp01", label: "CPU performance cores", category: "cpu", family: "performance", mappingReference: "M2", metric: { value: 56, status: "ok" } },
    { id: "smc:Tp02", label: "CPU performance cores", category: "cpu", family: "performance", mappingReference: "M2", metric: { value: 57, status: "ok" } },
  ];
  await page.route("**/api/v1/**", async route => {
    const url = new URL(route.request().url());
    if (url.pathname.endsWith("/events")) { await route.abort(); return; }
    const body = url.pathname.endsWith("/auth/status") ? { status: "authenticated" }
      : url.pathname.endsWith("/auth/session") ? { csrfToken: "fixture" }
      : url.pathname.endsWith("/snapshot") ? { sensors, thermalState: 0 }
      : url.pathname.endsWith("/viewers") ? { viewerId: "fixture" }
      : url.pathname.endsWith("/recent/system") ? { series: { "cpu.total": [] } } : {};
    await route.fulfill({ json: body });
  });
  await page.goto(base);
  await expect(page.locator(".temperature-list li")).toHaveCount(12);
  await expect(page.locator(".temperature-list")).toContainText("58.3 °C");
  await expect(page.locator(".temperature-list")).toContainText("External drive");
  await expect(page.locator(".temperature-list")).toContainText("Temperature is not exposed");
  await expect(page.locator(".temperature-summary")).toContainText("58.4 °C");
  await expect(page.locator(".temperature-summary")).not.toContainText("59 °C");
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(360);
  await expect(page.locator(".temperature-summary")).not.toContainText("95 °C");
  await expect(page.locator(".temperature-summary")).not.toContainText("96 °C");
  await expect(page.locator(".temperature-summary")).not.toContainText("97 °C");
  await expect(page.locator(".temperature-summary")).not.toContainText("98 °C");
  await page.locator("header select").selectOption("zh-Hans");
  await expect(page.locator(".temperature-list")).toContainText("CPU 芯片热点");
  await expect(page.locator(".temperature-list")).toContainText("内存供电轨");
  await expect(page.locator(".temperature-list")).toContainText("统一内存");
  await page.locator(".temperature-panel").screenshot({ path: "../artifacts/temperature-phone.png" });
});
