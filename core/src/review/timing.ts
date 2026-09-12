import { z } from "zod";
import type { ReviewSession } from "./state.js";

const instant = z.string().datetime();
export const RoundTimingSchema = z.object({
  round: z.number().int().positive(),
  messageReadyAt: instant.optional(), pageVerifiedAt: instant.optional(), submittedAt: instant.optional(),
  firstReplyObservedAt: instant.optional(), replyCompletedObservedAt: instant.optional(),
  codexReviewedAt: instant.optional(), consensusAt: instant.optional(),
  recoveryStartedAt: instant.optional(), recoveryFinishedAt: instant.optional(),
  maxObservationDelayMs: z.number().nonnegative().optional(),
}).strict();
export type RoundTiming = z.infer<typeof RoundTimingSchema>;
type Milestone = Exclude<keyof RoundTiming, "round" | "maxObservationDelayMs">;

// First observation wins. A reload/sync cannot turn old evidence into a new event.
export function markTiming(s: ReviewSession, key: Milestone, at: string): ReviewSession {
  const parsed = Date.parse(at);
  if (!Number.isFinite(parsed)) return s;
  const timings = [...(s.timings ?? [])];
  const index = timings.findIndex(t => t.round === s.round);
  const row: RoundTiming = index < 0 ? { round: s.round } : { ...timings[index] };
  if (row[key]) return s;
  row[key] = new Date(parsed).toISOString();
  if (index < 0) timings.push(row); else timings[index] = row;
  return { ...s, timings };
}

export function timingSummary(s: ReviewSession, now = new Date()) {
  const elapsed = (a?: string, b?: string) => a && b && Date.parse(b) >= Date.parse(a) ? Date.parse(b) - Date.parse(a) : null;
  return {
    totalElapsedMs: elapsed(s.createdAt, s.executionCompletedAt ?? now.toISOString()),
    executionElapsedMs: elapsed(s.executionStartedAt, s.executionVerifiedAt ?? s.executionCompletedAt ?? now.toISOString()),
    finalReviewElapsedMs: elapsed(s.executionVerifiedAt, s.executionCompletedAt ?? now.toISOString()),
    rounds: (s.timings ?? []).map(t => ({ ...t,
      preparationToSubmitMs: elapsed(t.messageReadyAt, t.submittedAt),
      verifiedToSubmitMs: elapsed(t.pageVerifiedAt, t.submittedAt),
      submissionTargetMet: elapsed(t.pageVerifiedAt, t.submittedAt) === null ? null : elapsed(t.pageVerifiedAt, t.submittedAt)! <= 30000,
      observedReplyWaitMs: elapsed(t.submittedAt, t.replyCompletedObservedAt),
      codexReviewMs: elapsed(t.replyCompletedObservedAt, t.codexReviewedAt),
      recoveryElapsedMs: elapsed(t.recoveryStartedAt, t.recoveryFinishedAt),
      nextRoundSubmittedAt: s.timings?.find(next => next.round === t.round + 1)?.submittedAt ?? null,
      reviewedToNextSubmitMs: elapsed(t.codexReviewedAt, s.timings?.find(next => next.round === t.round + 1)?.submittedAt),
    })),
    note: "未记录的时间为 null；网页等待含观察间隔及期间恢复，不能与恢复时长重复相加。网页思考时间不是完整耗时。",
  };
}
