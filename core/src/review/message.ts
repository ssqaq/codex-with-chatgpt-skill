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
    `ROUND: ${s.round}`, `REVIEW_MODE: ${s.reviewMode.toUpperCase()}`, ...(s.reviewStage === "final" ? ["REVIEW_STAGE: FINAL", `PLAN_ROUNDS: ${s.planRoundCount}`] : []), "", s.reviewStage === "final" ? "EXECUTION_SUMMARY:" : s.round > 1 ? "ROUND_DELTA:" : "PLAN_SUMMARY:", summary, "", "REQUEST:",
    s.reviewProvider === "deepseek" ? "仅根据以下摘要独立评审；你没有本地文件连接器，不能声称已读取源码或运行测试。信息不足时列出缺失证据。" : "通过当前工作区连接器核对相关文件，只做评审。",
    s.round > 1 ? "只评本轮修改点与尚存问题；已同意的内容不重复展开。用中文简述结论、必要建议与验收，正文不超过 600 字；摘要要求更短时按更短上限。不使用代码围栏；TASK_ID、ROUND、DECISION 各用独立一行输出，不能省略或重复。" : "用中文给出同意点、分歧、建议、测试和成功标准，正文控制在 1800 字以内。不使用代码围栏；TASK_ID、ROUND、DECISION 各用独立一行输出，不能省略或重复。",
    s.reviewMode === "consensus" ? "有实质分歧时返回 DECISION: REVISE；无分歧且方案完整时返回 DECISION: CONSENSUS。" : "只返回一次完整评审，附 DECISION: REVISE 或 DECISION: CONSENSUS。证据不足时明确说明，不虚构通过结论。",
  ].join("\n");
}
