import { Command } from "commander";
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import { readUiPrefs } from "../config/ui-prefs.js";
import { Workspace } from "../workspace/manager.js";
import { mergeSession, readSession, sessionFile, writeSession } from "../session/state.js";
import { deepseekDependency, readDeepseek, runDeepseek } from "../review/deepseek.js";
import { parseReviewMode, selectReviewer } from "../review/provider.js";
import { canExecuteReview, changeReview, isReviewTerminal, newReview, readReview, recoverReview, renderReview, type ReviewSession } from "../review/state.js";
import { buildReviewMessage } from "../review/message.js";
import { observeReview, trackWait, waitProgress } from "../review/wait.js";

type Options = { workspace?: string; thread?: string; json?: boolean; provider?: string; request?: string; mode?: string; task?: string; summary?: string; selfCheck?: string; pageVerify?: string; evidence?: string };
function context(opts: Options): { workspaceId: string; threadId: string } {
  const ws = new Workspace(opts.workspace ?? process.cwd());
  const threadId = (opts.thread ?? process.env.CODEX_THREAD_ID ?? "").replace(/^codex:\/\/threads\//, "").trim();
  if (!threadId) throw new Error("缺少当前 Codex 任务 ID，不能猜测其他任务的会话。");
  return { workspaceId: ws.id, threadId };
}
function current(opts: Options): ReviewSession {
  const c = context(opts);
  const s = readReview(c.workspaceId, c.threadId);
  if (!s) throw new Error("当前任务尚未开始评审；先运行 c2c review start。");
  return s;
}
function output(s: ReviewSession, opts: Options): void {
  console.log(opts.json ? JSON.stringify({ ok: true, session: s, canExecute: canExecuteReview(s) }) : renderReview(s));
}
function save(s: ReviewSession, next: ReviewSession): ReviewSession {
  return changeReview(s.workspaceId, s.threadId, prior => {
    if (!prior || prior.taskId !== s.taskId || prior.updatedAt !== s.updatedAt) throw new Error("评审状态已改变，先重新读取当前任务。");
    return { ...next, updatedAt: new Date().toISOString() };
  });
}
function refresh(s: ReviewSession): ReviewSession {
  const next = trackWait(s, refreshSource(s));
  if (next.phase === "WAITING") {
    const progress = waitProgress(next);
    if (progress.pauseReason) return { ...next, phase: "BLOCKED", blockedReason: progress.pauseReason,
      nextAction: "重新观察原评审网页，核对本轮消息和回复；不重复发送" };
  }
  return next;
}
function refreshSource(s: ReviewSession): ReviewSession {
  if (isReviewTerminal(s)) return s;
  if (s.reviewProvider === "deepseek") return readDeepseek(s);
  const legacy = readSession(s.workspaceId)?.checkpoint;
  if (!legacy || legacy.taskId !== s.taskId) return s;
  if (legacy.codexThreadId !== s.threadId) throw new Error("ChatGPT checkpoint belongs to another Codex task or needs an explicit owner claim");
  if ((legacy.reviewProvider ?? "chatgpt") !== "chatgpt") throw new Error("checkpoint reviewer mismatch");
  const waiting = ["INIT", "CONSENSUS_PLAN", "EXECUTED_SENT"].includes(legacy.protocolState);
  const received = ["PLAN_RECEIVED", "CONSENSUS_REVIEW", "CONSENSUS", "EXECUTING", "EXECUTED_LOCAL", "DONE"].includes(legacy.protocolState);
  const reviewerConsensus = s.reviewMode === "consensus" ? (legacy.reviewerConsensus ?? legacy.chatgptConsensus ?? false) : received;
  const codexConsensus = s.reviewMode === "consensus" ? legacy.codexConsensus === true : ["PLAN_RECEIVED", "EXECUTING", "EXECUTED_LOCAL", "DONE"].includes(legacy.protocolState);
  const ready = received && reviewerConsensus && codexConsensus;
  return { ...s, round: legacy.consensusRound ?? s.round, agreements: "", disagreements: legacy.consensusDisagreement ?? "",
    result: legacy.consensusPlan ?? s.result, replyReceived: received, receiptStatus: received || waiting ? "confirmed" : "none", reviewerConsensus, codexConsensus,
    phase: legacy.protocolState === "BLOCKED" ? "BLOCKED" : ready ? (s.executionStartedAt ? "EXECUTING" : "READY") : received ? "REVIEWED" : waiting ? "WAITING" : s.phase,
    blockedReason: legacy.protocolState === "BLOCKED" ? legacy.knownIssues ?? "ChatGPT 评审暂停" : "",
    chatUrl: legacy.chatUrl, modelName: legacy.modelName, reasoningStrength: legacy.reasoningStrength,
    nextAction: legacy.nextExpectedStep ?? "continue-chatgpt-protocol",
  };
}
function routed(opts: Options): { provider: ReviewSession["reviewProvider"]; previous: ReviewSession | null; taskId?: string; mode: ReviewSession["reviewMode"] } {
  const c = context(opts);
  const previous = readReview(c.workspaceId, c.threadId);
  const active = previous && !isReviewTerminal(previous) ? previous : null;
  // A workspace-level legacy checkpoint must be claimed by its original thread, never guessed.
  const legacy = !previous ? readSession(c.workspaceId)?.checkpoint : undefined;
  if (legacy && opts.task === legacy.taskId && legacy.codexThreadId && legacy.codexThreadId !== c.threadId) throw new Error("旧评审属于另一个 Codex 任务，不能接管。");
  const resumableLegacy = legacy && legacy.protocolState !== "DONE" &&
    (legacy.codexThreadId === c.threadId || (!legacy.codexThreadId && opts.task === legacy.taskId)) ? legacy : undefined;
  const saved = active?.reviewProvider ?? resumableLegacy?.reviewProvider ?? (resumableLegacy ? "chatgpt" : undefined);
  const provider = selectReviewer({ explicit: opts.provider, request: opts.request, saved, defaultProvider: readUiPrefs().reviewProvider });
  const mode = parseReviewMode(opts.mode ?? active?.reviewMode ?? resumableLegacy?.reviewMode ?? (resumableLegacy?.consensusMode || /多轮|共识|multi.?round|consensus/i.test(opts.request ?? "") ? "consensus" : "single"));
  if (active && (active.reviewMode !== mode || (opts.task && active.taskId !== opts.task))) throw new Error("原评审尚未结束，请恢复原任务或先停止它。");
  return { provider, previous, mode, taskId: active?.taskId ?? resumableLegacy?.taskId };
}

function claimLegacy(workspaceId: string, threadId: string, taskId: string): void {
  const file = `${sessionFile(workspaceId)}.owner.lock`;
  const fd = fs.openSync(file, "wx", 0o600);
  try {
    const legacy = readSession(workspaceId);
    if (legacy?.checkpoint?.taskId !== taskId || (legacy.checkpoint.codexThreadId && legacy.checkpoint.codexThreadId !== threadId)) throw new Error("旧评审归属已改变，不能接管。");
    writeSession(workspaceId, mergeSession(legacy, { checkpoint: { codexThreadId: threadId } }));
  } finally { fs.closeSync(fd); fs.rmSync(file, { force: true }); }
}

export function registerReviewCommands(program: Command): void {
  const review = program.command("review").description("选择评审渠道，复用单次或多轮评审并查看中文进度");
  const command = (name: string, description: string): Command => review.command(name).description(description)
    .option("-w, --workspace <path>").option("--thread <id>", "当前 Codex 任务 ID，默认 CODEX_THREAD_ID")
    .option("--json", "输出结构化结果", false);
  const action = (cmd: Command, run: (opts: Options) => Promise<void> | void): void => {
    cmd.action(async (opts: Options) => { try { await run(opts); } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      console.log(opts.json ? JSON.stringify({ ok: false, error: message }) : `遇到问题了：${message}`);
      process.exitCode = 1;
    } });
  };
  const routing = (cmd: Command): Command => cmd.option("--provider <name>", "deepseek | chatgpt（gpt 也可）")
    .option("--mode <mode>", "single | consensus").option("--task <id>", "恢复已确认属于本任务的旧评审")
    .option("--request <text>", "本次渠道或评审方式指令，不保存原始文本");
  action(routing(command("resolve", "只读查看本次将使用的渠道和依赖")), opts => {
    const route = routed(opts);
    const payload = { ok: true, reviewProvider: route.provider, reviewMode: route.mode, resumeTaskId: route.taskId ?? null,
      dependency: route.provider === "deepseek" ? deepseekDependency(route.mode) : null };
    console.log(opts.json ? JSON.stringify(payload) : `评审渠道：${route.provider}\n评审方式：${route.mode}\n${route.taskId ? "恢复原评审" : "开始新评审"}`);
  });
  action(routing(command("start", "创建或恢复评审记录；不代替网页发送"))
    .option("--summary <text>", "由 Codex 整理的短需求摘要"), opts => {
    const route = routed(opts), c = context(opts);
    const s = changeReview(c.workspaceId, c.threadId, previous => {
      if (previous && !isReviewTerminal(previous)) return previous;
      if (!opts.summary?.trim()) throw new Error("新评审需要 --summary 短需求摘要。");
      const next = newReview({ ...c, taskId: route.taskId ?? opts.task ?? `c2c-${randomUUID()}`, reviewProvider: route.provider, reviewMode: route.mode, summary: opts.summary.trim() });
      // Also validate the outgoing summary before committing task state.
      buildReviewMessage(next);
      if (route.taskId && !previous) { claimLegacy(c.workspaceId, c.threadId, route.taskId); return refresh(next); }
      return next;
    });
    output(s, opts);
  });
  action(command("get", "读取当前任务已保存的评审进度"), opts => output(current(opts), opts));
  action(command("recover", "从本任务检查点恢复，重新核验前禁止执行")
    .requiredOption("--task <id>", "需要恢复的原评审任务号"), opts => {
    const c = context(opts);
    output(recoverReview(c.workspaceId, c.threadId, opts.task!), opts);
  });
  action(command("observe", "记录内置浏览器刚读取的页面状态，不代替回复核对")
    .requiredOption("--evidence <path>", "内置浏览器观察摘要 JSON"), opts => {
    const s = current(opts);
    const input = fs.readFileSync(opts.evidence!, "utf8");
    if (Buffer.byteLength(input) > 8192) throw new Error("网页观察摘要过大。");
    const next = observeReview(s, JSON.parse(input.replace(/^\uFEFF/, "")));
    output(save(s, { ...next, recoveryRequired: next.wait?.pageStatus === "thinking" || next.wait?.pageStatus === "reply-ready" ? false : s.recoveryRequired }), opts);
  });
  action(command("heartbeat", "按保存的等待起点计时，每满一分钟生成一次回显；不访问网页"), opts => {
    const s = current(opts), checked = refresh(s), progress = waitProgress(checked);
    const active = checked.phase === "WAITING" || (checked.phase === "BLOCKED" && s.phase === "WAITING");
    const shouldReport = active && (progress.shouldReport || checked.phase !== s.phase);
    const next = save(s, { ...checked, wait: shouldReport && checked.wait ? { ...checked.wait, lastReportedMinute: progress.minute } : checked.wait });
    const message = shouldReport ? progress.message + (checked.blockedReason ? `\n已暂停：${checked.blockedReason}` : "") : "";
    console.log(opts.json ? JSON.stringify({ ok: true, shouldReport, message, phase: next.phase, round: next.round, canExecute: canExecuteReview(next) }) : message);
  });
  action(command("prepare", "准备下一轮方案摘要，不执行网页发送")
    .requiredOption("--summary <text>", "修订后的短方案摘要"), opts => {
    const s = current(opts), checked = refresh(s);
    if (checked.reviewMode !== "consensus" || checked.phase !== "REVIEWED" || !checked.replyReceived) throw new Error("必须先收到本轮完整评审并核对分歧，才能准备下一轮。");
    const next: ReviewSession = { ...checked, summary: opts.summary!.trim(), round: checked.round + 1,
      phase: "PREPARING", reviewerConsensus: false, codexConsensus: false, replyReceived: false,
      wait: undefined,
      receiptStatus: "none", blockedReason: "", nextAction: "按专用 Skill 准备下一轮消息，再用内置浏览器发送" };
    buildReviewMessage(next);
    output(save(s, next), opts);
  });
  action(command("message", "生成待发送的摘要；本命令不会打开网页或发送"), opts => {
    const s = current(opts);
    if (s.phase !== "PREPARING" || s.receiptStatus !== "none") throw new Error("已有发送或评审记录；先核对原消息，禁止重复发送。");
    const payload = buildReviewMessage(s);
    console.log(opts.json ? JSON.stringify({ ok: true, sent: false, message: payload }) : payload);
  });
  action(command("sync", "从专用 Skill 读取真实绑定与评审结果"), opts => {
    const s = current(opts); output(save(s, refresh(s)), opts);
  });
  action(command("advance", "推进专用 Skill 的下一步，网页仍由内置浏览器操作"), async opts => {
    const s = current(opts);
    if (isReviewTerminal(s)) { output(s, opts); return; }
    if (s.reviewProvider === "chatgpt") { output(save(s, refresh(s)), opts); return; }
    try {
      let synced = refresh(s);
      if (synced.phase === "WAITING" || synced.wait && synced.phase === "BLOCKED") {
        output(save(s, synced), opts); return;
      }
      if (synced.nextAction === "activate-deepseek-skill") {
        await runDeepseek(s, "activate");
      }
      const result = await runDeepseek(s, "advance");
      synced = refresh(s);
      if (typeof result.nextAction === "string") synced.nextAction = result.nextAction;
      if (result.status === "workflow-timeout") { synced.phase = "BLOCKED"; synced.blockedReason = "浏览器动作超时，停止重复推进；按原 Skill 的失败流程处理。"; }
      output(save(s, synced), opts);
    } catch (error) {
      const blocked = { ...s, phase: "BLOCKED" as const, blockedReason: (error as Error).message, nextAction: "检查原任务和依赖；不重发、不切换渠道" };
      output(save(s, blocked), opts); process.exitCode = 1;
    }
  });
  action(command("cancel", "停止当前评审，保留历史和浏览器会话"), async opts => {
    const s = current(opts);
    if (isReviewTerminal(s)) { output(s, opts); return; }
    let note = "已停止，不继续发送或修改";
    if (s.reviewProvider === "deepseek") {
      try { await runDeepseek(s, "cancel"); } catch {
        output(save(s, { ...s, phase: "BLOCKED", reviewerConsensus: false, codexConsensus: false,
          blockedReason: "专用 Skill 取消未确认", nextAction: "不再发送或执行；先核对原绑定的取消状态" }), opts);
        process.exitCode = 1; return;
      }
    }
    output(save(s, { ...s, phase: "CANCELLED", reviewerConsensus: false, codexConsensus: false, nextAction: note }), opts);
  });
  action(command("execute", "核对评审门槛后记录执行开始；不直接改业务文件"), opts => {
    const s = current(opts), checked = refresh(s);
    if (!canExecuteReview(checked)) throw new Error("尚未收到完整评审并通过双方核对，禁止开始修改。");
    output(save(s, { ...checked, phase: "EXECUTING", executionStartedAt: new Date().toISOString(), nextAction: "Codex 修改文件、运行测试并检查页面" }), opts);
  });
  action(command("finish", "记录修改后自检和页面验证完成")
    .requiredOption("--self-check <status>", "PASS")
    .requiredOption("--page-verify <status>", "PASS | NOT_APPLICABLE"), async opts => {
    const s = current(opts), checked = refresh(s);
    if (!s.executionStartedAt || !["EXECUTING", "WAITING"].includes(s.phase) || opts.selfCheck !== "PASS" || !["PASS", "NOT_APPLICABLE"].includes(opts.pageVerify ?? "")) throw new Error("只有评审通过且修改后的检查通过，才能完成任务。");
    if (checked.phase !== "EXECUTING" || !checked.reviewerConsensus || !checked.codexConsensus) throw new Error("评审依据已改变，请先复核原任务。");
    if (s.reviewProvider === "chatgpt" && readSession(s.workspaceId)?.checkpoint?.protocolState !== "DONE") throw new Error("ChatGPT 尚未完成修改结果复核。");
    if (s.reviewProvider === "deepseek") await runDeepseek(s, "complete");
    output(save(s, { ...s, phase: "DONE", verification: { selfCheck: "PASS", pageVerify: opts.pageVerify as "PASS" | "NOT_APPLICABLE", at: new Date().toISOString() }, nextAction: "已完成本次修改和自检" }), opts);
  });
}
