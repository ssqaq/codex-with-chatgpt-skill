# DeepSeek 官网右侧栏浏览器绑定协议

## 固定环境

```text
入口：https://chat.deepseek.com/
目标：专家模式
推理：深度思考
浏览器：Codex 右侧栏内置浏览器（iab）
```

硬规则：只能在 Codex 右侧栏内置浏览器里打开和操作 DeepSeek 官网。禁止 Chrome 集成、Chrome、Edge、扩展浏览器和外部桌面浏览器；iab 不可用就停止并报告，不能回退。

页面必须真实显示专家模式和深度思考已开启。没有页面证据不能伪造模型或推理等级。

## 浏览器工具硬闸门

- 唯一页面工具是 Codex 右侧栏内置浏览器的 `mcp__node_repl.js`。PowerShell/普通命令/`read_mcp_resource`/文字进度消息不算页面证据，不能用来代替 DOM、填充或点击。
- 先复用同一个 `iab` 绑定，再各读取一次 `user.openTabs()` 与 `tabs.list()`。返回 `empty`/`unknown` 只表示该来源暂时不可判定，不等于“原 tab 确认不存在”；只有双来源都给出明确丢失证据并已 `MarkLost` 后，才允许一次 `tabs.new()` replacement。
- 页面动作后必须紧接着用浏览器工具回读 DOM 或截图。发送采用两阶段：`PrepareSend` 只登记消息并进入平台确认；平台确认通过后调用 `ConfirmBrowserSend`，它返回 `sendNow=true` 后下一步只能真实发送并回读回执，不能再做文件扫描或空转命令。
- `PrepareSend` 的 `browserConfirmationStatus=awaiting` 阶段不启动 30 秒 deadline。只有 `ConfirmBrowserSend -PlatformConfirmationStatus confirmed` 成功后才写入 `deadlineStartedAt` 和 `sendDeadlineAt`。
- 平台确认是消息级一次确认，绑定当前 `TaskId + fingerprint + session/tab/runtime/lease`。同一消息已确认、尚未发生 fill/click/press、提交动作或 DOM 落点时，本地参数校验、命令拼接或 DOM 重读失败后直接复用原确认，不得再次提示用户。`ConfirmBrowserSend` 重入返回 `platform-already-confirmed`，`Verify` 返回 `verified-confirmed-send`，`PrepareSend` 返回 `send-confirmed-ready`；这三种结果的下一步都是 `send-immediately-without-reconfirmation`。
- 首次 `ConfirmBrowserSend` 必须带齐 `DomTargetUrl`、`DomModel`、`DomReasoning`、session/marker、tab、runtime、lease、`DomInputPresence` 和 `DomInputEnabled`。如果首次命令仅因这些本地参数缺失而失败，修正参数后沿用原 `action-time-user-response` 证据重试，不重新询问用户。已确认重入可以省略 `ConfirmationSource` 和 `PlatformConfirmationEvidence`，脚本会校验原上下文哈希且不会刷新 deadline。
- 已确认但 30 秒到期且仍没有浏览器动作时，返回 `fail-browser-workflow-without-reconfirmation`：失败收尾，不靠再次询问刷新确认。已经出现浏览器动作或提交状态时必须先核对原发送结果，禁止再次确认或原样重发。
- 平台确认拒绝时调用 `ConfirmBrowserSend -PlatformConfirmationStatus rejected`，保持 fail-closed 并核对页面；不能把业务提前授权伪装成平台确认，也不能绕过宿主平台的真实确认闸门。
- 平台确认通过后超过 30 秒仍未真实发送或取得回执，调用 `session_binding.ps1 -Action FailBrowserWorkflow`，冻结当前任务并停止，不得继续重试无效工具。该动作会释放当前 thread 的 lease、保留审计并禁止误发。

## 失败事务、unknown 回执和丢失证据

