---
name: deepseek-independent-review
description: "通过 DeepSeek 官网做一次独立技术评审。用户显式点名本 Skill，或明确要求 DeepSeek 独立找错、反驳 Codex、比较方案、复核根因或验证 Codex 判断时使用；普通提及 DeepSeek 不触发。固定在 Codex 右侧栏内置浏览器打开 https://chat.deepseek.com/，目标为保持深度思考和智能搜索开启；一个 Codex thread 只绑定一个专用官网会话和 tab，同一 thread 后续 R2…Rn 复用。"
---

## 配套更新 1.19.1：浏览器恢复与完整复测

浏览器工具、恢复、轮次衔接和计时统一遵循 [references/browser-runtime.md](references/browser-runtime.md)。当前宿主优先使用 mcp__cua_repl；不得导入内部浏览器包或猜测旧接口。旧任务仍复用原官方对话；暂时冻结按仅恢复流程处理。


## 配套更新 1.19.0

- 第 1 次发送完整短摘要；后续复核只发送新增事实、修改点和当前分歧，不重复上一轮全文。
- 等待网页和 Codex 执行分别计时；连续 10 分钟没有新回复才暂停。
- 429 和 503 按服务给出的时间或递增退避恢复，不重复发送、不重复建会话。

## 配套更新 1.18.1

通过 codex-with-chatgpt 进入评审时，发送、等待与恢复遵循 [references/reliability.md](references/reliability.md)。发送前使用新鲜浏览器证据；正常回复等待不受两次无变化规则影响；恢复必须重新核对原页面，不直接恢复权限。

评审和执行门槛全部通过后必须立即回到 Codex 执行。当前任务若被锁在“只做计划方案”，不要等待用户再发“继续”：调用 `c2c review execute --plan-mode-detected --json` 记录转交要求，在同一工作区建立普通执行任务，随后用 `--execution-thread <新任务号>` 记录接手任务。新任务直接修改、测试和复核，不重新发起评审。


# DeepSeek独立一次评审

## 激活

用户显式点名 `$deepseek-independent-review` 时：

1. 读取本文件和 [references/browser-protocol.md](references/browser-protocol.md)；
2. 创建或恢复当前 `TaskId`；
3. 优先调用 `scripts/activate_review.ps1 -SkillName deepseek-independent-review` 幂等激活。它必须返回 `new`、`resume` 或 `conflict`、真实耗时和慢路径原因；正常 `new/resume` 目标小于 2 秒。不要先扫描项目、日志或全部浏览器标签。

Skill chip 不算执行证据。没有真实页面、绑定和回执时不得写“已发送/已收到”。

激活性能记录：

- 默认阈值是 2000ms；
- `activationElapsedMs` 超过阈值时，结果返回 `activationSlowPathAlert=true`；
- 慢路径耗时、阈值和原因会自动写回当前 Task 状态；
- 状态二次写入失败时，只追加 `activation-slow-path.log`，不记录消息正文、指纹、密码、Token 或密钥；
- 正常激活不先扫描整个项目、日志或全部浏览器标签。

## 固定环境与隔离

```text
页面：https://chat.deepseek.com/
目标：网页当前模型（官网已合并快速、专家、识图入口）
推理：深度思考 + 智能搜索
浏览器：Codex 右侧栏内置浏览器（iab）
一个 Codex thread = 一个官网会话 + 一个专用 runtime tab
```

- 禁止 Chrome 集成、Chrome、Edge、扩展和外部浏览器；`iab` 不可用就停止，不回退。
- 页面必须真实确认当前网页模型，并确认深度思考和智能搜索开启。
- 同一 thread 的新 TaskId、R2…Rn 先 Claim 后复用；不同 thread 必须使用不同 `official-chat` sessionId 和 tab。
- 会话没有稳定 ID 时使用当前 thread 的 `official-marker`，不能用标题、数字 tab 或相同 URL 猜身份。
- 所有发送步骤必须匹配 lease、runtime、tab、sessionId 和可用时的 marker。

## 浏览器工具硬闸门（防止五分钟不发送）

