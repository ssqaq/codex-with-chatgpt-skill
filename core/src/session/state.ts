import path from "node:path";
import fs from "node:fs";
import { getStateDir, writeSecureJson } from "../config/paths.js";
import { parseReviewProvider, parseReviewMode, type ReviewProvider, type ReviewMode } from "../review/provider.js";

export type ConversationMode = "long-chat" | "project";

export type ConversationReason = "existing-long-chat" | "project" | "new-workspace";

export type ProtocolState =
  | "INIT"
  | "CONSENSUS_PLAN"
  | "CONSENSUS_REVIEW"
  | "CONSENSUS"
  | "PLAN_RECEIVED"
  | "EXECUTING"
  | "EXECUTED_LOCAL"
  | "EXECUTED_SENT"
  | "DONE"
  | "BLOCKED";

export type WaitingFor = "none" | "GPT_PLAN" | "GPT_REVIEW" | "GPT_CONSENSUS" | "REVIEWER_PLAN" | "REVIEWER_REVIEW" | "REVIEWER_CONSENSUS" | "USER";
export type SelfCheckStatus = "PASS" | "FAIL";
export type PageVerifyStatus = "PASS" | "FAIL" | "NOT_APPLICABLE";

export const PROTOCOL_STATES: readonly ProtocolState[] = [
  "INIT",
  "CONSENSUS_PLAN",
  "CONSENSUS_REVIEW",
  "CONSENSUS",
  "PLAN_RECEIVED",
  "EXECUTING",
  "EXECUTED_LOCAL",
  "EXECUTED_SENT",
  "DONE",
  "BLOCKED",
];

export const WAITING_FOR: readonly WaitingFor[] = ["none", "GPT_PLAN", "GPT_REVIEW", "GPT_CONSENSUS", "REVIEWER_PLAN", "REVIEWER_REVIEW", "REVIEWER_CONSENSUS", "USER"];

const CONSENSUS_EXECUTION_STATES: readonly ProtocolState[] = [
  "PLAN_RECEIVED",
  "EXECUTING",
  "EXECUTED_LOCAL",
  "EXECUTED_SENT",
  "DONE",
];

const VERIFICATION_REQUIRED_STATES: readonly ProtocolState[] = ["EXECUTED_LOCAL", "EXECUTED_SENT", "DONE"];

export interface TaskCheckpoint {
  reviewProvider?: ReviewProvider;
  reviewMode?: ReviewMode;
  reviewerConsensus?: boolean;
  reviewSessionRef?: string;
  codexThreadId?: string;
  taskId: string;
  iteration: number;
  protocolState: ProtocolState;
  waitingFor: WaitingFor;
  originalGoal?: string;
  completedSubtasks?: string;
  knownIssues?: string;
  nextExpectedStep?: string;
  chatUrl?: string;
  projectUrl?: string;
  consensusMode?: boolean;
  consensusRound?: number;
  consensusPlan?: string;
  consensusDisagreement?: string;
  consensusDisagreementFingerprint?: string;
  consensusRepeatedRounds?: number;
  codexConsensus?: boolean;
  chatgptConsensus?: boolean;
  selfCheckStatus?: SelfCheckStatus;
  pageVerifyStatus?: PageVerifyStatus;
  pageScope?: string;
  verificationAt?: string;
  modelName?: string;
  reasoningStrength?: string;
  updatedAt: string;
}

export interface SavedSession {
  url?: string;
  title?: string;
  taskId?: string;
  iteration?: number;
  lastState?: string;
  savedAt: string;
  conversationMode?: ConversationMode;
  projectUrl?: string;
  connectorName?: string;
  checkpoint?: TaskCheckpoint;
}

export interface SessionPatch {
  url?: string;
  title?: string;
  taskId?: string;
  iteration?: number;
  lastState?: string;
  conversationMode?: ConversationMode;
  projectUrl?: string;
  connectorName?: string;
  checkpoint?: Partial<TaskCheckpoint> & { protocolState?: ProtocolState };
  clearCheckpoint?: boolean;
}

