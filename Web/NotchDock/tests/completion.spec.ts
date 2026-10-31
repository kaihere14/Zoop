import { expect, test, type Page } from "@playwright/test";

async function seed(page: Page, progress = 96, sound = true, secondProgress = 40) {
  await page.addInitScript(({ progress, sound, secondProgress }) => {
    const tasks = [
      { id: "keyboard", title: "Find your next keyboard", domain: "rtings.com", file: "mechanical_keyboards.md", kind: "keyboards", progress },
      { id: "weekend", title: "A little weekend escape", domain: "travel.google.com", file: "weekend_getaway.md", kind: "travel", progress: secondProgress },
      { id: "paused", title: "Research your idea", domain: "notion.so", file: "research_notes.md", kind: "research", progress: 40 },
    ].map(t => ({ ...t, prompt: "Compare options", steps: ["Research", "Compare", "Report"], status: "paused" }));
    localStorage.setItem("zoop-notch-demo-v1", JSON.stringify({ tasks, messages: [], sound }));
    const original = AudioBufferSourceNode.prototype.start;
    AudioBufferSourceNode.prototype.start = function (...args: Parameters<typeof original>) {
      const data = document.documentElement.dataset;
      data.voiceStarts = String(Number(data.voiceStarts || 0) + 1);
      data.activeVoices = String(Number(data.activeVoices || 0) + 1);
      data.maxVoices = String(Math.max(Number(data.maxVoices || 0), Number(data.activeVoices)));
      this.addEventListener("ended", () => { data.activeVoices = String(Number(data.activeVoices) - 1); }, { once: true });
      return original.apply(this, args);
    };
  }, { progress, sound, secondProgress });
}

async function resume(page: Page, id: string) {
  await page.locator(`[data-task-id="${id}"]`).click();
  await page.getByRole("button", { name: "Resume", exact: true }).click();
}

