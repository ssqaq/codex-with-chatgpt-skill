---
name: deepseek-consensus-review
description: "通过 DeepSeek 官网与 Codex 做多轮独立共识评审。用户显式点名本 Skill，或明确要求实际调用 DeepSeek 反驳/复核 Codex、比较根因与方案、核对风险/回滚/验证顺序，并要求双方消除实质分歧后再修改时使用；普通提及 DeepSeek 不触发。固定在 Codex 右侧栏内置浏览器打开 https://chat.deepseek.com/，目标为保持深度思考和智能搜索开启；一个 Codex thread 只绑定一个专用官网会话和 tab。"
---

## 配套更新 1.19.0

- 第 1 轮发送完整短摘要；第 2 轮起只发送 `ROUND_DELTA`，包含新增事实、修改点和当前分歧，不重复上一轮全文。
- 等待网页和 Codex 执行分别计时；连续 10 分钟没有新回复才暂停。
- 429 和 503 按服务给出的时间或递增退避恢复，不重复发送、不重复建会话。
- 达成共识后立即发起普通执行任务接力，不等待用户再次发送“继续”。

## 配套更新 1.18.1

通过 codex-with-chatgpt 进入评审时，发送、等待与恢复遵循 [references/reliability.md](references/reliability.md)。发送前使用新鲜浏览器证据；正常回复等待不受两次无变化规则影响；恢复必须重新核对原页面，不直接恢复权限。

共识和执行门槛全部通过后必须立即回到 Codex 执行。当前任务若被锁在“只做计划方案”，不要等待用户再发“继续”：调用 `c2c review execute --plan-mode-detected --json` 记录转交要求，在同一工作区建立普通执行任务，随后用 `--execution-thread <新任务号>` 记录接手任务。新任务直接修改、测试和复核，不重新发起评审。


# DeepSeek多轮共识评审

## 激活

用户显式点名 `$deepseek-consensus-review` 时：

1. 读取本文件和 [references/browser-protocol.md](references/browser-protocol.md)；
2. 创建或恢复当前 `TaskId`；
3. 优先调用 `scripts/activate_review.ps1 -SkillName deepseek-consensus-review` 幂等激活。它必须返回 `new`、`resume` 或 `conflict`、真实耗时和慢路径原因；正常 `new/resume` 目标小于 2 秒。不要先扫描项目、日志或全部浏览器标签。

Skill chip 不是执行证据。没有真实激活状态、绑定、页面和回执时，不得声称已调用、已发送或已收到。

激活性能记录：

- 默认阈值是 2000ms；
- `activationElapsedMs` 超过阈值时，结果返回 `activationSlowPathAlert=true`；
- 慢路径耗时、阈值和原因会自动写回当前 Task 状态；
- 状态二次写入失败时，只追加 `activation-slow-path.log`，不记录消息正文、指纹、密码、Token 或密钥；
- 正常激活不先扫描整个项目、日志或全部浏览器标签。

## 固定环境

```text
页面：https://chat.deepseek.com/
目标：网页当前模型（官网已合并快速、专家、识图入口）
推理：深度思考 + 智能搜索
浏览器：Codex 右侧栏内置浏览器（iab）
```

- 只允许 `iab`。禁止 Chrome 集成、Chrome、Edge、扩展浏览器和外部桌面浏览器。
- `iab` 不可用时 fail-closed：报告失败，不得回退到其他浏览器。
- 页面必须真实显示当前网页模型，并确认“深度思考”和“智能搜索”已开启；不能只靠提示词猜测。

## 浏览器工具硬闸门（防止五分钟不发送）

