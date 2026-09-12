import fs from "node:fs";
import path from "node:path";
import { z } from "zod";
import { ensureDir, getStateDir, writeSecureJson } from "../config/paths.js";
import { REVIEW_PROVIDERS, providerLabel, type ReviewMode, type ReviewProvider } from "./provider.js";
import { WaitSchema, waitProgress } from "./wait.js";

const id = z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/).refine(s => s !== "." && s !== "..");
const summary = z.string().max(2400);
const roundDelta = z.string().max(1800);
const reviewPhase = z.enum(["PREPARING", "WAITING", "REVIEWED", "READY", "EXECUTING", "DONE", "BLOCKED", "CANCELLED"]);
const RateLimitSchema = z.object({
  detectedAt: z.string().datetime(),
  retryAfterAt: z.string().datetime().optional(),
  statusCode: z.enum(["429", "503"]).default("429"),
  backoffSeconds: z.number().int().positive().max(86_400).optional(),
  attempts: z.number().int().nonnegative().safe(),
  source: z.enum(["reviewer", "codex-service", "browser", "unknown"]),
  message: z.string().max(240),
  resumePhase: reviewPhase.optional(),
  resumeNextAction: z.string().max(500).optional(),
}).strict();
export const ReviewSessionSchema = z.object({
  schemaVersion: z.literal(1), workspaceId: id, threadId: id, taskId: id,
  reviewProvider: z.enum(REVIEW_PROVIDERS), reviewMode: z.enum(["single", "consensus"]),
  round: z.number().int().positive().safe(),
  phase: reviewPhase,
  summary, previousSummary: summary.optional(), roundDelta: roundDelta.optional(),
  agreements: summary.default(""), disagreements: summary.default(""), result: summary.default(""),
  reviewerConsensus: z.boolean(), codexConsensus: z.boolean(),
  receiptStatus: z.enum(["none", "confirmed", "unknown"]), replyReceived: z.boolean(),
  nextAction: z.string().max(500), blockedReason: summary.default(""),
  bindingRef: z.object({ skillName: z.enum(["deepseek-independent-review", "deepseek-consensus-review"]), taskId: id }).optional(),
  chatUrl: z.string().optional(), modelName: z.string().max(120).optional(), reasoningStrength: z.string().max(80).optional(),
  evidenceRevision: z.number().int().nonnegative().optional(),
  evidenceFingerprint: z.string().max(256).optional(),
  evidenceRound: z.number().int().positive().safe().optional(),
  wait: WaitSchema.optional(),
  rateLimit: RateLimitSchema.optional(),
  recoveryRequired: z.boolean().optional(),
  executionMode: z.enum(["same-thread", "handoff-required", "handoff-started"]).optional(),
  executionThreadId: id.optional(),
  handoffRequestedAt: z.string().datetime().optional(),
  createdAt: z.string().datetime(), updatedAt: z.string().datetime(),
  executionStartedAt: z.string().datetime().optional(),
  executionLastReportedMinute: z.number().int().min(-1).optional(),
  verification: z.object({ selfCheck: z.literal("PASS"), pageVerify: z.enum(["PASS", "NOT_APPLICABLE"]), at: z.string().datetime() }).optional(),
}).strict();
export type ReviewSession = z.infer<typeof ReviewSessionSchema>;
export type ReviewRateLimit = z.infer<typeof RateLimitSchema>;
export const isReviewTerminal = (s: ReviewSession): boolean => s.phase === "DONE" || s.phase === "CANCELLED";

export function reviewFile(workspaceId: string, threadId: string): string {
  return path.join(getStateDir(), "reviews", id.parse(workspaceId), `${id.parse(threadId)}.json`);
}

export function readReview(workspaceId: string, threadId: string): ReviewSession | null {
  const file = reviewFile(workspaceId, threadId);
  if (!fs.existsSync(file)) return null;
  // Corruption must not silently become a new task or a send permission.
  const s = ReviewSessionSchema.parse(JSON.parse(fs.readFileSync(file, "utf8")));
  if (s.workspaceId !== workspaceId || s.threadId !== threadId) throw new Error("review ownership mismatch");
  return s;
}

