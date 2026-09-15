import fs from "node:fs";
import path from "node:path";
import { Command } from "commander";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { registerReviewCommands } from "../src/cli/review.js";
import { readDeepseek, runDeepseek } from "../src/review/deepseek.js";
import { canExecuteReview, changeReview, newReview, readReview, type ReviewSession } from "../src/review/state.js";
import { Workspace } from "../src/workspace/manager.js";
import { cleanup, isolateStateDir } from "./helpers.js";

vi.mock("../src/review/deepseek.js", async importOriginal => ({
  ...await importOriginal<typeof import("../src/review/deepseek.js")>(),
  runDeepseek: vi.fn(),
  readDeepseek: vi.fn(),
}));

let directory: string;
let workspaceId: string;
const threadId = "routing-gate-thread";
let originalExitCode: typeof process.exitCode;
let originalStateDirectory: string | undefined;
let output: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  originalExitCode = process.exitCode;
  originalStateDirectory = process.env.C2C_STATE_DIR;
  directory = isolateStateDir();
  workspaceId = new Workspace(directory).id;
  output = vi.spyOn(console, "log").mockImplementation(() => undefined);
  vi.mocked(runDeepseek).mockReset();
  vi.mocked(readDeepseek).mockReset();
});
afterEach(() => {
  vi.restoreAllMocks();
  cleanup(directory);
  process.exitCode = originalExitCode;
  if (originalStateDirectory === undefined) delete process.env.C2C_STATE_DIR;
  else process.env.C2C_STATE_DIR = originalStateDirectory;
});

async function cli(...args: string[]) {
  process.exitCode = 0;
  output.mockClear();
  const program = new Command();
  registerReviewCommands(program);
  await program.parseAsync(["review", ...args, "--workspace", directory, "--thread", threadId, "--json"], { from: "user" });
  return JSON.parse(String(output.mock.calls.at(-1)?.[0]));
}
function saved(phase: ReviewSession["phase"] = "PREPARING", provider: ReviewSession["reviewProvider"] = "deepseek") {
  const s = newReview({ workspaceId, threadId, taskId: "routing-gate-task", reviewProvider: provider,
    reviewMode: "consensus", summary: "检查本机设置入口，保留已有功能，运行测试。" });
  return changeReview(workspaceId, threadId, () => ({ ...s, phase }));
}

// These tests exercise CLI state/gates with a deliberately unavailable adapter.
// They are not claims of a successful live browser review or shell write sandbox.
describe("review CLI routing preserves user intent", () => {
  it("resolves the skill brand to DeepSeek and rejects an inconsistent start without saving a review", async () => {
    const request = "使用 Codex with ChatGPT 帮我修复设置问题并测试。";
    expect(await cli("resolve", "--request", request)).toMatchObject({ ok: true, reviewProvider: "deepseek" });
    expect(await cli("start", "--request", request, "--provider", "chatgpt", "--summary", "检查设置问题。"))
      .toMatchObject({ ok: false, error: expect.stringContaining("原始需求解析") });
    expect(readReview(workspaceId, threadId)).toBeNull();
    expect(runDeepseek).not.toHaveBeenCalled();
    const started = await cli("start", "--request", request, "--provider", "deepseek", "--summary", "检查设置问题。");
    expect(started).toMatchObject({ ok: true, canExecute: false, session: { reviewProvider: "deepseek" } });
  });

  it("honors an explicit GPT user request", async () => {
    const started = await cli("start", "--request", "使用 GPT 评审设置页。", "--provider", "chatgpt", "--summary", "检查设置页。");
    expect(started).toMatchObject({ ok: true, canExecute: false, session: { reviewProvider: "chatgpt" } });
  });

  it.each([
    "请用网页版 ChatGPT 评审这个问题",
    "请用网页 ChatGPT 评审这个问题",
    "请用官网 ChatGPT 评审这个问题",
    "请用 [ChatGPT](https://chatgpt.com/) 评审这个问题",
    "请用官方网页版 [**ChatGPT**](https://chatgpt.com/) 评审这个问题",
    "这次交给 ChatGPT 评审",
  ])("uses the same original formatted request for resolve and start: %s", async request => {
    expect(await cli("resolve", "--request", request)).toMatchObject({ ok: true, reviewProvider: "chatgpt" });
    expect(await cli("start", "--request", request, "--provider", "chatgpt", "--summary", "检查设置页。"))
      .toMatchObject({ ok: true, canExecute: false, session: { reviewProvider: "chatgpt" } });
  });

  it("resumes an existing ChatGPT review without silently migrating it to the new default", async () => {
    const previous = saved("WAITING", "chatgpt");
    expect(await cli("resolve", "--request", "使用 Codex with ChatGPT 继续"))
      .toMatchObject({ ok: true, reviewProvider: "chatgpt", resumeTaskId: previous.taskId });
    expect(await cli("start", "--request", "继续", "--provider", "chatgpt"))
      .toMatchObject({ ok: true, session: { taskId: previous.taskId, reviewProvider: "chatgpt", phase: "WAITING" } });
  });
});