- `FailBrowserWorkflow` 通过 `workflow-transaction.<thread>.<task>.json` 记录阶段：`prepared → binding-updated → lease-released → task-updated`。下次绑定脚本调用只恢复当前 thread/task 的未完成事务，恢复后清理日志、冻结任务并标记 `recoveredFromTransaction=true`。
- 事务恢复只处理当前 `CodexThreadId + TaskId`，不能清理其他 thread 的事务。原子 JSON 替换只解决本地半写，不代表 DeepSeek 服务端 exactly-once。
- `unknown` 回执必须保留 `pendingReceipt` 和原 fingerprint/key，不能直接重发。重新核验原页面：DOM `present` 走 `RecordSendOutcome confirmed`；只有 DOM `absent` 且至少一个标签来源明确 `absent`/`wrong-session` 才能调用：

  ```powershell
  & $sessionBinding -Action ResolvePendingSend `
      -TaskId $TaskId -CodexThreadId $CodexThreadId `
      -MessageFingerprint $Fingerprint `
      -ReceiptStatus not-found `
      -DomMessagePresence absent `
      -SendIdempotencyKey $SendIdempotencyKey
  ```

  返回 `retryAllowedAfter` 后，只有达到 `sendDeadlineAt` 才能用同一 key 调 `RetrySendAfterTimeout`；DOM 仍为 `unknown` 时冻结。
- `SendIdempotencyKey` 是当前 thread、TaskId 和消息 fingerprint 的稳定 SHA-256，只防本地误重发；每次重试只换 `sendAttemptId`。
- `empty`/`unknown` 不能当作 `absent`。`MarkLost` 必须同时提交 `LossEvidence=confirmed-absent`、`LossObservationCount>=1` 和 `LossEvidenceSources=openTabs,tabs.list`，并且两次来源都必须是真实的明确丢失观测；工具失败走 `FailBrowserWorkflow`，不能走 `MarkLost`。
- `FailBrowserWorkflow` 的 `BrowserFailureClass` 默认是 `runtime-disconnected`：临时断线、工具失败或 unknown 只进入 `recovery-pending`，保留原 session/tab，最多允许一次 `RecoverRuntimeTab`；不能直接清空绑定或新建 replacement。只有 `MarkLost` 的双来源明确 absent/wrong-session 证据才能进入 `lost`。
- 自动恢复规则：`recovery-pending` 一旦重新取得 `iab`，当前执行端自动执行一次 `Claim → RecoverRuntimeTab → DOM/Verify`，不等待用户手动重开；双来源明确 absent/wrong-session 时自动执行 `MarkLost → tabs.new → BeginBootstrap -ReplaceLost`。每类最多一次，失败后冻结并写入 `nextAction`，不循环、不跨 thread 接管。
- 临时断线的状态文件可能暂时是 `frozen + auto-recover-runtime-tab`；这只允许当前 Task 做 `Claim/RecoverRuntimeTab` 的受限恢复，不允许发送或修改。恢复成功后才回到 `active/activated`，再重新核验页面。

## `lost` 绑定的已有官方会话接回

- `advance_review_workflow.ps1 -Action Advance` 对 `lost + replacementRequired` 返回 `bind-existing-official-session`，这是先核验并接回已有官方会话的动作合同，不是直接创建新 tab。
- 用 `mcp__node_repl.js` 核验当前右侧栏页面的真实官网 URL、官方 session 路由、标题、专家模式、深度思考、DOM marker、tab、runtime 后，调用：

  ```powershell
  & $sessionBinding -Action BindExistingOfficialSession `
      -TaskId $TaskId -CodexThreadId $CodexThreadId `
      -DeepSeekSessionId 'official-chat:<由当前官网 URL 证明的 id>' `
      -BrowserTabId $BrowserTabId -BrowserTabTitle $BrowserTabTitle `
      -BrowserRuntimeId $BrowserRuntimeId -RuntimeEpoch $RuntimeEpoch `
      -TabMatchCount 1 -BrowserSurface codex-in-app-sidebar `
      -EvidenceSource dom -DomTargetUrl $DomTargetUrl `
      -DomSessionTitle $DomSessionTitle -DomModel '专家模式' `
      -DomReasoning '深度思考' -DomMessageMarker $DomMessageMarker
  ```

- 该动作只允许当前 thread 的 `lost/cancelled/terminated` 绑定或已终态旧 Task，必须拒绝运行中的旧 Task、跨 thread session/tab/runtime、非官网页面和未开启的模式。
- 成功后旧发送风险必须进入 `previousSendAudit`，当前 `pendingReceipt/resendBlocked/auditRisk` 发送闸门按真实类型清空并同步当前 Task；不会把旧回执当作新消息，也不会自动重发。
- `user.openTabs()` 或 `tabs.list()` 的 `empty/unknown` 只能标记暂时不可判定，不能直接 `MarkLost`、不能直接新建 tab。只有两来源明确 `confirmed-absent` 后才走 replacement bootstrap。

## 会话隔离

```text
一个 Codex thread = 一个官网 official-chat sessionId + 一个 Codex 右侧栏专用 tab
同一 thread 的新 TaskId、C2…Cn、R2…Rn = Claim 后复用原 sessionId 和 tab
不同 Codex thread = 不同 sessionId、不同 tab，禁止复用
```

`thread-bindings.json` 由两个 Skill 共用。会话身份优先保存为 `official-chat:<id>`；稳定的官网 sessionId 本身就是正式绑定凭据，marker 可以为空。只有拿不到稳定 sessionId 时，才使用包含当前 thread 的 `official-marker:CODEX-BINDING-<thread>` 并持续核对 marker。不能用活动 tab、数字序号、标题、重复消息文本或“看起来一样的页面”猜身份。

所有发送临界区固定为：读取 DOM → Verify → PrepareSend → 宿主平台真实确认 → ConfirmBrowserSend → 真实发送 → 回读 DOM/openTabs/tabs.list → RecordSendOutcome。lease 不属于当前 thread/task 时直接停止。

核实页面前先准备好完整评审消息。session、可用时的 marker、tab、专家模式和深度思考一旦核验通过，必须在同一连续操作中执行到平台确认。`ConfirmBrowserSend` 返回 `sendNow=true` 后不得插入新分析、长篇汇报或人为等待。正常目标是在平台确认通过后的 30 秒内发出；超时就立即重读一次 DOM 和输入框，只有明确确认目标消息不存在时才能调用 `RetrySendAfterTimeout`。每次重试都重新经过平台确认，最多重试 2 次。

三段发送证据不能合并或补写：

1. 填入前：`DomInputPresence=present`、`DomInputEnabled=enabled`；
2. 提交时：`SubmissionMechanism=button|enter`、`SubmissionStatus=succeeded`。空输入时按钮 disabled 属于正常；button 路径必须在填入后证明 `DomSendControl=enabled`，Enter 路径不依赖按钮状态；
3. 提交后：`DomMessagePresence=present`，`openTabs`/`tabs.list` 至少一个来源为 `confirmed`，且任一来源都不能是 `wrong-session`。

`ConfirmationSource` 只允许 `action-time-user-response` 和浏览器工具真实返回的 `browser-tool-token`，禁止虚构 token。`PrepareSend` 写入当前 `sendOwnerTaskId`，后续确认、重试和回执必须保持相同 Task。激活与已有绑定 `Claim` 走本地快路径，目标各自小于 2 秒；不在激活后先做无关扫描。阶段时间必须保留到状态和 Dashboard，便于区分卡在消息准备、页面核实、平台确认、浏览器动作还是回执。

## 原窗口找不到时

1. 先在 Codex 右侧栏逐个核对当前 thread 的原 sessionId、可用时的 marker、tabId 和 runtimeId；不能只看当前聚焦的 tab。
2. 能核验原窗口：继续复用原会话，不新建。
3. 原窗口确实不存在：先 `MarkLost` 保留旧绑定和审计字段，再在 Codex 右侧栏新建一个 `https://chat.deepseek.com/` 窗口；用新 tab/runtime 执行 `BeginBootstrap -ReplaceLost`。
4. 新窗口必须重新确认专家模式、深度思考和正式会话身份；没有稳定 sessionId 时还要确认当前 thread marker。通过 `VerifyBootstrap`、真实发送和 confirmed 回执后才能写成 bound。
5. 新窗口不得占用另一个 Codex thread 的 tab/session；找不到原窗口不等于可以抢用当前活动窗口。

