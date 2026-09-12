import { describe, expect, it } from "vitest";
import { buildReviewMessage, buildRoundDelta } from "../src/review/message.js";
import { beginReviewExecution, executionProgress, markReviewRateLimited, newReview, renderReview, type ReviewSession } from "../src/review/state.js";
import { REVIEW_IDLE_TIMEOUT_MINUTES, waitProgress } from "../src/review/wait.js";

function ready(overrides: Partial<ReviewSession> = {}): ReviewSession {
  return {
    ...newReview({ workspaceId: "ws-opt", threadId: "thread-opt", taskId: "task-opt", reviewProvider: "deepseek", reviewMode: "consensus", summary: "第一轮方案" }),
    phase: "READY", replyReceived: true, receiptStatus: "confirmed", reviewerConsensus: true, codexConsensus: true,
    result: "已达成共识", ...overrides,
  };
}

describe("多轮评审速度和状态优化", () => {
  it("后续轮次只发送新增内容和当前分歧，不重复上一轮全文", () => {
    const delta = buildRoundDelta("保留旧入口\n增加回滚测试", "保留旧入口\n增加回滚测试\n补充超时保护", "需要明确 503 的退避时间");
    expect(delta).toContain("补充超时保护");
    expect(delta).toContain("503");
    expect(delta).not.toContain("保留旧入口");
    const session = ready({ round: 2, summary: "保留旧入口\n增加回滚测试\n补充超时保护", roundDelta: delta });
    const message = buildReviewMessage(session);
    expect(message).toContain("ROUND_DELTA:");
    expect(message).toContain("补充超时保护");
    expect(message).not.toContain("PLAN_SUMMARY:");
    expect(message).not.toContain("保留旧入口");
  });

  it("把网页等待和 Codex 执行分别计时", () => {
    const started = new Date("2026-09-12T00:00:00.000Z");
    const executing = ready({ phase: "EXECUTING", executionStartedAt: started.toISOString(), executionLastReportedMinute: 2 });
    const progress = executionProgress(executing, new Date("2026-09-12T00:04:00.000Z"));
    expect(progress.minute).toBe(4);
    expect(progress.shouldReport).toBe(true);
    expect(progress.message).toContain("Codex 执行中");
    expect(renderReview(executing, new Date("2026-09-12T00:04:00.000Z"))).toContain("执行中，已进行约 4 分钟");
  });

  it("连续 10 分钟没有新回复才暂停，不把普通等待当成卡死", () => {
    const started = new Date("2026-09-12T00:00:00.000Z");
    const waiting = { ...ready({ phase: "WAITING" }), wait: {
      round: 1, startedAt: started.toISOString(), lastProgressAt: started.toISOString(), pageStatus: "thinking" as const, lastReportedMinute: -1,
    } };
    expect(waitProgress(waiting, new Date("2026-09-12T00:09:59.000Z")).pauseReason).toBe("");
    expect(waitProgress(waiting, new Date("2026-09-12T00:10:00.000Z")).pauseReason).toContain(`${REVIEW_IDLE_TIMEOUT_MINUTES} 分钟`);
  });

  it("503 使用递增退避，仍然关闭发送和执行权限", () => {
    const blocked = markReviewRateLimited(ready(), { source: "reviewer", statusCode: "503", now: new Date("2026-09-12T00:00:00.000Z") });
    expect(blocked.rateLimit).toMatchObject({ statusCode: "503", attempts: 1, backoffSeconds: 60, retryAfterAt: "2026-09-12T00:01:00.000Z" });
    expect(blocked.phase).toBe("BLOCKED");
    expect(blocked.blockedReason).toContain("503");
    expect(renderReview(blocked)).toContain("服务暂时不可用");
  });

  it("共识后计划模式会记录自动接力请求，不等待用户再次发送继续", () => {
    const handoff = beginReviewExecution(ready(), { planModeDetected: true });
    expect(handoff.executionMode).toBe("handoff-required");
    expect(handoff.handoffRequestedAt).toBeTruthy();
    expect(handoff.nextAction).toContain("已记录普通执行任务接力请求");
  });
});
