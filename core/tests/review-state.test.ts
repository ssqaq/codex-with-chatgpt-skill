import fs from "node:fs";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  parseReviewMode,
  parseReviewProvider,
  requestProvider,
  selectReviewer,
} from "../src/review/provider.js";
import {
  canExecuteReview,
  changeReview,
  isReviewTerminal,
  newReview,
  readReview,
  renderReview,
  reviewFile,
  type ReviewSession,
} from "../src/review/state.js";
import { cleanup, isolateStateDir } from "./helpers.js";

function makeReview(overrides: Partial<ReviewSession> = {}): ReviewSession {
  return {
    ...newReview({
      workspaceId: overrides.workspaceId ?? "workspace-1",
      threadId: overrides.threadId ?? "thread-1",
      taskId: overrides.taskId ?? "review-1",
      reviewProvider: overrides.reviewProvider ?? "deepseek",
      reviewMode: overrides.reviewMode ?? "consensus",
      summary: overrides.summary ?? "整理设置页入口，检查旧链接，再修改并测试。",
    }),
    ...overrides,
  };
}

function readyReview(overrides: Partial<ReviewSession> = {}): ReviewSession {
  return makeReview({
    phase: "READY",
    receiptStatus: "confirmed",
    replyReceived: true,
    reviewerConsensus: true,
    codexConsensus: true,
    agreements: "保留旧入口并增加兼容测试。",
    result: "CONSENSUS",
    nextAction: "开始修改并测试",
    ...overrides,
  });
}

describe("review provider selection", () => {
  it.each([
    [" deepseek ", "deepseek"],
    ["DeepSeek", "deepseek"],
    ["CHATGPT", "chatgpt"],
    ["gpt", "chatgpt"],
  ] as const)("normalizes provider %s", (input, expected) => {
    expect(parseReviewProvider(input)).toBe(expected);
  });

  it("rejects unsupported providers and modes", () => {
    expect(() => parseReviewProvider("claude")).toThrow(/review-provider/);
    expect(() => parseReviewMode("automatic")).toThrow(/review-mode/);
    expect(parseReviewMode("single")).toBe("single");
    expect(parseReviewMode("consensus")).toBe("consensus");
  });

  it.each([
    ["使用 DeepSeek 评审这个问题。", "deepseek"],
    ["用 GPT 评审这个问题。", "chatgpt"],
    ["使用 ChatGPT 多轮评审后再修改。", "chatgpt"],
    ["让 DeepSeek 多轮复审后再修改代码", "deepseek"],
    ["Use GPT to review this plan", "chatgpt"],
  ] as const)("recognizes an explicit reviewer: %s", (request, expected) => {
    expect(requestProvider(request)).toBe(expected);
    expect(selectReviewer({ request, defaultProvider: "deepseek" })).toBe(expected);
  });

  it("uses the configured default when the request only names the skill", () => {
    const request = "使用 Codex with ChatGPT，多轮方案评审后再修改代码。";
    expect(requestProvider(request)).toBeUndefined();
    expect(selectReviewer({ request, defaultProvider: "deepseek" })).toBe("deepseek");
    expect(selectReviewer({ request, defaultProvider: "chatgpt" })).toBe("chatgpt");
  });

  it("preserves the reviewer of a resumed task even if the default changed", () => {
    expect(selectReviewer({ request: "继续", saved: "chatgpt", defaultProvider: "deepseek" })).toBe("chatgpt");
    expect(selectReviewer({ request: "继续", saved: "deepseek", defaultProvider: "chatgpt" })).toBe("deepseek");
  });

  it("rejects a provider change in an active review", () => {
    expect(() => selectReviewer({ request: "用 GPT 评审", saved: "deepseek", defaultProvider: "deepseek" }))
      .toThrow(/中途换渠道/);
    expect(() => selectReviewer({ explicit: "deepseek", saved: "chatgpt", defaultProvider: "deepseek" }))
      .toThrow(/中途换渠道/);
  });

  it("rejects conflicting reviewer commands instead of silently picking one", () => {
    expect(() => requestProvider("使用 DeepSeek 评审，用 ChatGPT 复审。"))
      .toThrow(/一个评审渠道/);
    expect(requestProvider("使用 GPT 评审，让 ChatGPT 做复核。")).toBe("chatgpt");
  });
});

