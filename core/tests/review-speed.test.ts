import { describe, expect, it } from "vitest";
import { createHash } from "node:crypto";
import { newReview, assertReviewCompletion, beginReviewExecution, ReviewSessionSchema, prepareFinalReview } from "../src/review/state.js";
import { buildReviewMessage } from "../src/review/message.js";
import { observeReview, nextReviewCheck, trackWait } from "../src/review/wait.js";
import { acceptReply } from "../src/review/reply.js";
import { markTiming, timingSummary } from "../src/review/timing.js";

const start = new Date("2026-09-12T00:00:00Z");
const at = (seconds: number) => new Date(+start + seconds * 1000);
function waiting() {
  const s = newReview({ workspaceId: "speed-ws", threadId: "speed-thread", taskId: "speed-task", reviewProvider: "deepseek", reviewMode: "consensus", summary: "计时页面" });
  return trackWait(s, { ...s, phase: "WAITING", receiptStatus: "confirmed", evidenceFingerprint: "message-hash", chatUrl: "https://chat.deepseek.com/a/chat/s/speed-session" }, start, start.toISOString());
}
function observation(seconds = 1) {
  const s = waiting();
  return { taskId: s.taskId, threadId: s.threadId, round: s.round, source: "codex-in-app-browser", observationId: `observation-${seconds}`,
    observedAt: at(seconds).toISOString(), conversationUrl: s.chatUrl, status: "thinking" };
}
function reply() {
  const { status: _status, ...e } = observation();
  const text = "TASK_ID: speed-task\nROUND: 1\nDECISION: CONSENSUS\n同意；先覆盖恢复和取消测试。";
  return { ...e, role: "assistant", complete: true, messageFingerprint: "message-hash", replyFingerprint: createHash("sha256").update(text).digest("hex"), text };
}
describe("reply polling and measured timings", () => {
  it("checks immediately then within 30s, and never waits again after a complete reply", () => {
    expect(nextReviewCheck(waiting(), start).checkAfterMs).toBe(0);
    const s = observeReview(waiting(), observation(1), at(1));
    expect(nextReviewCheck(s, at(2))).toMatchObject({ checkAfterMs: 29000, intervalMs: 30000 });
    expect(nextReviewCheck(s, at(31)).checkAfterMs).toBe(0);
    expect(nextReviewCheck(s, at(40)).checkAfterMs).toBe(0);
    const late = observeReview(s, observation(61), at(61));
    expect(nextReviewCheck(late, at(62)).checkAfterMs).toBe(29000);
    const done = observeReview(late, { ...observation(62), status: "reply-ready" }, at(62));
    expect(nextReviewCheck(done, at(62)).nextAction).toBe("read-and-validate-current-reply");
    expect(done.reviewerConsensus).toBe(false);
  });
  it("keeps actual milestones across reload, reports missing data and polling delay", () => {
    let s = markTiming(waiting(), "messageReadyAt", at(-2).toISOString());
    s = observeReview(s, { ...observation(1), progressFingerprint: "a".repeat(64) }, at(1));
    s = observeReview(s, { ...observation(45), status: "reply-ready" }, at(45));
    s = ReviewSessionSchema.parse(JSON.parse(JSON.stringify(s)));
    const again = markTiming(s, "submittedAt", at(55).toISOString());
    expect(again.timings![0].submittedAt).toBe(start.toISOString());
    expect(again.wait!.maxObservationDelayMs).toBe(14000);
    expect(timingSummary(again, at(60)).rounds[0]).toMatchObject({ observedReplyWaitMs: 45000, preparationToSubmitMs: 2000, codexReviewMs: null });
  });
  it.each([[29.999, 0], [30, 0], [30.001, 1], [45, 15000]])("records the actual overrun for a %ss gap", (gap, delay) => {
    const s = observeReview(waiting(), observation(0), at(0));
    const checked = observeReview(s, observation(gap), at(gap));
    expect(checked.wait!.maxObservationDelayMs).toBe(delay);
    expect(timingSummary(checked, at(gap)).rounds[0].maxObservationDelayMs).toBe(delay);
    expect(checked.reviewerConsensus).toBe(false);
  });
  it("counts command time and reload against the original check deadline", () => {
    const checked = observeReview(waiting(), observation(1), at(1));
    const restored = ReviewSessionSchema.parse(JSON.parse(JSON.stringify(checked)));
    expect(nextReviewCheck(restored, at(21)).checkAfterMs).toBe(10000);
    expect(nextReviewCheck(restored, at(31)).checkAfterMs).toBe(0);
    expect(nextReviewCheck(restored, at(91)).checkAfterMs).toBe(0);
    expect(restored.wait!.lastCheckedAt).toBe(at(1).toISOString());
  });
  it("does not invent a send timestamp for a legacy record", () => {
    const s = waiting();
    const legacy = trackWait({ ...s, wait: undefined, timings: undefined }, { ...s, wait: undefined, timings: undefined }, start);
    expect(legacy.timings).toBeUndefined();
  });
  it.each(["BLOCKED", "CANCELLED", "DONE"] as const)("keeps %s action despite an old ready reply", phase => {
    const s = observeReview(waiting(), { ...observation(1), status: "reply-ready" }, at(1));
    expect(nextReviewCheck({ ...s, phase, nextAction: "stop" }, at(2)).nextAction).toBe("stop");
  });
  it("reports actual verified-to-submit and inter-round times", () => {
    const s=waiting();s.timings=[{round:1,messageReadyAt:at(-30).toISOString(),pageVerifiedAt:at(-10).toISOString(),submittedAt:start.toISOString(),codexReviewedAt:at(10).toISOString()}, {round:2,submittedAt:at(20).toISOString()}];
    expect(timingSummary(s,at(30)).rounds[0]).toMatchObject({submissionTargetMet:true,verifiedToSubmitMs:10000,reviewedToNextSubmitMs:10000});
  });
  it("records initial observation delay instead of inventing an immediate check",()=>{
    const s=observeReview(waiting(),observation(25),at(25));expect(s.wait?.maxObservationDelayMs).toBe(25000);
  });
});
describe("current complete assistant reply only", () => {
  it("records evidence idempotently without granting consensus", () => {
    const s = acceptReply(waiting(), reply(), at(1));
    expect(s.acceptedReply?.decision).toBe("CONSENSUS");
    expect(s.codexConsensus).toBe(false);
    expect(acceptReply(s, reply(), at(1))).toBe(s);
  });
  it.each([{ round: 2 }, { role: "user" }, { complete: false }, { taskId: "other" }, { threadId: "other" },
    { conversationUrl: "https://chat.deepseek.com/a/chat/s/other-session" }, { messageFingerprint: "old" },
    { text: "用户说 CONSENSUS" }, { text: "TASK_ID: speed-task\nROUND: 2\nDECISION: CONSENSUS" },
    { text: "TASK_ID: speed-task\nROUND: 1\nDECISION: REVISE\nDECISION: CONSENSUS" }])("rejects mismatched or incomplete proof %j", change => {
    const changed = { ...reply(), ...change };
    changed.replyFingerprint = createHash("sha256").update(changed.text).digest("hex");
    expect(() => acceptReply(waiting(), changed, at(1))).toThrow();
  });
  it("refuses stale, changed and cancelled replies", () => {
    expect(() => acceptReply(waiting(), reply(), at(70))).toThrow();
    const s = acceptReply(waiting(), reply(), at(1));
    expect(() => acceptReply(s, { ...reply(), replyFingerprint: "b".repeat(64) }, at(1))).toThrow();
    expect(() => acceptReply({ ...s, phase: "CANCELLED" }, reply(), at(1))).toThrow();
  });
  it("starting execution twice preserves its original timestamp; cancellation blocks execution", () => {
    const ready = { ...waiting(), phase: "READY" as const, replyReceived: true, reviewerConsensus: true, codexConsensus: true };
    const started = beginReviewExecution(ready);
    expect(beginReviewExecution(started)).toBe(started);
    expect(() => beginReviewExecution({ ...started, phase: "CANCELLED" })).toThrow();
    expect(() => beginReviewExecution({ ...started, receiptStatus: "unknown" })).toThrow();
    expect(() => beginReviewExecution({ ...started, disagreements: "new issue" })).toThrow();
  });
  it("final verification is separate from plan rounds and cannot restart execution",()=>{
    const started=beginReviewExecution({...waiting(),phase:'READY',replyReceived:true,reviewerConsensus:true,codexConsensus:true});
    const final=prepareFinalReview(started,'实际修改并通过测试，等待独立结果复核');
    expect(final).toMatchObject({reviewStage:'final',planRoundCount:1,round:2,phase:'PREPARING',codexConsensus:false});
    expect(final.executionStartedAt).toBe(started.executionStartedAt);
    expect(buildReviewMessage(final)).toContain('REVIEW_STAGE: FINAL');
    expect(buildReviewMessage(final)).toContain('EXECUTION_SUMMARY:');
    expect(()=>prepareFinalReview(final,'duplicate')).toThrow();
    expect(()=>prepareFinalReview({...started,phase:'CANCELLED'},'cancelled')).toThrow();
  });
});

