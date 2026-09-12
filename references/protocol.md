# Coding and consensus protocol workflow

Read this reference for an actual coding task, text-only multi-round consensus review, execution checkpoints, self-checks, and ChatGPT review. The wire message schema is maintained separately in [`core/docs/protocol.md`](../core/docs/protocol.md).

## Workflow: coding task（"使用 Codex with ChatGPT 完成 XXX"）

Review-channel selection is saved per task. New review tasks default to DeepSeek; explicit GPT/ChatGPT instructions select the existing ChatGPT path. Never mix a DeepSeek task with a ChatGPT task.

Protocol states sent to ChatGPT: INIT → (CONSENSUS_PLAN ↔ CONSENSUS_REVIEW → CONSENSUS)? → PLAN → EXECUTING → EXECUTED → REVIEW → (PLAN | DONE | BLOCKED).
Local checkpoint states (session only, never a ChatGPT `STATE:` line):
`INIT`, `CONSENSUS_PLAN`, `CONSENSUS_REVIEW`, `CONSENSUS`, `PLAN_RECEIVED`, `EXECUTING`, `EXECUTED_LOCAL`, `EXECUTED_SENT`, `DONE`, `BLOCKED`.
Do not invent `STATE: RESUME`. If the original chat is gone, send HANDOFF.
All control messages start with `[C2C]`. Keep Codex→ChatGPT messages under 1 KB.
ChatGPT's replies are expected to be substantive (see step 3). Docs: `docs/protocol.md`.

## 计划模式卡住恢复

普通编码任务不等待 Codex 客户端的计划模式按钮，也不把 `<proposed_plan>` 当成
执行完成。若回复只包含 `<proposed_plan>`，或连续两轮没有进入 `STATE: PLAN`、
`STATE: EXECUTED` 等正常状态，Codex 显示：

```text
当前会话处于只出方案模式，自动切换到普通执行流程。
```

随后保留当前方案摘要、工作区、连接器和旧会话历史，先运行 `c2c review execute
--plan-mode-detected --json` 保存转交状态，再在同一工作区和连接器中启动普通执行续接；
当前任务无法切换时，使用 Codex 任务工具创建普通执行任务并发送 HANDOFF。创建成功后
运行 `c2c review execute --thread <原任务号> --execution-thread <新任务号>` 记录真实接手
任务。用户已经要求“共识后自动修改”时，不再询问，也不等待用户再发“继续”。不要编辑
`state_5.sqlite`、历史 JSONL 或旧消息，也不要要求用户切换顶部模式。普通执行从修改、
测试、复核和页面检查开始，不能再次发送计划包装标签。

若客户端拒绝创建普通执行任务、复制任务或切换模式，立即停止等待，回显“当前会话无法切换到执行模式，已停止等待；原会话和历史保持不变。”，并记录 `BLOCKED`/`PLAN_MODE_UNAVAILABLE`。不得继续轮询、重复发送消息或声称执行成功。

如果续接或 HANDOFF 创建失败，或连续两次状态完全没有变化，立即停止轮询并回显：

```text
计划模式恢复失败，已停止等待。
原因：当前 Codex 会话无法切换到普通执行任务。
原工作区和连接器已保留，没有修改历史记录。
```

不得重复发送同一消息，也不得修改本地 Codex 数据库。

多轮共识是独立流程：用户明确要求多轮评审时，仍需双方返回 `CONSENSUS` 后才允许
修改文件。计划模式恢复只解决客户端停在计划界面的情况。

## 普通任务阶段进度回显

没有触发纯文字多轮共识评审时，Codex 仍要在进入新阶段时回显一次进度，避免用户
误以为任务卡住。每次回显使用短格式：

```text
当前阶段：正在分析 / 正在规划 / 正在修改 / 正在测试 / 正在复核 / 正在检查页面 / 已完成
任务摘要：<一句话说明正在处理什么>
当前结果：<已完成的结果，或“进行中”>
下一步：<下一步会做什么>
```