export function changeReview(workspaceId: string, threadId: string, transform: (s: ReviewSession | null) => ReviewSession): ReviewSession {
  const file = reviewFile(workspaceId, threadId);
  ensureDir(path.dirname(file));
  const lock = `${file}.lock`;
  let fd: number;
  try { fd = fs.openSync(lock, "wx", 0o600); }
  catch { throw new Error("review is being updated; retry once after the current command finishes"); }
  try {
    const previous = readReview(workspaceId, threadId);
    const next = ReviewSessionSchema.parse(transform(previous));
    if (next.workspaceId !== workspaceId || next.threadId !== threadId) throw new Error("review ownership mismatch");
    if (previous && previous.taskId !== next.taskId) {
      if (!isReviewTerminal(previous)) throw new Error("active review must be completed or cancelled before a new task");
      writeSecureJson(path.join(path.dirname(file), "history", threadId, `${id.parse(previous.taskId)}.json`), previous);
    }
    writeSecureJson(file, next);
    // A validated local checkpoint; it is never a browser receipt or send permit.
    writeSecureJson(`${file}.checkpoint`, next);
    fs.appendFileSync(`${file}.audit.jsonl`, JSON.stringify({ at: next.updatedAt, taskId: next.taskId,
      threadId, round: next.round, phase: next.phase }) + "\n", { mode: 0o600 });
    return next;
  } finally { fs.closeSync(fd); fs.rmSync(lock, { force: true }); }
}

export function newReview(input: { workspaceId: string; threadId: string; taskId: string; reviewProvider: ReviewProvider; reviewMode: ReviewMode; summary: string }): ReviewSession {
  const now = new Date().toISOString();
  return ReviewSessionSchema.parse({ ...input, schemaVersion: 1, round: 1, phase: "PREPARING",
    reviewerConsensus: false, codexConsensus: false, receiptStatus: "none", replyReceived: false,
    nextAction: input.reviewProvider === "deepseek" ? "activate-deepseek-skill" : "continue-chatgpt-protocol",
    bindingRef: input.reviewProvider === "deepseek" ? {
      skillName: input.reviewMode === "single" ? "deepseek-independent-review" : "deepseek-consensus-review", taskId: input.taskId,
    } : undefined, createdAt: now, updatedAt: now,
  });
}

function hasExecutionConsensus(s: ReviewSession): boolean {
  return !s.recoveryRequired && s.phase === "READY" && s.replyReceived && s.receiptStatus === "confirmed" &&
    s.codexConsensus && s.reviewerConsensus && !s.disagreements && !s.blockedReason && !s.rateLimit;
}

export function canExecuteReview(s: ReviewSession): boolean {
  return hasExecutionConsensus(s) && s.executionMode !== "handoff-required";
}

/** A retry is never automatic. The caller must request one explicitly; a server-provided
 * Retry-After deadline, when present, must also have elapsed. */
export function canRetryRateLimit(s: ReviewSession, now = new Date()): boolean {
  if (!s.rateLimit) return true;
  if (!s.rateLimit.retryAfterAt) return true;
  return Date.parse(s.rateLimit.retryAfterAt) <= now.getTime();
}

