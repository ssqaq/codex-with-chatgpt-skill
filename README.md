# codex-with-chatgpt Skill

这是一个给 Codex 用的 Skill。它把 ChatGPT 当作“参谋”：ChatGPT 帮忙分析、规划和检查，Codex 负责真正修改项目、运行命令和测试。

## 怎么用

在 Codex 会话里直接说：

> 用 ChatGPT 帮我规划这个功能并完成修改。

不需要输入 `/skill`。

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
- 卸载 Skill：Windows 运行 `scripts/uninstall.ps1`；macOS/Linux 运行 `bash scripts/uninstall.sh`。默认只移除 Skill，项目目录会保留。

连接方式已经选择过后，后面换项目会自动沿用最近一次选择，一般不会再重复询问临时地址或固定域名。

核心程序源码在本仓库的 `core/` 目录。以后更新只看这个仓库，不用再找别的地址。

## 自动检查和发布

每次提交或发起合并请求，GitHub 会自动安装依赖、跑测试、做类型检查和构建。修改根目录 `VERSION` 并提交后，GitHub 会自动创建对应标签和 Release。

## 适合做什么

- 开发新功能
- 排查报错
- 修改代码并测试
- 让 ChatGPT 复核修改结果

## 安装

把 `SKILL.md` 放到 Codex 的 Skill 目录：

```text
~/.codex/skills/codex-with-chatgpt/SKILL.md
```

Windows 和 macOS 的目录位置按自己的 Codex 配置为准。

## 许可证

MIT