- 页面操作只能使用 Codex 右侧栏内置浏览器的 `mcp__cua_repl.js`；PowerShell、普通命令、`read_mcp_resource`、文字“继续/下一步”和命令输出都不算浏览器证据，也不能代替点击或发送。
- 先加载并复用同一个 `iab` 浏览器绑定，再调用一次 `user.openTabs()` 和一次 `tabs.list()` 读取真实标签。只有确认当前 thread 的原 tab 确实不存在，并且已经 `MarkLost` 后，才允许调用一次 `tabs.new()` 建立 replacement tab；禁止在未检查现有 tab 前直接新建。
- 每次浏览器动作后，下一步必须仍是浏览器工具读取 DOM/截图并核对结果；不得在页面核实到发送之间插入无关扫描、长篇汇报或空转命令。
- `PrepareSend` 默认只进入 `browserConfirmationStatus=awaiting`，不发送也不启动 deadline。宿主平台确认后调用 `ConfirmBrowserSend`；只有它返回 `sendNow=true` 后才能填入并通过 button 或 Enter 提交，然后回读 DOM。平台确认通过后超过 30 秒仍没有真实发送或回执，立即调用 `FailBrowserWorkflow`。
- `ConfirmationSource` 只接受 `action-time-user-response` 或浏览器工具真实返回的 `browser-tool-token`；禁止用业务提前授权、Skill chip、文字“继续”或自造 token 冒充宿主平台确认。
- 平台确认按 `TaskId + fingerprint + session/tab/runtime/lease` 绑定。同一消息确认后，只要尚未执行 fill/click/press、没有提交动作和 DOM 落点，本地参数校验、命令拼接或 DOM 重读失败都必须复用原确认，禁止再次提示“确认发送 Rn”。重新调用 `ConfirmBrowserSend` 可省略确认来源参数；返回 `platform-already-confirmed`、`verified-confirmed-send` 或 `send-confirmed-ready` 时，下一步直接发送。若确认已过 30 秒但仍无浏览器动作，调用 `FailBrowserWorkflow`，也不得靠再次询问刷新确认。
- 本地激活和已有绑定的 `Claim` 只做必要状态读写，不先扫描项目、日志或全部 tab；目标是各自在 2 秒内完成。完整评审消息先准备好，再进入页面核实和发送链。
- 激活或用户说“继续”后，不能只调用状态面板再重复汇报。必须读取 `nextAction` 并执行对应动作；如果没有 bound 会话，下一步必须是 `prepare-browser-binding`，不能是 `record-next-round`。连续两次汇报没有浏览器动作、状态变化或明确失败记录，视为流程 Bug，立即停止重复汇报并按 `FailBrowserWorkflow` 或恢复/绑定流程收口。
- “继续”必须先调用 `scripts/advance_review_workflow.ps1 -Action Advance`，由脚本按当前 `CodexThreadId + TaskId` 确定下一步；不能只调用 `show_review_dashboard.ps1`。进度汇报前调用 `-Action RecordReport`，如果 `noOpReportCount>=2`，必须停止重复汇报，改做推进、恢复或明确失败收口。
- 浏览器工具不可用、调用失败或连续一次无法取得真实页面时，立即调用 `session_binding.ps1 -Action FailBrowserWorkflow`，释放当前 thread 自己的 lease、冻结发送授权并保留审计；浏览器故障必须先分类，不能把临时断线直接标记成会话丢失。

浏览器故障分类：

- `runtime-disconnected`、`tool-failed`、`unknown`：进入 `recovery-pending`，保留原 session、原 tab、原 runtime 身份和审计；当前任务冻结，最多允许一次 `RecoverRuntimeTab`。新 Task 只能 `Claim` 后恢复原 runtime，返回 `recover-runtime-required` 时禁止新建 tab。
  - 只有 `MarkLost` 收到两来源明确 `confirmed-absent`，或明确 `wrong-session` 证据时，才允许清空活动身份、进入 `lost` 并执行一次 replacement bootstrap。
  - 恢复成功后回到 `bound`；恢复失败或达到一次恢复上限时继续冻结并等待明确的丢失证据或用户裁决，不自动循环重连，不重复 Claim，不新建第二个会话。

### 自动恢复硬规则

