import { test, expect } from "@playwright/test";
import { spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, rmSync, readFileSync } from "node:fs";
import path from "node:path";
const version = readFileSync(new URL('../../Resources/Control-Info.plist', import.meta.url), 'utf8').match(/CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/)![1];
let process: ChildProcess, base: string, root: string;
test.beforeAll(async () => {
  root = mkdtempSync("/private/tmp/cmm-browser.");
  const project = path.resolve("..");
  process = spawn(globalThis.process.env.CMM_TEST_AGENT ?? project + "/.build/debug/MonitorAgent", [
    "--data-root",
    root,
    "--web-root",
    globalThis.process.env.CMM_TEST_WEB_ROOT ?? project + "/web/dist",
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
  page.on("pageerror", (error) => { errors.push(error.message); console.error(error.stack); });
  const streams = new Set<string>();
  page.on("request", (request) => {
    if (request.url().includes("/events?")) streams.add(request.url());
  });
  await page.goto(base);
  await expect(page.locator("header .version")).toHaveText("v" + version);
  await expect(page.locator(".brand")).toHaveText("Mac Monitor");
  await expect(page.locator(".brand-mark")).toHaveJSProperty("naturalWidth", 1254);
  await expect(page).toHaveTitle("Mac Monitor");
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
    { id: "disk:missing", label: "Unavailable internal SSD", external: false, metric: { status: "unsupported" } },
    { id: "disk:denied", label: "Denied internal SSD", external: false, metric: { status: "permissionDenied" } },
    { id: "smc:TMVR", label: "Memory voltage regulator", mappingReference: "M2", metric: { value: 54, status: "ok" } },
    { id: "smc:TVD0", label: "Display / SoC voltage regulator", mappingReference: "M2", metric: { value: 60, status: "ok" } },
    { id: "smc:TVA0", label: "Auxiliary voltage regulator", mappingReference: "M2", metric: { value: 40, status: "ok" } },
    { id: "smc:Ta09", label: "Ambient", mappingReference: "M2", metric: { value: 30, status: "ok" } },
    { id: "smc:Tg0P", label: "Tg0P", metric: { value: 50, status: "ok" } },
    { id: "hid:NAND CH0 temp", label: "NAND CH0 temp", metric: { value: 44, status: "ok" } },
    { id: "smc:TH0T", label: "NAND flash", mappingReference: "M2", metric: { value: 42, status: "ok" } },
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
  await expect(page.locator(".temperature-panel > .temperature-list li")).toHaveCount(13);
  await expect(page.locator(".temperature-panel > .temperature-list")).toContainText("58.3 °C");
  await expect(page.locator(".temperature-panel > .temperature-list")).toContainText("External drive");
  await expect(page.locator(".temperature-panel > .temperature-list")).toContainText("Temperature is not exposed");
  await expect(page.locator(".temperature-summary")).toContainText("58.4 °C");
  await expect(page.locator(".temperature-summary")).not.toContainText("59 °C");
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(360);
  await expect(page.locator(".temperature-summary")).not.toContainText("95 °C");
  await expect(page.locator(".temperature-summary")).not.toContainText("96 °C");
  await expect(page.locator(".temperature-summary")).not.toContainText("97 °C");
  await expect(page.locator(".temperature-summary")).not.toContainText("98 °C");
  await page.locator("header select").selectOption("zh-Hans");
  await expect(page.locator(".temperature-panel > .temperature-list")).toContainText("CPU 芯片热点");
  await expect(page.locator(".temperature-panel > .temperature-list")).toContainText("内存供电轨");
  await expect(page.locator(".temperature-panel > .temperature-list")).toContainText("统一内存");
  await expect(page.locator(".temperature-panel")).not.toContainText("Unavailable internal SSD");
  await expect(page.locator(".temperature-panel")).not.toContainText("Denied internal SSD");
  await expect(page.locator(".temperature-panel > .temperature-list .temperature-name > span").filter({ hasText: /^内存$/ })).toHaveCount(1);
  await expect(page.locator(".secondary-sensors")).not.toHaveAttribute("open", "");
  await expect(page.locator(".secondary-sensors li")).toHaveCount(6);
  await expect(page.locator(".secondary-sensors li").first()).not.toBeVisible();
  await page.locator(".secondary-sensors summary").click();
  for (const name of ["显示／SoC 供电", "辅助供电", "环境", "传感器 Tg0P", "NAND CH0 temp", "NAND 闪存"]) {
    await expect(page.locator(".secondary-sensors .temperature-name > span").filter({ hasText: name })).toBeVisible();
  }
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(360);
  await page.locator(".secondary-sensors summary").click();
  await page.locator(".temperature-panel").screenshot({ path: "../artifacts/temperature-phone.png" });
});

test("reload updates dashboard labels after delayed translations arrive", async ({ page }) => {
  await page.setViewportSize({ width: 360, height: 800 });
  await page.addInitScript(() => {
    localStorage.setItem("language", "zh-Hans");
    (window as any).translationErrors = [];
    new MutationObserver(() => {
      const text = document.querySelector("main")?.textContent ?? "";
      if (text.includes("操作失败，请重试。"))
        (window as any).translationErrors.push("missing translation");
      if ((text.match(/Loading…|加载中|載入中/g) ?? []).length > 1)
        (window as any).translationErrors.push("repeated loading labels");
    }).observe(document, { childList: true, subtree: true, characterData: true });
  });
  await page.route("**/locales/*/dashboard.json", async route => {
    await new Promise(resolve => setTimeout(resolve, 1000));
    await route.continue();
  });
  await page.route("**/api/v1/**", async route => {
    const pathname = new URL(route.request().url()).pathname;
    if (pathname.endsWith("/events")) {
      await route.fulfill({ contentType: "text/event-stream", body: ": connected\n\n" });
      return;
    }
    const body = pathname.endsWith("/auth/status") ? { status: "authenticated" }
      : pathname.endsWith("/auth/session") ? { csrfToken: "fixture" }
      : pathname.endsWith("/snapshot") ? { thermalState: 0, sensors: null }
      : pathname.endsWith("/viewers") ? { viewerId: "fixture" }
      : pathname.endsWith("/recent/system") ? { series: { "cpu.total": [] } } : {};
    await route.fulfill({ json: body });
  });
  await page.goto(base);
  await expect(page.locator(".metric h2").first()).toHaveText("CPU %", { timeout: 5000 });
  expect(await page.evaluate(() => (window as any).translationErrors)).toEqual([]);
  await page.reload();
  await expect(page.locator(".metric h2").first()).toHaveText("CPU %", { timeout: 5000 });
  await expect(page.locator("main")).not.toContainText("操作失败，请重试。");
  expect(await page.evaluate(() => (window as any).translationErrors)).toEqual([]);
});

test("phone errors use one visible toast that can close and expires", async ({ page }) => {
  await page.setViewportSize({ width: 360, height: 800 });
  await page.clock.install();
  let authenticated = false;
  await page.route("**/api/v1/**", async route => {
    const pathname = new URL(route.request().url()).pathname;
    if (pathname.endsWith("/events")) {
      await route.fulfill({ contentType: "text/event-stream", body: ": connected\n\n" });
      return;
    }
    if (pathname.endsWith("/auth/login") && !authenticated) {
      await route.fulfill({ status: 401, json: { error: { code: "invalidCredentials" } } });
      return;
    }
    if (pathname.endsWith("/recent/system") || pathname.endsWith("/apps") || pathname.endsWith("/history/system")) {
      await route.fulfill({ status: 503, json: { error: { code: "serviceUnavailable" } } });
      return;
    }
    const body = pathname.endsWith("/auth/status") ? { status: "loginRequired" }
      : pathname.endsWith("/auth/session") || pathname.endsWith("/auth/login") ? { csrfToken: "fixture" }
      : pathname.endsWith("/snapshot") ? { thermalState: 0, sensors: [] }
      : pathname.endsWith("/viewers") ? { viewerId: "fixture" } : { rows: [] };
    await route.fulfill({ json: body });
  });
  await page.goto(base);
  await page.getByLabel("Username", { exact: true }).fill("browser-owner");
  await page.getByLabel("Password (12–128 characters)", { exact: true }).fill("bad-password");
  await page.getByRole("button", { name: "Continue", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveCount(1);
  await expect(page.locator("main [role=alert]")).toHaveCount(0);
  await page.getByRole("button", { name: "Close", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveCount(0);
  authenticated = true;
  await page.getByRole("button", { name: "Continue", exact: true }).click();
  await expect(page.locator(".overview-grid")).toBeVisible();
  await page.clock.runFor(500);
  await expect(page.getByRole("alert")).toHaveCount(1);
  await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
  const bounds = await page.getByRole("alert").boundingBox();
  expect(bounds!.y).toBeGreaterThanOrEqual(0);
  expect(bounds!.y + bounds!.height).toBeLessThanOrEqual(800);
  expect(bounds!.x).toBeGreaterThanOrEqual(0);
  expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(360);
  await page.getByRole("button", { name: "Close", exact: true }).click();
  await page.getByRole("button", { name: "Applications", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveCount(1);
  await page.getByRole("button", { name: "Close", exact: true }).click();
  await page.getByRole("button", { name: "History", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveCount(1);
  await page.clock.runFor(6100);
  await expect(page.getByRole("alert")).toHaveCount(0);
});

test("dark dashboard fills desktop and keeps every page within mobile viewports", async ({ page }) => {
  const errors: string[] = [];
  page.on("pageerror", error => errors.push(error.message));
  const sensors = [
    { id: "smc:TCMz", label: "CPU die hotspot", mappingReference: "M2", category: "cpu", metric: { value: 58.4, status: "ok" }, seriesId: "temperature.cpu" },
    { id: "hid:Graphics", label: "Graphics", metric: { value: 55.1, status: "ok" } },
    { id: "disk:external", label: "External SSD with a very long device name SOLIDIGM SSDPFKKW010X7", category: "storage", external: true, metric: { status: "unsupported" } },
    { id: "hid:PMU tdie1", label: "PMU tdie1", metric: { value: 95, status: "ok" }, seriesId: "temperature.pmu1" },
    { id: "hid:PMU2 tdie8", label: "PMU2 tdie8", metric: { value: 96, status: "ok" } },
    { id: "hid:PMU tdev2", label: "PMU tdev2", metric: { value: 97, status: "ok" } },
    { id: "hid:PMU tcal", label: "PMU tcal", metric: { value: 98, status: "ok" } },
    { id: "hid:PMU unknown", label: "PMU unknown", metric: { value: 99, status: "ok" } },
  ];
  const points = [{ bucketStartUtc: 1, bucketEndUtc: 2, avg: 15 }, { bucketStartUtc: 2, bucketEndUtc: 3, avg: 30 }];
  await page.route("**/api/v1/**", async route => {
    const pathname = new URL(route.request().url()).pathname;
    if (pathname.endsWith("/events")) {
      await route.fulfill({ contentType: "text/event-stream", body: ": connected\n\n" });
      return;
    }
    const body = pathname.endsWith("/auth/status") ? { status: "authenticated" }
      : pathname.endsWith("/auth/session") ? { csrfToken: "fixture" }
      : pathname.endsWith("/snapshot") ? { sensors, thermalState: 0, cpu: { value: 34, status: "ok" }, nonIdlePercent: { value: 65, status: "ok" }, appWiredPercent: { value: 45, status: "ok" }, appMemoryBytes: 5 * 1024 ** 3, wiredBytes: 2.2 * 1024 ** 3, compressorBytes: 1024 ** 3, serviceOverhead: { cpuPercentCore: 0.25, physicalFootprintBytes: 32 * 1048576 }, networkInterfaces: [{ id: "en0", receivedBytesPerSecond: { value: 10 }, sentBytesPerSecond: { value: 20 } }, { id: "en8", receivedBytesPerSecond: { value: 30 }, sentBytesPerSecond: { value: 40 } }], swapUsedBytes: { value: 128 * 1048576, status: "ok" }, gpu: { value: 15, status: "ok" }, physicalMemoryBytes: 16 * 1024 ** 3, freeBytes: 3 * 1024 ** 3 }
      : pathname.endsWith("/viewers") ? { viewerId: "fixture" }
      : pathname.endsWith("/recent/system") || pathname.endsWith("/history/system") ? { series: { "cpu.total": points }, recordingStatus: { enabled: true } }
      : pathname.endsWith("/history/apps") ? { rows: [] }
      : pathname.endsWith("/history/status") ? { diskBytes: 1048576 }
      : pathname.endsWith("/apps") ? { rows: [{ id: "app", name: "A very long application name that should wrap inside its table column", cpuPercentCore: 123.4, physicalFootprintBytes: 1234567890, diskReadBytesPerSecond: 23456789, diskWriteBytesPerSecond: 34567890 }], coverage: { readable: 1, attempted: 1 } }
      : pathname.endsWith("/processes") ? { rows: [{ processKey: "process", name: "A very long process name", pid: 1234, cpuPercentCore: 100 }] } : {};
    if (pathname.endsWith("/apps") && new URL(route.request().url()).searchParams.get("limit") === "5") body.rows = Array.from({ length: 5 }, (_, index) => ({ ...body.rows[0], id: "fixture-" + index }));
    await route.fulfill({ json: body });
  });
  await page.route("**/locales/zh-Hans/common.json", async route => {
    await new Promise(resolve => setTimeout(resolve, 400));
    await route.continue();
  });
  await page.goto(base);
  await expect(page.getByRole("button", { name: "Applications", exact: true })).toBeVisible();
  await page.locator("header select").selectOption("zh-Hans");
  await page.getByRole("button", { name: "Applications", exact: true }).click();
  await expect(page.getByRole("button", { name: "概览", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "概览", exact: true }).click();
  await expect(page.locator(".temperature-summary")).toContainText("58.4 °C");
  await expect(page.locator(".temperature-summary")).not.toContainText("95 °C");
  await page.locator(".pmu-panel summary").click();
  await expect(page.locator(".pmu-panel")).toContainText("电源管理单元");
  await expect(page.locator(".pmu-panel")).toContainText("不是 CPU 核心编号");
  await expect(page.locator(".pmu-panel")).toContainText("PMU2 芯片测点 8");
  await expect(page.locator(".pmu-panel")).toContainText("PMU 设备测点 2");
  await expect(page.locator(".pmu-panel")).toContainText("PMU 校准参考");
  await expect(page.locator(".pmu-panel")).toContainText("PMU unknown");
  expect(await page.evaluate(() => getComputedStyle(document.documentElement).colorScheme)).toBe("dark");
  await expect(page.locator(".overview-metrics .card")).toHaveCount(5);
  await expect(page.locator(".overview-metrics")).not.toContainText("可用");
  await expect(page.locator(".overview-metrics .metric").nth(1).locator("strong")).toHaveText("45%");
  await expect(page.locator(".overview-metrics .overhead-card")).toContainText("0.25 %");
  await expect(page.locator(".overview-metrics .overhead-card")).toContainText("32 MiB");
  await expect(page.locator(".io-card")).not.toContainText("en0");
  await expect(page.locator(".io-card")).not.toContainText("en8");
  await expect(page.locator("header nav button")).toHaveCount(3);
  await expect(page.getByRole("button", { name: "设置", exact: true })).toHaveCount(0);
  expect(await page.locator(".metric-icon").first().evaluate(el => getComputedStyle(el).color)).toBe("rgb(0, 153, 255)");
  await expect(page.locator(".trend-card")).toHaveCount(3);
  await expect(page.locator(".ranking-card")).toHaveCount(2);
  await expect(page.locator(".memory-bar span")).toHaveCount(4);
  for (const width of [320, 390, 768, 1440, 1920]) {
    await page.setViewportSize({ width, height: 900 });
    expect(await page.locator(".brand").evaluate(el => Boolean(el.compareDocumentPosition(document.querySelector("header nav")!) & Node.DOCUMENT_POSITION_FOLLOWING))).toBe(true);
    if (width > 1000) {
      expect(await page.locator(".brand-block").evaluate(el => el.getBoundingClientRect().right)).toBeLessThan(await page.locator("header nav").evaluate(el => el.getBoundingClientRect().left));
    } else {
      expect(await page.locator(".brand-block").evaluate(el => el.getBoundingClientRect().bottom)).toBeLessThanOrEqual(await page.locator("header nav").evaluate(el => el.getBoundingClientRect().top));
    }
    for (const name of ["概览", "应用", "历史"]) {
      await page.getByRole("button", { name, exact: true }).click();
      await expect(page.locator("main")).not.toContainText("操作失败，请重试。");
      expect(await page.evaluate(() => document.documentElement.scrollWidth), `${name} at ${width}px`).toBeLessThanOrEqual(width);
      expect(await page.locator("main").evaluate(el => el.getBoundingClientRect().width)).toBe(width);
      if (name === "应用") {
        await expect(page.locator("tbody tr")).toHaveCount(1);
        if (width <= 390) expect(await page.locator(".table-scroll").evaluate(el => el.scrollWidth > el.clientWidth)).toBe(true);
      }
      if (name === "历史") {
        await expect(page.locator("canvas")).toBeVisible();
        await expect(page.getByLabel("指标")).toContainText("PMU 芯片测点 1");
      }
    }
    await page.getByRole("button", { name: "概览", exact: true }).click();
    if (width === 390 || width === 1920) {
      await page.locator(".pmu-panel summary").click();
      if (width > 1100) expect(await page.evaluate(() => document.documentElement.scrollHeight)).toBeLessThanOrEqual(900);
      await page.evaluate(() => window.scrollTo(0, 0));
      await page.screenshot({ path: `../artifacts/dark-dashboard-${width}.png`, fullPage: true });
    }
  }
  for (const viewport of [{ width: 1280, height: 720 }, { width: 1366, height: 768 }, { width: 1672, height: 941 }, { width: 1920, height: 1080 }]) {
    await page.setViewportSize(viewport);
    await expect(page.locator(".ranking-card").first().locator("tbody tr")).toHaveCount(5);
    for (const table of await page.locator(".ranking-card .table-scroll").all()) expect(await table.evaluate(el => el.scrollHeight - el.clientHeight), "all five ranking rows fit").toBeLessThanOrEqual(1);
    expect(await page.evaluate(() => document.documentElement.scrollHeight), `desktop fits ${viewport.width}x${viewport.height}`).toBeLessThanOrEqual(viewport.height);
    for (const selector of [".overview-metrics", ".temperature-panel", ".trend-grid", ".ranking-grid", ".memory-composition", ".memory-card", ".io-card"]) {
      const rect = await page.locator(selector).evaluate(el => ({ top: el.getBoundingClientRect().top, bottom: el.getBoundingClientRect().bottom }));
      expect(rect.top).toBeGreaterThanOrEqual(0);
      expect(rect.bottom).toBeLessThanOrEqual(viewport.height);
    }
    if (viewport.width === 1672) {
      await page.locator(".pmu-panel summary").click();
      await expect(page.locator(".ranking-card").first().locator("tbody tr")).toHaveCount(5);
      await page.screenshot({ path: "../artifacts/dashboard-one-screen.png" });
      await page.locator(".pmu-panel summary").click();
    }
  }
  await page.locator("header select").selectOption("zh-Hant");
  await page.locator(".pmu-panel summary").click();
  await expect(page.locator(".pmu-panel")).toContainText("電源管理單元");
  await page.locator("header select").selectOption("en");
  await expect(page.locator(".pmu-panel")).toContainText("Power Management Unit");
  expect(errors).toEqual([]);
});

test("dark sign-in form fits a narrow phone and landscape viewport", async ({ page }) => {
  await page.route("**/api/v1/auth/status", route => route.fulfill({ json: { status: "loginRequired" } }));
  await page.goto(base);
  await page.locator("header select").selectOption("zh-Hans");
  for (const viewport of [{ width: 320, height: 640 }, { width: 390, height: 844 }, { width: 844, height: 390 }]) {
    await page.setViewportSize(viewport);
    await expect(page.getByRole("heading", { name: "登录", exact: true })).toBeVisible();
    await page.getByLabel("用户名", { exact: true }).fill("mobile-owner");
    await page.getByLabel("密码（12–128 字符）", { exact: true }).fill("mobile-password-12345");
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(viewport.width);
    expect(await page.getByLabel("用户名", { exact: true }).evaluate(el => el.getBoundingClientRect().width)).toBeGreaterThan(200);
  }
});