test("background completion speaks once, celebrates, and opens the specific report", async ({ page }, info) => {
  await seed(page, 92);
  const audio = page.waitForResponse(response => response.url().endsWith("/audio/completion.mp3") && response.ok());
  await page.goto("/");
  await page.getByRole("button", { name: /Live Activities/ }).click();
  await audio;
  await resume(page, "keyboard");
  await resume(page, "weekend");
  await page.getByRole("button", { name: "Minimize Zoop" }).click();
  await expect(page.getByRole("status", { name: "2 tasks working", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "View completed task: Find your next keyboard" })).toBeVisible();
  await expect(page.locator(".completion-toast")).toHaveClass(/is-speaking/);
  await expect(page.locator(".notch-anchor").getByRole("img", { name: "Zoop is done", exact: true })).toBeVisible();
  await expect(page.getByRole("status", { name: "1 task working", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Open Zoop", exact: true })).toBeVisible();
  await page.screenshot({ path: `/tmp/zoop-${info.project.name}-completion.png` });
  const card = await page.locator(".completion-toast").boundingBox();
  const notch = await page.locator(".notch-frame").boundingBox();
  expect(card!.y).toBeGreaterThan(notch!.y + notch!.height);
  expect(card!.x).toBeGreaterThanOrEqual(0);
  expect(card!.x + card!.width).toBeLessThanOrEqual(page.viewportSize()!.width);
  await expect(page.locator("html")).toHaveAttribute("data-voice-starts", "1");
  await expect(page.locator(".completion-toast")).not.toHaveClass(/is-speaking/);
  await expect(page.locator(".notch-anchor").getByRole("img", { name: "Zoop is cooking", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "View completed task: Find your next keyboard" }).click();
  await expect(page.getByRole("button", { name: "Save report" })).toBeVisible();
  await expect(page.locator(".completion-toast")).toHaveCount(0);
  await expect(page.locator("html")).toHaveAttribute("data-voice-starts", "1");
});

test("active interaction is quiet and old completions never replay after refresh", async ({ page }) => {
  await seed(page);
  await page.goto("/");
  await page.getByRole("button", { name: /Live Activities/ }).click();
  await resume(page, "keyboard");
  await expect.poll(() => page.evaluate(() => JSON.parse(localStorage.getItem("zoop-notch-demo-v1")!).tasks.find((t: { id: string }) => t.id === "keyboard").status)).toBe("complete");
  await expect(page.locator(".completion-toast")).toHaveCount(0);
  await expect(page.locator("html")).not.toHaveAttribute("data-voice-starts");
  // A fresh page restores the actual saved completion without the initial seed script.
  const snapshot = await page.evaluate(() => localStorage.getItem("zoop-notch-demo-v1"));
  const fresh = await page.context().newPage();
  await fresh.addInitScript(snapshot => localStorage.setItem("zoop-notch-demo-v1", snapshot!), snapshot);
  await fresh.goto("/");
  await fresh.getByRole("button", { name: "Minimize Zoop" }).click();
  await expect(fresh.locator(".completion-toast")).toHaveCount(0);
  await expect(fresh.locator(".notch-anchor").getByRole("img", { name: "Zoop is sleeping", exact: true })).toBeVisible();
  await fresh.close();
});

test("muted completions queue separately and reset clears pending alerts", async ({ page }) => {
  await seed(page, 92, false, 92);
  await page.goto("/");
  await page.getByRole("button", { name: /Live Activities/ }).click();
  await resume(page, "keyboard");
  await resume(page, "weekend");
  await page.getByRole("button", { name: "Minimize Zoop" }).click();
  await expect(page.getByRole("button", { name: "View completed task: Find your next keyboard" })).toBeVisible();
  await expect(page.getByText("+1 more ready")).toBeVisible();
  await expect(page.locator(".working-count")).toHaveCount(0);
  await expect(page.locator("html")).not.toHaveAttribute("data-voice-starts");
  await page.getByRole("button", { name: "Dismiss task notification" }).click();
  await expect(page.getByRole("button", { name: "View completed task: A little weekend escape" })).toBeVisible();
  await page.getByRole("button", { name: "Open Zoop", exact: true }).click();
  await page.getByRole("button", { name: "Reset demo" }).click();
  await expect(page.locator(".completion-toast")).toHaveCount(0);
  await expect(page.locator(".notch-anchor").getByRole("img", { name: "Zoop is sleeping", exact: true })).toBeVisible();
});

test("queued voices play once each without overlapping and retire automatically", async ({ page }) => {
  await seed(page, 92, true, 92);
  await page.goto("/");
  await page.getByRole("button", { name: /Live Activities/ }).click();
  await resume(page, "keyboard");
  await resume(page, "weekend");
  await page.getByRole("button", { name: "Minimize Zoop" }).click();
  await expect(page.getByRole("button", { name: "View completed task: Find your next keyboard" })).toBeVisible();
  await expect(page.locator("html")).toHaveAttribute("data-voice-starts", "1");
  await expect(page.getByRole("button", { name: "View completed task: A little weekend escape" })).toBeVisible();
  await expect(page.locator("html")).toHaveAttribute("data-voice-starts", "2");
  await expect(page.locator("html")).toHaveAttribute("data-max-voices", "1");
  await expect(page.locator(".completion-toast")).toHaveCount(0);
  await expect(page.locator("html")).toHaveAttribute("data-voice-starts", "2");
});

test("an idle open drawer receives a card with reduced motion", async ({ page }) => {
  await seed(page, 96, false);
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/");
  await page.getByRole("button", { name: /Live Activities/ }).click();
  await resume(page, "keyboard");
  const now = await page.evaluate(() => Date.now());
  await page.clock.setSystemTime(now + 16_000);
  await expect(page.getByRole("button", { name: "View completed task: Find your next keyboard" })).toBeVisible();
  const card = await page.locator(".completion-toast").boundingBox();
  expect(card!.y + card!.height).toBeLessThanOrEqual(page.viewportSize()!.height);
  expect(card!.x + card!.width).toBeLessThanOrEqual(page.viewportSize()!.width);
  await page.getByRole("button", { name: "Dismiss task notification" }).click();
  await expect(page.locator(".completion-toast")).toHaveCount(0);
  await expect(page.locator(".notch-anchor").getByRole("img", { name: "Zoop is sleeping", exact: true })).toBeVisible();
});
