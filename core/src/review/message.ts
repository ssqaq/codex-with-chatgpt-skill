import { redact } from "../logger/index.js";
import type { ReviewSession } from "./state.js";

export function buildReviewMessage(s: ReviewSession): string {
  const summary = s.summary.trim();
  if (!summary || summary.length > 2400) throw new Error("请先整理不超过 2400 字的需求/方案摘要。");
  if (/```|diff --git|^@@ |-----BEGIN .*PRIVATE KEY-----/m.test(summary) || redact(summary) !== summary) {
    throw new Error("评审只接收不含密钥、代码块、完整 diff 或日志的短摘要；请先精简脱敏。");
  }
  return ["[C2C]", `REVIEW_PROVIDER: ${s.reviewProvider.toUpperCase()}`, `TASK_ID: ${s.taskId}`,
    `ROUND: ${s.round}`, `REVIEW_MODE: ${s.reviewMode.toUpperCase()}`, "", "PLAN_SUMMARY:", summary, "", "REQUEST:",
    s.reviewProvider === "deepseek" ? "仅根据以下摘要独立评审；你没有本地文件连接器，不能声称已读取源码或运行测试。信息不足时列出缺失证据。" : "通过当前工作区连接器核对相关文件，只做评审。",
    "用中文给出同意点、分歧、建议、测试和成功标准。保留 TASK_ID 和 ROUND。",
    s.reviewMode === "consensus" ? "有实质分歧时返回 DECISION: REVISE；无分歧且方案完整时返回 DECISION: CONSENSUS。" : "只返回一次完整评审。证据不足时明确说明，不虚构通过结论。",
  ].join("\n");
}
