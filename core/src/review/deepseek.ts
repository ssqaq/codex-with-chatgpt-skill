import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { ReviewMode } from "./provider.js";
import { ReviewSessionSchema, type ReviewSession } from "./state.js";
import { trackWait } from "./wait.js";
import { createHash } from "node:crypto";

const execFileAsync = promisify(execFile);
export const deepseekSkillName = (mode: ReviewMode): string => mode === "single" ? "deepseek-independent-review" : "deepseek-consensus-review";
export function deepseekStateDir(): string {
  return path.resolve(process.env.C2C_DEEPSEEK_STATE_DIR ?? path.join(os.homedir(), ".codex", "deepseek-review-state"));
}
export function deepseekDependency(mode: ReviewMode): { available: boolean; skillName: string; skillPath: string; missing: string[]; changed: string[]; requiredVersion: string; installedVersion: string | null } {
  const skillName = deepseekSkillName(mode);
  const roots = process.env.C2C_REVIEW_SKILLS_ROOT ? [process.env.C2C_REVIEW_SKILLS_ROOT] : [
    path.join(process.env.CODEX_HOME ?? path.join(os.homedir(), ".codex"), "skills"), path.join(os.homedir(), ".agents", "skills"),
  ];
  const root = roots.find(r => fs.existsSync(path.join(r, skillName, "SKILL.md"))) ?? roots[0];
  const skillPath = path.resolve(root, skillName);
  const manifest = JSON.parse(fs.readFileSync(new URL("../../../bundled-skills/manifest.json", import.meta.url), "utf8")) as { version: string; skills: Record<string, Record<string, string>> };
  const missing: string[] = [], changed: string[] = [];
  for (const [relative, expected] of Object.entries(manifest.skills[skillName])) {
    const file = path.join(skillPath, relative);
    if (!fs.existsSync(file)) { missing.push(relative); continue; }
    const actual = createHash("sha256").update(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, "").replace(/\r\n/g, "\n")).digest("hex");
    if (actual !== expected) changed.push(relative);
  }
  const versionFile = path.join(skillPath, "VERSION");
  const installedVersion = fs.existsSync(versionFile) ? fs.readFileSync(versionFile, "utf8").trim() : null;
  return { available: !missing.length && !changed.length && installedVersion === manifest.version,
    skillName, skillPath, missing, changed, requiredVersion: manifest.version, installedVersion };
}

/** No browser or HTTP implementation here: reuse the installed skill's state/lease/recovery engine. */
export async function runDeepseek(s: ReviewSession, action: "activate" | "advance" | "cancel" | "complete"): Promise<Record<string, unknown>> {
  ReviewSessionSchema.parse(s);
  if (s.reviewProvider !== "deepseek") throw new Error("当前任务不是 DeepSeek 评审，未执行专用脚本。");
  const dep = deepseekDependency(s.reviewMode);
  if (!dep.available) throw new Error(`${dep.skillName} 缺少配套文件、文件已改变或版本不同（本机 ${dep.installedVersion ?? "未知"} / 需要 ${dep.requiredVersion}）；请运行仓库 scripts/install-review-skills.mjs 修复；未发送。`);
  // The installed activator unconditionally passes C1/R1, including on resume.
  // Existing tasks must use its advance engine instead or later rounds regress.
  const previous = readObject(path.join(deepseekStateDir(), `${s.taskId}.json`));
  if (previous && (previous.taskId !== s.taskId || previous.codexThreadId !== s.threadId || previous.skillName !== dep.skillName)) {
    throw new Error("DeepSeek 原任务归属或评审方式不一致，未执行脚本。");
  }
  if (!previous && (s.evidenceRevision !== undefined || s.round > 1)) throw new Error("DeepSeek 原任务状态缺失，禁止重新激活或重发。");
  const operation = action === "activate" && previous ? "advance" : action;
  const script = operation === "activate" ? "activate_review.ps1" : operation === "advance" ? "advance_review_workflow.ps1" : "session_binding.ps1";
  const args = ["-NoProfile", "-NonInteractive", "-File", path.join(dep.skillPath, "scripts", script), "-TaskId", s.taskId, "-CodexThreadId", s.threadId, "-StateDir", deepseekStateDir()];
  if (operation === "activate") args.push("-SkillName", dep.skillName);
  if (operation === "advance") args.push("-Action", "Advance");
  if (operation === "cancel") args.push("-Action", "CancelReview", "-Reason", "用户停止当前评审");
  if (operation === "complete") args.push("-Action", "CompleteTask", "-Reason", "Codex 已完成修改、测试和复核");
  try {
    const r = await execFileAsync("pwsh", args, { encoding: "utf8", windowsHide: true, timeout: 15000, maxBuffer: 1024 * 1024 });
    return JSON.parse(r.stdout.replace(/^\uFEFF/, ""));
  } catch (e) {
    // Never leak script stdout, lease token, auth proof, or user payload via errors.
    const error = e as NodeJS.ErrnoException & { killed?: boolean };
    throw new Error(error.code === "ENOENT" ? "DeepSeek 依赖 PowerShell 7 (pwsh)，当前不可用；未发送。" :
      error.killed ? "DeepSeek 本地流程超过 15 秒，状态未确认；先检查原任务，禁止重复发送。" : "DeepSeek 专用脚本执行失败；保留原任务，按专用 Skill 检查状态，未认定发送成功。");
  }
}