describe("c2c review bind aligns only with a verified task", () => {
  let deepseekDir: string;
  let originalDeepseekDir: string | undefined;
  const skillName = "deepseek-consensus-review";
  beforeEach(() => {
    deepseekDir = path.join(directory, "deepseek-state");
    fs.mkdirSync(deepseekDir, { recursive: true });
    originalDeepseekDir = process.env.C2C_DEEPSEEK_STATE_DIR;
    process.env.C2C_DEEPSEEK_STATE_DIR = deepseekDir;
  });
  afterEach(() => {
    if (originalDeepseekDir === undefined) delete process.env.C2C_DEEPSEEK_STATE_DIR;
    else process.env.C2C_DEEPSEEK_STATE_DIR = originalDeepseekDir;
  });
  const conversationUrl = "https://chat.deepseek.com/a/chat/s/abcdefgh12345678";
  function writeNative(active = "live-task") {
    const shared = { codexThreadId: threadId, skillName, deepseekSessionId: "official-chat:abcdefgh12345678",
      conversationUrl, browserTabId: "tab-1", browserRuntimeId: "runtime-1", runtimeEpoch: 1,
      model: "网页当前模型（合并升级版）", reasoning: "深度思考", searchMode: "智能搜索",
      targetUrl: "https://chat.deepseek.com/", browserSurface: "codex-in-app-sidebar", sendOwnerTaskId: active };
    const source: Record<string, unknown> = { ...shared, taskId: active, taskName: "检查按钮状态", sessionOwner: threadId,
      reviewBatch: "C3", stateRevision: 13, activationStatus: "activated", taskTerminalStatus: "active" };
    const binding: Record<string, unknown> = { ...shared, owner: threadId, activeTaskId: active, taskId: active, status: "bound",
      bindingRevision: 7, pendingReceipt: false, auditRisk: false, resendBlocked: false, auditOnly: false };
    fs.writeFileSync(path.join(deepseekDir, `${active}.json`), JSON.stringify(source));
    fs.writeFileSync(path.join(deepseekDir, "thread-bindings.json"), JSON.stringify({ bindings: [binding] }));
  }
  it("points the panel at the verified task without sending and keeps execution closed", async () => {
    saved("BLOCKED");
    writeNative();
    const result = await cli("bind", "--task", "live-task");
    expect(result).toMatchObject({ ok: true, aligned: true, previousTaskId: "routing-gate-task", canExecute: false });
    expect(result.session).toMatchObject({ taskId: "live-task", round: 3, phase: "PREPARING", receiptStatus: "none",
      reviewerConsensus: false, codexConsensus: false, chatUrl: conversationUrl });
    expect(runDeepseek).not.toHaveBeenCalled();
    expect(readReview(workspaceId, threadId)).toMatchObject({ taskId: "live-task" });
  });
  it("refuses an operator-supplied task id that the binding does not confirm", async () => {
    saved("BLOCKED");
    writeNative();
    const result = await cli("bind", "--task", "some-other-task");
    expect(result).toMatchObject({ ok: false, error: expect.stringContaining("不一致") });
    expect(readReview(workspaceId, threadId)).toMatchObject({ taskId: "routing-gate-task" });
    expect(runDeepseek).not.toHaveBeenCalled();
  });
  it("reports no-op alignment and refuses when nothing is verified", async () => {
    saved("BLOCKED");
    writeNative("routing-gate-task");
    const same = await cli("bind");
    expect(same).toMatchObject({ ok: true, aligned: false, canExecute: false });
    fs.writeFileSync(path.join(deepseekDir, "thread-bindings.json"), JSON.stringify({ bindings: [] }));
    const blocked = await cli("bind");
    expect(blocked).toMatchObject({ ok: false, error: expect.stringContaining("DeepSeek 绑定") });
  });
});

describe("cancellation remains closed when browser cancellation fails", () => {
  it.each(["PREPARING", "READY", "EXECUTING"] as const)("persists the local stop before remote work from %s", async phase => {
    const s = saved(phase);
    // Even a stale source claiming consensus must not revive a locally stopped task.
    vi.mocked(readDeepseek).mockImplementation(state => ({ ...state, phase: "READY", receiptStatus: "confirmed",
      replyReceived: true, reviewerConsensus: true, codexConsensus: true, blockedReason: "", disagreements: "" }));
    vi.mocked(runDeepseek).mockImplementation(async () => {
      expect(readReview(workspaceId, threadId)).toMatchObject({ phase: "CANCELLED", reviewerConsensus: false, codexConsensus: false });
      throw new Error("Codex auth token is unavailable");
    });
    const cancelled = await cli("cancel");
    expect(cancelled).toMatchObject({ ok: true, canExecute: false, session: { phase: "CANCELLED", taskId: s.taskId,
      blockedReason: expect.stringContaining("取消尚未确认") } });
    expect(process.exitCode).toBe(1);
    expect(canExecuteReview(readReview(workspaceId, threadId)!)).toBe(false);
    expect(await cli("sync")).toMatchObject({ ok: true, canExecute: false, session: { phase: "CANCELLED" } });
    expect(await cli("advance")).toMatchObject({ ok: true, canExecute: false, session: { phase: "CANCELLED" } });
    expect(await cli("execute")).toMatchObject({ ok: false, error: expect.stringContaining("禁止开始修改") });
    expect(readDeepseek).not.toHaveBeenCalled();
    expect(runDeepseek).toHaveBeenCalledTimes(1);
    expect(await cli("recover", "--task", s.taskId)).toMatchObject({ ok: true, canExecute: false, session: { phase: "CANCELLED" } });
  });

  it("keeps successful cancellation terminal and idempotent", async () => {
    saved();
    vi.mocked(runDeepseek).mockResolvedValue({ ok: true });
    expect(await cli("cancel")).toMatchObject({ ok: true, canExecute: false, session: { phase: "CANCELLED", blockedReason: "" } });
    expect(await cli("cancel")).toMatchObject({ ok: true, canExecute: false, session: { phase: "CANCELLED" } });
    expect(runDeepseek).toHaveBeenCalledTimes(1);
    expect(process.exitCode).toBe(0);
  });
});
