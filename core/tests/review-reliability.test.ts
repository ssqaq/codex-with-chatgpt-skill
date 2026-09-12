import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { canExecuteReview, changeReview, newReview, readReview, recoverReview, reviewFile } from "../src/review/state.js";
import { observeReview, trackWait, waitProgress } from "../src/review/wait.js";
import { deepseekDependency } from "../src/review/deepseek.js";
import { Workspace } from "../src/workspace/manager.js";
import { cleanup, isolateStateDir, makeTmpDir } from "./helpers.js";

const repo = fileURLToPath(new URL("../../", import.meta.url));
const bundle = path.join(repo, "bundled-skills/deepseek-consensus-review");
const start = new Date("2026-09-12T00:00:00Z");
const at = (minutes: number) => new Date(+start + minutes * 60000);
const hash = (s: string) => createHash("sha256").update(s).digest("hex");
function session() {
  const s = newReview({ workspaceId: "workspace-test", threadId: "thread-test", taskId: "task-test", reviewProvider: "deepseek", reviewMode: "consensus", summary: "检查等待恢复" });
  return trackWait(s, { ...s, phase: "WAITING", round: 4, receiptStatus: "confirmed", chatUrl: "https://chat.deepseek.com/a/chat/s/test-session-123" }, start);
}
function evidence(s = session(), minutes = 1, extra = {}) {
  return { taskId: s.taskId, threadId: s.threadId, round: s.round, observedAt: at(minutes).toISOString(),
    observationId: `observation-${minutes}`, source: "codex-in-app-browser", conversationUrl: s.chatUrl,
    status: "thinking", ...extra };
}
function ps(script: string, args: string[]) {
  return spawnSync("pwsh", ["-NoProfile", "-NonInteractive", "-File", path.join(bundle, "scripts", script), ...args],
    { encoding: "utf8", timeout: 20000, windowsHide: true });
}
let dir: string;
beforeEach(() => { dir = isolateStateDir(); });
afterEach(() => { vi.restoreAllMocks(); cleanup(dir); vi.unstubAllEnvs(); });