- `FailBrowserWorkflow` 返回 `recovery-pending` 时，不得把任务交回用户手动恢复；只要 `iab` 重新可用，当前执行端必须自动沿同一 thread/task 执行一次 `Claim → RecoverRuntimeTab → DOM/Verify`。
- 浏览器临时断线会把任务暂时写成 `taskTerminalStatus=frozen`、`activationStatus=frozen`，但只要 `nextAction=auto-recover-runtime-tab`，原 Task 的 `Claim` 和 `RecoverRuntimeTab` 属于受限“仅恢复”路径，允许继续执行；这不是恢复发送授权，也不是永久终态。
- 如果 `FailBrowserWorkflow` 已把当前 Task 暂时冻结并写入 `nextAction=auto-recover-runtime-tab`，恢复动作允许原 TaskId 进入“仅恢复”路径；恢复成功后自动回到 active/activated，再继续页面核验。这个恢复路径不等于发送授权，仍必须重新走发送闸门；有 `pendingReceipt/auditRisk` 时继续禁止重发。
- 两来源都明确确认原 tab/session 不存在后，当前执行端必须自动完成 `MarkLost → tabs.new(https://chat.deepseek.com/) → BeginBootstrap -ReplaceLost`，随后重新核验当前网页模型、深度思考和智能搜索和当前 thread 身份；不得等待用户说“重新打开”。
- 自动恢复不等于自动发送：恢复页面后仍必须重新取得 DOM 证据，发送继续经过 `PrepareSend → 宿主平台真实确认 → ConfirmBrowserSend`；不得把业务提前授权当成平台发送确认。
- 每个 thread 最多一次 runtime 恢复、一次 replacement bootstrap；失败后写入明确 `nextAction` 并冻结，禁止循环新建窗口、跨 thread 接管或静默重发。
- 只有 `iab` 工具本身不可用、平台发送确认需要用户动作或出现决策僵局时，才可以暂停等待用户；“找不到原窗口”本身不再要求用户手动处理。

### `lost` 绑定优先复用已有官方会话

- `advance_review_workflow.ps1 -Action Advance` 在发现当前 thread 的绑定为 `lost` 且 `replacementRequired=true` 时，必须先返回 `nextAction=bind-existing-official-session`，不能直接新建 replacement，也不能只汇报不推进。
- 执行端随后必须在 Codex 右侧栏用 `mcp__cua_repl.js` 核验当前官方 DeepSeek 会话的真实 URL、标题、当前网页模型、深度思考和智能搜索、DOM marker、tab 和 runtime，再调用 `session_binding.ps1 -Action BindExistingOfficialSession`。这个动作不是“接管当前活动 tab”，而是把已核验的官方 session/tab/runtime 绑定回当前 thread。
- `BindExistingOfficialSession` 只允许当前 thread 的 `lost/cancelled/terminated` 绑定，或已经终态的旧 Task；如果旧 Task 仍在运行、session/tab/runtime 与当前 bound 绑定不一致、页面不是官网或模式未开启，必须拒绝。
- 接管成功后必须把旧 Task 的 `pendingReceipt`、`auditRisk`、指纹、确认和重试记录留在 `previousSendAudit`，清空当前发送闸门并同步当前 Task；不能把旧回执当成新消息已发送，也不能自动重发。
- 只有真实 DOM 核验失败、当前官方 session 无法证明，或两个来源明确 `confirmed-absent` 后，才允许走 `MarkLost → tabs.new → BeginBootstrap -ReplaceLost`。`tabs.list()` 返回 `empty/unknown` 不能跳过绑定核验或直接新建窗口。

### 失败流程和崩溃恢复

- `FailBrowserWorkflow` 先写 `workflow-transaction.<thread>.<task>.json`，再更新绑定、释放当前 thread/task 自己的 lease、冻结任务状态；不能只删 lease 或只写一半状态。
- 下一次绑定脚本调用会先检查属于当前 `CodexThreadId + TaskId` 的未完成事务并按阶段恢复；恢复后清理事务日志、标记任务失败和 `recoveredFromTransaction=true`，禁止继续发送。
- 只恢复当前 thread/task 的事务，不能接管或覆盖其他 thread 的事务。
- 失败前若存在 `pendingReceipt`，恢复后必须保留 `auditRisk=true` 和原消息指纹，不能把工具失败当成消息不存在，更不能直接重发。
- 原子 JSON 写入只保证本地状态不被半写覆盖；是否真的发送仍必须用页面 DOM 回读确认，不能宣称 DeepSeek 服务端 exactly-once。

## 首次绑定与恢复

首次：

```text
BeginBootstrap → AcquireBrowserLease → DOM → VerifyBootstrap → PrepareSend
→ Codex 平台确认通过后 ConfirmBrowserSend
→ 发送完整评审消息；没有稳定 sessionId 时消息必须含 thread marker
→ 回读官网 sessionId、可用时的 marker、消息落点、openTabs 和 tabs.list
→ CompleteBootstrap → RecordSendOutcome（三来源证据）→ ReleaseBrowserLease
```

