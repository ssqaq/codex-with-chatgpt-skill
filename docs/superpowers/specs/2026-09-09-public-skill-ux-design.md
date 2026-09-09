# 公开 Skill 易用性优化设计

## 目标

让不懂技术的人也能看懂、安装和使用 codex-with-chatgpt Skill，并让公开仓库具备清楚的版本记录。

## 方案

1. 在 README 和 Skill 开头加入中文大白话说明，并提供两张不含个人信息的安装示意图。
2. 统一连接器名称为 `Codex with ChatGPT · <项目名>`，安装脚本和手动步骤都使用同一规则。
3. 提供 Windows PowerShell 和 macOS/Linux Shell 一键安装脚本，自动检查 Git、Node.js 20+、cloudflared，更新代码、构建并安装 Skill。
4. 用 `VERSION` 和 `CHANGELOG.md` 记录版本，并发布 Git 标签和 GitHub Release。

## 验收

- 两个平台脚本能通过语法检查，并在缺少命令时给出可执行的安装动作。
- README 能直接看到中文说明、示意图、安装命令和统一名称规则。
- 公开仓库显示 `v1.1.0`，文件在线可读取，工作区没有未提交改动。
