import fs from "node:fs";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  mergeUiPrefs,
  prefsFile,
  readUiPrefs,
  SETUP_CHOICE_PROMPT,
} from "../src/config/ui-prefs.js";
import { selectReviewer } from "../src/review/provider.js";
import { cleanup, isolateStateDir } from "./helpers.js";

describe("ui prefs", () => {
  const dirs: string[] = [];

  afterEach(() => {
    for (const dir of dirs) cleanup(dir);
    dirs.length = 0;
    delete process.env.C2C_STATE_DIR;
  });

  it("starts empty and is not bound to a workspace", () => {
    dirs.push(isolateStateDir());
    const prefs = readUiPrefs();
    expect(prefs.reviewProvider).toBe("deepseek");
    expect(prefs.developerModeEnabled).toBe(false);
    expect(prefs.setupMode).toBeNull();
    expect(prefs.remembered).toEqual({ developerMode: false, setupMode: false });
    expect(prefs.setupChoicePrompt).toBe(SETUP_CHOICE_PROMPT);
    expect(prefs.setupChoicePrompt).toContain("AI 自动化配置（预览版）");
    expect(prefs.setupChoicePrompt).toContain("手动教学配置");
    expect(prefs.setupChoicePrompt).toContain("请回复「1」或「2」");
  });

  it("remembers developer mode as on only, never as off", () => {
    dirs.push(isolateStateDir());
    const saved = mergeUiPrefs({ developerModeEnabled: true });
    expect(saved.developerModeEnabled).toBe(true);
    const raw = JSON.parse(fs.readFileSync(prefsFile(), "utf8")) as { developerModeEnabled?: boolean };
    expect(raw.developerModeEnabled).toBe(true);
    expect(JSON.stringify(raw)).not.toMatch(/token|pairing|secret/i);
  });

  it("saves setup mode without dropping developer mode", () => {
    dirs.push(isolateStateDir());
    mergeUiPrefs({ developerModeEnabled: true });
    const next = mergeUiPrefs({ setupMode: "manual" });
    expect(next.developerModeEnabled).toBe(true);
    expect(next.setupMode).toBe("manual");
    const auto = mergeUiPrefs({ setupMode: "auto" });
    expect(auto.setupMode).toBe("auto");
    expect(auto.developerModeEnabled).toBe(true);
  });

  it("rejects an unknown setup mode", () => {
    dirs.push(isolateStateDir());
    expect(() => mergeUiPrefs({ setupMode: "browser" as "auto" })).toThrow(/setup-mode/);
    expect(readUiPrefs().setupMode).toBeNull();
  });

  it("ignores a hand-edited developerModeEnabled false", () => {
    dirs.push(isolateStateDir());
    fs.mkdirSync(path.dirname(prefsFile()), { recursive: true });
    fs.writeFileSync(
      prefsFile(),
      JSON.stringify({ developerModeEnabled: false, setupMode: "auto", updatedAt: "2026-01-01T00:00:00.000Z" }),
      { mode: 0o600 }
    );
    expect(readUiPrefs().developerModeEnabled).toBe(false);
    expect(readUiPrefs().remembered.developerMode).toBe(false);
    expect(readUiPrefs().setupMode).toBe("auto");
  });

  it("persists the default reviewer independently of ChatGPT setup preferences", () => {
    dirs.push(isolateStateDir());
    mergeUiPrefs({ setupMode: "manual", developerModeEnabled: true });
    const changed = mergeUiPrefs({ reviewProvider: "chatgpt" });
    expect(changed.reviewProvider).toBe("chatgpt");
    expect(changed.setupMode).toBe("manual");
    expect(changed.developerModeEnabled).toBe(true);
    expect(readUiPrefs().reviewProvider).toBe("chatgpt");
    mergeUiPrefs({ setupMode: "auto" });
    expect(readUiPrefs().reviewProvider).toBe("chatgpt");
    expect(mergeUiPrefs({ reviewProvider: "deepseek" }).reviewProvider).toBe("deepseek");
  });

  it("uses DeepSeek for legacy preference files without losing their setup choices", () => {
    dirs.push(isolateStateDir());
    fs.writeFileSync(prefsFile(), JSON.stringify({
      developerModeEnabled: true, setupMode: "manual", updatedAt: "2026-01-01T00:00:00.000Z",
    }));
    const before = fs.readFileSync(prefsFile(), "utf8");
    const prefs = readUiPrefs();
    expect(prefs.reviewProvider).toBe("deepseek");
    expect(prefs.developerModeEnabled).toBe(true);
    expect(prefs.setupMode).toBe("manual");
    expect(fs.readFileSync(prefsFile(), "utf8")).toBe(before);
  });

  it("does not persist an explicit per-task GPT override as a new default", () => {
    dirs.push(isolateStateDir());
    mergeUiPrefs({ reviewProvider: "deepseek", setupMode: "manual" });
    const before = fs.readFileSync(prefsFile(), "utf8");
    expect(selectReviewer({ request: "用 GPT 评审这个问题", defaultProvider: readUiPrefs().reviewProvider }))
      .toBe("chatgpt");
    expect(readUiPrefs().reviewProvider).toBe("deepseek");
    expect(fs.readFileSync(prefsFile(), "utf8")).toBe(before);
    expect(selectReviewer({ request: "继续处理另一个任务", defaultProvider: readUiPrefs().reviewProvider }))
      .toBe("deepseek");
  });

  it("rejects an invalid reviewer patch without changing saved preferences", () => {
    dirs.push(isolateStateDir());
    mergeUiPrefs({ reviewProvider: "chatgpt", setupMode: "manual" });
    const before = fs.readFileSync(prefsFile(), "utf8");
    expect(() => mergeUiPrefs({ reviewProvider: "unknown" as "deepseek" })).toThrow(/review-provider/);
    expect(fs.readFileSync(prefsFile(), "utf8")).toBe(before);
    expect(readUiPrefs().reviewProvider).toBe("chatgpt");
  });
});
