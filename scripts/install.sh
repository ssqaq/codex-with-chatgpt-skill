#!/usr/bin/env bash
set -euo pipefail

CHECKOUT="${CODEX_CHECKOUT:-$HOME/codex-with-chatgpt}"
SKILL_DIRECTORY="${CODEX_SKILL_DIRECTORY:-$HOME/.codex/skills/codex-with-chatgpt}"
REPO_URL="https://github.com/ssqaq/codex-with-chatgpt-skill.git"

install_macos_dependencies() {
  command -v brew >/dev/null 2>&1 || { echo "请先安装 Homebrew。" >&2; exit 1; }
  command -v git >/dev/null 2>&1 || brew install git
  command -v node >/dev/null 2>&1 || brew install node
  command -v cloudflared >/dev/null 2>&1 || brew install cloudflared
  command -v python3 >/dev/null 2>&1 || brew install python
}

if [[ "${OSTYPE:-}" == darwin* ]]; then
  install_macos_dependencies
else
  for command_name in git node cloudflared python3; do
    command -v "$command_name" >/dev/null 2>&1 || {
      echo "当前脚本面向 macOS；缺少 $command_name。请先安装后重试。" >&2
      exit 1
    }
  done
fi

node_major="$(node -p 'process.versions.node.split(".")[0]')"
if (( node_major < 20 )); then
  echo "Node.js 版本低于 20，请升级后重试。" >&2
  exit 1
fi

if [[ -d "$CHECKOUT/.git" ]]; then
  echo "更新已有项目：$CHECKOUT"
  git -C "$CHECKOUT" pull --ff-only
else
  echo "下载项目：$CHECKOUT"
  mkdir -p "$(dirname "$CHECKOUT")"
  git clone "$REPO_URL" "$CHECKOUT"
fi

if [[ -f "$CHECKOUT/core/package.json" ]]; then
  PROJECT_ROOT="$CHECKOUT/core"
else
  PROJECT_ROOT="$CHECKOUT"
fi

cd "$PROJECT_ROOT"
corepack enable
corepack pnpm install
corepack pnpm build

mkdir -p "$SKILL_DIRECTORY"
source_skill="$CHECKOUT/SKILL.md"
if [[ ! -f "$source_skill" ]]; then
  source_skill="$PROJECT_ROOT/skill/SKILL.md"
fi
target_skill="$SKILL_DIRECTORY/SKILL.md"
[[ -f "$source_skill" ]] || { echo "找不到 Skill 文件：$source_skill" >&2; exit 1; }
cp "$source_skill" "$target_skill"
python3 - "$target_skill" "$CHECKOUT" <<'PY'
from pathlib import Path
import sys

target = Path(sys.argv[1])
checkout = sys.argv[2]
text = target.read_text(encoding="utf-8")
old = "- The codex-with-chatgpt checkout lives at:"
lines = text.splitlines()
for index, line in enumerate(lines):
    if line.startswith(old):
        lines[index] = f"{old} `{checkout}`"
        target.write_text("\n".join(lines) + "\n", encoding="utf-8")
        break
else:
    raise SystemExit("Skill 中找不到工作区路径行。")
PY

echo "安装完成。"
echo "项目目录：$CHECKOUT"
echo "Skill 文件：$target_skill"
echo "连接器名称规则：Codex with ChatGPT · <项目名>"