已有绑定：新 TaskId 先 Claim，不新建会话。如果旧绑定只是被过期 lease 清理误标为 `lost`，先核验原 sessionId、可用时的 marker、当前网页模型、深度思考和智能搜索，再调用 `RecoverExpiredLeaseBinding` 复用原会话，禁止直接新建第二个 DeepSeek 会话。

如果在 Codex 右侧栏找不到当前 thread 原来绑定的 session、可用时的 marker 或专用 tab，先确认不是另一个 thread 的窗口；确认原窗口确实不存在后，先 `MarkLost` 保留旧绑定审计，再在 Codex 右侧栏新建一个 DeepSeek 官网窗口，使用新 tab/runtime 执行 `BeginBootstrap -ReplaceLost`。新窗口必须重新确认当前网页模型、深度思考和智能搜索和正式会话身份；没有稳定 sessionId 时还要核对当前 thread marker，不能接管其他 thread 的会话。

“找不到原窗口”与“原窗口只是暂时未读到”要分开处理：能通过真实 DOM 核验原 session 和可用时的 marker 就复用；无法核验且页面确实没有原窗口才新建。浏览器 runtime 重建使用 `RecoverRuntimeTab`；已是同一官网会话但来源不是右侧栏时使用 `MigrateToInAppSidebar`。旧本机 Harness、旧规则或损坏绑定必须 `MarkLost` 后在官网右侧栏重新 bootstrap，不能静默迁移。

单纯过期的浏览器 lease，如果没有 `pendingReceipt` 或其他未确认发送风险，按 `expired-lease-safe-release` 自动清理并恢复；只有存在待回执、unknown/wrong-session/not-found 等风险时才标记审计风险并冻结。

新 Task `Claim` 复用同一官网会话前，会把旧 Task 的 `pendingReceipt`、`auditRisk`、fingerprint、回执和重试记录移入 `previousSendAudit`，清空当前发送闸门；旧审计保留，但不阻塞新 Task 的新 fingerprint。用户说“继续”不等于任务完成，也不能把 heartbeat 暂停当成完成，应恢复当前 Task/同一会话。

## 一次独立评审流程

```text
读取任务与绑定状态
→ Codex检查本地事实、证据、根因候选、方案、风险和验证计划
→ 把 Codex结论标为初步判断
→ Claim 或首次 bootstrap
→ Acquire → DOM → Verify → PrepareSend → 平台确认 → ConfirmBrowserSend → 发送一条完整请求
→ 回读 → Record → Release
→ 等待一份完整回复
→ Codex逐项标记采纳、部分采纳、不采纳或暂无法确认
→ 检查无冲突、方案敲定后才修改
```

DeepSeek必须根据本轮事实重新推导，不能只附和 Codex，也不能机械反对。回复至少包含：独立问题理解、事实/推断/缺失证据、独立根因、对 Codex 初步判断的结论、反驳/修正/补充、风险和边界、推荐方案、备选方案、回滚、验证顺序、最终结论、置信度。

## 批次记录和状态面板

- 收到并核对完整回复后，调用 `scripts/review_round.ps1 -Action RecordRound` 记录当前 `R1…Rn`、双方立场、未解决分歧和新证据。
- 同一 thread 后续独立批次若连续两轮重复相同实质分歧且没有新证据，同样标记决策僵局并保持禁止修改；不能靠继续发送绕过用户裁决。
- 用户裁决或补充新证据后先调用 `ResolveDeadlock`，再决定是否进入新的独立批次；解除僵局不等于双方达成共识。
- 使用 `scripts/show_review_dashboard.ps1` 输出固定六列状态面板。两个脚本只处理本地状态，不访问 DeepSeek 页面。

## 取消评审

用户说“不要 DeepSeek”“本次不评审”“只整理不发送”时：

- 不打开或操作 DeepSeek 页面；
- 调用 `CancelBootstrap` 或 `update_review_status.ps1 -CancelReview`；
- 撤销发送授权，释放当前 thread 自己持有的 lease；
- 保留未核实回执和审计字段，禁止重发；
- 直接由 Codex 做本地整理和修复。

## 发送和执行门槛

