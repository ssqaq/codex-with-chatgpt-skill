import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { cleanup, makeTmpDir } from "./helpers.js";

const repo = fileURLToPath(new URL("../../", import.meta.url));
const bundle = path.join(repo, "bundled-skills/deepseek-consensus-review");
const scripts = path.join(bundle, "scripts");
const run = (file: string, args: string[]) => spawnSync(
  "pwsh", ["-NoProfile", "-NonInteractive", "-File", path.join(scripts, file), ...args],
  { encoding: "utf8", windowsHide: true, timeout: 20000 },
);

function activate(dir: string) {
  const result = run("activate_review.ps1", [
    "-TaskId", "new-task", "-SkillName", "deepseek-consensus-review",
    "-TaskName", "runtime tab identity regression", "-CodexThreadId", "new-thread", "-StateDir", dir,
  ]);
  expect(result.status, result.stderr).toBe(0);
}

function registry(runtime: string) {
  return {
    schemaVersion: 7,
    bindings: [{
      codexThreadId: "other-thread", owner: "other-thread", taskId: "other-task", activeTaskId: "other-task",
      status: "bound", deepseekSessionId: "official-chat:other-session-12345678",
      browserTabId: "4", browserRuntimeId: runtime,
      expectedMessageMarker: "CODEX-BINDING-other-thread", domMessageMarker: "CODEX-BINDING-other-thread",
    }],
  };
}

const bootstrapArgs = (dir: string, runtime: string) => [
  "-Action", "BeginBootstrap", "-TaskId", "new-task", "-CodexThreadId", "new-thread", "-StateDir", dir,
  "-BrowserSurface", "codex-in-app-sidebar", "-BrowserTabId", "4", "-BrowserRuntimeId", runtime,
  "-RuntimeEpoch", "1", "-TabMatchCount", "1", "-EvidenceSource", "dom",
  "-DomTargetUrl", "https://chat.deepseek.com/", "-DomSessionTitle", "DeepSeek - 探索未至之境",
  "-DomModel", "网页当前模型（合并升级版）", "-DomReasoning", "深度思考", "-DomSearch", "智能搜索",
  "-DomInputPresence", "present", "-DomInputEnabled", "enabled", "-DomMessagePresence", "absent",
  "-ExpectedMessageMarker", "CODEX-BINDING-new-thread",
];

describe("browser tab identity is scoped by runtime", () => {
  it("allows a reused numeric tab id in a different runtime", () => {
    const dir = makeTmpDir("runtime-tab-reuse");
    try {
      activate(dir);
      fs.writeFileSync(path.join(dir, "thread-bindings.json"), JSON.stringify(registry("old-runtime")));
      const result = run("session_binding.ps1", bootstrapArgs(dir, "new-runtime"));
      expect(result.status, result.stderr).toBe(0);
      const saved = JSON.parse(fs.readFileSync(path.join(dir, "thread-bindings.json"), "utf8"));
      expect(saved.bindings).toHaveLength(2);
      expect(saved.bindings.find((item: { codexThreadId: string }) => item.codexThreadId === "new-thread")?.browserRuntimeId).toBe("new-runtime");
    } finally {
      cleanup(dir);
    }
  });

  it("still rejects the same runtime and tab pair across threads", () => {
    const dir = makeTmpDir("runtime-tab-collision");
    try {
      activate(dir);
      fs.writeFileSync(path.join(dir, "thread-bindings.json"), JSON.stringify(registry("shared-runtime")));
      const result = run("session_binding.ps1", bootstrapArgs(dir, "shared-runtime"));
      expect(result.status).not.toBe(0);
      expect(`${result.stdout}\n${result.stderr}`).toContain("runtime + tab");
    } finally {
      cleanup(dir);
    }
  });
});