describe("real-time wait accounting without pretending to inspect a page", () => {
  it("keeps the same origin across repeated syncs and process reload", () => {
    const s = session();
    expect(trackWait({ ...s, wait: undefined }, s, at(4)).wait?.startedAt).toBe(start.toISOString());
    changeReview(s.workspaceId, s.threadId, () => s);
    const loaded = readReview(s.workspaceId, s.threadId)!;
    const processRead = spawnSync(process.execPath, ["--import", "tsx", "--input-type=module", "-e",
      'import {readReview} from "./src/review/state.ts"; console.log(JSON.stringify(readReview("workspace-test","thread-test")));'],
      { cwd: path.join(repo, "core"), env: process.env, encoding: "utf8" });
    expect(processRead.status, processRead.stderr).toBe(0);
    expect(JSON.parse(processRead.stdout).wait.startedAt).toBe(s.wait!.startedAt);
    expect(trackWait(loaded, { ...loaded }, at(4)).wait?.startedAt).toBe(start.toISOString());
    expect(waitProgress(loaded, at(4)).minute).toBe(4);
    expect(waitProgress(loaded, at(4)).message).toContain("最近未能确认");
    expect(waitProgress(loaded, at(4)).message).not.toContain("未卡死");
  });
  it("reports each new minute, including 3 then 4, and suppresses duplicates", () => {
    const s = session();
    s.wait!.lastReportedMinute = 2;
    expect(waitProgress(s, at(3)).shouldReport).toBe(true);
    s.wait!.lastReportedMinute = 3;
    expect(waitProgress(s, at(3.9)).shouldReport).toBe(false);
    expect(waitProgress(s, at(4)).message).toContain("4 分钟");
    expect(waitProgress(s, at(4)).shouldReport).toBe(true);
  });
  it("does not pause after two identical browser observations; pauses after 10 idle minutes", () => {
    let s = session();
    for (const minute of [1, 2, 3]) s = observeReview(s, evidence(s, minute), at(minute));
    expect(waitProgress(s, at(3)).pauseReason).toBe("");
    expect(waitProgress(s, at(10)).pauseReason).toContain("10 分钟");
  });
  it("new reply content resets idle timeout but never resets total elapsed time", () => {
    const s = observeReview(session(), evidence(session(), 9, { progressFingerprint: hash("new reply content") }), at(9));
    expect(waitProgress(s, at(11)).minute).toBe(11);
    expect(waitProgress(s, at(11)).pauseReason).toBe("");
    expect(waitProgress(s, at(19)).pauseReason).not.toBe("");
  });
  it.each(["unavailable", "login-required"])("pauses immediately on %s without granting execution", status => {
    const s = observeReview(session(), evidence(session(), 1, { status }), at(1));
    expect(s.phase).toBe("BLOCKED");
    expect(canExecuteReview(s)).toBe(false);
  });
  it.each([{ threadId: "other" }, { taskId: "other" }, { round: 3 }, { source: "external-browser" },
    { conversationUrl: "https://chat.deepseek.com/a/chat/s/other-session" }, { observedAt: start.toISOString() }])(
    "rejects stale or unrelated observations %j", extra => {
      expect(() => observeReview(session(), evidence(session(), 3, extra), at(3))).toThrow();
    });
  it("ignores old and replayed observations and cancelled tasks", () => {
    const s = observeReview(session(), evidence(), at(1));
    expect(() => observeReview(s, evidence(), at(1))).toThrow();
    expect(() => observeReview({ ...s, phase: "CANCELLED" }, evidence(s, 2), at(2))).toThrow();
  });
  it("finished page is not consensus, and a new round gets a new clock", () => {
    const s = observeReview(session(), evidence(session(), 1, { status: "reply-ready" }), at(1));
    expect(canExecuteReview(s)).toBe(false);
    expect(waitProgress(s, at(15)).pauseReason).toBe("");
    expect(trackWait(s, { ...s, phase: "WAITING", round: 5 }, at(2)).wait?.startedAt).toBe(at(2).toISOString());
  });
});

describe("recover only the same task, never recover execution permission", () => {
  it("recovers corruption with time and round intact, preserves damaged file, then requires revalidation", () => {
    const s = session();
    changeReview(s.workspaceId, s.threadId, () => ({ ...s, phase: "READY", reviewerConsensus: true, codexConsensus: true, replyReceived: true }));
    const file = reviewFile(s.workspaceId, s.threadId);
    fs.writeFileSync(file, "broken-json");
    const recovered = recoverReview(s.workspaceId, s.threadId, s.taskId);
    expect(recovered.round).toBe(4);
    expect(recovered.wait?.startedAt).toBe(s.wait?.startedAt);
    expect(recovered.recoveryRequired).toBe(true);
    expect(canExecuteReview(recovered)).toBe(false);
    expect(fs.readdirSync(path.dirname(file)).some(name => name.endsWith(".damaged"))).toBe(true);
    expect(recovered.nextAction).toContain("第 4 轮");
  });
  it("does not read another task's last audit line", () => {
    const s = session();
    changeReview(s.workspaceId, s.threadId, () => s);
    fs.writeFileSync(reviewFile(s.workspaceId, s.threadId), "broken");
    expect(() => recoverReview(s.workspaceId, s.threadId, "other-task")).toThrow();
  });
  it("refuses missing or corrupt checkpoints and reports audit write errors", () => {
    const s = session();
    const file = reviewFile(s.workspaceId, s.threadId);
    changeReview(s.workspaceId, s.threadId, () => s);
    fs.writeFileSync(`${file}.checkpoint`, "invalid");
    fs.writeFileSync(file, "invalid");
    expect(() => recoverReview(s.workspaceId, s.threadId, s.taskId)).toThrow(/恢复记录/);
    fs.writeFileSync(file, JSON.stringify(s));
    fs.rmSync(`${file}.audit.jsonl`);
    fs.mkdirSync(`${file}.audit.jsonl`);
    expect(() => changeReview(s.workspaceId, s.threadId, prior => prior!)).toThrow();
  });
});