export interface ConversationView {
  mode: ConversationMode;
  reason: ConversationReason;
  projectUrl: string | null;
  projectReady: boolean;
  chatUrl: string | null;
  connectorName: string | null;
  /** long-chat: Skill may goto chatUrl. project: only if THIS Codex thread already bound it. */
  reuseSavedChat: boolean;
}

/** A saved session could not be parsed or no longer has the required shape. */
export class CorruptSessionError extends Error {
  readonly code = "SESSION_CORRUPT" as const;
  readonly sessionPath: string;
  readonly backupPath: string;

  constructor(sessionPath: string, backupPath: string, reason: string) {
    super(`Saved ChatGPT session is corrupt (${reason}). A backup was kept at ${backupPath}.`);
    this.name = "CorruptSessionError";
    this.sessionPath = sessionPath;
    this.backupPath = backupPath;
  }
}

export function sessionFile(workspaceId: string): string {
  return path.join(getStateDir(), "sessions", `${workspaceId}.json`);
}

function backupCorruptSession(file: string, workspaceId: string): string {
  const directory = path.join(getStateDir(), "sessions", "corrupt");
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const safeWorkspaceId = workspaceId.replace(/[^A-Za-z0-9._-]/g, "_");
  const base = `${safeWorkspaceId}.${Date.now()}.${process.pid}`;
  let backup = path.join(directory, `${base}.json`);
  let suffix = 0;
  while (fs.existsSync(backup)) {
    suffix += 1;
    backup = path.join(directory, `${base}.${suffix}.json`);
  }
  fs.copyFileSync(file, backup);
  try {
    fs.chmodSync(backup, 0o600);
  } catch {
    // best effort on platforms without chmod semantics
  }
  return backup;
}

function corruptSession(file: string, workspaceId: string, reason: string): never {
  const backup = backupCorruptSession(file, workspaceId);
  throw new CorruptSessionError(file, backup, reason);
}

export type SessionReadResult =
  | { status: "missing"; session: null }
  | { status: "ok"; session: SavedSession }
  | { status: "corrupt"; session: null; backupPath: string; sessionPath: string; message: string };

/** Read a session while exposing corruption as an explicit status for CLI/JSON callers. */
export function readSessionResult(workspaceId: string): SessionReadResult {
  const file = sessionFile(workspaceId);
  if (!fs.existsSync(file)) return { status: "missing", session: null };
  try {
    const parsed: unknown = JSON.parse(fs.readFileSync(file, "utf8"));
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      corruptSession(file, workspaceId, "expected a JSON object");
    }
    const candidate = parsed as Partial<SavedSession>;
    if (typeof candidate.savedAt !== "string" || !candidate.savedAt.trim()) {
      corruptSession(file, workspaceId, "missing savedAt");
    }
    return { status: "ok", session: parsed as SavedSession };
  } catch (error) {
    if (error instanceof CorruptSessionError) {
      return {
        status: "corrupt",
        session: null,
        backupPath: error.backupPath,
        sessionPath: error.sessionPath,
        message: error.message,
      };
    }
    if (error instanceof SyntaxError) {
      const backup = backupCorruptSession(file, workspaceId);
      return {
        status: "corrupt",
        session: null,
        backupPath: backup,
        sessionPath: file,
        message: `Saved ChatGPT session is corrupt (invalid JSON). A backup was kept at ${backup}.`,
      };
    }
    throw error;
  }
}

export function readSession(workspaceId: string): SavedSession | null {
  const result = readSessionResult(workspaceId);
  if (result.status === "corrupt") {
    throw new CorruptSessionError(result.sessionPath, result.backupPath, "session file is unreadable; restore from the backup");
  }
  return result.session;
}

export function writeSession(workspaceId: string, session: SavedSession): SavedSession {
  writeSecureJson(sessionFile(workspaceId), session);
  return session;
}

export function normalizeProjectUrl(url: string): string | null {
  try {
    const parsed = new URL(url.trim());
    if (parsed.hostname !== "chatgpt.com" && parsed.hostname !== "www.chatgpt.com") return null;
    const match = parsed.pathname.match(/^\/g\/(g-p-[a-zA-Z0-9]+)\/project\/?$/);
    if (!match) return null;
    return `https://chatgpt.com/g/${match[1]}/project`;
  } catch {
    return null;
  }
}