type Raw = Record<string, unknown>;
const text = (v: unknown): string => typeof v === "string" ? v.trim() : "";
const MODEL_NAMES = new Set(["网页当前模型（合并升级版）", "专家模式"]);
const SEARCH_MODE = "智能搜索";
// PowerShell writes booleans to the registry and boolean strings to task files.
// Unknown nonempty flag values are unsafe, never interpreted as false.
const risk = (v: unknown): boolean => !(v === undefined || v === null || v === false || v === 0 ||
  (typeof v === "string" && /^(?:false|0|no)?$/i.test(v.trim())));
const snippet = (v: unknown): string => text(v).slice(0, 2400);
function integer(v: unknown): number | null {
  if (typeof v !== "number" && !(typeof v === "string" && /^\d+$/.test(v))) return null;
  const n = Number(v);
  return Number.isSafeInteger(n) && n >= 0 ? n : null;
}
function object(v: unknown): v is Raw { return !!v && typeof v === "object" && !Array.isArray(v); }
function readObject(file: string): Raw | null {
  if (!fs.existsSync(file)) return null;
  try {
    const raw: unknown = JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
    if (object(raw)) return raw;
  } catch { /* Never include file contents or parser snippets in diagnostics. */ }
  throw new Error("DeepSeek 状态损坏，原文件保留；禁止重建任务或重发。");
}
function confirmedReceipt(raw: Raw): boolean {
  return raw.lastReceiptStatus === "confirmed" && raw.sendPhase === "receipt-confirmed" &&
    raw.domMessagePresence === "present" && raw.submissionStatus === "succeeded" &&
    (raw.submissionMechanism === "button" ? raw.domSendControl === "enabled" :
      raw.submissionMechanism === "enter" && raw.domInputPresence === "present" && raw.domInputEnabled === "enabled") &&
    raw.browserConfirmationStatus === "confirmed" &&
    (raw.lastOpenTabsEvidence === "confirmed" || raw.lastTabsListEvidence === "confirmed") &&
    raw.lastOpenTabsEvidence !== "wrong-session" && raw.lastTabsListEvidence !== "wrong-session" &&
    !!text(raw.lastMessageFingerprint);
}
function conversation(raw: Raw, threadId: string): string | null {
  const url = text(raw.conversationUrl), session = text(raw.deepseekSessionId);
  try {
    const u = new URL(url);
    if (u.protocol !== "https:" || u.host !== "chat.deepseek.com" || u.username || u.password) return null;
    const chat = u.pathname.replace(/^\/|\/$/g, "").match(/^a\/chat\/s\/([A-Za-z0-9][A-Za-z0-9_-]{7,127})$/);
    if (session.startsWith("official-chat:")) return chat && session === `official-chat:${chat[1]}` ? url : null;
    const marker = `CODEX-BINDING-${threadId}`;
    return session === `official-marker:${marker}` && raw.domMessageMarker === marker ? url : null;
  } catch { return null; }
}

