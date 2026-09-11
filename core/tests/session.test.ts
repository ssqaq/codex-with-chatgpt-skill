import fs from "node:fs";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  clearChatPointer,
  mergeSession,
  normalizeProjectUrl,
  projectIdFromUrl,
  readSession,
  readSessionResult,
  resolveConversation,
  sessionFile,
  writeSession,
  type SavedSession,
} from "../src/session/state.js";
import { cleanup, makeTmpDir } from "./helpers.js";

const PROJECT = "https://chatgpt.com/g/g-p-6a94399430e08191860ab5364b7748b8/project";

describe("normalizeProjectUrl", () => {
  it("accepts the collection URL and strips extras", () => {
    expect(normalizeProjectUrl(`${PROJECT}/`)).toBe(PROJECT);
    expect(normalizeProjectUrl("https://www.chatgpt.com/g/g-p-abc123/project?foo=1")).toBe(
      "https://chatgpt.com/g/g-p-abc123/project"
    );
    expect(projectIdFromUrl(PROJECT)).toBe("g-p-6a94399430e08191860ab5364b7748b8");
  });

  it("rejects a normal chat URL or a guessed name", () => {
    expect(normalizeProjectUrl("https://chatgpt.com/c/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")).toBeNull();
    expect(normalizeProjectUrl("https://chatgpt.com/")).toBeNull();
    expect(normalizeProjectUrl("https://example.com/g/g-p-abc/project")).toBeNull();
  });
});

describe("resolveConversation", () => {
  it("treats a missing file as a new workspace (Project by default)", () => {
    const view = resolveConversation(null);
    expect(view.mode).toBe("project");
    expect(view.reason).toBe("new-workspace");
    expect(view.reuseSavedChat).toBe(false);
    expect(view.projectReady).toBe(false);
  });

  it("keeps a legacy session file on long-chat and does not migrate", () => {
    const view = resolveConversation({
      url: "https://chatgpt.com/c/old-chat",
      savedAt: "2026-01-01T00:00:00.000Z",
    });
    expect(view.mode).toBe("long-chat");
    expect(view.reason).toBe("existing-long-chat");
    expect(view.reuseSavedChat).toBe(true);
    expect(view.chatUrl).toBe("https://chatgpt.com/c/old-chat");
  });

  it("lets an explicit long-chat opt-out win over a leftover collection URL", () => {
    const view = resolveConversation({
      conversationMode: "long-chat",
      projectUrl: PROJECT,
      url: "https://chatgpt.com/c/keep",
      savedAt: "2026-01-01T00:00:00.000Z",
    });
    expect(view.mode).toBe("long-chat");
    expect(view.reuseSavedChat).toBe(true);
  });

  it("uses Project when a collection URL is stored", () => {
    const view = resolveConversation({
      conversationMode: "project",
      projectUrl: PROJECT,
      url: "https://chatgpt.com/c/thread-1",
      connectorName: "Codex with ChatGPT · Demo",
      savedAt: "2026-01-01T00:00:00.000Z",
    });
    expect(view.mode).toBe("project");
    expect(view.projectReady).toBe(true);
    expect(view.reuseSavedChat).toBe(false);
    expect(view.connectorName).toBe("Codex with ChatGPT · Demo");
  });
});