export function markReviewRateLimited(
  s: ReviewSession,
  input: { source: ReviewRateLimit["source"]; statusCode?: ReviewRateLimit["statusCode"]; retryAfterSeconds?: number; message?: string; now?: Date },
): ReviewSession {
  const now = input.now ?? new Date();
  const statusCode = input.statusCode ?? "429";
  const attempts = (s.rateLimit?.attempts ?? 0) + 1;
  const defaultBackoff = Math.min(statusCode === "503" ? 60 * 2 ** (attempts - 1) : 30 * 2 ** (attempts - 1), 900);
  const suppliedSeconds = input.retryAfterSeconds !== undefined && Number.isSafeInteger(input.retryAfterSeconds) &&
    input.retryAfterSeconds > 0 && input.retryAfterSeconds <= 86_400 ? input.retryAfterSeconds : undefined;
  const seconds = suppliedSeconds ?? defaultBackoff;
  const retryAfterAt = new Date(now.getTime() + seconds * 1000).toISOString();
  const label = statusCode === "503" ? "服务暂时不可用（503）" : "评审服务暂时限流（429）";
  return {
    ...s,
    phase: "BLOCKED",
    reviewerConsensus: false,
    codexConsensus: false,
    rateLimit: { detectedAt: now.toISOString(), retryAfterAt, statusCode, backoffSeconds: seconds, attempts, source: input.source,
      resumePhase: s.rateLimit?.resumePhase ?? (s.phase === "BLOCKED" ? undefined : s.phase),
      resumeNextAction: s.rateLimit?.resumeNextAction ?? (s.phase === "BLOCKED" ? undefined : s.nextAction),
      // Never persist service response text: it can contain private headers,
      // tokens, or account-specific details. The optional message is accepted
      // for API compatibility but deliberately ignored.
      message: `${label}，已停止自动重试` },
    blockedReason: `${label}，已停止自动重试；不会重复发送或重复创建会话。`,
    nextAction: `等待 ${retryAfterAt} 之后，再用 --retry-rate-limit 进行一次恢复检查`,
  };
}

export function clearReviewRateLimit(s: ReviewSession, nextAction?: string): ReviewSession {
  const resumePhase = s.rateLimit?.resumePhase;
  return { ...s, rateLimit: undefined, phase: resumePhase && !["DONE", "CANCELLED"].includes(resumePhase) ? resumePhase : s.phase,
    blockedReason: "", nextAction: nextAction ?? s.rateLimit?.resumeNextAction ?? s.nextAction };
}

export function beginReviewExecution(
  s: ReviewSession,
  input: { planModeDetected?: boolean; executionThreadId?: string } = {}
): ReviewSession {
  if (!hasExecutionConsensus(s)) throw new Error("尚未收到完整评审并通过双方核对，禁止开始修改。");
  const targetThreadId = input.executionThreadId?.trim();

  if (input.planModeDetected && !targetThreadId) {
    return {
      ...s,
      executionMode: "handoff-required",
      executionThreadId: undefined,
      handoffRequestedAt: new Date().toISOString(),
      nextAction: "已自动发起普通执行任务接力；立即在同一工作区创建普通执行任务并接手当前共识摘要，不要重新评审或等待用户再发继续",
    };
  }

  if (targetThreadId) {
    id.parse(targetThreadId);
    if (targetThreadId === s.threadId) throw new Error("正常执行任务必须使用新的任务编号，不能仍指向只做计划方案的原任务。");
    if (s.executionMode !== "handoff-required" && !input.planModeDetected) {
      throw new Error("当前评审没有记录计划模式阻塞，不能跳过转交准备。");
    }
    return {
      ...s,
      phase: "EXECUTING",
      executionMode: "handoff-started",
      executionThreadId: targetThreadId,
      executionStartedAt: new Date().toISOString(),
      executionLastReportedMinute: -1,
      handoffRequestedAt: s.handoffRequestedAt,
      nextAction: "普通执行任务已接手；Codex 修改文件、运行测试并检查页面",
    };
  }

  if (s.executionMode === "handoff-required") {
    throw new Error("当前任务只能出方案，必须先创建普通执行任务并提供真实的新任务编号。");
  }

  return {
    ...s,
    phase: "EXECUTING",
    executionMode: "same-thread",
    executionThreadId: s.threadId,
    executionStartedAt: new Date().toISOString(),
    executionLastReportedMinute: -1,
    nextAction: "Codex 修改文件、运行测试并检查页面",
  };
}

export function executionProgress(s: ReviewSession, now = new Date()): { message: string; minute: number; shouldReport: boolean } {
  if (s.phase !== "EXECUTING" || !s.executionStartedAt) return { message: "尚未开始执行", minute: 0, shouldReport: false };
  const minute = Math.max(0, Math.floor((now.getTime() - Date.parse(s.executionStartedAt)) / 60000));
  return { message: `Codex 执行中，已进行约 ${minute} 分钟`, minute,
    shouldReport: minute > (s.executionLastReportedMinute ?? -1) };
}

