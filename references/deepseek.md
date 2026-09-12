# DeepSeek 评审渠道

新评审默认使用 DeepSeek；用户明确说“用 GPT/ChatGPT 评审”时才切回 ChatGPT。

## 网页条件

- 只使用 Codex 右侧栏内置浏览器打开 `https://chat.deepseek.com/`。
- DeepSeek 官网现在把快速、专家、识图模式合并。不要寻找旧的专家模式按钮。
- 发送前必须从页面真实确认“深度思考”和“智能搜索”都开启。
- 一个 Codex 任务只绑定一个 DeepSeek 官方会话和一个专用标签页；后续轮次复用它。

## 信息边界

发送给 DeepSeek 的内容只包括需求摘要、事实、方案摘要、分歧、文件方向、测试方法和测试结果。不要发送完整源码、完整 diff、完整日志、密钥或凭据。摘要发送成功不等于 DeepSeek 已读取工作区文件。

## 两种流程

- 单次：发送一次短摘要，读取完整评审，Codex 核对执行门槛后继续修改、测试和复核。
- 多轮：发送 `C1`、`C2`……摘要，每轮在 Codex 显示同意点、分歧点和下一步；双方明确共识后才允许修改。

网页发送、会话绑定、回执和恢复由随仓库安装的 `deepseek-independent-review` / `deepseek-consensus-review` Skill 处理。安装器检查版本和文件；缺失时修复安装，不重新建立评审对话。页面模式未确认、回执不完整或会话身份不一致时，必须暂停且不能直接重发。

## v1.19.0 等待、增量和恢复

- 第 1 轮发送完整短摘要；第 2 轮起只发送 `ROUND_DELTA`，包含新增事实、修改点和当前分歧，不重复上一轮全文。
- 等待 DeepSeek 和 Codex 执行分开计时，分别显示网页等待分钟数和执行分钟数。
- 连续 10 分钟没有确认到新的回复内容才暂停；429/503 按明确时间或递增退避恢复，不重复发送或建会话。
- 达成共识后立即发起普通执行任务接力，不等待用户再次发送“继续”。

- 一轮发送准备：`deepseek-consensus-review/scripts/send_review_round.ps1`。必须提供实际 `-EvidenceFile`、已有用户授权依据及当前 lease；不再从本地状态猜测网页。只返回准备状态，实际提交和回执由内置浏览器完成。
- 每轮留底账：`deepseek-review-state\audit\round-audit.jsonl`，只追加，不记正文和敏感信息。
- RecordRound 新参数：`-ResolvedCount -TotalIssues`，用于分歧进度显示。
- 浏览器标签自动认路：按会话 URL + 标题 + 暗号识别，编号变化自动 RecoverRuntimeTab。

等待、每分钟回显、同任务检查点恢复和测试要求见 [reliability.md](reliability.md)。流水账仅用于核对进度，恢复必须读取同任务检查点并重新验证原网页。
