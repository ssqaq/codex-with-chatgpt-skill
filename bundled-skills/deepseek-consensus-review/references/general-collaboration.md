# DeepSeek 官网评审通用协作规则

## 固定入口

- 只用 Codex 右侧栏内置浏览器（iab）。
- 只打开 `https://chat.deepseek.com/`。
- 目标固定为 `专家模式`，推理固定为 `深度思考`。
- 禁止 Chrome、Edge、扩展浏览器、外部桌面浏览器和任何其他地址。
- iab 不可用就停止，不回退、不伪造发送成功。

## 失败事务和回执恢复

- `FailBrowserWorkflow` 必须先记录事务阶段，再更新绑定、释放当前 thread/task 的 lease、冻结任务；下一次绑定脚本调用自动恢复当前 thread/task 的未完成事务并清理日志。
- `unknown` 回执必须保留 pending 状态，先重新核验原页面。`empty`/`unknown` 不是 `absent`：`confirmed` 允许 DOM `present` 加至少一个标签来源 `confirmed`；`not-found` 需要 DOM `absent` 加至少一个明确 `absent` 来源；`wrong-session` 需要 DOM `absent` 加至少一个 `wrong-session` 来源。仍为 `unknown` 就冻结。
- 原子 JSON 和 SHA-256 幂等键只保护本地状态与本地误重发，不能冒充服务端 exactly-once。
- `MarkLost` 必须有 `confirmed-absent`、观测次数和 `openTabs,tabs.list` 双来源证据；工具不可用只能走 `FailBrowserWorkflow`。

## 任务和会话

- `CodexThreadId` 决定隔离：一个 Codex thread 永远只绑定一个官网 `official-chat` sessionId 和一个右侧栏 tab。
- 同一 thread 的新 TaskId、继续、补证据、C2…Cn、R2…Rn，先 Claim 后复用，不新建第二个官网会话。
- 若绑定因旧版过期 lease 清理被误标 `lost`，先用当前 DOM 核验原 sessionId 和 marker，再调用 `RecoverExpiredLeaseBinding`；核验失败才允许 replacement bootstrap。
- 如果 Codex 右侧栏找不到当前 thread 原来的 session、marker 或专用 tab，先确认原窗口确实不存在；然后 `MarkLost` 保留审计，在右侧栏新建一个 DeepSeek 官网窗口，用新 tab/runtime `BeginBootstrap -ReplaceLost` 重新绑定。不能抢用其他 thread 的窗口。
- 能核验原窗口就复用，不能因为当前焦点不在原 tab 就误判“窗口丢失”；只有真实 DOM 找不到原身份时才新建。
- 发送控件失败不能让用户手动粘贴；Codex 必须先复核 `DomMessagePresence=absent` 且已经超时，再沿用同一 fingerprint 调用 `RetrySendAfterTimeout`，最多2次。
- 不同 Codex thread 必须用不同 sessionId、不同 tab 和完整 runtime 证据。
- 浏览器重启只用 `RecoverRuntimeTab` 恢复同一官网会话，不能把旧数字 tab 当新身份。
- 新 Task `Claim` 复用同一官网会话前，会把旧 Task 的 `pendingReceipt`、`auditRisk`、fingerprint、回执和重试记录放进 `previousSendAudit`，清空当前发送闸门；旧风险保留但不阻塞新 fingerprint。

## Skill 激活和发送

用户显式点名 Skill 就先读取对应 `SKILL.md`，再写真实激活状态。用户已经要求评审/继续时，自动按工作流授权，不要每轮先问能不能发；每条消息仍执行 fingerprint、PrepareSend、真实回读和 RecordSendOutcome。

激活优先调用 `activate_review.ps1`，正常新建/恢复只做本地状态读写，目标小于2秒。相同 Task/fingerprint 的 Cn/Rn 已确认且没有 fill/click/press、提交动作或 DOM 落点时，任何本地参数校验失败都复用原确认；`platform-already-confirmed`、`verified-confirmed-send`、`send-confirmed-ready` 都表示直接发送，禁止再次询问。正常结束使用 `CompleteTask`，异常恢复才使用 `ForceTerminateTask`。

## Codex发送前

