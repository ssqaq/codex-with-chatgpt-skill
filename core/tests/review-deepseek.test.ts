import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { deepseekDependency, deepseekSkillName, readDeepseek, runDeepseek, syncDeepseek } from "../src/review/deepseek.js";
import { canExecuteReview, newReview, ReviewSessionSchema, type ReviewSession } from "../src/review/state.js";

const execScript = vi.hoisted(() => vi.fn());
vi.mock("node:util", async original => ({ ...await original<typeof import("node:util")>(), promisify: () => execScript }));

type Raw = Record<string, unknown>;
// Synthetic fixtures follow the installed schema-7 scripts: task mirror flags and
// counts are strings, registry flags/epochs are booleans/numbers, and the result
// is deepSeekPosition (capital S). They are NOT evidence of an online review.
function fixture(mode: "single" | "consensus" = "consensus", round = 1) {
  const session = newReview({ workspaceId: "workspace-test", threadId: "thread-test", taskId: "task-test",
    reviewProvider: "deepseek", reviewMode: mode, summary: "检查按钮状态并提出修复方案" });
  const batch = `${mode === "single" ? "R" : "C"}${round}`;
  const shared = {
    codexThreadId: session.threadId, taskId: session.taskId,
    deepseekSessionId: "official-chat:abcdefgh12345678", conversationUrl: "https://chat.deepseek.com/a/chat/s/abcdefgh12345678",
    targetUrl: "https://chat.deepseek.com/", browserSurface: "codex-in-app-sidebar", browserTabId: "tab-1", browserRuntimeId: "runtime-1",
    model: "网页当前模型（合并升级版）", reasoning: "深度思考", searchMode: "智能搜索", lastMessageFingerprint: `round-${round}-fingerprint`, sendOwnerTaskId: session.taskId,
    lastReceiptStatus: "confirmed", sendPhase: "receipt-confirmed", domMessagePresence: "present", submissionStatus: "succeeded",
    submissionMechanism: "button", domSendControl: "enabled", domInputPresence: "present", domInputEnabled: "enabled",
    lastOpenTabsEvidence: "confirmed", lastTabsListEvidence: "unknown", browserConfirmationStatus: "confirmed",
  };
  const source: Raw = { ...shared, sessionOwner: session.threadId, skillName: deepseekSkillName(mode),
    reviewBatch: batch, stateRevision: 10 + round, activationStatus: "activated", taskTerminalStatus: "active",
    sessionBindingStatus: "bound", runtimeEpoch: "1", bindingRevision: "4", pendingReceipt: "false", auditRisk: "false", resendBlocked: "false",
    deepseekCompletedRounds: `${round}`, deepseekStatus: "已收到完整回复", deepSeekPosition: "同意此方案，验证按钮加载和失败恢复。",
    codexPosition: "已核对修改范围、风险和验收标准。", agreementSummary: "只改按钮状态处理", unresolvedIssues: "",
    consensusStatus: "已达成", decisionDeadlock: "false", codexSummaryStatus: "已完成", checkResult: "无问题", planStatus: "已敲定",
    executionStatus: "允许开始执行", nextAction: "complete-codex-summary",
    roundHistory: [{ batch, roundNumber: round, recordedAt: "2026-09-11T10:00:00+08:00", consensusReached: true,
      codexPosition: "已核对修改范围、风险和验收标准。", deepSeekPosition: "同意此方案，验证按钮加载和失败恢复。", unresolvedIssues: "" }],
  };
  const binding: Raw = { ...shared, owner: session.threadId, activeTaskId: session.taskId, status: "bound",
    runtimeEpoch: 1, bindingRevision: 4, pendingReceipt: false, auditRisk: false, resendBlocked: false };
  return { session, source, binding };
}

function denied(session: ReviewSession) {
  expect(canExecuteReview(session)).toBe(false);
  expect(session.codexConsensus).toBe(false);
  expect(session.phase).not.toBe("READY");
}