- 页面操作只能使用 Codex 右侧栏内置浏览器的 `mcp__node_repl.js`；PowerShell、普通命令、`read_mcp_resource`、文字“继续/下一步”和命令输出都不算浏览器证据，也不能代替点击或发送。
- 先加载并复用同一个 `iab` 浏览器绑定，再调用一次 `user.openTabs()` 和一次 `tabs.list()` 读取真实标签。只有确认当前 thread 的原 tab 确实不存在，并且已经 `MarkLost` 后，才允许调用一次 `tabs.new()` 建立 replacement tab；禁止在未检查现有 tab 前直接新建。
- 每次浏览器动作后，下一步必须仍是浏览器工具读取 DOM/截图并核对结果；不得在页面核实到发送之间插入无关扫描、长篇汇报或空转命令。
- `PrepareSend` 默认只进入 `browserConfirmationStatus=awaiting`，此时不能发送也不启动 deadline。宿主平台真实确认后调用 `ConfirmBrowserSend`；只有它返回 `sendNow=true` 后，下一步才能填入并通过 button 或 Enter 提交，然后回读 DOM。平台确认通过后超过 30 秒仍没有真实发送或回执，立即调用 `FailBrowserWorkflow` 记录失败并停止本轮。
- `ConfirmationSource` 只接受 `action-time-user-response` 或浏览器工具真实返回的 `browser-tool-token`；禁止用业务提前授权、Skill chip、文字“继续”或自造 token 冒充宿主平台确认。
- 平台确认按 `TaskId + fingerprint + session/tab/runtime/lease` 绑定。同一消息确认后，只要尚未执行 fill/click/press、没有提交动作和 DOM 落点，本地参数校验、命令拼接或 DOM 重读失败都必须复用原确认，禁止再次提示“确认发送 Cn”。重新调用 `ConfirmBrowserSend` 可省略确认来源参数；返回 `platform-already-confirmed`、`verified-confirmed-send` 或 `send-confirmed-ready` 时，下一步直接发送。若确认已过 30 秒但仍无浏览器动作，调用 `FailBrowserWorkflow`，也不得靠再次询问刷新确认。
- 本地激活和已有绑定的 `Claim` 只做必要状态读写，不先扫描项目、日志或全部 tab；目标是各自在 2 秒内完成。完整评审消息必须先准备好，再进入页面核实和发送链。
- 激活或用户说“继续”后，不能只调用状态面板再重复汇报。必须读取 `nextAction` 并执行对应动作；如果没有 bound 会话，下一步必须是 `prepare-browser-binding`，不能是 `record-next-round`。连续两次汇报没有浏览器动作、状态变化或明确失败记录，视为流程 Bug，立即停止重复汇报并按 `FailBrowserWorkflow` 或恢复/绑定流程收口。
- “继续”必须先调用 `scripts/advance_review_workflow.ps1 -Action Advance`，由脚本按当前 `CodexThreadId + TaskId` 确定下一步；不能只调用 `show_review_dashboard.ps1`。进度汇报前调用 `-Action RecordReport`，如果 `noOpReportCount>=2`，必须停止重复汇报，改做推进、恢复或明确失败收口。
- 浏览器工具不可用、调用失败或连续一次无法取得真实页面时，立即调用：

  ```powershell
  & $sessionBinding -Action FailBrowserWorkflow `
      -TaskId $TaskId -CodexThreadId $CodexThreadId `
      -BrowserTool 'mcp__node_repl.js' `
      -BrowserToolStatus 'unavailable' `
      -Reason 'Codex 右侧栏浏览器工具不可用，未完成真实发送。'
  ```

  该动作会释放当前 thread 自己的 lease、冻结发送授权并保留审计；浏览器故障必须先分类，不能把临时断线直接标记成会话丢失。

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
- 执行端随后必须在 Codex 右侧栏用 `mcp__node_repl.js` 核验当前官方 DeepSeek 会话的真实 URL、标题、当前网页模型、深度思考和智能搜索、DOM marker、tab 和 runtime，再调用 `session_binding.ps1 -Action BindExistingOfficialSession`。这个动作不是“接管当前活动 tab”，而是把已核验的官方 session/tab/runtime 绑定回当前 thread。
- `BindExistingOfficialSession` 只允许当前 thread 的 `lost/cancelled/terminated` 绑定，或已经终态的旧 Task；如果旧 Task 仍在运行、session/tab/runtime 与当前 bound 绑定不一致、页面不是官网或模式未开启，必须拒绝。
- 接管成功后必须把旧 Task 的 `pendingReceipt`、`auditRisk`、指纹、确认和重试记录留在 `previousSendAudit`，清空当前发送闸门并同步当前 Task；不能把旧回执当成新消息已发送，也不能自动重发。
- 只有真实 DOM 核验失败、当前官方 session 无法证明，或两个来源明确 `confirmed-absent` 后，才允许走 `MarkLost → tabs.new → BeginBootstrap -ReplaceLost`。`tabs.list()` 返回 `empty/unknown` 不能跳过绑定核验或直接新建窗口。

