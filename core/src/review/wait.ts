import { z } from "zod";
import type { ReviewSession } from "./state.js";

export const WaitSchema = z.object({
  round: z.number().int().positive(), startedAt: z.string().datetime(),
  lastCheckedAt: z.string().datetime().optional(), lastProgressAt: z.string().datetime(),
  lastObservationId: z.string().max(200).optional(), progressFingerprint: z.string().max(128).optional(),
  pageStatus: z.enum(["unverified", "thinking", "reply-ready", "unavailable", "login-required"]),
  lastReportedMinute: z.number().int().min(-1).default(-1),
}).strict();
export type ReviewWait = z.infer<typeof WaitSchema>;
export const ObservationSchema = z.object({
  taskId: z.string(), threadId: z.string(), round: z.number().int().positive(),
  observedAt: z.string().datetime(), observationId: z.string().min(1).max(200),
  source: z.literal("codex-in-app-browser"), conversationUrl: z.string().url(),
  status: z.enum(["thinking", "reply-ready", "unavailable", "login-required"]),
  progressFingerprint: z.string().regex(/^[a-f0-9]{64}$/).optional(),
}).strict();
export type ReviewObservation = z.infer<typeof ObservationSchema>;

// Local commands never claim to have inspected a page. Only a fresh browser
// observation changes lastCheckedAt. Equal page snapshots are normal while thinking.
export function trackWait(previous: ReviewSession, next: ReviewSession, now = new Date(), sentAt?: string): ReviewSession {
  if (next.phase !== "WAITING") return next;
  if (previous.wait?.round === next.round) return { ...next, wait: previous.wait };
  if (next.wait?.round === next.round) return next;
  const sent = sentAt ? Date.parse(sentAt) : NaN;
  const at = Number.isFinite(sent) && sent <= now.getTime() + 5000 ? new Date(Math.min(sent, now.getTime())).toISOString() : now.toISOString();
  return { ...next, wait: { round: next.round, startedAt: at, lastProgressAt: at, pageStatus: "unverified", lastReportedMinute: -1 } };
}

export function observeReview(s: ReviewSession, input: unknown, now = new Date()): ReviewSession {
  const e = ObservationSchema.parse(input);
  if (["DONE", "CANCELLED", "EXECUTING"].includes(s.phase)) throw new Error("当前任务不接受等待观察。");
  if (e.taskId !== s.taskId || e.threadId !== s.threadId || e.round !== s.round) throw new Error("网页观察属于其他任务或轮次。");
  if (!s.chatUrl || new URL(s.chatUrl).href !== new URL(e.conversationUrl).href) throw new Error("网页观察不是原评审会话。");
  const age = now.getTime() - Date.parse(e.observedAt);
  if (age < -5000 || age > 60000) throw new Error("网页观察已过期，请重新读取原页面。");
  const wait = s.wait?.round === s.round ? s.wait : {
    round: s.round, startedAt: now.toISOString(), lastProgressAt: now.toISOString(), pageStatus: "unverified" as const, lastReportedMinute: -1,
  };
  if (wait.lastCheckedAt && Date.parse(e.observedAt) <= Date.parse(wait.lastCheckedAt)) throw new Error("拒绝旧网页观察，计时未重置。");
  if (wait.lastObservationId === e.observationId) throw new Error("该网页观察已记录，不能当作新检查。");
  const changed = !!e.progressFingerprint && e.progressFingerprint !== wait.progressFingerprint;
  const next = { ...s, wait: { ...wait, lastCheckedAt: e.observedAt, lastObservationId: e.observationId,
    pageStatus: e.status, progressFingerprint: e.progressFingerprint ?? wait.progressFingerprint,
    lastProgressAt: changed ? e.observedAt : wait.lastProgressAt } };
  // Observing a finished answer never grants consensus or execution permission.
  if (e.status === "unavailable" || e.status === "login-required") return { ...next, phase: "BLOCKED",
    blockedReason: e.status === "login-required" ? "原评审页面需要登录" : "无法读取原评审页面",
    nextAction: "恢复原页面后重新检查；不重发、不修改" };
  return next;
}

export function waitProgress(s: ReviewSession, now = new Date()): { message: string; minute: number; shouldReport: boolean; pauseReason: string } {
  const w = s.wait;
  if (!w || w.round !== s.round) return { message: "尚未确认本轮等待起点", minute: 0, shouldReport: false, pauseReason: "" };
  const minute = Math.max(0, Math.floor((now.getTime() - Date.parse(w.startedAt)) / 60000));
  const stale = !w.lastCheckedAt || now.getTime() - Date.parse(w.lastCheckedAt) > 90000;
  const idle = now.getTime() - Date.parse(w.lastProgressAt);
  const pauseReason = w.pageStatus === "unavailable" || w.pageStatus === "login-required" ? "原页面不可用，需要恢复" :
    idle >= 600000 && w.pageStatus !== "reply-ready" ? "已连续 10 分钟没有确认到新回复内容，暂停并检查原页面" : "";
  const detail = stale ? "最近未能确认网页状态" : w.pageStatus === "thinking" ? "最近检查：网页仍显示生成中" :
    w.pageStatus === "reply-ready" ? "网页回复已结束，正在核对本轮结果" : "网页状态需要核对";
  const label = s.reviewMode === "consensus" ? `多轮评审：第 ${s.round} 轮` : "单次评审";
  return { message: `${label}（等待回复，已等待约 ${minute} 分钟）\n${detail}\n最近检查时间：${w.lastCheckedAt ?? "尚未检查"}`,
    minute, shouldReport: minute > w.lastReportedMinute, pauseReason };
}
