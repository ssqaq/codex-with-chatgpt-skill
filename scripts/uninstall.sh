#!/usr/bin/env bash
set -euo pipefail

SKILL_DIRECTORY="${CODEX_SKILL_DIRECTORY:-$HOME/.codex/skills/codex-with-chatgpt}"
CHECKOUT="${CODEX_CHECKOUT:-$HOME/codex-with-chatgpt}"
REMOVE_CHECKOUT="${1:-}"

if [[ -d "$SKILL_DIRECTORY" ]]; then
  rm -rf -- "$SKILL_DIRECTORY"
  echo "已移除 Skill：$SKILL_DIRECTORY"
else
  echo "Skill 已不存在：$SKILL_DIRECTORY"
fi
if [[ "$REMOVE_CHECKOUT" == "--remove-checkout" && -d "$CHECKOUT" ]]; then
  rm -rf -- "$CHECKOUT"
  echo "已移除项目目录：$CHECKOUT"
fi
echo "卸载完成。默认保留项目目录；如需一起移除，请加 --remove-checkout。"
