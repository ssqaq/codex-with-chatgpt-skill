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