describe("review execution gate and visible status", () => {
  it.each(["single", "consensus"] as const)("starts %s without permission to modify files", reviewMode => {
    const state = makeReview({ reviewMode });
    expect(state.round).toBe(1);
    expect(canExecuteReview(state)).toBe(false);
    expect(isReviewTerminal(state)).toBe(false);
  });

  it.each(["single", "consensus"] as const)("allows %s only after receipt, review, and both confirmations", reviewMode => {
    expect(canExecuteReview(readyReview({ reviewMode }))).toBe(true);
  });

  it.each([
    { phase: "PREPARING" },
    { phase: "WAITING" },
    { phase: "REVIEWED" },
    { phase: "BLOCKED" },
    { phase: "CANCELLED" },
    { phase: "DONE" },
    { receiptStatus: "none" },
    { receiptStatus: "unknown" },
    { replyReceived: false },
    { reviewerConsensus: false },
    { codexConsensus: false },
    { disagreements: "旧链接兼容还没有测试。" },
    { blockedReason: "网页发送回执不明确。" },
  ] satisfies Partial<ReviewSession>[])("blocks execution when %j", invalid => {
    expect(canExecuteReview(readyReview(invalid))).toBe(false);
  });

  it("binds each DeepSeek mode to the existing matching skill", () => {
    for (const reviewMode of ["single", "consensus"] as const) {
      const state = newReview({
        workspaceId: "workspace-1", threadId: "thread-1", taskId: "review-1",
        reviewProvider: "deepseek", reviewMode, summary: "评审设置页。",
      });
      expect(state.bindingRef).toEqual({
        skillName: reviewMode === "single" ? "deepseek-independent-review" : "deepseek-consensus-review",
        taskId: "review-1",
      });
    }
    const chatgpt = newReview({
      workspaceId: "workspace-1", threadId: "thread-1", taskId: "review-1",
      reviewProvider: "chatgpt", reviewMode: "consensus", summary: "评审设置页。",
    });
    expect(chatgpt.bindingRef).toBeUndefined();
  });

  it("shows the actual channel, round, result, disagreement, and next action", () => {
    const output = renderReview(makeReview({
      round: 3, phase: "REVIEWED", replyReceived: true, receiptStatus: "confirmed",
      agreements: "保留旧入口。", disagreements: "补充失败时的回退方式。",
      result: "需要修订方案。", nextAction: "根据意见修订第 4 轮方案。",
      modelName: "页面实际显示模型", reasoningStrength: "深度思考",
    }));
    for (const expected of [
      "评审渠道：DeepSeek", "多轮评审：第 3 轮", "保留旧入口。", "补充失败时的回退方式。",
      "需要修订方案。", "根据意见修订第 4 轮方案。", "页面实际显示模型 / 深度思考",
      "执行门槛：不允许开始修改",
    ]) expect(output).toContain(expected);
  });

  it("shows a single-review result without inventing round progress or model verification", () => {
    const output = renderReview(readyReview({ reviewMode: "single", reviewProvider: "chatgpt" }));
    expect(output).toContain("评审渠道：ChatGPT");
    expect(output).toContain("评审方式：单次评审");
    expect(output).not.toContain("多轮评审：");
    expect(output).toContain("尚未从页面确认");
    expect(output).toContain("执行门槛：允许修改");
  });

  it("keeps the failed round visible and does not claim success after a blocked send", () => {
    const output = renderReview(makeReview({
      round: 2, phase: "BLOCKED", receiptStatus: "unknown",
      blockedReason: "发送结果不明确，不能重复发送。", nextAction: "先核对原网页中的发送记录。",
    }));
    expect(output).toContain("第 2 轮");
    expect(output).toContain("当前状态：已暂停");
    expect(output).toContain("发送结果不明确，不能重复发送。");
    expect(output).toContain("执行门槛：不允许开始修改");
  });
});

