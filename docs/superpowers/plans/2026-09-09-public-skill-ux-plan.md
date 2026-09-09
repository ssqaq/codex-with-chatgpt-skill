# 公开 Skill 易用性优化 Implementation Plan

**Goal:** 为公开的 codex-with-chatgpt Skill 增加中文入门说明、安装示意图、一键安装脚本、统一连接器名称和版本发布记录。

**Architecture:** 文档负责解释和引导，脚本负责重复安装动作，Skill 正文继续保留完整的连接与协作规则。脚本只操作用户指定的本地目录，不把凭据写入仓库。

**Tech Stack:** Markdown、SVG、PowerShell 5.1+、POSIX Shell、GitHub CLI。

**Spec:** `docs/superpowers/specs/2026-09-09-public-skill-ux-design.md`

## Tasks

- [ ] 更新 README 和 SKILL.md 的中文入门说明、截图链接和统一命名规则。
- [ ] 添加 `scripts/install.ps1` 与 `scripts/install.sh`，实现环境检查、仓库更新、构建和 Skill 安装。
- [ ] 添加两张通用 SVG 安装示意图，确保不含账号、密码、域名和配对码。
- [ ] 添加 `VERSION` 与 `CHANGELOG.md`，执行脚本语法检查和文本敏感信息检查。
- [ ] 提交到 GitHub，创建 `v1.1.0` 标签和 Release，核对公开文件。