describe("DeepSeek native-skill evidence projection", () => {
  it.each(["single", "consensus"] as const)("accepts a completed %s review with canonical mixed PowerShell types", mode => {
    const { session, source, binding } = fixture(mode);
    const result = syncDeepseek(session, source, [binding]);
    expect(result.phase).toBe("READY");
    expect(canExecuteReview(result)).toBe(true);
    expect(result.result).toBe(source.deepSeekPosition);
    expect(result.evidenceFingerprint).toBe(binding.lastMessageFingerprint);
    expect(result.evidenceRound).toBe(1);
    expect(ReviewSessionSchema.safeParse(result).success).toBe(true);
  });

  it("requires the independent R1 reply but does not invent a second consensus turn", () => {
    const { session, source, binding } = fixture("single");
    source.consensusStatus = "不适用";
    source.roundHistory = [];
    const result = syncDeepseek(session, source, [binding]);
    expect(canExecuteReview(result)).toBe(true);
    expect(result.round).toBe(1);
  });

  it("does not turn an R2 task into another pre-implementation single review", () => {
    const { session, source, binding } = fixture("single", 2);
    const result = syncDeepseek(session, source, [binding]);
    denied(result);
    expect(result.blockedReason).toContain("只接受 R1");
  });

  it("waits after a confirmed send until the current full reply is recorded", () => {
    const { session, source, binding } = fixture();
    source.deepseekCompletedRounds = "0";
    source.deepseekStatus = "已发送，等待回复";
    source.deepSeekPosition = "未回复";
    const result = syncDeepseek(session, source, [binding]);
    expect(result.phase).toBe("WAITING");
    expect(result.receiptStatus).toBe("confirmed");
    expect(result.replyReceived).toBe(false);
    expect(result.result).toBe("");
    denied(result);
  });

  it.each(["未完成", "尚未收到完整回复", "未收到", "已回复", "uncompleted", "received"]) (
    "does not promote incomplete or ambiguous reply status %s", status => {
      const { session, source, binding } = fixture();
      source.deepseekStatus = status;
      const result = syncDeepseek(session, source, [binding]);
      expect(result.replyReceived).toBe(false);
      denied(result);
    });

  it("does not use a case-mismatched field or placeholder as the webpage reply", () => {
    const { session, source, binding } = fixture();
    source.deepseekPosition = source.deepSeekPosition;
    delete source.deepSeekPosition;
    expect(syncDeepseek(session, source, [binding]).replyReceived).toBe(false);
    source.deepSeekPosition = "未回复";
    expect(syncDeepseek(session, source, [binding]).replyReceived).toBe(false);
  });

  it.each(["codexSummaryStatus", "checkResult", "planStatus", "executionStatus"]) (
    "keeps the implementation gate shut before Codex completes %s", gate => {
      const { session, source, binding } = fixture();
      source[gate] = "未完成";
      const result = syncDeepseek(session, source, [binding]);
      expect(result.replyReceived).toBe(true);
      expect(result.reviewerConsensus).toBe(true);
      expect(result.phase).toBe("REVIEWED");
      denied(result);
    });

  it("requires the current consensus round record rather than a leftover consensus label", () => {
    const { session, source, binding } = fixture();
    (source.roundHistory as Raw[])[0].consensusReached = false;
    denied(syncDeepseek(session, source, [binding]));
    source.roundHistory = [];
    denied(syncDeepseek(session, source, [binding]));
  });

  it("keeps disagreements visible without permitting implementation", () => {
    const { session, source, binding } = fixture();
    source.unresolvedIssues = "还需要明确失败时是否保留旧内容";
    source.consensusStatus = "进行中";
    Object.assign((source.roundHistory as Raw[])[0], { consensusReached: false, unresolvedIssues: source.unresolvedIssues });
    const result = syncDeepseek(session, source, [binding]);
    expect(result.phase).toBe("REVIEWED");
    expect(result.disagreements).toBe(source.unresolvedIssues);
    denied(result);
  });

  it("preserves round 3 through a local session save/reload and repeated read", () => {
    const { session, source, binding } = fixture("consensus", 3);
    const first = syncDeepseek(session, source, [binding]);
    const saved = ReviewSessionSchema.parse(JSON.parse(JSON.stringify(first)));
    const restored = syncDeepseek(saved, source, [binding]);
    expect(restored.round).toBe(3);
    expect(restored.evidenceRound).toBe(3);
    expect(canExecuteReview(restored)).toBe(true);
    expect(execScript).not.toHaveBeenCalled();
  });

  it("rejects a prior-round receipt and accepts a distinct receipt for the next round", () => {
    const first = fixture();
    const previous = syncDeepseek(first.session, first.source, [first.binding]);
    const next = fixture("consensus", 2);
    next.binding.lastMessageFingerprint = first.binding.lastMessageFingerprint;
    next.source.lastMessageFingerprint = first.source.lastMessageFingerprint;
    const reused = syncDeepseek(previous, next.source, [next.binding]);
    denied(reused);
    expect(reused.blockedReason).toContain("上一轮发送回执");
    next.binding.lastMessageFingerprint = next.source.lastMessageFingerprint = "new-round-2-fingerprint";
    expect(canExecuteReview(syncDeepseek(reused, next.source, [next.binding]))).toBe(true);
  });

  it.each([
    ["taskId", "different-task"], ["codexThreadId", "different-thread"], ["skillName", "deepseek-independent-review"],
    ["sessionOwner", "different-thread"], ["sendOwnerTaskId", "different-task"], ["browserTabId", "different-tab"],
    ["browserRuntimeId", "different-runtime"], ["runtimeEpoch", "2"], ["bindingRevision", "3"],
    ["lastMessageFingerprint", "different-fingerprint"], ["model", "快速、专家、识图已合并"], ["reasoning", "未开启"],
    ["browserSurface", "chrome"], ["activationStatus", "requested"], ["taskTerminalStatus", "completed"],
  ])("rejects mismatched source evidence %s", (field, value) => {
    const { session, source, binding } = fixture();
    source[field] = value;
    denied(syncDeepseek(session, source, [binding]));
  });

  it.each(["pendingReceipt", "auditRisk", "resendBlocked", "auditOnly"]) (
    "honors %s in both registry booleans and task string flags", flag => {
      const { session, source, binding } = fixture();
      source[flag] = "yes";
      denied(syncDeepseek(session, source, [binding]));
      source[flag] = "false";
      binding[flag] = true;
      denied(syncDeepseek(session, source, [binding]));
    });

  it.each(["lastReceiptStatus", "domMessagePresence", "lastOpenTabsEvidence", "submissionStatus", "browserConfirmationStatus"]) (
    "never treats a partial receipt as proof when %s is missing", field => {
      const { session, source, binding } = fixture();
      delete binding[field];
      denied(syncDeepseek(session, source, [binding]));
    });

  it("accepts one confirmed tab evidence source and rejects conflicting evidence", () => {
    const { session, source, binding } = fixture();
    binding.lastOpenTabsEvidence = source.lastOpenTabsEvidence = "empty";
    binding.lastTabsListEvidence = source.lastTabsListEvidence = "confirmed";
    expect(canExecuteReview(syncDeepseek(session, source, [binding]))).toBe(true);
    source.lastOpenTabsEvidence = "wrong-session";
    denied(syncDeepseek(session, source, [binding]));
  });

  it("accepts an Enter submission with an enabled input even if its send button is disabled", () => {
    const { session, source, binding } = fixture();
    for (const raw of [source, binding]) { raw.submissionMechanism = "enter"; raw.domSendControl = "disabled"; }
    expect(canExecuteReview(syncDeepseek(session, source, [binding]))).toBe(true);
    source.domInputEnabled = "disabled";
    denied(syncDeepseek(session, source, [binding]));
  });

  it("rejects official-looking URLs that do not identify the recorded conversation", () => {
    const { session, source, binding } = fixture();
    for (const url of ["https://chat.deepseek.com/", "https://chat.deepseek.com/a/chat/s/other123456", "https://chat.deepseek.com.evil.example/a/chat/s/abcdefgh12345678", "http://chat.deepseek.com/a/chat/s/abcdefgh12345678"]) {
      source.conversationUrl = binding.conversationUrl = url;
      denied(syncDeepseek(session, source, [binding]));
    }
  });

  it("only accepts a fallback marker belonging to the current thread", () => {
    const { session, source, binding } = fixture();
    for (const raw of [source, binding]) {
      raw.conversationUrl = "https://chat.deepseek.com/";
      raw.deepseekSessionId = `official-marker:CODEX-BINDING-${session.threadId}`;
      raw.domMessageMarker = `CODEX-BINDING-${session.threadId}`;
    }
    expect(canExecuteReview(syncDeepseek(session, source, [binding]))).toBe(true);
    for (const raw of [source, binding]) { raw.deepseekSessionId = "official-marker:CODEX-BINDING-other"; raw.domMessageMarker = "CODEX-BINDING-other"; }
    denied(syncDeepseek(session, source, [binding]));
  });

  it("rejects duplicate thread bindings and sessions still owned by another thread", () => {
    const { session, source, binding } = fixture();
    denied(syncDeepseek(session, source, [binding, { ...binding }]));
    denied(syncDeepseek(session, source, [binding, { ...binding, codexThreadId: "other-thread", status: "recovery-pending" }]));
  });

  it("does not reuse the previous task's receipt after a new task has claimed the session", () => {
    const { session, source, binding } = fixture();
    binding.activeTaskId = session.taskId;
    binding.sendOwnerTaskId = "old-task";
    binding.previousSendAudit = [{ taskId: "old-task", lastReceiptStatus: "confirmed" }];
    denied(syncDeepseek(session, source, [binding]));
  });

  it("rejects revision rollback, invalid counts and backward rounds", () => {
    const { session, source, binding } = fixture();
    const previous = { ...session, evidenceRevision: 12, round: 2 };
    denied(syncDeepseek(previous, source, [binding]));
    for (const bad of [null, "", "1/2", 1.5, "9999999999999999999999999"]) {
      source.deepseekCompletedRounds = bad;
      denied(syncDeepseek(session, source, [binding]));
    }
    source.deepseekCompletedRounds = "1";
    source.stateRevision = null;
    denied(syncDeepseek(session, source, [binding]));
  });

  it("preserves the explicit local recovery action while stopping sends and execution", () => {
    const { session, source, binding } = fixture("consensus", 2);
    source.taskTerminalStatus = "frozen";
    source.nextAction = "auto-recover-runtime-tab";
    binding.status = "recovery-pending";
    const result = syncDeepseek(session, source, [binding]);
    expect(result.round).toBe(2);
    expect(result.nextAction).toBe("auto-recover-runtime-tab");
    denied(result);
  });

  it("keeps a deadlock or a cancelled task from reopening execution", () => {
    const { session, source, binding } = fixture();
    source.decisionDeadlock = "true";
    const result = syncDeepseek(session, source, [binding]);
    denied(result);
    expect(result.nextAction).toBe("await-user-decision");
    const cancelled = { ...session, phase: "CANCELLED" as const };
    expect(syncDeepseek(cancelled, source, [binding])).toBe(cancelled);
  });

  it("does not restart a missing native task after evidence has been saved", () => {
    const { session } = fixture();
    expect(syncDeepseek(session, null, []).phase).toBe("PREPARING");
    denied(syncDeepseek({ ...session, evidenceRevision: 1 }, null, []));
  });
});

