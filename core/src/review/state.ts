import fs from "node:fs";
import path from "node:path";
import { z } from "zod";
import { ensureDir, getStateDir, writeSecureJson } from "../config/paths.js";
import { REVIEW_PROVIDERS, providerLabel, type ReviewMode, type ReviewProvider } from "./provider.js";
import { WaitSchema, waitProgress } from "./wait.js";

const id = z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/).refine(s => s !== "." && s !== "..");
const summary = z.string().max(2400);
export const ReviewSessionSchema = z.object({
  schemaVersion: z.literal(1), workspaceId: id, threadId: id, taskId: id,
  reviewProvider: z.enum(REVIEW_PROVIDERS), reviewMode: z.enum(["single", "consensus"]),
  round: z.number().int().positive().safe(),
  phase: z.enum(["PREPARING", "WAITING", "REVIEWED", "READY", "EXECUTING", "DONE", "BLOCKED", "CANCELLED"]),
  summary, agreements: summary.default(""), disagreements: summary.default(""), result: summary.default(""),
  reviewerConsensus: z.boolean(), codexConsensus: z.boolean(),
  receiptStatus: z.enum(["none", "confirmed", "unknown"]), replyReceived: z.boolean(),
  nextAction: z.string().max(500), blockedReason: summary.default(""),
  bindingRef: z.object({ skillName: z.enum(["deepseek-independent-review", "deepseek-consensus-review"]), taskId: id }).optional(),
  chatUrl: z.string().optional(), modelName: z.string().max(120).optional(), reasoningStrength: z.string().max(80).optional(),
  evidenceRevision: z.number().int().nonnegative().optional(),
  evidenceFingerprint: z.string().max(256).optional(),
  evidenceRound: z.number().int().positive().safe().optional(),
  wait: WaitSchema.optional(),
  recoveryRequired: z.boolean().optional(),
  createdAt: z.string().datetime(), updatedAt: z.string().datetime(),
  executionStartedAt: z.string().datetime().optional(),
  verification: z.object({ selfCheck: z.literal("PASS"), pageVerify: z.enum(["PASS", "NOT_APPLICABLE"]), at: z.string().datetime() }).optional(),
}).strict();
export type ReviewSession = z.infer<typeof ReviewSessionSchema>;
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

export function canExecuteReview(s: ReviewSession): boolean {
  return !s.recoveryRequired && s.phase === "READY" && s.replyReceived && s.receiptStatus === "confirmed" &&
    s.codexConsensus && s.reviewerConsensus && !s.disagreements && !s.blockedReason;
}

export function renderReview(s: ReviewSession): string {
  const status = { PREPARING: "准备评审", WAITING: "等待网页回复", REVIEWED: "已收到评审，Codex 核对中", READY: "评审通过，可开始修改",
    EXECUTING: "正在修改和测试", DONE: "已完成", BLOCKED: "已暂停", CANCELLED: "已取消" }[s.phase];
  return [
    `评审渠道：${providerLabel(s.reviewProvider)}`,
    s.reviewMode === "single" ? "评审方式：单次评审" : `多轮评审：第 ${s.round} 轮`,
    `当前状态：${status}`,
    ...(s.wait && (s.phase === "WAITING" || s.phase === "BLOCKED") ? [waitProgress(s).message] : []),
    `实际模型：${s.modelName ?? "尚未从页面确认"} / ${s.reasoningStrength ?? "尚未确认"}`,
    `同意的地方：${s.agreements || "尚未收到"}`,
    `分歧的地方：${s.disagreements || (s.replyReceived ? "无" : "尚未确认")}`,
    `评审结果：${s.result || "尚未收到完整回复"}`,
    ...(s.blockedReason ? [`原因：${s.blockedReason}`] : []),
    `执行门槛：${canExecuteReview(s) ? "允许修改" : s.phase === "EXECUTING" ? "修改中，尚未验收" : s.phase === "DONE" ? "已验收" : "不允许开始修改"}`,
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