### 失败流程和崩溃恢复

- `FailBrowserWorkflow` 先写入 `workflow-transaction.<thread>.<task>.json`，再依次更新绑定、释放当前 thread/task 自己的 lease、冻结任务状态；不能只删 lease 或只写一半状态。
- 任意下一次绑定脚本调用都会先检查属于当前 `CodexThreadId + TaskId` 的未完成事务，并按阶段恢复；恢复后标记 `recoveredFromTransaction=true`，清理事务日志，禁止继续发送。
- 恢复只允许处理当前 thread/task 的事务。其他 thread 的事务不能被接管、覆盖或清理。
- 如果失败前已有 `pendingReceipt`，恢复后必须保留 `auditRisk=true` 和原消息审计信息；不能把浏览器工具失败当成“消息不存在”，不能直接重发。
- 原子替换 JSON 并不等于 DeepSeek 服务端 exactly-once；它只保证本地状态不会被半写覆盖，服务端是否落点仍必须靠 DOM 回读确认。

## 会话隔离

```text
一个 Codex thread = 一个官网 official-chat sessionId + 一个专用右侧栏 runtime tab
同一 thread 的新 TaskId、C2…Cn 和后续调用 = Claim 后复用
不同 Codex thread = 不同 sessionId + 不同 tab
```

- 两个 DeepSeek Skill 共用 `thread-bindings.json`。
- 优先保存官网真实会话为 `official-chat:<id>`；没有稳定 ID 时使用包含当前 thread 的 `official-marker:CODEX-BINDING-<thread>`。
- 禁止用活动 tab、数字序号、相同标题或仅相同 URL 猜会话。
- session/tab/runtime 属于另一个 thread 时立即停止。
- 所有发送临界区必须持有同一 `LeaseToken + LeaseEpoch + BrowserRuntimeId + RuntimeEpoch`。

## 首次绑定

```text
在 Codex 右侧栏打开 DeepSeek 官网
→ 确认当前网页模型
→ 开启深度思考
→ 开启智能搜索
→ BeginBootstrap 预占唯一 tab；没有稳定官网 sessionId 时同时准备当前 thread marker
→ AcquireBrowserLease
→ 重新读 DOM 并 VerifyBootstrap
→ PrepareSend（记录业务授权；平台确认未通过时只进入 awaiting）
→ Codex 平台真实确认后调用 ConfirmBrowserSend
→ 发送一条完整 C1 基线消息
→ 回读消息落点、官网 sessionId、可用时的 marker、openTabs、tabs.list 和当前 tab
→ CompleteBootstrap
→ RecordSendOutcome -ReceiptStatus confirmed，并提交 DOM/openTabs/tabs.list 三来源证据
→ ReleaseBrowserLease
```

`bootstrap-pending` 重入保留指纹和待回执状态。没有真实 `official-chat` sessionId 且 marker 也没有回显时不能完成绑定；稳定 `official-chat` sessionId 存在时 marker 可以为空。

业务授权和平台动作确认分开：用户点名 Skill 或明确要求评审时，自动记录
`workflow-authorized`，不重复询问业务授权；`PrepareSend` 默认返回
`browserConfirmationStatus=awaiting`，不启动 `sendDeadlineAt`。只有 Codex 平台真实确认对外发送后，
调用 `ConfirmBrowserSend -PlatformConfirmationStatus confirmed`，才写入
`deadlineStartedAt` 并开始 30 秒发送时限。平台拒绝时 fail-closed，保留待回执和审计，不自动重发。

## 老任务、旧绑定和取消