- 用户显式要求评审/继续时自动按当前流程授权，不提前逐条问能不能发。
- 每条消息必须 `PrepareSend`；它只记录业务授权和待发送消息，默认不启动 deadline。
- Codex 平台真实确认通过后调用 `ConfirmBrowserSend`，此时才开始 `deadlineStartedAt` 和 30 秒发送时限。
- `ConfirmBrowserSend` 首次确认必须提交完整 URL、模型、推理、session、tab、runtime、lease 和 DOM 输入框证据。首次本地校验失败且没有浏览器动作时，修正参数后复用同一条用户确认和 fingerprint 重试脚本，不得再次索要确认。
- 填入前必须记录 `DomInputPresence=present` 和 `DomInputEnabled=enabled`；提交时必须记录 `SubmissionMechanism=button|enter` 与 `SubmissionStatus=succeeded`；提交后必须记录 `DomMessagePresence=present`，且 `openTabs`/`tabs.list` 至少一个来源为 `confirmed`、不能出现 `wrong-session`。
- 空输入时发送按钮可以是 disabled；Enter 路径只要求输入框存在且启用。button 路径必须证明填入消息后 `DomSendControl=enabled`。
- `sendOwnerTaskId` 必须始终等于当前 Task。新 Task `Claim` 时，把旧发送的完整确认、deadline、回执、重试和阶段时间放入 `previousSendAudit`，并按布尔、数字、数组的真实类型复位当前发送状态。
- 平台拒绝时保留 `pendingReceipt`、冻结发送，不自动重发。
- `confirmed` 的安全降级条件是 DOM `present` 加至少一个标签来源 `confirmed`；另一个来源为 `empty`/`unknown` 时原样保留。`not-found` 必须是 DOM `absent` 加至少一个明确 `absent` 来源；`wrong-session` 必须是 DOM `absent` 加至少一个 `wrong-session` 来源；冲突或没有任何 confirmed 标签来源时冻结。
- 没有 confirmed 回执、session/tab/runtime/可用时的 marker 不一致时禁止写“已发送/已收到”。
- `unknown` 只能重新核验原 session/tab/可用时的 marker：DOM `present` 且至少一个标签来源 confirmed 时记录 `confirmed`；只有 DOM `absent` 且有明确负证据才可 `ResolvePendingSend -ReceiptStatus not-found`；`empty`/`unknown` 不等于 `absent`，仍无法判断就冻结。
- `PrepareSend` 计算稳定 SHA-256 `SendIdempotencyKey`；重试沿用同一 key，只生成新的 `sendAttemptId`。该 key 只防本地误重发，不代表服务端 exactly-once。
- 输入框定位或发送控件第一次失败时，不得让用户手动粘贴；先重新读取 DOM 和消息落点。只有 DOM 明确确认目标消息不存在、首轮发送已超过 `sendDeadlineAt` 时，才能调用 `RetrySendAfterTimeout`，最多重试 2 次。页面显示消息存在或无法确认时冻结，不把发送责任转给用户。
- `MarkLost` 只有在 `LossEvidence=confirmed-absent`、至少一次观测、并同时有 `LossEvidenceSources=openTabs,tabs.list` 双来源空结果时才允许；浏览器工具失败必须走 `FailBrowserWorkflow`，不能误标丢失。
- 旧 `confirmed` 但缺 DOM/openTabs/tabs.list 的历史任务，普通状态更新不能强行改写；只能明确调用 `update_review_status.ps1 -FinalizeLegacyAudit` 转成只读历史终态。迁移必须保留 `legacy*` 证据缺口、`auditRisk=true`，撤销发送授权，禁止重发。

### 核实后立即发送

- 先把本地事实和完整评审消息准备好，再核实页面，避免占住页面后继续分析。
- session、可用时的 marker、tab、当前网页模型、深度思考和智能搜索核验通过后，在同一连续操作里完成 `Acquire → DOM → Verify → PrepareSend → 平台确认 → ConfirmBrowserSend → 真实发送`。
- `ConfirmBrowserSend` 返回 `sendNow=true` 后不得插入新分析、长篇汇报或人为等待；正常目标是在平台确认通过后的 30 秒内发出。
- 超过 30 秒仍未发送时，立即重读一次 DOM 和输入框；确认未落点后进入有限重试，每次重试都重新取得平台确认，不能空等十几分钟。
- 每次重试都必须保留原消息 fingerprint，生成新的 `sendAttemptId` 并写入 `retryHistory`；达到上限、出现 `present/unknown` DOM 证据或收到 `confirmed` 回执后，禁止继续重发。
- 等待完整回复只能发生在消息真实发送以后。
- 绑定脚本必须同步当前 Task 状态，页面切到官网后不能继续显示旧本机入口、旧模型或旧 tab 标题。
- 评审、修改、验证、打包和发布全部正常完成后，使用 `CompleteTask` 写入正常终态并释放当前 Task；`ForceTerminateTask` 只用于异常恢复，不能代替正常完成。