通常按“分析 → 规划 → 修改 → 测试 → 复核 → 页面检查（适用时）→ 完成”推进。
任何测试、复核或页面检查失败，都必须回到对应阶段修复并重新验证；在验证通过前
不得回显“已完成”，也不得发送同步或发布回执。多轮评审继续使用本文件后面的轮次
格式，不与普通阶段计数混用。

0. `c2c tunnel status -w <workspace> --json`. If `needsChoice`, follow
   **Connection choice** first (existing installs: ask once, then remember).
   Then `c2c doctor -w <workspace> --json` (auto-repairs). **Doctor gate:** if local
   is not green, do not open ChatGPT and do not send INIT. If
   `namedRepair.needed` is true, tell the user `namedRepair.userMessage`, run
   `c2c tunnel login --json` (their browser; Cloudflare exception), then doctor
   again. If `chatgptRepair.needed` is true, tell the user `chatgptRepair.userMessage`
   (one paragraph, no internals), run **Workflow: reconnect after address
   reclaim**, then doctor again and only continue when the gate is green.
   Generate task id: `c2c_` + 4 random hex chars — unless a checkpoint already
   has one (reuse that id; do not mint a second task).
1. `c2c session -w <workspace> --json`. Open ChatGPT on the same iab tab
   per **Conversation management** for `conversation.mode` (foreground +
   markHandoff). long-chat: saved chat, or `https://chatgpt.com/` if none.
   project: this thread's chat URL, or the collection page for a new chat,
   or **Bind Project** if `projectReady` is false. On a NEW conversation
   confirm Chat mode (**In-app browser** §7), then send the boot prompt from
   `docs/protocol.md` §Boot Prompt and the workspace_info check (name the
   exact `connectorName`). Confirm the reply names the current workspace
   before saving the session URL. Do not use the browser to re-read code MCP
   already provides. After sending a control message, wait per
   **In-app browser** §8.

   **Resume from `session.checkpoint` before any INIT.** Missing checkpoint
   (legacy session): continue as a normal new/continued loop. A browser/js
   timeout is not a lost task — claim the original tab; do not INIT, re-run,
   or resend EXECUTED just because a wait timed out.
   - `EXECUTED_SENT` + `waitingFor=GPT_REVIEW`: do not INIT, do not re-run,
     do not resend EXECUTED. Stay on the saved chat and wait for review. If
     that chat 404s: HANDOFF from checkpoint fields (no logs), then wait.
   - `EXECUTED_LOCAL`: local work is done; only send EXECUTED (record first
     if this iteration has no record yet). Do not re-run.
   - `EXECUTING`: not finished. Continue the current PLAN if you still have
     it; otherwise HANDOFF and ask ChatGPT to restate the last PLAN. Do not
     treat it as done and do not INIT a new task.
   - `PLAN_RECEIVED`: execute that plan. Do not INIT.
   - `CONSENSUS_PLAN` / `CONSENSUS_REVIEW` / `waitingFor=GPT_CONSENSUS`: show the saved round and continue the same consensus loop. Do not restart at round 1.
   - `INIT` / `waitingFor=GPT_PLAN`: claim the tab and wait. Do not resend INIT.
   - `DONE`: summarize to the user if needed; `c2c session set --clear-checkpoint`.
    - `BLOCKED`: surface ChatGPT's reason; do not INIT.
    Never re-pair, never recreate the connector, and never rewrite Project
    instructions just to resume.

    **Fast failure for connector and usage errors.** After a control message,
    do at most two short checks (about 20–30 seconds apart; 60 seconds total).
    If the page or tool reports `Codex auth token is unavailable`, exhausted
    Codex/Work usage, an upstream `HTTP 502`, or two consecutive
    `workspace_info` failures, set the local checkpoint to `BLOCKED` and stop
    waiting. Do not resend the same round, open a second chat, re-pair, or ask
    for a token/API key. Show the current round, exact error, and one next step.
    If access later recovers, resume from the saved `CONSENSUS_PLAN` or
    `CONSENSUS_REVIEW` round; never restart at round 1.