describe("mergeSession", () => {
  it("keeps Project fields when only the chat URL is updated", () => {
    const next = mergeSession(
      {
        conversationMode: "project",
        projectUrl: PROJECT,
        connectorName: "Codex with ChatGPT · Demo",
        url: "https://chatgpt.com/c/old",
        savedAt: "2026-01-01T00:00:00.000Z",
      },
      { url: "https://chatgpt.com/c/new", taskId: "c2c_ab12", iteration: 1 }
    );
    expect(next.projectUrl).toBe(PROJECT);
    expect(next.conversationMode).toBe("project");
    expect(next.url).toBe("https://chatgpt.com/c/new");
    expect(next.connectorName).toBe("Codex with ChatGPT · Demo");
    expect(next.taskId).toBe("c2c_ab12");
  });

  it("writes and clears a checkpoint without dropping the chat URL", () => {
    const withCheckpoint = mergeSession(
      {
        url: "https://chatgpt.com/c/keep",
        taskId: "c2c_ab12",
        iteration: 7,
        savedAt: "2026-01-01T00:00:00.000Z",
      },
      {
        checkpoint: {
          protocolState: "EXECUTED_SENT",
          waitingFor: "GPT_REVIEW",
          originalGoal: "dark mode",
          nextExpectedStep: "wait for review",
          selfCheckStatus: "PASS",
          pageVerifyStatus: "NOT_APPLICABLE",
          verificationAt: "2026-01-01T00:00:00.000Z",
        },
      }
    );
    expect(withCheckpoint.url).toBe("https://chatgpt.com/c/keep");
    expect(withCheckpoint.checkpoint?.protocolState).toBe("EXECUTED_SENT");
    expect(withCheckpoint.checkpoint?.waitingFor).toBe("GPT_REVIEW");
    expect(withCheckpoint.checkpoint?.taskId).toBe("c2c_ab12");
    const cleared = mergeSession(withCheckpoint, { clearCheckpoint: true });
    expect(cleared.checkpoint).toBeUndefined();
    expect(cleared.url).toBe("https://chatgpt.com/c/keep");
  });

  it("keeps an existing checkpoint when only the chat URL is updated", () => {
    const previous = mergeSession(
      {
        url: "https://chatgpt.com/c/keep",
        taskId: "c2c_ab12",
        iteration: 7,
        savedAt: "2026-01-01T00:00:00.000Z",
      },
      {
        checkpoint: {
          protocolState: "EXECUTED_SENT",
          waitingFor: "GPT_REVIEW",
          originalGoal: "dark mode",
          selfCheckStatus: "PASS",
          pageVerifyStatus: "NOT_APPLICABLE",
          verificationAt: "2026-01-01T00:00:00.000Z",
        },
      }
    );
    const next = mergeSession(previous, { url: "https://chatgpt.com/c/new" });
    expect(next.url).toBe("https://chatgpt.com/c/new");
    expect(next.checkpoint?.protocolState).toBe("EXECUTED_SENT");
    expect(next.checkpoint?.originalGoal).toBe("dark mode");
  });

  it("caps checkpoint text so it cannot become a log dump", () => {
    const next = mergeSession(
      {
        url: "https://chatgpt.com/c/keep",
        taskId: "c2c_ab12",
        savedAt: "2026-01-01T00:00:00.000Z",
      },
      {
        checkpoint: {
          protocolState: "PLAN_RECEIVED",
          originalGoal: "x".repeat(600),
        },
      }
    );
    expect(next.checkpoint?.originalGoal?.length).toBeLessThanOrEqual(501);
    expect(next.checkpoint?.originalGoal?.endsWith("…")).toBe(true);
  });

  it("persists the text-only consensus round and both confirmations", () => {
    const next = mergeSession(
      {
        url: "https://chatgpt.com/c/consensus",
        taskId: "c2c_consensus",
        savedAt: "2026-01-01T00:00:00.000Z",
      },
      {
        checkpoint: {
          protocolState: "CONSENSUS_REVIEW",
          waitingFor: "GPT_CONSENSUS",
          consensusMode: true,
          consensusRound: 2,
          consensusPlan: "Update the settings flow and add regression tests.",
          consensusDisagreement: "Whether the legacy path remains supported.",
          consensusDisagreementFingerprint: "legacy-path",
          consensusRepeatedRounds: 1,
          codexConsensus: false,
          chatgptConsensus: false,
        },
      }
    );
    expect(next.checkpoint?.protocolState).toBe("CONSENSUS_REVIEW");
    expect(next.checkpoint?.waitingFor).toBe("GPT_CONSENSUS");
    expect(next.checkpoint?.consensusMode).toBe(true);
    expect(next.checkpoint?.consensusRound).toBe(2);
    expect(next.checkpoint?.consensusDisagreementFingerprint).toBe("legacy-path");

    const agreed = mergeSession(next, {
      checkpoint: {
        protocolState: "CONSENSUS",
        waitingFor: "none",
        codexConsensus: true,
        chatgptConsensus: true,
      },
    });
    expect(agreed.checkpoint?.protocolState).toBe("CONSENSUS");
    expect(agreed.checkpoint?.codexConsensus).toBe(true);
    expect(agreed.checkpoint?.chatgptConsensus).toBe(true);
    expect(agreed.checkpoint?.consensusRound).toBe(2);
  });

  it("caps consensus text and keeps legacy checkpoints compatible", () => {
    const next = mergeSession(
      { url: "https://chatgpt.com/c/consensus", taskId: "c2c_consensus", savedAt: "2026-01-01T00:00:00.000Z" },
      {
        checkpoint: {
          protocolState: "CONSENSUS_PLAN",
          consensusPlan: "x".repeat(1400),
          consensusDisagreement: "y".repeat(900),
          consensusDisagreementFingerprint: "z".repeat(200),
        },
      }
    );
    expect(next.checkpoint?.consensusPlan?.length).toBeLessThanOrEqual(1201);
    expect(next.checkpoint?.consensusDisagreement?.length).toBeLessThanOrEqual(801);
    expect(next.checkpoint?.consensusDisagreementFingerprint?.length).toBeLessThanOrEqual(129);
  });

  it("rejects invalid consensus round counters", () => {
    expect(() =>
      mergeSession(
        { url: "https://chatgpt.com/c/consensus", taskId: "c2c_consensus", savedAt: "2026-01-01T00:00:00.000Z" },
        { checkpoint: { protocolState: "CONSENSUS_PLAN", consensusRound: 0 } }
      )
    ).toThrow(/consensus-round/);
    expect(() =>
      mergeSession(
        { url: "https://chatgpt.com/c/consensus", taskId: "c2c_consensus", savedAt: "2026-01-01T00:00:00.000Z" },
        { checkpoint: { protocolState: "CONSENSUS_REVIEW", consensusRepeatedRounds: -1 } }
      )
    ).toThrow(/consensus-repeats/);
  });

  it("blocks consensus execution until both sides confirm", () => {
    expect(() =>
      mergeSession(
        { url: "https://chatgpt.com/c/consensus", taskId: "c2c_consensus", savedAt: "2026-01-01T00:00:00.000Z" },
        {
          checkpoint: {
            protocolState: "EXECUTING",
            waitingFor: "none",
            consensusMode: true,
            consensusRound: 1,
            codexConsensus: true,
            chatgptConsensus: false,
          },
        }
      )
    ).toThrow(/consensus confirmations/);
  });

  it("blocks completion until post-change verification is recorded", () => {
    expect(() =>
      mergeSession(
        { url: "https://chatgpt.com/c/verify", taskId: "c2c_verify", savedAt: "2026-01-01T00:00:00.000Z" },
        { checkpoint: { protocolState: "EXECUTED_LOCAL", waitingFor: "none" } }
      )
    ).toThrow(/post-change verification/);

    const verified = mergeSession(
      { url: "https://chatgpt.com/c/verify", taskId: "c2c_verify", savedAt: "2026-01-01T00:00:00.000Z" },
      {
        checkpoint: {
          protocolState: "EXECUTED_LOCAL",
          waitingFor: "none",
          selfCheckStatus: "PASS",
          pageVerifyStatus: "NOT_APPLICABLE",
          pageScope: "none",
          verificationAt: "2026-01-01T00:00:00.000Z",
        },
      }
    );
    expect(verified.checkpoint?.selfCheckStatus).toBe("PASS");
    expect(verified.checkpoint?.pageVerifyStatus).toBe("NOT_APPLICABLE");
  });

  it("leaves legacy sessions without a checkpoint unchanged", () => {
    const next = mergeSession(
      {
        url: "https://chatgpt.com/c/old",
        taskId: "c2c_aa01",
        iteration: 2,
        lastState: "EXECUTED",
        savedAt: "2026-01-01T00:00:00.000Z",
      },
      { iteration: 3, lastState: "EXECUTED" }
    );
    expect(next.checkpoint).toBeUndefined();
    expect(next.taskId).toBe("c2c_aa01");
  });

  it("rejects a non-collection project URL", () => {
    expect(() =>
      mergeSession(null, {
        conversationMode: "project",
        projectUrl: "https://chatgpt.com/c/nope",
      })
    ).toThrow(/project URL/);
  });
});

