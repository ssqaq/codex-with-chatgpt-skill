# DeepSeek 评审状态模板

```text
TaskId：T-YYYYMMDD-HHMMSS-01
CodexThreadId：<当前 thread id>
SkillName：deepseek-consensus-review / deepseek-independent-review
激活状态：activated

目标页面：https://chat.deepseek.com/
目标模式：专家模式
推理等级：深度思考
浏览器来源：codex-in-app-sidebar
DeepSeekSessionId：official-chat:<id> / official-marker:CODEX-BINDING-<thread>
会话 URL：https://chat.deepseek.com/a/chat/s/<官网会话 id>
BrowserTabId：<右侧栏稳定 tab id>
BrowserRuntimeId：<当前 browser runtime id>
RuntimeEpoch：<正整数>
TabMatchCount：1
绑定置信度：official-session-id+browser-tab-id / official-marker+browser-tab-id
DOM marker：CODEX-BINDING-<thread> / 空（稳定 official-chat sessionId 时允许）

LeaseEpoch：<正整数>
发送指纹：<sha256>
发送状态：未发送 / 已发送，等待回复 / 已收到完整回复
回执状态：confirmed / unknown / wrong-session / not-found
激活耗时：<毫秒>
激活慢路径告警：true / false
慢路径阈值：2000
慢路径原因：<原因或空>
平台确认状态：awaiting / confirmed / rejected
平台确认时间：browserConfirmationAt
平台确认来源：browserConfirmationEvidence
Deadline启动时间：deadlineStartedAt
发送截止：sendDeadlineAt
重试次数：0 / 1 / 2
最大重试：2
DOM消息证据：absent / present / unknown
openTabs证据：confirmed / absent / wrong-session / unknown / empty
tabs.list证据：confirmed / absent / wrong-session / unknown / empty
重试耗尽：true / false
重发阻断：true / false
审计风险：true / false

当前轮次：C1 / C2 / C3 / ... / Cn（C3 不是最终仲裁）
相同分歧重复次数：0 / 1 / 2...
僵局阈值：2
决策僵局：true / false
僵局原因：<连续重复的实质分歧>
下一步：record-next-round / continue-review / await-user-decision / complete-codex-summary
轮次总进度：0-100%
共识状态：未开始 / 进行中 / 决策僵局 / 已达成
Codex总结状态：未开始 / 整理中 / 已完成
检查结果：待检查 / 发现冲突 / 无问题
方案状态：未敲定 / 已敲定
执行状态：禁止修改 / 允许开始执行 / 已完成
```

“已发送/已收到”只能在以下证据成立时写入：官网 URL、专家模式、深度思考、Codex 右侧栏、同一 sessionId 和可用时的 marker、同一 tab/runtime/lease、宿主平台 confirmed、DOM present，以及至少一个标签来源 confirmed。另一个标签来源为 empty/unknown 时必须原样记录，不能当成 absent；没有任何 confirmed 标签来源时只能记 unknown。

历史 `confirmed` 但缺证据的任务不能用普通状态更新硬改。必须通过
`update_review_status.ps1 -FinalizeLegacyAudit` 进入只读历史终态，保留
`legacyLastReceiptStatus`、`legacyReceiptEvidenceGap`、原始三来源值和 `auditRisk=true`，并撤销发送授权。

状态面板固定六列；“会话和发送”一行必须同时显示 `重试=当前/最大`、`截止=sendDeadlineAt`、`DOM=absent/present/unknown` 和 `耗尽=true/false`。字段缺失时显示安全默认值，不得猜测成已发送。

连续两轮相同分歧且没有新证据时，`decisionDeadlock=true`。决策僵局不等同于共识，执行状态必须保持“禁止修改”。