describe("packaged installation", () => {
  it("rolls back both skills when the second directory replacement fails and preserves the backups", async () => {
    const installer = path.join(repo, "scripts/install-review-skills.mjs");
    const { installReviewSkills } = await import(/* @vite-ignore */ installer);
    const root = path.join(dir, "rollback-skills");
    const names = ["deepseek-consensus-review", "deepseek-independent-review"];
    for (const name of names) {
      fs.mkdirSync(path.join(root, name), { recursive: true });
      fs.writeFileSync(path.join(root, name, "SKILL.md"), `old-${name}`);
    }
    const rename = fs.renameSync;
    const spy = vi.spyOn(fs, "renameSync").mockImplementation((from, to) => {
      if (String(from).includes(".c2c-stage-") && String(to) === path.join(root, names[1])) throw new Error("simulated locked directory");
      return rename(from, to);
    });
    expect(() => installReviewSkills(root)).toThrow("simulated locked directory");
    spy.mockRestore();
    for (const name of names) expect(fs.readFileSync(path.join(root, name, "SKILL.md"), "utf8")).toBe(`old-${name}`);
    const installed = installReviewSkills(root);
    expect(installed.ok).toBe(true);
    expect(installed.backups).toHaveLength(2);
    for (const backup of installed.backups) expect(fs.readFileSync(path.join(backup, "SKILL.md"), "utf8")).toMatch(/^old-/);
    expect(installReviewSkills(root, { check: true }).ok).toBe(true);
  });

  it("installs both real dependencies into an empty directory and detects missing or edited scripts", async () => {
    const root = path.join(dir, "skills");
    const run = (...args: string[]) => spawnSync(process.execPath, [path.join(repo, "scripts/install-review-skills.mjs"), "--skills-root", root, ...args], { encoding: "utf8" });
    expect(run().status).toBe(0);
    vi.stubEnv("C2C_REVIEW_SKILLS_ROOT", root);
    for (const mode of ["single", "consensus"] as const) expect(deepseekDependency(mode).available).toBe(true);
    fs.appendFileSync(path.join(root, "deepseek-consensus-review/scripts/send_review_round.ps1"), "\n# changed");
    expect(run("--check").status).toBe(1);
    expect(deepseekDependency("consensus").available).toBe(false);
    fs.rmSync(path.join(root, "deepseek-independent-review/scripts/review_checkpoint.ps1"));
    expect(deepseekDependency("single").missing).toContain("scripts/review_checkpoint.ps1");
    expect(run().status).toBe(0);
    expect(run("--check").status).toBe(0);
  });
});