describe("review provider checkpoint compatibility", () => {
  function legacySession(confirmed = false): SavedSession {
    return {
      url: "https://chatgpt.com/c/legacy-review",
      connectorName: "Codex with ChatGPT · Existing",
      taskId: "legacy-review",
      savedAt: "2026-01-01T00:00:00.000Z",
      checkpoint: {
        taskId: "legacy-review", iteration: 2, protocolState: "CONSENSUS_REVIEW",
        waitingFor: "GPT_CONSENSUS", consensusMode: true, consensusRound: 2,
        consensusPlan: "保留旧入口，增加回归测试。",
        codexConsensus: confirmed, chatgptConsensus: confirmed,
        updatedAt: "2026-01-01T00:00:00.000Z",
      },
    };
  }

  it("keeps a legacy checkpoint on ChatGPT without rewriting its original data", () => {
    const legacy = legacySession();
    const before = JSON.stringify(legacy);
    const resumed = mergeSession(legacy, { checkpoint: { nextExpectedStep: "继续第 2 轮" } });
    expect(resumed.checkpoint?.reviewProvider).toBe("chatgpt");
    expect(resumed.checkpoint?.reviewMode).toBe("consensus");
    expect(resumed.checkpoint?.reviewerConsensus).toBe(false);
    expect(resumed.checkpoint?.consensusRound).toBe(2);
    expect(resumed.checkpoint?.waitingFor).toBe("GPT_CONSENSUS");
    expect(resumed.url).toBe(legacy.url);
    expect(resumed.connectorName).toBe(legacy.connectorName);
    expect(JSON.stringify(legacy)).toBe(before);
  });

  it("accepts legacy ChatGPT confirmation after resuming an unconfirmed checkpoint", () => {
    const resumed = mergeSession(legacySession(), { checkpoint: { nextExpectedStep: "等待 ChatGPT 评审" } });
    const confirmed = mergeSession(resumed, {
      checkpoint: { protocolState: "CONSENSUS", codexConsensus: true, chatgptConsensus: true, waitingFor: "none" },
    });
    expect(confirmed.checkpoint?.reviewerConsensus).toBe(true);
    const executing = mergeSession(confirmed, { checkpoint: { protocolState: "EXECUTING" } });
    expect(executing.checkpoint?.protocolState).toBe("EXECUTING");
  });

  it("honors a legacy ChatGPT confirmation being withdrawn", () => {
    const confirmed = mergeSession(legacySession(true), { checkpoint: { protocolState: "CONSENSUS" } });
    const withdrawn = mergeSession(confirmed, {
      checkpoint: { protocolState: "CONSENSUS_REVIEW", chatgptConsensus: false },
    });
    expect(withdrawn.checkpoint?.reviewerConsensus).toBe(false);
    expect(() => mergeSession(withdrawn, { checkpoint: { protocolState: "EXECUTING" } }))
      .toThrow(/consensus confirmations/);
  });

  it("does not accept a ChatGPT flag as DeepSeek approval", () => {
    expect(() => mergeSession(null, {
      taskId: "deepseek-review",
      checkpoint: {
        protocolState: "EXECUTING", reviewProvider: "deepseek", reviewMode: "consensus",
        consensusRound: 1, codexConsensus: true, chatgptConsensus: true,
      },
    })).toThrow(/consensus confirmations/);
  });

  it("accepts generic DeepSeek approval and preserves review references and round on resume", () => {
    const saved = mergeSession(null, {
      taskId: "deepseek-review",
      checkpoint: {
        protocolState: "CONSENSUS", waitingFor: "REVIEWER_CONSENSUS",
        reviewProvider: "deepseek", reviewMode: "consensus", consensusRound: 3,
        reviewerConsensus: true, codexConsensus: true,
        reviewSessionRef: "reviews/workspace-1/thread-1.json", codexThreadId: "thread-1",
        chatUrl: "https://chat.deepseek.com/a/chat/saved-review",
      },
    });
    const resumed = mergeSession(saved, { checkpoint: { protocolState: "EXECUTING", waitingFor: "none" } });
    expect(resumed.checkpoint).toMatchObject({
      protocolState: "EXECUTING", reviewProvider: "deepseek", reviewMode: "consensus",
      consensusRound: 3, reviewerConsensus: true, codexConsensus: true,
      reviewSessionRef: "reviews/workspace-1/thread-1.json", codexThreadId: "thread-1",
      chatUrl: "https://chat.deepseek.com/a/chat/saved-review",
    });
    expect(resumed.checkpoint?.chatgptConsensus).toBeUndefined();
  });

  it("rejects changing channels inside the same existing checkpoint", () => {
    expect(() => mergeSession(legacySession(), { checkpoint: { reviewProvider: "deepseek" } }))
      .toThrow(/cannot switch reviewer/);
  });

  it("does not carry old confirmations into a different task and reviewer", () => {
    const previous = mergeSession(legacySession(true), { checkpoint: {
      protocolState: "DONE", selfCheckStatus: "PASS", pageVerifyStatus: "NOT_APPLICABLE",
    } });
    expect(() => mergeSession(previous, {
      taskId: "new-deepseek-review",
      checkpoint: {
        taskId: "new-deepseek-review", protocolState: "EXECUTING", reviewProvider: "deepseek",
        reviewMode: "consensus", consensusRound: 1,
      },
    })).toThrow(/consensus confirmations/);
  });
});