export function projectIdFromUrl(url: string): string | null {
  const normalized = normalizeProjectUrl(url);
  if (!normalized) return null;
  return normalized.match(/\/g\/(g-p-[a-zA-Z0-9]+)\/project/)?.[1] ?? null;
}

export function resolveConversation(session: SavedSession | null): ConversationView {
  if (!session) {
    return {
      mode: "project",
      reason: "new-workspace",
      projectUrl: null,
      projectReady: false,
      chatUrl: null,
      connectorName: null,
      reuseSavedChat: false,
    };
  }

  const projectUrl = session.projectUrl ? normalizeProjectUrl(session.projectUrl) : null;
  const projectReady = Boolean(projectUrl);

  if (session.conversationMode === "long-chat") {
    return {
      mode: "long-chat",
      reason: "existing-long-chat",
      projectUrl: null,
      projectReady: false,
      chatUrl: session.url ?? null,
      connectorName: session.connectorName ?? null,
      reuseSavedChat: Boolean(session.url),
    };
  }

  if (session.conversationMode === "project" || projectReady) {
    return {
      mode: "project",
      reason: "project",
      projectUrl,
      projectReady,
      chatUrl: session.url ?? null,
      connectorName: session.connectorName ?? null,
      reuseSavedChat: false,
    };
  }

  return {
    mode: "long-chat",
    reason: "existing-long-chat",
    projectUrl: null,
    projectReady: false,
    chatUrl: session.url ?? null,
    connectorName: session.connectorName ?? null,
    reuseSavedChat: Boolean(session.url),
  };
}

const CHECKPOINT_LIMITS = {
  originalGoal: 500,
  completedSubtasks: 800,
  knownIssues: 800,
  nextExpectedStep: 400,
  consensusPlan: 1200,
  consensusDisagreement: 800,
  consensusDisagreementFingerprint: 128,
  pageScope: 400,
} as const;

function capCheckpointText(value: string | undefined, max: number): string | undefined {
  if (value === undefined) return undefined;
  const trimmed = value.trim();
  if (!trimmed) return undefined;
  return trimmed.length > max ? `${trimmed.slice(0, max)}…` : trimmed;
}