2. Send INIT with the user's goal (skip when the checkpoint says not to):

   If the request matched **纯文字多轮方案评审**, do not send the normal INIT
   first. Generate the Codex draft locally, display `多轮评审：第 1 轮`, save a
   `CONSENSUS_PLAN` checkpoint with `waitingFor=GPT_CONSENSUS`, and send the
   compact `CONSENSUS_PLAN` message from `docs/protocol.md`. The normal INIT →
   PLAN path below is used only when consensus mode was not triggered.

```
[C2C]
STATE: INIT
TASK_ID: c2c_f81a
ITERATION: 0

GOAL:
<user's goal, one paragraph>

INSTRUCTION:
Inspect the connected workspace through the Codex with ChatGPT MCP connector.
Produce a C2C PLAN message.
```

   Then:
   `c2c session set -w <ws> --task <id> --iteration 0 --state INIT --protocol-state INIT --waiting-for GPT_PLAN --goal "<short goal>" --next-step "wait for PLAN"`
3. Wait for ChatGPT's `STATE: PLAN` reply (**In-app browser** §8 — short DOM
   checks, same tab; do not treat a 5-minute browser timeout as failure).
   Read GOAL/ACTIONS/TESTS/SUCCESS_CRITERIA.
   A good PLAN also carries RATIONALE and concrete natural-language edit
   suggestions (which file, what to change, why). If the reply is a bare
   one-liner with no rationale or file-level guidance, ask once:
   "Please expand the plan with rationale and concrete per-file suggestions."
   Then:
   `c2c session set -w <ws> --protocol-state PLAN_RECEIVED --waiting-for none --next-step "execute PLAN"`
4. Execute the plan yourself with your own harness (your tools, your judgment;
   ChatGPT does not micro-manage tool calls).
   Before you start:
   `c2c session set -w <ws> --protocol-state EXECUTING --waiting-for none --next-step "finish PLAN then record"`
5. **强制完成修改后自检与页面验证**（见上节）后，才能记录执行结果。至少要
   查看一次当前 `git diff`；涉及页面时必须在内置浏览器完成加载、主要入口和刷新
   检查；不涉及页面时记录 `PAGE_VERIFY: NOT_APPLICABLE`。检查失败就先修复并重做，
   不得发送 `EXECUTED` 或同步 GitHub。通过后记录执行结果，供 ChatGPT 通过 MCP 读取。
   Metadata always:
   `c2c record -w <ws> --task c2c_f81a --iteration 1 --changed-files "src/a.ts,src/b.ts" --tests "27 passed" --exit-status ok --self-check PASS --page-verify NOT_APPLICABLE --verification-at "<ISO timestamp>"`
   If this iteration ran a **test / build / lint / typecheck** command, also
   pass that command's output. Write stdout/stderr to a local temp file first,
   then:
   `c2c record … --command "pnpm test" --output-file <temp> --exit-code <n>`
   Record both success and failure. Do not record shell history, `.env`,
   keys, or unrelated dumps. Never paste that file (or any log) into ChatGPT.
   If the CLI says the output was not released, still send EXECUTED; ChatGPT
   reviews from git. Then:
   `c2c session set -w <ws> --iteration 1 --state EXECUTED --protocol-state EXECUTED_LOCAL --waiting-for none --next-step "send EXECUTED"`
6. Send EXECUTED (no diffs, no logs) only after the local gate is green. Include the
   verification fields so the result is auditable. Tell ChatGPT to use MCP, including
   `execution_output` when a readable item exists:

```
[C2C]
STATE: EXECUTED
TASK_ID: c2c_f81a
ITERATION: 1

RESULT:
Execution finished.

CHANGED_FILES:
4

TESTS:
27 passed

SELF_CHECK: PASS
PAGE_VERIFY: PASS | NOT_APPLICABLE
PAGE_SCOPE:
<affected page/function, or none>

Please independently inspect the workspace and current git diff through MCP.
If execution_output lists a readable item for this iteration, list then read it.
If status is restricted, ignore it and review from git_diff.
```

   Then:
   `c2c session set -w <ws> --protocol-state EXECUTED_SENT --waiting-for GPT_REVIEW --next-step "wait for PLAN or DONE"`