export function renderReview(s: ReviewSession, now = new Date()): string {
  const status = { PREPARING: "准备评审", WAITING: "等待网页回复", REVIEWED: "已收到评审，Codex 核对中", READY: s.executionMode === "handoff-required" ? "评审通过，正在转交正常执行任务" : "评审通过，可开始修改",
    EXECUTING: "正在修改和测试", DONE: "已完成", BLOCKED: "已暂停", CANCELLED: "已取消" }[s.phase];
  return [
    `评审渠道：${providerLabel(s.reviewProvider)}`,
    s.reviewMode === "single" ? "评审方式：单次评审" : `多轮评审：第 ${s.round} 轮`,
    `当前状态：${status}`,
    ...(s.wait && (s.phase === "WAITING" || s.phase === "BLOCKED") ? [waitProgress(s, now).message] : []),
    ...(s.phase === "EXECUTING" ? [executionProgress(s, now).message] : []),
    ...(s.rateLimit ? [`${s.rateLimit.statusCode === "503" ? "服务暂时不可用" : "服务限流"}：第 ${s.rateLimit.attempts} 次（${s.rateLimit.statusCode}），等待服务恢复后再试${s.rateLimit.retryAfterAt ? `（可在 ${s.rateLimit.retryAfterAt} 后检查）` : ""}；不会重复发送`] : []),
    `实际模型：${s.modelName ?? "尚未从页面确认"} / ${s.reasoningStrength ?? "尚未确认"}`,
    `同意的地方：${s.agreements || "尚未收到"}`,
    `分歧的地方：${s.disagreements || (s.replyReceived ? "无" : "尚未确认")}`,
    `评审结果：${s.result || "尚未收到完整回复"}`,
    ...(s.blockedReason ? [`原因：${s.blockedReason}`] : []),
    `执行门槛：${s.executionMode === "handoff-required" ? "共识已通过，等待正常执行任务接手" : canExecuteReview(s) ? "允许修改" : s.phase === "EXECUTING" ? "修改中，尚未验收" : s.phase === "DONE" ? "已验收" : "不允许开始修改"}`,
    ...(s.executionMode === "handoff-started" && s.executionThreadId ? [`执行任务：${s.executionThreadId}`] : []),
    `下一步：${s.nextAction}`,
  ].join("\n");
}

export function recoverReview(workspaceId: string, threadId: string, taskId: string): ReviewSession {
  const file = reviewFile(workspaceId, threadId);
  const lock = `${file}.lock`;
  const fd = fs.openSync(lock, "wx", 0o600);
  try {
    try {
      const current = readReview(workspaceId, threadId);
      if (current) {
        if (current.taskId !== taskId) throw new Error("task-mismatch");
        return current;
      }
    } catch (error) {
      if ((error as Error).message === "task-mismatch" || (error as Error).message === "review ownership mismatch") throw error;
    }
    let saved: ReviewSession;
    try { saved = ReviewSessionSchema.parse(JSON.parse(fs.readFileSync(`${file}.checkpoint`, "utf8"))); }
    catch { throw new Error("没有可验证的恢复记录，保留原文件；不能新建任务或重发。"); }
    if (saved.workspaceId !== workspaceId || saved.threadId !== threadId || saved.taskId !== taskId) throw new Error("恢复记录不属于当前任务。");
    if (fs.existsSync(file)) fs.copyFileSync(file, `${file}.${Date.now()}.damaged`, fs.constants.COPYFILE_EXCL);
    const next: ReviewSession = isReviewTerminal(saved) ? saved : { ...saved, recoveryRequired: true, phase: "BLOCKED",
      reviewerConsensus: false, codexConsensus: false, blockedReason: "已恢复本地记录，尚未重新核对原网页和回执",
      nextAction: `从第 ${saved.round} 轮继续，上一轮停在 ${saved.phase}；先观察原网页，再同步真实回执`, updatedAt: new Date().toISOString() };
    writeSecureJson(file, next);
    return next;
  } finally { fs.closeSync(fd); fs.rmSync(lock, { force: true }); }
}