- 同一 thread 的新目标：新建 TaskId，旧 TaskId 终态后 `Claim`，复用原官网会话。
- 新 Task `Claim` 前会把旧 Task 的 `pendingReceipt`、`auditRisk`、fingerprint、回执和重试记录移入 `previousSendAudit`，清空当前发送闸门；旧审计保留，但不阻塞新 Task 的新 fingerprint。
- 用户说“继续、补充、再评审”：沿用当前 TaskId 和会话，不新建。
- 用户说“继续”不等于任务完成，也不能把 heartbeat 暂停当成完成；应恢复当前 Task/同一会话，除非是真实失败、用户取消或决策僵局。
- 如果旧绑定只是被过期 lease 清理误标为 `lost`，先在当前右侧栏核验原 sessionId、可用时的 marker、当前网页模型、深度思考和智能搜索，再调用 `RecoverExpiredLeaseBinding` 复用原会话；禁止直接新建第二个 DeepSeek 会话。
- 如果在 Codex 右侧栏找不到当前 thread 原来绑定的 session、可用时的 marker 或专用 tab，先确认不是另一个 thread 的窗口；确认原窗口确实不存在后，必须先 `MarkLost` 保留旧绑定审计，再在 Codex 右侧栏新建一个 DeepSeek 官网窗口，使用新 tab/runtime 执行 `BeginBootstrap -ReplaceLost`，重新绑定当前 thread。新窗口必须重新确认当前网页模型、深度思考和智能搜索和正式会话身份；没有稳定 sessionId 时还要核对当前 thread marker，不能接管其他 thread 的会话。
- “找不到原窗口”与“原窗口只是暂时未读到”要分开处理：能通过真实 DOM 核验原 session 和可用时的 marker 就复用；无法核验且页面确实没有原窗口才新建。不得因为当前聚焦到了别的 tab 就直接新建。
- 旧本机 Harness、旧规则或损坏绑定：保留审计，先 `MarkLost`，再在官网右侧栏 `BeginBootstrap -ReplaceLost`；不能把旧 session 静默改名。
- 旧 `confirmed` 但缺少 DOM/openTabs/tabs.list 的历史任务，普通状态更新不能强行改写；只能明确调用 `update_review_status.ps1 -FinalizeLegacyAudit` 转成只读历史终态。迁移必须保留 `legacy*` 证据缺口、`auditRisk=true`，撤销发送授权，禁止重发。
- 已是官网会话但浏览器来源不是右侧栏：`MigrateToInAppSidebar`，验证同一 sessionId 和可用时的 marker，`RuntimeEpoch` 递增。
- 浏览器 runtime 重建：`RecoverRuntimeTab`，同样验证 sessionId 和可用时的 marker，`RuntimeEpoch` 递增。
- 单纯过期的浏览器 lease，如果没有 `pendingReceipt` 或其他未确认发送风险，按 `expired-lease-safe-release` 自动清理并恢复；只有存在待回执、unknown/wrong-session/not-found 等风险时才标记审计风险并冻结。
- 用户说“不要 DeepSeek”“本次不评审”“只整理不发送”：不得打开或操作页面；调用 `CancelBootstrap` 或 `update_review_status.ps1 -CancelReview`，撤销发送授权、释放当前 thread 的 lease、保留审计字段。

## 多轮独立共识流程

```text
Codex检查本地事实、日志、配置、复现和缺失证据
→ 写清事实、推断、缺失证据和 Codex初步判断
→ 在当前 thread 的唯一官网会话发送一条完整 C1
→ DeepSeek独立重建问题，明确支持、部分支持、反驳或无法确认
→ Codex逐项核对
→ 有实质分歧时在同一会话按 C2、C3…Cn 继续
→ 双方没有实质分歧后，Codex完成最终总结
→ 满足执行门槛后才修改
```

DeepSeek不得完全听 Codex，也不得为了反对而机械唱反调。每轮必须给出：自己的问题理解、事实/推断/缺失证据、对 Codex 的结论、明确反驳或补充、独立根因、推荐方案、备选方案、风险、回滚、验证顺序、未解决分歧和置信度。

### 轮次与停止条件

- `C1` 是第一轮，`C2` 是第二轮，`C3` 只是第三轮，不是“最终仲裁”或硬上限。
- 第三轮后仍有实质分歧时，继续使用同一 TaskId、同一官网会话和同一专用 tab，轮次依次记为 `C4`、`C5`……`Cn`。
- 不预设固定数字上限；只要双方仍能根据新证据、反驳或修正继续收敛，就继续下一轮。
- 只有双方消除实质分歧、用户明确取消、页面/回执失败，或分歧已成为必须由用户选择且无法凭现有证据解决的决策僵局时才停止。
- 决策僵局不等同于达成共识：必须列出各方方案、证据和影响，保持“禁止修改”，等待用户裁决。