describe("PowerShell entrypoints with synthetic browser evidence (no web sends)", () => {
  function fixture(extra = {}) {
    const message = "C1: check plan\nCODEX-BINDING-thread-test";
    const state = { taskId: "task-test", codexThreadId: "thread-test", skillName: "deepseek-consensus-review", reviewBatch: "C1", stateRevision: 1,
      taskTerminalStatus: "active", sessionBindingStatus: "bound", browserTabId: "test-tab", browserRuntimeId: "test-runtime", runtimeEpoch: 1,
      deepseekSessionId: "official-chat:test-session-123", conversationUrl: "https://chat.deepseek.com/a/chat/s/test-session-123", domMessageMarker: "CODEX-BINDING-thread-test", roundHistory: [] };
    fs.writeFileSync(path.join(dir, "task-test.json"), JSON.stringify(state));
    const e = { source: "codex-in-app-browser", observationId: "synthetic-unit-fixture", capturedAt: new Date().toISOString(),
      taskId: state.taskId, codexThreadId: state.codexThreadId, round: 1, messageFingerprint: hash(message), messagePresence: "absent",
      browserSurface: "codex-in-app-sidebar", browserTabId: state.browserTabId, browserRuntimeId: state.browserRuntimeId, runtimeEpoch: 1,
      tabMatchCount: 1, deepseekSessionId: state.deepseekSessionId, domTargetUrl: state.conversationUrl, domSessionTitle: "test-title",
      domMessageMarker: state.domMessageMarker, domModel: "网页当前模型（合并升级版）", domReasoning: "深度思考", domSearch: "智能搜索",
      domInputPresence: "present", domInputEnabled: "enabled", ...extra };
    fs.writeFileSync(path.join(dir, "message.txt"), message);
    fs.writeFileSync(path.join(dir, "evidence.json"), JSON.stringify(e));
    return { state, e };
  }
  const baseArgs = () => ["-TaskId", "task-test", "-CodexThreadId", "thread-test", "-StateDir", dir];
  function preflight(extra: string[] = []) {
    return ps("send_review_round.ps1", [...baseArgs(), "-RoundNumber", "1", "-MessageFile", path.join(dir, "message.txt"), "-EvidenceFile", path.join(dir, "evidence.json"), ...extra]);
  }
  it("valid preflight changes nothing and does not claim a send", () => {
    fixture();
    const before = fs.readFileSync(path.join(dir, "task-test.json"), "utf8");
    const result = preflight(["-CheckOnly"]);
    expect(result.status, result.stderr + result.stdout).toBe(0);
    expect(JSON.parse(result.stdout)).toMatchObject({ ok: true, sent: false, stage: "checked-only" });
    expect(fs.readFileSync(path.join(dir, "task-test.json"), "utf8")).toBe(before);
  });
  it.each([{ domInputEnabled: "disabled" }, { messagePresence: "present" }, { messagePresence: "unknown" },
    { browserTabId: "other-tab" }, { capturedAt: "2020-01-01T00:00:00Z" }, { domSearch: "off" }, { messageFingerprint: "wrong" }])(
    "refuses invalid page evidence before native state changes: %j", extra => {
      fixture(extra);
      const before = fs.readFileSync(path.join(dir, "task-test.json"), "utf8");
      const result = preflight(["-CheckOnly"]);
      expect(result.status).toBe(1);
      expect(JSON.parse(result.stdout).sent).toBe(false);
      expect(fs.readFileSync(path.join(dir, "task-test.json"), "utf8")).toBe(before);
    });
  it("does not invent authorization, nor echo a private native exception", () => {
    fixture();
    expect(JSON.parse(preflight().stdout).problems.join()).toContain("授权依据");
    const stub = path.join(dir, "stub/scripts");
    fs.mkdirSync(stub, { recursive: true });
    fs.writeFileSync(path.join(stub, "session_binding.ps1"), "throw 'DO-NOT-LOG-AUTH-DETAILS'\n");
    const result = preflight(["-AuthorizationEvidence", "test-only authorization", "-SkillRoot", path.dirname(stub)]);
    expect(result.status).toBe(1);
    expect(result.stdout).toContain("PrepareSend");
    expect(result.stdout + result.stderr).not.toContain("DO-NOT-LOG-AUTH-DETAILS");
  });
  it("native checkpoint excludes credentials and restores progress with the execution gate closed", () => {
    const { state } = fixture();
    fs.writeFileSync(path.join(dir, "task-test.json"), JSON.stringify({ ...state, leaseToken: "DO-NOT-SAVE", authorizationEvidence: "DO-NOT-SAVE" }));
    let result = ps("review_checkpoint.ps1", ["-Action", "Save", ...baseArgs()]);
    expect(result.status, result.stderr).toBe(0);
    expect(fs.readFileSync(path.join(dir, "task-test.checkpoint.json"), "utf8")).not.toContain("DO-NOT-SAVE");
    fs.writeFileSync(path.join(dir, "task-test.json"), "damaged");
    result = ps("review_checkpoint.ps1", ["-Action", "Restore", ...baseArgs()]);
    expect(result.status, result.stderr).toBe(0);
    const restored = JSON.parse(fs.readFileSync(path.join(dir, "task-test.json"), "utf8"));
    expect(restored.reviewBatch).toBe("C1");
    expect(restored.executionStatus).toBe("禁止修改");
    expect(restored.reviewRecoveryRequired).toBe(true);
    expect(preflight(["-CheckOnly"]).status).toBe(1);
  });
  it("native recovery revalidates the original page and refuses another session", () => {
    const { state, e } = fixture();
    const native = { ...state, lastMessageFingerprint: e.messageFingerprint };
    fs.writeFileSync(path.join(dir, "task-test.json"), JSON.stringify(native));
    expect(ps("review_checkpoint.ps1", ["-Action", "Save", ...baseArgs()]).status).toBe(0);
    fs.writeFileSync(path.join(dir, "task-test.json"), "damaged");
    expect(ps("review_checkpoint.ps1", ["-Action", "Restore", ...baseArgs()]).status).toBe(0);
    fs.writeFileSync(path.join(dir, "thread-bindings.json"), JSON.stringify({ bindings: [{ ...native, activeTaskId: "task-test", status: "bound" }] }));
    const restoredEvidence = { ...e, messagePresence: "present", domTargetUrl: "https://chat.deepseek.com/a/chat/s/wrong-session" };
    fs.writeFileSync(path.join(dir, "evidence.json"), JSON.stringify(restoredEvidence));
    const args = ["-Action", "Revalidate", ...baseArgs(), "-EvidenceFile", path.join(dir, "evidence.json")];
    expect(ps("review_checkpoint.ps1", args).status).not.toBe(0);
    fs.writeFileSync(path.join(dir, "evidence.json"), JSON.stringify({ ...restoredEvidence, domTargetUrl: state.conversationUrl }));
    const result = ps("review_checkpoint.ps1", args);
    expect(result.status, result.stderr).toBe(0);
    const after = JSON.parse(fs.readFileSync(path.join(dir, "task-test.json"), "utf8"));
    expect(after.reviewRecoveryRequired).toBe(false);
    expect(after.executionStatus).toBe("禁止修改");
    expect(after.sendAuthorization).toBe("none");
  });
  it("real activator writes a usable checkpoint", () => {
    const result = ps("activate_review.ps1", [...baseArgs(), "-SkillName", "deepseek-consensus-review"]);
    expect(result.status, result.stderr).toBe(0);
    const checkpoint = JSON.parse(fs.readFileSync(path.join(dir, "task-test.checkpoint.json"), "utf8"));
    expect(checkpoint.state.reviewBatch).toBe("C1");
    expect(checkpoint.state.taskId).toBe("task-test");
  });
  it("runs actual prepare/confirm/receipt scripts and keeps repeated normal waits alive", () => {
    const result = spawnSync("pwsh", ["-NoProfile", "-NonInteractive", "-File", path.join(repo, "core/tests/fixtures/review-native-smoke.ps1"),
      "-SkillRoot", bundle, "-StateDir", dir], { encoding: "utf8", timeout: 20000, windowsHide: true });
    expect(result.status, result.stderr + result.stdout).toBe(0);
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: true,
      synthetic: true,
      receiptConfirmed: true,
      acquireRecoveredUniqueTab: true,
      releaseRecoveredSurface: true,
      wrongAcquireRejected: true,
      wrongReleaseRejected: true,
      checkpointExists: true,
    });
    vi.stubEnv("C2C_DEEPSEEK_STATE_DIR", dir);
    const ws = new Workspace(dir);
    const s = newReview({ workspaceId: ws.id, taskId: "native-smoke", threadId: "native-test-thread", reviewProvider: "deepseek", reviewMode: "consensus", summary: "Synthetic integration test" });
    changeReview(ws.id, s.threadId, () => s);
    const cli = (command: string) => {
      const r = spawnSync(process.execPath, ["--import", "tsx", "src/cli/index.ts", "review", command, "-w", dir, "--thread", s.threadId, "--json"],
        { cwd: path.join(repo, "core"), env: process.env, encoding: "utf8", timeout: 10000 });
      expect(r.status, r.stderr + r.stdout).toBe(0);
      return JSON.parse(r.stdout);
    };
    expect(cli("sync").session.phase).toBe("WAITING");
    const nativeFile = path.join(dir, "native-smoke.json"), original = fs.readFileSync(nativeFile, "utf8");
    cli("advance");
    expect(fs.readFileSync(nativeFile, "utf8")).toBe(original);
    changeReview(ws.id, s.threadId, prior => ({ ...prior!, wait: { ...prior!.wait!, startedAt: new Date(Date.now() - 240000).toISOString() } }));
    expect(cli("heartbeat")).toMatchObject({ shouldReport: true, round: 1 });
    expect(cli("heartbeat").shouldReport).toBe(false);
    expect(cli("get").session.wait.lastReportedMinute).toBe(4);
    // Exercise the entire CLI -> native Advance path, not only its projection.
    vi.stubEnv("C2C_REVIEW_SKILLS_ROOT", path.join(repo, "bundled-skills"));
    const failed = ps("session_binding.ps1", ["-Action", "FailBrowserWorkflow", "-TaskId", s.taskId, "-CodexThreadId", s.threadId,
      "-StateDir", dir, "-BrowserTool", "mcp__cua_repl.js", "-BrowserToolStatus", "failed", "-Reason", "Synthetic runtime disconnect"]);
    expect(failed.status, failed.stderr).toBe(0);
    const recovered = cli("advance");
    expect(recovered.session.nextAction).toBe("auto-recover-runtime-tab");
    const native = JSON.parse(fs.readFileSync(nativeFile, "utf8"));
    expect(native.requiredAction).toBe("browser-recover-runtime-tab");
    expect(native.requiredBrowserTool).toBe("mcp__cua_repl.js");
    expect(native.actionContractDeadlineAt).toBeTruthy();
    expect(recovered.session.wait.startedAt).toBe(cli("get").session.wait.startedAt);
    const recoverArgs = ["-Action", "RecoverRuntimeTab", "-TaskId", s.taskId, "-CodexThreadId", s.threadId, "-StateDir", dir,
      "-EvidenceSource", "dom", "-BrowserSurface", "codex-in-app-sidebar", "-BrowserTabId", "synthetic-tab-reloaded", "-BrowserRuntimeId", "synthetic-runtime-reloaded",
      "-RuntimeEpoch", "2", "-TabMatchCount", "1", "-DomTargetUrl", "https://chat.deepseek.com/a/chat/s/synthetic-session-123",
      "-DomSessionTitle", "Synthetic test", "-DomMessageMarker", "CODEX-BINDING-native-test-thread", "-DeepSeekSessionId", "official-chat:synthetic-session-123",
      "-DomModel", "网页当前模型（合并升级版）", "-DomReasoning", "深度思考", "-DomSearch", "智能搜索"];
    const registryFile = path.join(dir, "thread-bindings.json");
    const originalRegistry = fs.readFileSync(registryFile, "utf8");
    const expiredRegistry = JSON.parse(originalRegistry);
    expiredRegistry.bindings[0].lastBrowserToolAt = new Date(Date.now() - 61000).toISOString();
    fs.writeFileSync(registryFile, JSON.stringify(expiredRegistry));
    const expiredRecovery = ps("session_binding.ps1", recoverArgs);
    expect(expiredRecovery.status).not.toBe(0);
    expect(expiredRecovery.stderr).toContain("60 秒");
    fs.writeFileSync(registryFile, originalRegistry);
    const restore = ps("session_binding.ps1", recoverArgs);
    expect(restore.status, restore.stderr).toBe(0);
    expect(JSON.parse(restore.stdout).status).toBe("runtime-tab-recovered");
    expect(cli("sync").session.phase).toBe("WAITING");
    const twice = ps("session_binding.ps1", recoverArgs);
    expect(twice.status).not.toBe(0);
    expect(twice.stderr).toContain("一次浏览器恢复");
  }, 20000);
});