先检查源码、配置、日志、复现和真实页面，分开整理：

- 【事实】已经确认；
- 【推断】根据事实提出；
- 【缺失证据】还不能确认；
- 【Codex初步判断】根因、推荐方案、备选方案、风险、回滚、验证顺序。

## DeepSeek独立性

DeepSeek必须基于本轮事实重新推导，再对照 Codex。明确支持、部分支持、反驳或无法确认；不能只说“同意”，也不能机械唱反调。

多轮共识评审不以 C3 为硬上限。C3 只是第三轮；仍有可继续收敛的实质分歧时，在同一 TaskId 和同一官网会话继续 C4、C5……Cn。只有达成共识、用户取消、页面/回执失败，或出现必须由用户裁决且现有证据无法解决的决策僵局时才停止；僵局状态仍禁止修改。

## 轮次状态和决策僵局

- 每轮 Codex 核对完成后调用 `review_round.ps1 -Action RecordRound`，不能只在聊天里口头声明 Cn。
- 连续两轮相同实质分歧且没有新证据时自动标记决策僵局，停止继续发送并等待用户裁决。
- 用户裁决或新证据通过 `ResolveDeadlock` 留下记录后，才能进入下一轮；解除僵局不等于达成共识。
- 每次进度汇报前调用 `show_review_dashboard.ps1`，显示固定六列状态面板。
- 用户说“继续、补充、再评审”不等于任务完成，也不允许把 heartbeat 暂停当成完成；应恢复当前 Task/同一会话。只有共识达成、明确失败、用户取消或真实决策僵局才可以停。

## 发送流程

首次：`BeginBootstrap → AcquireBrowserLease → VerifyBootstrap → PrepareSend → 平台确认 → ConfirmBrowserSend → 发送基线 → 回读官网 sessionId/可用时的 marker/三来源证据 → CompleteBootstrap → RecordSendOutcome → ReleaseBrowserLease`。

后续：`Claim → AcquireBrowserLease → Verify → PrepareSend → 平台确认 → ConfirmBrowserSend → 发送一条完整消息 → 回读 DOM/openTabs/tabs.list → RecordSendOutcome → ReleaseBrowserLease`。

官网没有稳定 sessionId 时，使用只包含当前 thread 的 `official-marker:CODEX-BINDING-<thread>`；稳定 `official-chat` sessionId 存在时 marker 可以为空。sessionId 和 marker 都没有时不能写“已绑定”。

发送前先准备好完整消息。页面身份核验通过后，必须连续执行到平台确认，不得在 `Verify` 与发送之间继续分析或空等。`PrepareSend` 的 awaiting 阶段不启动 deadline；`ConfirmBrowserSend` 返回 `sendNow=true` 后，正常目标是在 30 秒内发出。超时就重读一次 DOM，只有明确 absent 才调用 `RetrySendAfterTimeout`，每次重试重新确认平台，最多2次。

旧 `confirmed` 但缺少 DOM/openTabs/tabs.list 的历史状态，普通更新不能强行改写；只能明确调用
`update_review_status.ps1 -FinalizeLegacyAudit` 转成只读历史终态。迁移必须保留
`legacy*` 证据缺口、`auditRisk=true`，撤销发送授权，禁止重发。

## 旧状态和取消

- 旧本机 Harness、旧规则或外部绑定：脚本自动隔离旧字段并保留审计，再进入官网 replacement bootstrap；绑定变化同步写回当前 Task 状态。
- 已经是官网会话但来源不是右侧栏：用 `MigrateToInAppSidebar` 验证同一 sessionId 和可用时的 marker 后迁入，不新建会话。
- 无 thread 归属的历史状态保持无归属，不猜。
- 用户说“不要 DeepSeek”“本次不评审”“只整理不发送”：执行 `CancelBootstrap`/`-CancelReview`，撤销授权、释放当前 thread lease、保留审计风险，禁止重发。

## 执行门槛

多轮评审：共识达成、Codex总结完成、检查无问题、方案敲定，才允许修改。

独立评审：1/1、已收到完整回复、Codex总结完成、检查无问题、方案敲定，才允许修改。

状态文件只保存身份、绑定、回执和流程状态，不保存账号、密码、密钥或完整敏感正文。