describe("DeepSeek installed-script dispatch and state reads", () => {
  let dir: string;
  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), "c2c-deepseek-adapter-test-"));
    vi.stubEnv("C2C_DEEPSEEK_STATE_DIR", dir);
    vi.stubEnv("C2C_REVIEW_SKILLS_ROOT", path.join(dir, "skills"));
    execScript.mockReset().mockResolvedValue({ stdout: '{"status":"simulated-local-action"}' });
    for (const mode of ["single", "consensus"] as const) {
      const dep = deepseekDependency(mode);
      for (const relative of dep.missing) {
        const file = path.join(dep.skillPath, relative);
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.writeFileSync(file, "# Simulated dependency path; never executes a browser.");
      }
    }
  });
  afterEach(() => {
    vi.unstubAllEnvs();
    fs.rmSync(dir, { recursive: true, force: true });
    execScript.mockReset();
  });

  function writeFixture(source: Raw, binding: Raw) {
    fs.writeFileSync(path.join(dir, "task-test.json"), JSON.stringify(source));
    fs.writeFileSync(path.join(dir, "thread-bindings.json"), JSON.stringify({ bindings: [binding] }));
  }

  it("reads native state without changing either file or invoking a browser", () => {
    const { session, source, binding } = fixture();
    writeFixture(source, binding);
    const before = fs.readFileSync(path.join(dir, "task-test.json"), "utf8");
    expect(canExecuteReview(readDeepseek(session))).toBe(true);
    expect(fs.readFileSync(path.join(dir, "task-test.json"), "utf8")).toBe(before);
    expect(execScript).not.toHaveBeenCalled();
  });

  it("retains corrupt JSON without leaking its content or pretending it is a new task", () => {
    const { session } = fixture();
    const file = path.join(dir, "task-test.json");
    const damaged = '{"private":"DO-NOT-LOG"';
    fs.writeFileSync(file, damaged);
    expect(() => readDeepseek(session)).toThrow(/状态损坏/);
    try { readDeepseek(session); } catch (e) { expect(String(e)).not.toContain("DO-NOT-LOG"); }
    expect(fs.readFileSync(file, "utf8")).toBe(damaged);
  });

  it("refuses a malformed registry instead of treating its entries as evidence", () => {
    const { session, source, binding } = fixture();
    writeFixture(source, binding);
    fs.writeFileSync(path.join(dir, "thread-bindings.json"), JSON.stringify({ bindings: [[]] }));
    expect(() => readDeepseek(session)).toThrow(/绑定记录损坏/);
  });

  it("activates a new task once and uses the original advance engine for round-3 resume", async () => {
    const { session, source, binding } = fixture("consensus", 3);
    await runDeepseek(session, "activate");
    expect(execScript.mock.calls[0][1]).toContain(path.join(deepseekDependency("consensus").skillPath, "scripts", "activate_review.ps1"));
    writeFixture(source, binding);
    await runDeepseek({ ...session, round: 3 }, "activate");
    const args = execScript.mock.calls[1][1] as string[];
    expect(args).toContain(path.join(deepseekDependency("consensus").skillPath, "scripts", "advance_review_workflow.ps1"));
    expect(args).not.toContain("-ReviewBatch");
    expect(args).toContain("Advance");
    expect(JSON.parse(fs.readFileSync(path.join(dir, "task-test.json"), "utf8")).reviewBatch).toBe("C3");
  });

  it("refuses a conflicting native task before dispatching any script", async () => {
    const { session, source, binding } = fixture();
    source.codexThreadId = "someone-else";
    writeFixture(source, binding);
    await expect(runDeepseek(session, "activate")).rejects.toThrow(/归属/);
    expect(execScript).not.toHaveBeenCalled();
  });

  it("completes through the installed binding engine without forging task state", async () => {
    const { session, source, binding } = fixture();
    writeFixture(source, binding);
    await runDeepseek({ ...session, phase: "EXECUTING" }, "complete");
    const args = execScript.mock.calls[0][1] as string[];
    expect(args).toContain(path.join(deepseekDependency("consensus").skillPath, "scripts", "session_binding.ps1"));
    expect(args).toContain("CompleteTask");
    expect(args).not.toContain("-SkillName");
    expect(JSON.parse(fs.readFileSync(path.join(dir, "task-test.json"), "utf8")).taskTerminalStatus).toBe("active");
  });

  it("fails closed when a native dependency disappears or the process times out", async () => {
    const { session } = fixture();
    execScript.mockRejectedValueOnce(Object.assign(new Error("private stdout DO-NOT-LOG"), { killed: true }));
    await expect(runDeepseek(session, "activate")).rejects.toThrow(/超过 15 秒/);
    execScript.mockClear();
    fs.rmSync(path.join(deepseekDependency("consensus").skillPath, "scripts", "session_binding.ps1"));
    await expect(runDeepseek(session, "activate")).rejects.toThrow(/缺少/);
    expect(execScript).not.toHaveBeenCalled();
  });
});
