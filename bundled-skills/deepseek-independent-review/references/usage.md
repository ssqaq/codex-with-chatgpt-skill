# DeepSeek 评审 Skill 使用说明

## 两个 Skill

- `$deepseek-consensus-review`：多轮独立评审，直到 Codex 和 DeepSeek 消除实质分歧再修改。
- `$deepseek-independent-review`：当前批次只做一次独立评审，Codex收到后自己判断。

统一环境：Codex 右侧栏内置浏览器、`https://chat.deepseek.com/`、专家模式、深度思考。

## 最简调用

```text
$deepseek-consensus-review
请对当前问题进行多轮独立共识评审。DeepSeek不要完全听 Codex，要有自己的判断，双方没有实质分歧前不要修改。
我的问题：
...
```

```text
$deepseek-independent-review
请对当前问题做一次独立技术评审，不要直接接受 Codex 初步判断。
我的问题：
...
```

## 新任务

同一个 Codex thread 里的新目标：

```text
请调用 $deepseek-consensus-review，继续当前 thread 的新任务。
创建新 TaskId，但 Claim 并复用原 DeepSeek 官网会话和 Codex 右侧栏 tab，不要新建第二个会话。
我的问题：
...
```

新的 Codex thread：

```text
请调用 $deepseek-consensus-review。
这是新的 Codex thread，请在 Codex 右侧栏 DeepSeek 官网建立唯一的新 official-chat sessionId 和专用 tab，不得复用其他 thread。
我的问题：
...
```

## 老任务继续

```text
请调用 $deepseek-consensus-review，继续当前老任务。
沿用原 TaskId 和当前 CodexThreadId，读取上一轮分歧；有分歧就进入 C2、C3……Cn，同一官网会话复用，不要新建。C3 只是第三轮，不是最终仲裁或轮次上限。用户说“继续”不能被当成完成，必须恢复当前 Task/heartbeat。

如果状态显示 `lost`，但原因只是旧版过期 lease 清理，且上条消息 `confirmed`、没有 `pendingReceipt`，先核验原 sessionId 和可用时的 marker，再调用 `RecoverExpiredLeaseBinding`，不要直接 bootstrap 新会话。
补充证据：
...
```

独立评审后续批次同理：沿用当前 thread 的官网会话，出现新证据进入 R2、R3……Rn。

## 轮次记录与状态面板

每次 Codex 核对完回复后记录本轮：

```powershell
$skillRoot = Join-Path $HOME '.codex\skills'
& "$skillRoot\deepseek-consensus-review\scripts\review_round.ps1" `
  -Action RecordRound `
  -TaskId T-YYYYMMDD-HHMMSS-01 `
  -CodexThreadId $env:CODEX_THREAD_ID `
  -ReviewBatch C2 `
  -UnresolvedIssues '仍未解决的实质分歧' `
  -CodexPosition 'Codex 当前判断' `
  -DeepSeekPosition 'DeepSeek 当前判断'
```

连续两轮相同分歧且没有新证据会自动进入决策僵局。用户裁决或补充新证据后：

```powershell
& "$skillRoot\deepseek-consensus-review\scripts\review_round.ps1" `
  -Action ResolveDeadlock `
  -TaskId T-YYYYMMDD-HHMMSS-01 `
  -CodexThreadId $env:CODEX_THREAD_ID `
  -UserDecision '用户选择的方案'
```

查看固定六列状态面板：

```powershell
& "$skillRoot\deepseek-consensus-review\scripts\show_review_dashboard.ps1" `
  -TaskId T-YYYYMMDD-HHMMSS-01 `
  -CodexThreadId $env:CODEX_THREAD_ID
```

## 激活慢路径、诊断和状态清理

Skill 激活默认以 2 秒为正常目标。超过 2000ms 时，`activate_review.ps1` 会返回 `activationSlowPathAlert=true`，并把耗时、阈值和原因写回当前任务状态；状态写入失败时只追加不含敏感内容的 `activation-slow-path.log`。

一键生成诊断报告：

```powershell
$skillRoot = Join-Path $HOME '.codex\skills'
& "$skillRoot\deepseek-consensus-review\scripts\export_diagnostic_report.ps1" `
  -CodexThreadId $env:CODEX_THREAD_ID
```

默认会在 `<用户目录>/.codex/deepseek-review-state/diagnostics/` 生成当前任务的 `.json` 和 `.md` 报告。报告只包含白名单状态字段，不包含消息正文、指纹、授权内容、lease Token、密码、Token 或密钥。

清理已完成任务：

```powershell
& "$skillRoot\deepseek-consensus-review\scripts\cleanup-completed-tasks.ps1" `
  -RetentionDays 7

# 确认预览结果无误后才真正删除
& "$skillRoot\deepseek-consensus-review\scripts\cleanup-completed-tasks.ps1" `
  -RetentionDays 7 -Delete
```

清理默认只预览，保留最近 7 天；只删除 `taskTerminalStatus=completed` 且超过7天的任务 JSON。活跃绑定、当前 lease、`pendingReceipt`、`auditRisk`、失败任务、备份和浏览器状态不会删除。两个清理进程同时运行时，后启动者会直接失败，避免互相删状态。

## 会话规则