7. ChatGPT reviews via MCP (`git_diff`, `read_file`, `read_image`, `test_status`,
   `execution_output`) and independently checks the changed behavior. Its review does not
   replace the local self-check or page verification. It replies DONE / PLAN (next iteration)
   / BLOCKED.
8. Loop. Respect maxIterations (`.c2c.json`, default 12). At the limit, pause and ask
   the user: "已完成 12 轮协作，仍有未解决问题，是否继续？"
9. On DONE: summarize the result to the user in plain language.
   `c2c session set -w <ws> --state DONE --clear-checkpoint`
10. On BLOCKED: read ChatGPT's reason, fix what you can, or surface the single
    decision the user must make.
    `c2c session set -w <ws> --protocol-state BLOCKED --waiting-for USER --known-issues "<short reason>"`


## 多轮评审等待与恢复（1.19.0）

发送证据、计时、失败判断与恢复使用唯一规则：[等待与恢复](reliability.md)。正常生成不使用两次检查或 60 秒暂停条件；页面观察不代替回执和双方共识。恢复只从同任务检查点读取，不能从全局最后一行获取执行许可。

## 后续轮次和执行状态（1.19.0）

第 1 轮消息使用 `PLAN_SUMMARY`。第 2 轮及以后使用 `ROUND_DELTA`，只包含新增事实、修改点和当前分歧；完整上一轮摘要只保存在本地状态，不重复发给评审网页。

等待网页回复和 Codex 执行是两个独立状态：前者显示本轮等待分钟数，后者显示 `executionStartedAt` 之后的执行分钟数。共识通过后必须立即发起普通执行任务接力，不能等待用户再次发送“继续”；计划模式接力会记录 `handoffRequestedAt` 和 `autoStart=true`。

## 429/503 服务暂停（1.19.0）

遇到 429 或 503 时记录 `statusCode`、`detectedAt`、`attempts`、`source`、`backoffSeconds` 和 `retryAfterAt`，状态为暂停，执行门槛关闭。没有服务提供的时间时，429 从 30 秒、503 从 60 秒开始指数退避，最多 15 分钟。恢复必须显式请求且到达 `retryAfterAt`；恢复失败再次保存次数，不重复发送或重建会话。状态不保存服务原始响应、令牌或私密头。


## 1.19.1 浏览器回复和计时

新 DeepSeek 任务在写入轮次前执行 `c2c review reply --evidence <短证据JSON>`，核验原会话、本轮完整助手回复及唯一 TASK_ID、ROUND、DECISION。该命令不确认 Codex 共识。`review get --json` 新增 polling、timing；旧字段保持兼容。缺少计时为 null，不补造；网页思考时间不代表总耗时。详细合同见随 Skill 发布的 `references/browser-runtime.md`。


最终复核新增 REVIEW_STAGE: FINAL、PLAN_ROUNDS 和 EXECUTION_SUMMARY；沿原会话继续一个独立复核轮，方案轮数固定在 planRoundCount。执行端在真实修改与检查后调用 review final-prepare --summary <结果摘要> --self-check PASS --page-verify PASS。保持原 executionStartedAt，保存 executionVerifiedAt；当前最终回复与双方核对通过后才能 finish。失败、取消或未通过最终复核时不能写 DONE。

每轮 timings 保存 messageReadyAt、sendPageVerifiedAt 对应的 pageVerifiedAt、submittedAt、firstReplyObservedAt、replyCompletedObservedAt、codexReviewedAt、consensusAt、recoveryStartedAt/recoveryFinishedAt 和 maxObservationDelayMs。UTC/时区等价时间按时间点比较；旧数据缺失为 null。发送回执必须先于等待回复保存，过期 lease 只在原页核对后重新获取并补录原发送，不重发。
