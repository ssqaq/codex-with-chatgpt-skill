# 调用捷径

## 多轮共识评审

```text
$deepseek-consensus-review
只在 Codex 右侧栏打开 https://chat.deepseek.com/。
固定使用专家模式并开启深度思考。
DeepSeek独立分析并明确反驳或支持 Codex，但不能机械唱反调。
双方没有消除实质分歧前不要修改。
每轮核对后记录 Cn 并显示六列状态面板；连续两轮相同分歧且没有新证据时停止发送，等待用户裁决。
我的问题：
...
```

## 独立一次评审

```text
$deepseek-independent-review
只在 Codex 右侧栏打开 https://chat.deepseek.com/。
固定使用专家模式并开启深度思考。
请独立找错，不要直接接受 Codex 初步判断。
收到回复后记录 Rn 并显示六列状态面板。
我的问题：
...
```

## 同一 Codex thread 的新任务

```text
这是当前 Codex thread 里的新目标。
创建新 TaskId，旧任务终态后 Claim 并复用原 DeepSeek 官网会话和右侧栏 tab；不要新建第二个会话。
```

## 新 Codex thread

```text
这是新的 Codex thread。
请在 Codex 右侧栏 DeepSeek 官网建立本 thread 唯一的新 official-chat sessionId 和专用 tab，不得复用其他 thread 的会话或 tab。
```

## 老任务继续

```text
继续当前老任务，沿用原 TaskId 和 CodexThreadId。
读取最近状态和上一轮分歧，在同一官网会话进入下一轮，不新建会话。
```

## 只整理不发送

```text
本次不要访问浏览器或发送消息，只整理本地事实、Codex初步判断、分歧和一条可复制的评审消息。
```