describe("recovery budget belongs to the review task", () => {
  it("new Claim resets the old budget, retains its audit, and never resets a used current budget", () => {
    const smoke = spawnSync("pwsh", ["-NoProfile", "-NonInteractive", "-File", path.join(repo, "core/tests/fixtures/review-native-smoke.ps1"),
      "-SkillRoot", bundle, "-StateDir", dir], { encoding: "utf8", timeout: 20000, windowsHide: true });
    expect(smoke.status, smoke.stderr).toBe(0);
    const file = path.join(dir, "thread-bindings.json");
    const oldFile = path.join(dir, "native-smoke.json");
    fs.writeFileSync(oldFile, JSON.stringify({ ...JSON.parse(fs.readFileSync(oldFile, "utf8")), taskTerminalStatus: "completed" }));
    const registry = JSON.parse(fs.readFileSync(file, "utf8"));
    registry.bindings[0].browserRecoveryCount = 1;
    registry.bindings[0].browserRecoveryStatus = "recovered";
    fs.writeFileSync(file, JSON.stringify(registry));
    const next = ["-TaskId", "next-review", "-CodexThreadId", "native-test-thread", "-StateDir", dir];
    expect(ps("activate_review.ps1", [...next, "-SkillName", "deepseek-consensus-review"]).status).toBe(0);
    const claim = () => ps("session_binding.ps1", ["-Action", "Claim", ...next]);
    expect(claim().status).toBe(0);
    let binding = JSON.parse(fs.readFileSync(file, "utf8")).bindings[0];
    expect(binding.browserRecoveryCount).toBe(0);
    expect(binding.browserRecoveryTaskId).toBe("next-review");
    expect(binding.previousSendAudit.at(-1)).toMatchObject({ browserRecoveryCount: 1, browserRecoveryStatus: "recovered" });
    // Reproduce an already-claimed 1.19.1 record; only dormant legacy state may migrate.
    const legacy = JSON.parse(fs.readFileSync(file, "utf8"));
    legacy.bindings[0].browserRecoveryCount = 1;
    legacy.bindings[0].browserRecoveryStatus = "";
    delete legacy.bindings[0].browserRecoveryTaskId;
    fs.writeFileSync(file, JSON.stringify(legacy));
    expect(claim().status).toBe(0);
    binding = JSON.parse(fs.readFileSync(file, "utf8")).bindings[0];
    expect(binding.browserRecoveryCount).toBe(0);
    expect(binding.previousRecoveryAudit.at(-1).reason).toBe("legacy-claim-inherited-recovery-budget");
    const recover = () => ps("session_binding.ps1", ["-Action", "RecoverRuntimeTab", ...next,
      "-EvidenceSource", "dom", "-BrowserSurface", "codex-in-app-sidebar", "-BrowserTabId", "restored-tab",
      "-BrowserRuntimeId", "restored-runtime", "-RuntimeEpoch", "2", "-TabMatchCount", "1",
      "-DomTargetUrl", "https://chat.deepseek.com/a/chat/s/synthetic-session-123", "-DomSessionTitle", "Synthetic test",
      "-DomMessageMarker", "CODEX-BINDING-native-test-thread", "-DomModel", "网页当前模型（合并升级版）",
      "-DomReasoning", "深度思考", "-DomSearch", "智能搜索"]);
    const restored = recover();
    expect(restored.status, restored.stderr).toBe(0);
    expect(claim().status).toBe(0);
    expect(JSON.parse(fs.readFileSync(file, "utf8")).bindings[0].browserRecoveryCount).toBe(1);
    expect(recover().status).not.toBe(0);
    // Legacy records with a pending send must not be silently repaired.
    legacy.bindings[0].pendingReceipt = true;
    fs.writeFileSync(file, JSON.stringify(legacy));
    claim();
    expect(JSON.parse(fs.readFileSync(file, "utf8")).bindings[0].browserRecoveryCount).toBe(1);
    legacy.bindings[0].pendingReceipt = false;
    legacy.bindings[0].browserToolStatus = "failed";
    legacy.bindings[0].lastBrowserToolAt = new Date().toISOString();
    fs.writeFileSync(file, JSON.stringify(legacy));
    claim();
    expect(JSON.parse(fs.readFileSync(file, "utf8")).bindings[0].browserRecoveryCount).toBe(1);
    legacy.bindings[0].browserToolStatus = "not-started";
    legacy.bindings[0].lastBrowserToolAt = "";
    fs.writeFileSync(file, JSON.stringify(legacy));
    fs.writeFileSync(oldFile, JSON.stringify({ taskId: "native-smoke", taskTerminalStatus: "unknown" }));
    claim();
    expect(JSON.parse(fs.readFileSync(file, "utf8")).bindings[0].browserRecoveryCount).toBe(1);
  }, 30000);
});

