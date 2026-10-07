import { defineConfig, devices } from "@playwright/test";
import config from "./playwright.config";
export default defineConfig({
  ...config,
  grep: /dark dashboard|dark sign-in/,
  use: { ...config.use, ...devices["iPhone 13"], browserName: "webkit", launchOptions: {} },
});