## 本地诊断和状态清理

不调用 DeepSeek 页面也可以执行这两个本地运维命令：

```powershell
$skillRoot = Join-Path $HOME '.codex\skills'

# 一键生成 JSON + Markdown 诊断报告，默认写入状态目录 diagnostics
& "$skillRoot\deepseek-independent-review\scripts\export_diagnostic_report.ps1" `
  -CodexThreadId $env:CODEX_THREAD_ID

# 默认只预览，保留最近7天；确认后再加 -Delete
& "$skillRoot\deepseek-independent-review\scripts\cleanup-completed-tasks.ps1" `
  -RetentionDays 7
```

诊断报告只输出绑定、发送、激活耗时、回执、lease 摘要和最近错误，不输出评审消息正文、消息指纹、授权内容、lease Token、密码、Token 或密钥。清理命令只处理 `taskTerminalStatus=completed` 且超过7天的任务 JSON，活跃绑定、pendingReceipt、auditRisk、失败任务、备份和浏览器状态都会保留；两个清理进程同时运行时，后启动者直接停止。

## 旧 lost 会话、待回执和重复 tab

- 旧绑定进入 `lost` 后，先用 `session_binding.ps1 -Action InspectLostBinding` 做只读核验。它只比较历史 `previousDeepSeekSessionId`/`previousConversationUrl`、可用的历史 marker、历史专用 tab、当前 DOM、当前网页模型、深度思考和智能搜索；任一不一致就返回不可恢复，不清理状态、不重发消息、不新建窗口。
- 如果右侧栏已经存在可证明属于当前 thread 的官方会话，优先调用 `BindExistingOfficialSession` 接回，不要因为旧绑定是 `lost` 就新建第二个窗口；该动作必须保留旧发送审计并输出真实绑定结果。
- 只有历史 session、marker、专用 tab、右侧栏来源、模式和回执全部一致，且没有 `pendingReceipt`/`auditRisk` 时，才允许 `-Action RecoverLostBinding`。找回动作只恢复原 session/tab，不会创建 replacement，也不会把待回执当成已处理。
- `show_pending_receipts.ps1` 提供当前 thread 的待回执管理面板；需要查看全部 thread 时显式加 `-AllThreads`。面板只输出 Task、thread、状态、回执、冻结原因和下一步，不输出正文、fingerprint、lease token 或凭据。
- `diagnose_duplicate_tabs.ps1` 接收 `user.openTabs()`/`tabs.list()` 的真实摘要做重复 tab 诊断。默认只提醒、拒绝重复接管，不自动关闭任何用户窗口，也不把当前聚焦 tab 当成身份。
- `invoke_browser_smoke_test.ps1` 只接受 Codex 右侧栏内置浏览器的真实 DOM/工具证据；来源、官网、当前网页模型、深度思考和智能搜索、session、tab、runtime 任一不对就 fail-closed，禁止回退到 Chrome、Edge、外部浏览器或手工发送。

只有下面条件同时满足才允许修改：

```text
当前批次：1/1
当前发送状态：已收到完整回复
Codex总结状态：已完成
检查结果：无问题
方案状态：已敲定
执行状态：允许开始执行
```

## 调用

```text
$deepseek-independent-review

请对当前问题做一次独立技术评审。
只在 Codex 右侧栏打开 https://chat.deepseek.com/，固定使用保持深度思考和智能搜索开启。
不要直接接受 Codex 的初步判断。
同一 Codex thread 复用唯一的官网会话，不同 thread 严格隔离。

我的问题：
【在这里写问题】
```

详细规则见：

- [references/usage.md](references/usage.md)
- [references/call-shortcuts.md](references/call-shortcuts.md)
- [references/status-template.md](references/status-template.md)
- [references/general-collaboration.md](references/general-collaboration.md)