export function mergeSession(previous: SavedSession | null, patch: SessionPatch): SavedSession {
  const conversationMode = patch.conversationMode ?? previous?.conversationMode;
  const rawProjectUrl = patch.projectUrl ?? previous?.projectUrl;
  let projectUrl = rawProjectUrl;
  if (rawProjectUrl) {
    const normalized = normalizeProjectUrl(rawProjectUrl);
    if (!normalized) {
      throw new Error("project URL must look like https://chatgpt.com/g/g-p-…/project");
    }
    projectUrl = normalized;
  }

  if (conversationMode === "project" && !projectUrl && !previous?.projectUrl) {
    throw new Error("project mode requires --project-url");
  }

  const url = patch.url ?? previous?.url;
  const hasChat = Boolean(url);
  const hasProject = Boolean(projectUrl);
  const hasTask = Boolean(patch.taskId ?? previous?.taskId);
  const hasCheckpoint = Boolean(patch.checkpoint || patch.clearCheckpoint || previous?.checkpoint);
  if (!hasChat && !hasProject && conversationMode !== "long-chat" && !hasTask && !hasCheckpoint) {
    throw new Error("nothing to save: pass --url, --project-url, or --mode");
  }

  const patchTaskId = patch.checkpoint?.taskId ?? patch.taskId;
  const priorCheckpoint = patchTaskId && previous?.checkpoint?.taskId !== patchTaskId ? undefined : previous?.checkpoint;
  let checkpoint = priorCheckpoint;
  if (patch.clearCheckpoint) {
    checkpoint = undefined;
  } else if (patch.checkpoint) {
    const taskId = patch.checkpoint.taskId ?? patch.taskId ?? priorCheckpoint?.taskId ?? previous?.taskId;
    const iteration =
      patch.checkpoint.iteration ??
      patch.iteration ??
      priorCheckpoint?.iteration ??
      previous?.iteration ??
      0;
    const protocolState = patch.checkpoint.protocolState ?? priorCheckpoint?.protocolState;
    if (!taskId || !protocolState) {
      throw new Error("checkpoint requires task id and protocol state");
    }
    if (!PROTOCOL_STATES.includes(protocolState)) {
      throw new Error(`protocol-state must be one of ${PROTOCOL_STATES.join(", ")}`);
    }
    const waitingFor = patch.checkpoint.waitingFor ?? priorCheckpoint?.waitingFor ?? "none";
    if (!WAITING_FOR.includes(waitingFor)) {
      throw new Error(`waiting-for must be one of ${WAITING_FOR.join(", ")}`);
    }
    const consensusRound = patch.checkpoint.consensusRound ?? priorCheckpoint?.consensusRound;
    if (consensusRound !== undefined && (!Number.isInteger(consensusRound) || consensusRound < 1)) {
      throw new Error("consensus-round must be a positive integer");
    }
    const consensusRepeatedRounds =
      patch.checkpoint.consensusRepeatedRounds ?? priorCheckpoint?.consensusRepeatedRounds;
    if (
      consensusRepeatedRounds !== undefined &&
      (!Number.isInteger(consensusRepeatedRounds) || consensusRepeatedRounds < 0)
    ) {
      throw new Error("consensus-repeats must be a non-negative integer");
    }
    const consensusMode = patch.checkpoint.consensusMode ?? priorCheckpoint?.consensusMode;
    const codexConsensus = patch.checkpoint.codexConsensus ?? priorCheckpoint?.codexConsensus;
    const reviewProvider = parseReviewProvider(patch.checkpoint.reviewProvider ?? priorCheckpoint?.reviewProvider ?? "chatgpt");
    if (priorCheckpoint?.taskId === taskId && reviewProvider !== (priorCheckpoint.reviewProvider ?? "chatgpt")) {
      throw new Error("cannot switch reviewer in an existing checkpoint");
    }
    const reviewMode = parseReviewMode(patch.checkpoint.reviewMode ?? priorCheckpoint?.reviewMode ?? (consensusMode ? "consensus" : "single"));
    const chatgptConsensus = patch.checkpoint.chatgptConsensus ?? priorCheckpoint?.chatgptConsensus;
    const reviewerConsensus = patch.checkpoint.reviewerConsensus ??
      (reviewProvider === "chatgpt" && patch.checkpoint.chatgptConsensus !== undefined ? patch.checkpoint.chatgptConsensus : undefined) ??
      priorCheckpoint?.reviewerConsensus ?? (reviewProvider === "chatgpt" ? chatgptConsensus : false);
    const selfCheckStatus = patch.checkpoint.selfCheckStatus ?? priorCheckpoint?.selfCheckStatus;
    const pageVerifyStatus = patch.checkpoint.pageVerifyStatus ?? priorCheckpoint?.pageVerifyStatus;
    if (selfCheckStatus !== undefined && selfCheckStatus !== "PASS" && selfCheckStatus !== "FAIL") {
      throw new Error("self-check must be PASS or FAIL");
    }
    if (
      pageVerifyStatus !== undefined &&
      pageVerifyStatus !== "PASS" &&
      pageVerifyStatus !== "FAIL" &&
      pageVerifyStatus !== "NOT_APPLICABLE"
    ) {
      throw new Error("page-verify must be PASS, FAIL, or NOT_APPLICABLE");
    }
    if ((consensusMode || reviewMode === "consensus") && CONSENSUS_EXECUTION_STATES.includes(protocolState) && !(codexConsensus && reviewerConsensus)) {
      throw new Error("consensus confirmations are required before execution");
    }
    if (
      VERIFICATION_REQUIRED_STATES.includes(protocolState) &&
      (selfCheckStatus !== "PASS" || (pageVerifyStatus !== "PASS" && pageVerifyStatus !== "NOT_APPLICABLE"))
    ) {
      throw new Error("post-change verification is required before execution can finish");
    }
    checkpoint = {
      reviewProvider,
      reviewMode,
      reviewerConsensus,
      reviewSessionRef: patch.checkpoint.reviewSessionRef ?? priorCheckpoint?.reviewSessionRef,
      codexThreadId: patch.checkpoint.codexThreadId ?? priorCheckpoint?.codexThreadId,
      taskId,
      iteration,
      protocolState,
      waitingFor,
      originalGoal: capCheckpointText(
        patch.checkpoint.originalGoal ?? priorCheckpoint?.originalGoal,
        CHECKPOINT_LIMITS.originalGoal
      ),
      completedSubtasks: capCheckpointText(
        patch.checkpoint.completedSubtasks ?? priorCheckpoint?.completedSubtasks,
        CHECKPOINT_LIMITS.completedSubtasks
      ),
      knownIssues: capCheckpointText(
        patch.checkpoint.knownIssues ?? priorCheckpoint?.knownIssues,
        CHECKPOINT_LIMITS.knownIssues
      ),
      nextExpectedStep: capCheckpointText(
        patch.checkpoint.nextExpectedStep ?? priorCheckpoint?.nextExpectedStep,
        CHECKPOINT_LIMITS.nextExpectedStep
      ),
      chatUrl: patch.checkpoint.chatUrl ?? priorCheckpoint?.chatUrl ?? url,
      projectUrl: patch.checkpoint.projectUrl ?? priorCheckpoint?.projectUrl ?? projectUrl,
      consensusMode,
      consensusRound,
      consensusPlan: capCheckpointText(
        patch.checkpoint.consensusPlan ?? priorCheckpoint?.consensusPlan,
        CHECKPOINT_LIMITS.consensusPlan
      ),
      consensusDisagreement: capCheckpointText(
        patch.checkpoint.consensusDisagreement ?? priorCheckpoint?.consensusDisagreement,
        CHECKPOINT_LIMITS.consensusDisagreement
      ),
      consensusDisagreementFingerprint: capCheckpointText(
        patch.checkpoint.consensusDisagreementFingerprint ?? priorCheckpoint?.consensusDisagreementFingerprint,
        CHECKPOINT_LIMITS.consensusDisagreementFingerprint
      ),
      consensusRepeatedRounds,
      codexConsensus,
      chatgptConsensus,
      selfCheckStatus,
      pageVerifyStatus,
      pageScope: capCheckpointText(
        patch.checkpoint.pageScope ?? priorCheckpoint?.pageScope,
        CHECKPOINT_LIMITS.pageScope
      ),
      verificationAt: patch.checkpoint.verificationAt ?? priorCheckpoint?.verificationAt,
      modelName: capCheckpointText(
        patch.checkpoint.modelName ?? priorCheckpoint?.modelName,
        120
      ),
      reasoningStrength: capCheckpointText(
        patch.checkpoint.reasoningStrength ?? priorCheckpoint?.reasoningStrength,
        80
      ),
      updatedAt: new Date().toISOString(),
    };
  }

  return {
    url,
    title: patch.title ?? previous?.title,
    taskId: patch.taskId ?? previous?.taskId,
    iteration: patch.iteration ?? previous?.iteration,
    lastState: patch.lastState ?? previous?.lastState,
    conversationMode: conversationMode === "project" && projectUrl ? "project" : conversationMode,
    projectUrl,
    connectorName: patch.connectorName ?? previous?.connectorName,
    checkpoint,
    savedAt: new Date().toISOString(),
  };
}

/** Drop the current chat pointer. Keep Project binding so the collection stays. */
export function clearChatPointer(workspaceId: string): { cleared: boolean; keptProject: boolean } {
  const previous = readSession(workspaceId);
  if (!previous) return { cleared: false, keptProject: false };
  const view = resolveConversation(previous);
  if (view.mode === "project" && view.projectUrl) {
    writeSession(workspaceId, {
      conversationMode: "project",
      projectUrl: view.projectUrl,
      connectorName: previous.connectorName,
      checkpoint: previous.checkpoint,
      savedAt: new Date().toISOString(),
    });
    return { cleared: true, keptProject: true };
  }
  fs.rmSync(sessionFile(workspaceId), { force: true });
  return { cleared: true, keptProject: false };
}