## 激活和授权

用户显式点名任一 DeepSeek Skill，就是硬触发：先读取对应 `SKILL.md`，创建或恢复当前 TaskId，再用 `update_review_status.ps1` 写入 `activationStatus=activated`、官网地址、专家模式、深度思考和 `sendAuthorization=workflow-authorized`。

用户已经说“评审、发送、继续”时，业务层视为提前授权，不要每轮再问用户“能不能发”。但业务授权不等于宿主平台的浏览器发送确认：每条消息仍要计算 fingerprint，执行 `PrepareSend`，等待宿主平台真实确认，再调用 `ConfirmBrowserSend`。fingerprint 是防重和审计，不是逐条询问。

用户已对当前 Cn/Rn 明确确认后，执行端只允许消费这一次确认或按上述同上下文规则复用，不能因为脚本参数拼错、重新 `Verify` 或重复 `PrepareSend` 再生成一条确认提示。

输入框定位或发送控件失败时，不得退回让用户手动粘贴。先重新读取 DOM、输入框内容和消息落点；只有平台确认已经通过、`DomMessagePresence=absent` 且已经超过 `sendDeadlineAt`，才能沿用同一 fingerprint 调用 `RetrySendAfterTimeout`。重试准备后必须再次取得平台确认并调用 `ConfirmBrowserSend`。`present/unknown`、confirmed 回执或达到2次上限时必须冻结。