/** This projection reads the existing skill's evidence, never synthesizes receipts. */
export function syncDeepseek(s: ReviewSession, source: Raw | null, bindings: Raw[]): ReviewSession {
  if (s.phase === "CANCELLED" || s.phase === "DONE") return s;
  const base: ReviewSession = { ...s, agreements: "", disagreements: "", result: "", reviewerConsensus: false, codexConsensus: false, replyReceived: false, receiptStatus: "none", updatedAt: new Date().toISOString() };
  const block = (why: string, nextAction = "按 DeepSeek 专用 Skill 恢复原任务；不重发、不改文件"): ReviewSession => ({ ...base, phase: "BLOCKED", blockedReason: why, nextAction });
  if (s.reviewProvider !== "deepseek" || s.bindingRef?.taskId !== s.taskId || s.bindingRef.skillName !== deepseekSkillName(s.reviewMode)) return block("当前渠道或专用任务引用不一致");
  if (!source) return s.evidenceRevision !== undefined || s.round > 1 ? block("DeepSeek 原任务状态缺失，不能重新开始") :
    { ...base, phase: "PREPARING", blockedReason: "", nextAction: "activate-deepseek-skill" };
  if (source.taskId !== s.taskId || source.codexThreadId !== s.threadId || source.skillName !== deepseekSkillName(s.reviewMode)) return block("DeepSeek 任务归属或评审方式不一致");
  if (risk(source.reviewRecoveryRequired)) return block("已恢复 DeepSeek 轮次记录，需要重新核对原网页", "revalidate-recovered-page");
  if (bindings.some(b => !object(b))) return block("DeepSeek 绑定记录损坏");
  const candidates = bindings.filter(b => b.codexThreadId === s.threadId);
  if (candidates.length > 1) return block("同一任务存在多个绑定，禁止猜测会话");
  const b = candidates[0];
  const batch = text(source.reviewBatch).match(s.reviewMode === "consensus" ? /^C([1-9]\d*)$/ : /^R([1-9]\d*)$/);
  if (!batch || !Number.isSafeInteger(Number(batch[1]))) return block("DeepSeek 轮次无效");
  const round = Number(batch[1]);
  if (s.reviewMode === "single" && round !== 1) return block("单次评审只接受 R1；新的复核需要新的任务编号");
  if (round < s.round) return block("拒绝旧轮次回执");
  base.round = round;
  const revision = integer(source.stateRevision);
  if (revision === null || revision < (s.evidenceRevision ?? 0)) return block("DeepSeek 状态版本无效或回退");
  base.evidenceRevision = revision;
  if (risk(source.decisionDeadlock)) return block("连续评审仍有相同分歧，等待用户决定", "await-user-decision");
  if (source.nextAction === "auto-recover-runtime-tab" && (source.taskTerminalStatus === "frozen" || b?.status === "recovery-pending")) {
    return block("浏览器暂时断开，保留当前轮次并恢复原任务", "auto-recover-runtime-tab");
  }
  if (source.activationStatus !== "activated" || source.taskTerminalStatus !== "active" || risk(source.reviewCancelled)) return block("DeepSeek 评审未激活、已暂停或已结束");
  const unsafe = [source, ...(b ? [b] : [])].some(x => ["pendingReceipt", "auditRisk", "resendBlocked", "auditOnly"].some(k => risk(x[k])));
  if (unsafe) return { ...block("发送回执尚未确认或存在审计风险，不能重复发送", "reconcile-pending-receipt"), receiptStatus: "unknown" };
  if (!b || b.status === "bootstrap-pending") return { ...base, phase: "PREPARING", blockedReason: "", nextAction: text(source.nextAction).slice(0, 500) || "prepare-browser-binding" };
  if (b.status !== "bound" || source.sessionBindingStatus !== "bound") return block("DeepSeek 原绑定尚未恢复");
  if ((text(b.activeTaskId) || text(b.taskId)) !== s.taskId || b.owner !== s.threadId || source.sessionOwner !== s.threadId) return block("DeepSeek 绑定属于其他任务");
  if ([source, b].some(x => x.targetUrl !== "https://chat.deepseek.com/" || x.browserSurface !== "codex-in-app-sidebar" || !MODEL_NAMES.has(text(x.model)) || x.reasoning !== "深度思考" || x.searchMode !== SEARCH_MODE)) return block("尚未确认内置浏览器的当前模型、深度思考和智能搜索");
  const url = conversation(source, s.threadId);
  if (!url || conversation(b, s.threadId) !== url) return block("DeepSeek 会话地址与官方会话身份不一致");
  if (["deepseekSessionId", "browserTabId", "browserRuntimeId"].some(k => !text(b[k]) || source[k] !== b[k]) ||
      ["runtimeEpoch", "bindingRevision"].some(k => integer(b[k]) === null || integer(b[k])! < 1 || integer(source[k]) !== integer(b[k]))) return block("DeepSeek 会话或浏览器身份不一致");
  const duplicate = bindings.some(other => other.codexThreadId !== s.threadId && !["lost", "cancelled", "terminated", "completed"].includes(text(other.status)) &&
    (other.deepseekSessionId === b.deepseekSessionId || (other.browserRuntimeId === b.browserRuntimeId && other.browserTabId === b.browserTabId)));
  if (duplicate) return block("DeepSeek 会话被其他 Codex 任务占用");
  base.chatUrl = url; base.modelName = text(b.model); base.reasoningStrength = text(b.reasoning);
  const fingerprint = text(b.lastMessageFingerprint);
  const receipt = confirmedReceipt(b) && confirmedReceipt(source) && source.lastMessageFingerprint === fingerprint &&
    b.sendOwnerTaskId === s.taskId && source.sendOwnerTaskId === s.taskId;
  if (!receipt) return { ...block("发送回执尚未确认，不能重复发送", "reconcile-pending-receipt"), receiptStatus: "unknown" };
  if (s.evidenceFingerprint === fingerprint && s.evidenceRound !== undefined && s.evidenceRound !== round) return block("新轮次仍引用上一轮发送回执，不能认定已收到本轮回复");
  base.evidenceFingerprint = fingerprint; base.evidenceRound = round;
  const completed = integer(source.deepseekCompletedRounds);
  if (completed === null || completed > round) return block("DeepSeek 已完成轮数与当前轮次不一致");
  // Task state and RecordRound both use deepSeekPosition (capital S).
  const result = snippet(source.deepSeekPosition);
  const received = completed === round && /^(?:已收到完整回复|已完成)$/.test(text(source.deepseekStatus)) &&
    !!result && !/^(?:未回复|未开始|等待回复)$/.test(result);
  if (received) {
    base.agreements = snippet(source.agreementSummary);
    base.disagreements = snippet(source.unresolvedIssues);
    base.result = result;
  }
  let roundConsensus = false;
  if (received && s.reviewMode === "consensus") {
    const history = source.roundHistory;
    if (!Array.isArray(history) || history.some(r => !object(r))) return block("DeepSeek 缺少有效轮次记录，不能认定共识");
    const records = history.filter(r => r.batch === source.reviewBatch);
    if (records.length !== 1 || integer(records[0].roundNumber) !== round ||
        text(records[0].deepSeekPosition) !== text(source.deepSeekPosition) || text(records[0].unresolvedIssues) !== text(source.unresolvedIssues)) return block("DeepSeek 轮次记录与当前回复不一致");
    roundConsensus = records[0].consensusReached === true && !!text(records[0].codexPosition) && !text(records[0].unresolvedIssues);
  }
  const reviewerConsensus = received && (s.reviewMode === "single" || (roundConsensus && source.consensusStatus === "已达成"));
  const codexConsensus = reviewerConsensus && source.codexSummaryStatus === "已完成" && source.checkResult === "无问题" && source.planStatus === "已敲定" && source.executionStatus === "允许开始执行" && !base.disagreements;
  return trackWait(s, { ...base, receiptStatus: "confirmed", replyReceived: received, reviewerConsensus, codexConsensus,
    phase: codexConsensus ? (s.phase === "EXECUTING" ? "EXECUTING" : "READY") : received ? "REVIEWED" : "WAITING",
    blockedReason: "", nextAction: codexConsensus ? "Codex 开始修改、测试和复核" : text(source.nextAction).slice(0, 500) || "读取当前网页完整回复，不重复发送",
  }, new Date(), source.browserActionAt === b.browserActionAt ? text(source.browserActionAt) : undefined);
}

export function readDeepseek(s: ReviewSession): ReviewSession {
  ReviewSessionSchema.parse(s);
  const source = readObject(path.join(deepseekStateDir(), `${s.taskId}.json`));
  const registry = readObject(path.join(deepseekStateDir(), "thread-bindings.json"));
  const bindings = registry?.bindings ?? [];
  if (!Array.isArray(bindings) || bindings.some(b => !object(b))) throw new Error("DeepSeek 绑定记录损坏，原文件保留。");
  return syncDeepseek(s, source, bindings);
}