describe("persisted review ownership and recovery", () => {
  let directory: string;
  const previousStateDirectory = process.env.C2C_STATE_DIR;

  beforeEach(() => { directory = isolateStateDir(); });
  afterEach(() => {
    cleanup(directory);
    if (previousStateDirectory === undefined) delete process.env.C2C_STATE_DIR;
    else process.env.C2C_STATE_DIR = previousStateDirectory;
  });

  it("treats only a missing file as a new review", () => {
    expect(readReview("workspace-1", "thread-1")).toBeNull();
    expect(fs.existsSync(reviewFile("workspace-1", "thread-1"))).toBe(false);
  });

  it("recovers the exact round, binding, receipt, disagreements, and next action from disk", () => {
    const state = makeReview({
      round: 3, phase: "BLOCKED", receiptStatus: "unknown",
      agreements: "保留旧入口", disagreements: "需要核对失败回退",
      nextAction: "检查已发送记录后续接第 3 轮", blockedReason: "页面暂时不可读",
      chatUrl: "https://chat.deepseek.com/a/chat/saved-review",
    });
    changeReview(state.workspaceId, state.threadId, () => state);
    const persisted = JSON.parse(fs.readFileSync(reviewFile(state.workspaceId, state.threadId), "utf8"));
    expect(persisted).toEqual(state);
    expect(readReview(state.workspaceId, state.threadId)).toEqual(state);
    expect(canExecuteReview(readReview(state.workspaceId, state.threadId)!)).toBe(false);
  });

  it("isolates separate threads and workspaces", () => {
    const first = makeReview();
    const second = makeReview({ threadId: "thread-2", taskId: "review-2", round: 2 });
    const third = makeReview({ workspaceId: "workspace-2", taskId: "review-3", round: 3 });
    for (const state of [first, second, third]) changeReview(state.workspaceId, state.threadId, () => state);
    expect(readReview("workspace-1", "thread-1")?.round).toBe(1);
    expect(readReview("workspace-1", "thread-2")?.round).toBe(2);
    expect(readReview("workspace-2", "thread-1")?.round).toBe(3);
    expect(new Set([first, second, third].map(s => reviewFile(s.workspaceId, s.threadId))).size).toBe(3);
  });

  it("refuses a file copied from another owner and leaves the evidence untouched", () => {
    const state = makeReview();
    changeReview(state.workspaceId, state.threadId, () => state);
    const foreignFile = reviewFile("workspace-1", "thread-2");
    fs.copyFileSync(reviewFile(state.workspaceId, state.threadId), foreignFile);
    const before = fs.readFileSync(foreignFile, "utf8");
    expect(() => readReview("workspace-1", "thread-2")).toThrow(/ownership mismatch/);
    expect(() => changeReview("workspace-1", "thread-2", () => makeReview({ threadId: "thread-2" })))
      .toThrow(/ownership mismatch/);
    expect(fs.readFileSync(foreignFile, "utf8")).toBe(before);
  });

  it("rejects an update that changes its thread or workspace owner", () => {
    const state = makeReview();
    changeReview(state.workspaceId, state.threadId, () => state);
    expect(() => changeReview(state.workspaceId, state.threadId, previous => ({ ...previous!, threadId: "thread-2" })))
      .toThrow(/ownership mismatch/);
    expect(() => changeReview(state.workspaceId, state.threadId, previous => ({ ...previous!, workspaceId: "workspace-2" })))
      .toThrow(/ownership mismatch/);
    expect(readReview(state.workspaceId, state.threadId)).toEqual(state);
  });

  it.each(["..", "../outside", "a/b", "a\\b", "", "a".repeat(129)])("rejects unsafe owner id %j", owner => {
    expect(() => reviewFile(owner, "thread-1")).toThrow();
    expect(() => reviewFile("workspace-1", owner)).toThrow();
  });

  it.each(["PREPARING", "WAITING", "BLOCKED", "READY", "EXECUTING"] as const)("does not replace active %s state with a new task", phase => {
    const state = makeReview({ phase });
    changeReview(state.workspaceId, state.threadId, () => state);
    expect(() => changeReview(state.workspaceId, state.threadId, () => makeReview({ taskId: "review-2" })))
      .toThrow(/completed or cancelled/);
    expect(readReview(state.workspaceId, state.threadId)).toEqual(state);
  });

  it.each(["DONE", "CANCELLED"] as const)("archives the previous %s task before a new one", phase => {
    const previous = makeReview({ phase, round: 4 });
    expect(isReviewTerminal(previous)).toBe(true);
    changeReview(previous.workspaceId, previous.threadId, () => previous);
    const next = makeReview({ taskId: "review-2" });
    changeReview(next.workspaceId, next.threadId, () => next);
    const historyFile = path.join(path.dirname(reviewFile(previous.workspaceId, previous.threadId)), "history", previous.threadId, `${previous.taskId}.json`);
    expect(JSON.parse(fs.readFileSync(historyFile, "utf8"))).toEqual(previous);
    expect(readReview(next.workspaceId, next.threadId)).toEqual(next);
  });

  it.each(["{ invalid JSON", JSON.stringify({ schemaVersion: 1, phase: "READY" })])("fails closed for corrupt state: %s", corrupt => {
    const file = reviewFile("workspace-1", "thread-1");
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, corrupt);
    const transform = vi.fn(() => readyReview());
    expect(() => readReview("workspace-1", "thread-1")).toThrow();
    expect(() => changeReview("workspace-1", "thread-1", transform)).toThrow();
    expect(transform).not.toHaveBeenCalled();
    expect(fs.readFileSync(file, "utf8")).toBe(corrupt);
    expect(fs.existsSync(`${file}.lock`)).toBe(false);
  });

  it("does not race another writer and does not remove its lock", () => {
    const state = makeReview();
    changeReview(state.workspaceId, state.threadId, () => state);
    const lock = `${reviewFile(state.workspaceId, state.threadId)}.lock`;
    fs.writeFileSync(lock, "another writer");
    const transform = vi.fn(() => readyReview());
    expect(() => changeReview(state.workspaceId, state.threadId, transform)).toThrow(/being updated/);
    expect(transform).not.toHaveBeenCalled();
    expect(fs.readFileSync(lock, "utf8")).toBe("another writer");
    expect(readReview(state.workspaceId, state.threadId)).toEqual(state);
  });

  it("releases its own lock after an invalid update without changing the saved state", () => {
    const state = makeReview();
    changeReview(state.workspaceId, state.threadId, () => state);
    expect(() => changeReview(state.workspaceId, state.threadId, previous => ({ ...previous!, round: 0 })))
      .toThrow();
    expect(fs.existsSync(`${reviewFile(state.workspaceId, state.threadId)}.lock`)).toBe(false);
    expect(readReview(state.workspaceId, state.threadId)).toEqual(state);
    expect(changeReview(state.workspaceId, state.threadId, previous => ({ ...previous!, round: 2 })).round).toBe(2);
  });
});