describe("clearChatPointer", () => {
  const dirs: string[] = [];

  afterEach(() => {
    for (const dir of dirs) cleanup(dir);
    dirs.length = 0;
    delete process.env.C2C_STATE_DIR;
  });

  it("keeps the collection binding in Project mode", () => {
    const dir = makeTmpDir("session-clear");
    dirs.push(dir);
    process.env.C2C_STATE_DIR = dir;
    writeSession("abc123abc123", {
      conversationMode: "project",
      projectUrl: PROJECT,
      url: "https://chatgpt.com/c/gone",
      connectorName: "Codex with ChatGPT · Demo",
      checkpoint: {
        taskId: "c2c_ab12",
        iteration: 4,
        protocolState: "EXECUTED_SENT",
        waitingFor: "GPT_REVIEW",
        originalGoal: "dark mode",
        updatedAt: "2026-01-01T00:00:00.000Z",
      },
      savedAt: "2026-01-01T00:00:00.000Z",
    });
    expect(clearChatPointer("abc123abc123")).toEqual({ cleared: true, keptProject: true });
    const saved = readSession("abc123abc123");
    expect(saved?.projectUrl).toBe(PROJECT);
    expect(saved?.url).toBeUndefined();
    expect(saved?.checkpoint?.protocolState).toBe("EXECUTED_SENT");
  });

  it("deletes a legacy long-chat file", () => {
    const dir = makeTmpDir("session-clear-legacy");
    dirs.push(dir);
    process.env.C2C_STATE_DIR = dir;
    writeSession("def456def456", {
      url: "https://chatgpt.com/c/legacy",
      savedAt: "2026-01-01T00:00:00.000Z",
    });
    expect(clearChatPointer("def456def456")).toEqual({ cleared: true, keptProject: false });
    expect(readSession("def456def456")).toBeNull();
  });
});

describe("corrupt saved sessions", () => {
  const dirs: string[] = [];

  afterEach(() => {
    for (const dir of dirs) cleanup(dir);
    dirs.length = 0;
    delete process.env.C2C_STATE_DIR;
  });

  it("keeps a backup and reports corrupt instead of treating the file as a new session", () => {
    const dir = makeTmpDir("session-corrupt");
    dirs.push(dir);
    process.env.C2C_STATE_DIR = dir;
    const file = sessionFile("corrupt123");
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, "{ this is not valid JSON", "utf8");

    const result = readSessionResult("corrupt123");
    expect(result.status).toBe("corrupt");
    if (result.status !== "corrupt") throw new Error("expected a corrupt result");
    expect(fs.existsSync(result.backupPath)).toBe(true);
    expect(fs.readFileSync(result.backupPath, "utf8")).toContain("this is not valid JSON");
    expect(() => readSession("corrupt123")).toThrow(/session is corrupt/i);
  });
});