```text
同一 Codex thread：一个 DeepSeek 官网会话 + 一个右侧栏 tab
不同 Codex thread：不同 sessionId + 不同 tab
浏览器重启：RecoverRuntimeTab，RuntimeEpoch 递增
旧本机 Harness/旧规则绑定：MarkLost 后官网 BeginBootstrap
```

每次真实发送必须有 `PrepareSend`、宿主平台真实确认、`ConfirmBrowserSend` 和页面回读；`confirmed` 允许 DOM `present` 加至少一个标签来源 `confirmed`，另一个来源为 `empty`/`unknown` 时原样保留；没有任何 confirmed 标签来源不能写“已发送/已收到”。

找到并核实原会话后要连续执行到平台确认：完整消息应在核实页面前准备好；`PrepareSend` 默认进入 awaiting 且不启动 deadline。`ConfirmBrowserSend` 返回 `sendNow=true` 后不再插入分析或长篇进度汇报，正常目标是在平台确认后的 30 秒内发出。超过 30 秒就重读一次页面，只有 `DomMessagePresence=absent` 时调用 `RetrySendAfterTimeout`；重试后重新取得平台确认，最多2次。无法确认或页面已有消息时冻结。

## 失败恢复和 unknown 回执

- 浏览器工具失败必须调用 `FailBrowserWorkflow`。脚本会用 `workflow-transaction.<thread>.<task>.json` 记录阶段并释放当前 thread/task 自己的 lease；下一次调用只恢复当前 thread/task 的未完成事务，冻结任务，不能继续空转。
- `unknown` 不等于“没有发送”，`empty`/`unknown` 也不等于 `absent`。先核验原 session/tab/可用时的 marker：DOM `present` 加至少一个标签来源 `confirmed` 时记录 `confirmed`；DOM `absent` 加至少一个明确 `absent`/`wrong-session` 来源时才能收口；仍是 `unknown` 就冻结。
- `SendIdempotencyKey` 由当前 thread、TaskId 和消息 fingerprint 稳定计算；它只防本地误重发，不是 DeepSeek 服务端 exactly-once。重试沿用 key，只换 `sendAttemptId`。
- `MarkLost` 必须带 `confirmed-absent`、至少一次观测和 `openTabs,tabs.list` 双来源空结果；浏览器工具失败不能用 `MarkLost` 代替。

页面和状态不一致时，绑定脚本会把旧本机入口、旧模型和旧会话移到审计字段，再把当前 Task 状态同步成官网、专家模式、深度思考和新的 tab/session；不再靠人工硬改 JSON。

同一 thread 的新 Task `Claim` 会把旧 Task 的 `pendingReceipt`、`auditRisk`、fingerprint、回执和重试记录移到 `previousSendAudit`，清空当前发送闸门，避免旧回执让新评审永久停住。旧 `confirmed` 但缺 DOM/openTabs/tabs.list 的状态，普通更新不能覆盖；明确使用 `update_review_status.ps1 -FinalizeLegacyAudit` 后才会转只读历史终态，保留 `legacy*` 缺口和 `auditRisk=true`，撤销发送授权。

## 只整理不发送

```text
请调用对应 DeepSeek Skill，但本次不要访问浏览器或发送消息。
只整理本地事实、Codex初步判断、已有分歧和一条可复制的评审消息。
```

## 状态查询

```powershell
$skillRoot = Join-Path $HOME '.codex\skills'
& "$skillRoot\deepseek-consensus-review\scripts\update_review_status.ps1" `
  -TaskId T-YYYYMMDD-HHMMSS-01 -Show

& "$skillRoot\deepseek-consensus-review\scripts\session_binding.ps1" `
  -Action Show -CodexThreadId $env:CODEX_THREAD_ID
```

## 旧 lost 会话和待回执排查

先只读检查旧 lost 绑定，不要直接新建窗口：

```powershell
& "$skillRoot\deepseek-independent-review\scripts\session_binding.ps1" `
  -Action InspectLostBinding `
  -TaskId T-YYYYMMDD-HHMMSS-01 `
  -CodexThreadId $env:CODEX_THREAD_ID `
  -BrowserSurface codex-in-app-sidebar `
  -BrowserTabId '<历史专用 tab>' `
  -BrowserRuntimeId '<当前 runtime>' `
  -RuntimeEpoch 1 `
  -TabMatchCount 1 `
  -EvidenceSource dom `
  -DomTargetUrl 'https://chat.deepseek.com/a/chat/s/<真实 session>' `
  -DomModel '专家模式' `
  -DomReasoning '深度思考' `
  -DomMessageMarker '<可用的历史 marker>' `
  -DeepSeekSessionId 'official-chat:<真实 session>'
```

只有返回 `canRecover=true` 且没有 `pendingReceipt/auditRisk`，才可在同一组证据下调用 `RecoverLostBinding`。不一致时保持 `lost`，不清理、不重发、不新建。

查看当前 thread 的待回执：

```powershell
& "$skillRoot\deepseek-independent-review\scripts\show_pending_receipts.ps1" `
  -CodexThreadId $env:CODEX_THREAD_ID
```

全局查看时显式加 `-AllThreads`。面板不输出正文、fingerprint、lease token 或凭据。
