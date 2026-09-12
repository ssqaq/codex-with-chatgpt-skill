---
name: deepseek-consensus-review
description: "通过 DeepSeek 官网与 Codex 做多轮独立共识评审。用户显式点名本 Skill，或明确要求实际调用 DeepSeek 反驳/复核 Codex、比较根因与方案、核对风险/回滚/验证顺序，并要求双方消除实质分歧后再修改时使用；普通提及 DeepSeek 不触发。固定在 Codex 右侧栏内置浏览器打开 https://chat.deepseek.com/，目标为保持深度思考和智能搜索开启；一个 Codex thread 只绑定一个专用官网会话和 tab。"
---

## 配套更新 1.19.2：原对话恢复与任务计数

浏览器工具、恢复、轮次衔接和计时统一遵循 [references/browser-runtime.md](references/browser-runtime.md)。当前宿主优先使用 mcp__cua_repl；不得导入内部浏览器包或猜测旧接口。旧任务仍复用原官方对话；暂时冻结按仅恢复流程处理。

恢复次数按当前 Task 计算，新 Task 不继承前任务的已用次数，同一 Task 重复 Claim 不清零。原标签关闭先重新打开原官方对话；用户已允许且原对话确实不存在时，按运行规则的真实丢失证据新建，携带已确认摘要。工具断开、登录失效、错误会话或未知发送不能当成原对话丢失。


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

## 浏览器操作、恢复和发送

按 [references/browser-runtime.md](references/browser-runtime.md) 完成公开工具初始化、原会话恢复、发送回执、完整回复校验和每轮计时。一次恢复最多 60 秒；不重复初始化、不导入内部模块。旧等待规则由此文件统一替代。

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
→ 回读消息落点、官网 sessionId、可用时的 marker、当前公开工具的标签清单和当前 tab
→ CompleteBootstrap
→ RecordSendOutcome -ReceiptStatus confirmed，提交 DOM 和真实标签清单；旧证据字段按运行规则映射，不存在的来源保留 unknown
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
- 原标签关闭时先确认没有重复标签，再重新打开保存的原对话地址。只有用户已允许、原对话确实不存在且没有未知发送时，才按运行规则执行 `MarkLost → BeginBootstrap -ReplaceLost`；新对话重新核对两个开关、正式身份和当前 thread，携带已确认摘要。
- 原标签不存在不等于原对话不存在。工具超时、页面加载中、登录失效或聚焦别的标签时，保留原记录并恢复，不能直接新建。
- 旧规则或损坏绑定保留审计，先核对原官方对话；没有明确丢失证据不执行 `MarkLost`，也不静默改名。
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
- `MarkLost` 按运行规则接受当前 `cua.getState,original-url` 的真实清单、原对话明确不存在及至少两次观察。旧双清单路径仅在宿主实际提供接口时可用；不能伪造旧来源或把工具失败当成丢失。
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

## 配套更新 1.19.3

按浏览器运行规则使用有界连续读取；先保存真实观察再分析，部分失败保留已有记录，错轮不计进展，不因页面完成提前取得执行共识。

同一个 Task 可以多次恢复：新的故障或再次关闭的原标签按运行规则重新核对，旧回执、轮次和时间保留，不循环重发。
