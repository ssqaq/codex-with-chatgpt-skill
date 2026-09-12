import { redact } from "../logger/index.js";
import type { ReviewSession } from "./state.js";

function cleanLines(value: string): string[] {
  return value.split(/\r?\n/).map(line => line.trim()).filter(Boolean);
}

/** Keep later rounds small: only send lines that changed plus the active disagreement. */
export function buildRoundDelta(previous: string, next: string, disagreements = ""): string {
  const oldLines = new Set(cleanLines(previous));
  const changed = cleanLines(next).filter(line => !oldLines.has(line));
  const body = changed.join("\n");
  const disagreement = disagreements.trim();
  if (!body && !disagreement) throw new Error("本轮没有新增事实、修改点或分歧，不发送重复评审。");
  const result = [body ? `本轮新增或修改：\n${body}` : "", disagreement ? `本轮仍需解决的分歧：\n${disagreement}` : ""].filter(Boolean).join("\n\n");
  if (!result || result.length > 1800) throw new Error("本轮新增内容超过 1800 字，请先精简。 ".trim());
  return result;
}

export function buildReviewMessage(s: ReviewSession): string {
  const fullSummary = s.summary.trim();
  const summary = (s.round > 1 && s.roundDelta?.trim() ? s.roundDelta : fullSummary).trim();
  if (!fullSummary || fullSummary.length > 2400 || !summary || summary.length > 2400) throw new Error("请先整理不超过 2400 字的需求/方案摘要。");
  if (/```|diff --git|^@@ |-----BEGIN .*PRIVATE KEY-----/m.test(fullSummary) || redact(fullSummary) !== fullSummary ||
      /```|diff --git|^@@ |-----BEGIN .*PRIVATE KEY-----/m.test(summary) || redact(summary) !== summary) {
    throw new Error("评审只接收不含密钥、代码块、完整 diff 或日志的短摘要；请先精简脱敏。");
  }
  return ["[C2C]", `REVIEW_PROVIDER: ${s.reviewProvider.toUpperCase()}`, `TASK_ID: ${s.taskId}`,
    `ROUND: ${s.round}`, `REVIEW_MODE: ${s.reviewMode.toUpperCase()}`, "", s.round > 1 ? "ROUND_DELTA:" : "PLAN_SUMMARY:", summary, "", "REQUEST:",
    s.reviewProvider === "deepseek" ? "仅根据以下摘要独立评审；你没有本地文件连接器，不能声称已读取源码或运行测试。信息不足时列出缺失证据。" : "通过当前工作区连接器核对相关文件，只做评审。",
    "用中文给出同意点、分歧、建议、测试和成功标准。保留 TASK_ID 和 ROUND。",
    s.reviewMode === "consensus" ? "有实质分歧时返回 DECISION: REVISE；无分歧且方案完整时返回 DECISION: CONSENSUS。" : "只返回一次完整评审。证据不足时明确说明，不虚构通过结论。",
  ].join("\n");
}
