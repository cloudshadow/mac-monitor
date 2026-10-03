import { defineConfig } from "@playwright/test";
export default defineConfig({
  testDir: "tests",
  workers: 1,
  timeout: 30000,
  use: {
    headless: true,
    launchOptions: {
      executablePath:
        process.env.CMM_CHROME ??
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    },
    screenshot: "only-on-failure",
  },
  reporter: "list",
});