## 首次绑定

```text
在 Codex 右侧栏打开 https://chat.deepseek.com/
→ 确认专家模式
→ 确认深度思考
→ BeginBootstrap 预占唯一 tab；没有稳定 sessionId 时准备当前 thread marker
→ AcquireBrowserLease
→ 重新读取真实 DOM 并 VerifyBootstrap
→ PrepareSend
→ 等待宿主平台真实确认
→ ConfirmBrowserSend
→ 发送完整基线消息；没有稳定 sessionId 时消息必须含当前 thread marker
→ 回读官网 sessionId、可用时的 marker、消息落点、openTabs、tabs.list 和当前 tab
→ CompleteBootstrap
→ RecordSendOutcome -ReceiptStatus confirmed，并提交 DOM present、openTabs/tabs.list 原始来源证据
→ ReleaseBrowserLease
```

没有真实 `official-chat` sessionId 且当前 thread marker 也没有回显时，绑定保持 `bootstrap-pending`，不能写成已绑定或已发送。有稳定 `official-chat` sessionId 时 marker 可为空。`confirmed` 回执要求 DOM `present` 加至少一个标签来源 `confirmed`；另一个来源为 `empty`/`unknown` 时必须原样保留，不能把它当成 `absent`。`not-found` 要求 DOM `absent` 加至少一个明确 `absent` 来源，`wrong-session` 要求 DOM `absent` 加至少一个 `wrong-session` 来源。

## 老任务、旧绑定和取消

- 同一 Codex thread 的老任务：创建新 TaskId，先 Claim，复用原官网会话；不要每次新建会话。
- 新 Task Claim 前会把旧 Task 的 `pendingReceipt`、`auditRisk`、fingerprint、确认来源、deadline、提交动作、回执、重试和阶段时间完整移到 `previousSendAudit`，再按真实类型清空当前发送闸门；旧审计保留，但不能阻塞新 Task 的新 fingerprint。
- 用户说“继续、补充、再评审”不等于任务完成，也不能把 heartbeat 暂停当成完成；应恢复当前 Task/同一会话。只有共识达成、明确失败、用户取消或真实决策僵局才可以停。
- 旧 `confirmed` 但缺 DOM/openTabs/tabs.list 的状态，普通更新不能强行改写；只能明确调用 `update_review_status.ps1 -FinalizeLegacyAudit` 转成只读历史终态。迁移必须保留 `legacy*` 证据缺口、`auditRisk=true`，撤销发送授权，禁止重发。
- 旧本机 Harness、旧规则或损坏绑定：绑定脚本先自动隔离旧入口、旧模型、旧推理等级和旧 session，保留到 `previous*`/`legacy*` 审计字段，再在官网右侧栏 `BeginBootstrap -ReplaceLost`；不能把旧 session 静默改名，也不能让当前 Task 状态继续显示旧入口。
- 已经是同一官网 session、只是浏览器来源不是右侧栏：用 `MigrateToInAppSidebar`，验证同一 sessionId 和可用时的 marker，并让 `RuntimeEpoch` 递增。
- 浏览器重启：旧 tab ID 立即失效，用 `RecoverRuntimeTab` 恢复同一官网会话，`RuntimeEpoch` 必须递增。
- 用户说“不要 DeepSeek”“本次不评审”“只整理不发送”：调用 `CancelBootstrap` 或 `-CancelReview`，撤销授权、释放当前 thread 的 lease，并保留审计字段。
- 正常工作全部结束使用 `CompleteTask`；它只在执行门槛满足、没有 pending/auditRisk/resendBlocked 且浏览器 lease 已释放时完成 Task。`ForceTerminateTask` 只处理异常恢复或损坏状态。

## 执行门槛

多轮评审必须同时满足：`共识状态=已达成`、`Codex总结状态=已完成`、`检查结果=无问题`、`方案状态=已敲定`，才允许修改。

独立一次评审必须同时满足：当前批次 `1/1`、已收到完整回复、Codex总结已完成、检查无问题、方案已敲定，才允许修改。

没有真实右侧栏页面证据、没有 confirmed 回执、session/tab/runtime/可用时的 marker 不一致时，禁止报告“已发送/已收到”。
