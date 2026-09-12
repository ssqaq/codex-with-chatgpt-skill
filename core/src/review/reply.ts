import { z } from "zod";
import { createHash } from "node:crypto";
import type { ReviewSession } from "./state.js";
import { markTiming } from "./timing.js";

export const ReplyEvidenceSchema = z.object({
  taskId: z.string(), threadId: z.string(), round: z.number().int().positive(),
  source: z.literal("codex-in-app-browser"), observationId: z.string().min(1).max(200),
  observedAt: z.string().datetime(), conversationUrl: z.string().url(),
  role: z.literal("assistant"), complete: z.literal(true),
  messageFingerprint: z.string().min(1).max(256), replyFingerprint: z.string().regex(/^[a-f0-9]{64}$/),
  text: z.string().min(1).max(2400),
}).strict();
export const AcceptedReplySchema = ReplyEvidenceSchema.omit({ text: true }).extend({ decision: z.enum(["REVISE", "CONSENSUS"]) });

export function acceptReply(s: ReviewSession, input: unknown, now = new Date()): ReviewSession {
  const e = ReplyEvidenceSchema.parse(input);
  if (createHash("sha256").update(e.text).digest("hex") !== e.replyFingerprint) throw new Error("回复正文与指纹不一致。");
  if (["DONE", "CANCELLED", "EXECUTING"].includes(s.phase) || s.rateLimit || s.recoveryRequired) throw new Error("当前状态不能接收新评审回复。");
  if (e.taskId !== s.taskId || e.threadId !== s.threadId || e.round !== s.round || e.conversationUrl !== s.chatUrl ||
      s.receiptStatus !== "confirmed" || e.messageFingerprint !== s.evidenceFingerprint) throw new Error("回复不属于本轮已确认发送的原会话。");
  const age = +now - Date.parse(e.observedAt);
  if (age < -5000 || age > 60000) throw new Error("回复证据已过期，请重新读取原页面。");
  const field = (name: string) => [...e.text.matchAll(new RegExp(`^${name}:\\s*([^\\r\\n]+)$`, "gm"))].map(m => m[1].trim());
  const task = field("TASK_ID"), round = field("ROUND"), decisions = field("DECISION");
  if (task.length !== 1 || task[0] !== s.taskId || round.length !== 1 || round[0] !== String(s.round) ||
      decisions.length !== 1 || !["REVISE", "CONSENSUS"].includes(decisions[0])) throw new Error("本轮完整助手回复缺少唯一、匹配的 TASK_ID、ROUND 或 DECISION。");
  const decision = decisions[0] as "REVISE" | "CONSENSUS";
  if (s.acceptedReply?.round === s.round) {
    if (s.acceptedReply.replyFingerprint !== e.replyFingerprint || s.acceptedReply.decision !== decision) throw new Error("本轮已记录不同回复，禁止静默覆盖。");
    return s;
  }
  const { text: _text, ...proof } = e;
  return markTiming({ ...s, acceptedReply: { ...proof, decision } }, "replyCompletedObservedAt", e.observedAt);
}