describe("completion gate", () => {
  it("requires independent final agreement, current scope, and passing checks", () => {
    const started=beginReviewExecution({...waiting(),phase:'READY',replyReceived:true,reviewerConsensus:true,codexConsensus:true});
    const checked={...started,replyValidationVersion:1 as const,acceptedReply:{...reply(),decision:'CONSENSUS' as const}};
    expect(()=>assertReviewCompletion(checked,'PASS','PASS')).toThrow(/最终复核/);
    const final={...checked,reviewStage:'final' as const,executionVerifiedAt:at(4).toISOString()};
    expect(()=>assertReviewCompletion(final,'PASS','PASS')).not.toThrow();
    expect(()=>assertReviewCompletion({...final,acceptedReply:{...final.acceptedReply,decision:'REVISE'}},'PASS','PASS')).toThrow();
    for(const phase of ['CANCELLED','BLOCKED','WAITING','DONE'] as const) expect(()=>assertReviewCompletion({...final,phase},'PASS','PASS')).toThrow();
    expect(()=>assertReviewCompletion({...final,disagreements:'new issue'},'PASS','PASS')).toThrow();
    expect(()=>assertReviewCompletion(final,'FAIL','PASS')).toThrow();
    expect(()=>assertReviewCompletion(final,'PASS','FAIL')).toThrow();
  });
});