### 轮次记录、僵局识别和状态面板

- Codex 每次核对完 DeepSeek 回复后，必须调用 `scripts/review_round.ps1 -Action RecordRound`，真实记录当前 `C1…Cn`、双方立场、未解决分歧和是否出现新证据。
- 连续两轮出现相同实质分歧且没有新证据时，脚本自动写入 `decisionDeadlock=true`、`共识状态=决策僵局`、`执行状态=禁止修改` 和 `nextAction=await-user-decision`。
- 僵局时不能继续发送下一轮绕过用户裁决。用户选择方案或补充新证据后，先调用 `ResolveDeadlock`，再进入下一轮核对；解除僵局不等于达成共识。
- 每次汇报进度前调用 `scripts/show_review_dashboard.ps1`，使用固定六列展示当前轮次、分歧、重复次数、绑定/回执、执行门槛和下一步。
- `review_round.ps1` 和状态面板只处理本地状态，不访问或操作 DeepSeek 页面。

## 发送闸门

唯一受支持顺序：

```text
AcquireBrowserLease → DOM → Verify/VerifyBootstrap → PrepareSend
→ ConfirmBrowserSend（平台确认通过）→ 真实发送 → 回读 → CompleteBootstrap（仅首次）
→ RecordSendOutcome → ReleaseBrowserLease
```

- `PrepareSend` 用 fingerprint 防重复，不是要求用户每轮重新确认。
- `ConfirmBrowserSend` 首次确认必须提交完整 URL、模型、推理、session、tab、runtime、lease 和 DOM 输入框证据。首次本地校验失败且没有浏览器动作时，修正参数后复用同一条用户确认和 fingerprint 重试脚本，不得再向用户索要确认。
- 用户明确要求评审/继续后，当前流程自动授权，不提前重复问“能不能发”。
- 填入前必须记录 `DomInputPresence=present` 和 `DomInputEnabled=enabled`；提交时必须记录 `SubmissionMechanism=button|enter` 与 `SubmissionStatus=succeeded`；提交后必须记录 `DomMessagePresence=present`，并让 `openTabs`/`tabs.list` 至少一个来源为 `confirmed` 且不能出现 `wrong-session`。
- 空输入时发送按钮可能是 disabled，这不阻止 Enter 路径。只有选择 `SubmissionMechanism=button` 时，才要求填入消息后 `DomSendControl=enabled`。
- `PrepareSend` 必须把当前 Task 写入 `sendOwnerTaskId`；确认、重试和回执必须保持同一 Task。新 Task `Claim` 时，旧发送的完整确认、deadline、回执、重试和阶段时间进入 `previousSendAudit`，当前布尔值、数字和数组按真实类型复位。
- 没有对应 `PrepareSend` 的回执会标记 `audit-risk` 并冻结。
- `unknown`、`wrong-session`、`not-found` 都禁止原样重发，先查清落点。
- `confirmed` 的安全降级条件是 DOM `present` 加至少一个标签来源 `confirmed`；另一个来源为 `empty`/`unknown` 时原样保留，不能当成 `absent`。`not-found` 必须是 DOM `absent` 加至少一个明确 `absent` 来源；`wrong-session` 必须是 DOM `absent` 加至少一个 `wrong-session` 来源；冲突来源拒绝并冻结。
- `unknown` 只能沿着“重新核验原 session/tab/可用时的 marker → DOM 明确 `present` 且至少一个标签来源 confirmed 则 `RecordSendOutcome confirmed`；DOM 明确 `absent` 且有明确负证据才可 `ResolvePendingSend -ReceiptStatus not-found` → 到 `sendDeadlineAt` 后按同一幂等键 `RetrySendAfterTimeout`”处理；页面仍 `unknown` 时冻结。
- `PrepareSend` 生成稳定的 SHA-256 `SendIdempotencyKey`（输入为当前 thread、TaskId 和消息 fingerprint）。重试必须沿用同一 key，只更换 `sendAttemptId`；key 只防本地误重发，不能宣称服务端 exactly-once。
- 输入框定位或发送控件第一次失败时，不得让用户手动粘贴；先重新读取 DOM 和消息落点。只有 DOM 明确确认目标消息不存在、首轮发送已超过 `sendDeadlineAt` 时，才能调用 `RetrySendAfterTimeout`，最多重试 2 次。页面显示消息存在或无法确认时冻结，不把发送责任转给用户。
- `MarkLost` 不是浏览器工具失败的替代品。只有同时记录 `LossEvidence=confirmed-absent`、至少一次观测，以及 `LossEvidenceSources=openTabs,tabs.list` 的双来源空结果，才能把绑定标为 `lost` 并允许 replacement bootstrap。
- `openTabs`/`tabs.list` 返回 `empty` 或 `unknown` 不等于明确 `absent`，不能单独触发 `MarkLost` 或 replacement。