describe("replacement after the original conversation is proven missing", () => {
  it("accepts current public evidence but refuses unknown sends, wrong URLs, tool failures and stopped tasks", () => {
    const smoke = spawnSync("pwsh", ["-NoProfile", "-NonInteractive", "-File", path.join(repo, "core/tests/fixtures/review-native-smoke.ps1"),
      "-SkillRoot", bundle, "-StateDir", dir], { encoding: "utf8", timeout: 20000, windowsHide: true });
    expect(smoke.status, smoke.stderr).toBe(0);
    const file = path.join(dir, "thread-bindings.json"), taskFile = path.join(dir, "native-smoke.json");
    const original = fs.readFileSync(file, "utf8"), task = fs.readFileSync(taskFile, "utf8");
    const mark = (extra: Record<string, string> = {}) => {
      const params = { Action: "MarkLost", TaskId: "native-smoke", CodexThreadId: "native-test-thread", StateDir: dir,
        Reason: "Synthetic original URL not found after a successful tab inventory", LossEvidence: "confirmed-absent",
        LossEvidenceSources: "cua.getState,original-url", LossObservationCount: "2", BrowserToolStatus: "available",
        OpenTabsEvidence: "absent", TabsListEvidence: "unknown", OriginalConversationStatus: "not-found",
        DomTargetUrl: "https://chat.deepseek.com/a/chat/s/synthetic-session-123", ...extra };
      return ps("session_binding.ps1", Object.entries(params).flatMap(([k,v]) => [`-${k}`,v]));
    };
    for (const extra of [{ OriginalConversationStatus: "unknown" }, { BrowserToolStatus: "unavailable" },
      { DomTargetUrl: "https://chat.deepseek.com/a/chat/s/wrong-session" }, { OpenTabsEvidence: "unknown" }]) {
      expect(mark(extra).status).not.toBe(0);
      expect(fs.readFileSync(file, "utf8")).toBe(original);
    }
    const pending = JSON.parse(original);pending.bindings[0].pendingReceipt = true;
    fs.writeFileSync(file, JSON.stringify(pending));expect(mark().status).not.toBe(0);
    fs.writeFileSync(file, original);
    fs.writeFileSync(taskFile, JSON.stringify({ ...JSON.parse(task), taskTerminalStatus: "cancelled" }));
    expect(mark().status).not.toBe(0);
    fs.writeFileSync(taskFile, task);
    const result = mark();expect(result.status, result.stderr).toBe(0);
    expect(JSON.parse(result.stdout).status).toBe("marked-lost");
    const after = JSON.parse(fs.readFileSync(file,"utf8")).bindings[0];
    expect(after.previousConversationUrl).toContain("synthetic-session-123");
    expect(after.replacementRequired).toBe(true);
  }, 30000);
});

describe("public browser tool compatibility evidence", () => {
  it.each(["mcp__cua_repl.js", "mcp__node_repl.js"])("accepts %s only with a successful tool observation", tool => {
    const evidence = { surface:"codex-in-app-sidebar", url:"https://chat.deepseek.com/a/chat/s/synthetic-session-123",
      model:"网页当前模型（合并升级版）", reasoning:"深度思考", searchMode:"智能搜索", sessionId:"synthetic-session-123",
      tabId:"tab", runtimeId:"runtime", tabMatchCount:1, tool, toolStatus:"succeeded" };
    const args = (e: object) => ["-TaskId","compat-test","-CodexThreadId","compat-thread","-BrowserEvidenceJson",JSON.stringify(e)];
    const good=ps("invoke_browser_smoke_test.ps1",args(evidence));
    expect(good.status,good.stderr).toBe(0);
    expect(JSON.parse(good.stdout).model).toBe(evidence.model);
    expect(ps("invoke_browser_smoke_test.ps1",args({...evidence,toolStatus:"unavailable"})).status).not.toBe(0);
  });
});
