import { defineConfig } from "@playwright/test";

const externalPreview = process.env.ZOOP_PREVIEW_URL;

export default defineConfig({
  testDir: "./tests",
  timeout: 60_000,
  expect: { timeout: 10_000 },
  fullyParallel: true,
  workers: 2,
  reporter: "list",
  use: { baseURL: externalPreview || "http://127.0.0.1:3017", trace: "retain-on-failure", screenshot: "only-on-failure" },
  projects: [
    { name: "desktop", use: { browserName: "chromium", viewport: { width: 1440, height: 900 } } },
    { name: "mobile", use: { browserName: "chromium", viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true } },
  ],
  webServer: externalPreview ? undefined : { command: "npm run dev -- --port 3017", url: "http://127.0.0.1:3017", env: { ZOOP_TEST_MODE: "1" }, reuseExistingServer: !process.env.CI, timeout: 120_000 },
});