### 核实后立即发送

- 本地事实和完整评审消息准备好后，再开始绑定/核实页面；不要先占住页面再继续分析十几分钟。
- 一旦当前 thread 的 session、可用时的 marker、tab、当前网页模型、深度思考和智能搜索核验通过，必须在同一连续操作里完成 `Acquire → DOM → Verify → PrepareSend → 平台确认 → ConfirmBrowserSend → 真实发送`。
- `ConfirmBrowserSend` 返回 `sendNow=true` 时，下一步只能是立即发送；禁止插入新的方案分析、长篇进度汇报、无关文件扫描或人为等待。
- 正常目标是在平台确认通过后的 30 秒内完成真实发送。超过 30 秒仍未发送时，视为发送流程异常：立即重读一次 DOM 和输入框；确认未落点后进入有限重试，且每次重试都重新取得平台确认，不能继续空等十几分钟。
- 每次重试都必须保留原消息 fingerprint，生成新的 `sendAttemptId` 并写入 `retryHistory`；达到上限、出现 `present/unknown` DOM 证据或收到 `confirmed` 回执后，禁止继续重发。
- 等待 DeepSeek 生成回复发生在发送之后；不能把“等待回复”误写成“还没发送”。
- `thread-bindings.json` 和当前 Task 状态必须由绑定脚本同步更新，禁止页面已切到官网但任务状态仍显示旧本机入口、旧模型或旧 tab 标题。
- 评审、修改、验证、打包和发布全部正常完成后，使用 `CompleteTask` 写入正常终态并释放当前 Task；`ForceTerminateTask` 只用于异常恢复，不能代替正常完成。

## 本地诊断和状态清理

不调用 DeepSeek 页面也可以执行这两个本地运维命令：

```powershell
$skillRoot = Join-Path $HOME '.codex\skills'

# 一键生成 JSON + Markdown 诊断报告，默认写入状态目录 diagnostics
& "$skillRoot\deepseek-consensus-review\scripts\export_diagnostic_report.ps1" `
  -CodexThreadId $env:CODEX_THREAD_ID

# 默认只预览，保留最近7天；确认后再加 -Delete
& "$skillRoot\deepseek-consensus-review\scripts\cleanup-completed-tasks.ps1" `
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

## 执行门槛

只有以下条件全部满足才允许修改：

```text
共识状态：已达成
Codex总结状态：已完成
检查结果：无问题
方案状态：已敲定
执行状态：允许开始执行
```

## 调用

```text
$deepseek-consensus-review

请对当前问题进行多轮独立共识评审。
只在 Codex 右侧栏打开 https://chat.deepseek.com/，固定使用保持深度思考和智能搜索开启。
DeepSeek必须独立分析并明确反驳或支持 Codex，但不能机械唱反调。
同一 Codex thread 复用一个官网会话，不同 thread 严格隔离。
双方没有消除实质分歧前不要修改。

我的问题：
【在这里写问题】
```

新老任务、状态字段和调用捷径见：

- [references/usage.md](references/usage.md)
- [references/call-shortcuts.md](references/call-shortcuts.md)
- [references/status-template.md](references/status-template.md)
- [references/general-collaboration.md](references/general-collaboration.md)
