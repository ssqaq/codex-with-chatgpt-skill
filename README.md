# codex-with-chatgpt Skill

这是一个给 Codex 用的 Skill。它把 ChatGPT 当作“参谋”：ChatGPT 帮忙分析、规划和检查，Codex 负责真正修改项目、运行命令和测试。

## 怎么用

在 Codex 会话里直接说：

> 用 ChatGPT 帮我规划这个功能并完成修改。

不需要输入 `/skill`。

## 推荐模型

连接 ChatGPT 时，优先选择 **GPT-5.6 Sol**，思考强度选择 **Pro（最高）**。如果你的账号暂时看不到这个模型，就使用当前能看到的最高模型；Skill 不会伪造模型名称。

## 安装步骤（看图就会）

### 第一步：安装

Windows 在 PowerShell 运行 `scripts/install.ps1`；macOS/Linux 在终端运行 `bash scripts/install.sh`。脚本会自动检查环境、下载项目、构建并安装 Skill。

![一键安装流程](docs/images/install-flow.svg)

### 第二步：填写连接器

连接器名称统一填写：`Codex with ChatGPT · <项目名>`。例如项目名是 `my-app`，就填写 `Codex with ChatGPT · my-app`，不要填 `1` 或其他临时名字。这样每个项目都能找到自己的连接。

![连接器填写示意图](docs/images/connector-form.svg)

### 第三步：配对

安装脚本完成后，在 ChatGPT 里连接对应名称，输入 Codex 显示的一次性配对码即可。

![配对流程示意图](docs/images/pairing-flow.svg)

## 更新、检查和卸载

- 更新：Windows 运行 `scripts/update.ps1`；macOS/Linux 运行 `bash scripts/update.sh`。
- 检查版本：Windows 运行 `scripts/check-version.ps1`；macOS/Linux 运行 `bash scripts/check-version.sh`。
- 版本检查会直接显示：本机版本、GitHub 最新版本、是否需要更新。
- 更新前会自动备份；更新失败会自动恢复。需要手动操作时，运行 `scripts/backup.ps1` / `scripts/backup.sh` 备份，运行 `scripts/rollback.ps1` / `scripts/rollback.sh` 回滚。
- 卸载 Skill：Windows 运行 `scripts/uninstall.ps1`；macOS/Linux 运行 `bash scripts/uninstall.sh`。默认只移除 Skill，项目目录会保留。

连接方式已经选择过后，后面换项目会自动沿用最近一次选择，一般不会再重复询问临时地址或固定域名。

核心程序源码在本仓库的 `core/` 目录。以后更新只看这个仓库，不用再找别的地址。

## 已经打开的旧会话怎么同步

更新 Skill 后，新会话会自动使用新规则。已经打开的旧会话不会自动改写
历史消息，但也不用重新开会话：更新完成后让 Codex 给原会话发一次同步，
发送前会先显示“会话名称 + 工作区”供核对；确认后它会在原来的工作区、原来的连接上继续，不会重复配对。

旧会话同步只影响下一步怎么做，之前已经显示的回复不会被改写，这是正常的。

## 自动检查和发布

每次提交或发起合并请求，GitHub 会自动安装依赖、跑测试、做类型检查和构建。修改根目录 `VERSION` 并提交后，GitHub 会自动创建对应标签和 Release。

## 适合做什么

- 开发新功能
- 排查报错
- 修改代码并测试
- 让 ChatGPT 复核修改结果

## 多轮方案评审

如果你希望先把方案讨论清楚，再开始改代码，可以直接说：

> 先做方案，多轮评审后再修改这个功能。

Codex 会显示“多轮评审：第 N 轮”，把纯文字方案发给当前网页版 GPT-5.6
Sol + Pro 最高强度评审，双方确认 `CONSENSUS` 后才修改文件。普通请求仍然
走快速流程；当前版本暂不包含图片直接读取。

## 安装

把 `SKILL.md` 放到 Codex 的 Skill 目录：

```text
~/.codex/skills/codex-with-chatgpt/SKILL.md
```

Windows 和 macOS 的目录位置按自己的 Codex 配置为准。

## 许可证

MIT
