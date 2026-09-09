#!/usr/bin/env bash
set -euo pipefail

BACKUP_PATH="${1:-}"
BACKUP_ROOT="${CODEX_BACKUP_ROOT:-$HOME/.codex/backups/codex-with-chatgpt}"
FORCE="${C2C_ROLLBACK_FORCE:-0}"
if [[ -z "$BACKUP_PATH" ]]; then BACKUP_PATH="$(cat "$BACKUP_ROOT/latest.txt")"; fi
CHECKOUT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["checkout"])' "$BACKUP_PATH/manifest.json")"
COMMIT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$BACKUP_PATH/manifest.json")"
if [[ "$FORCE" != "1" && -n "$(git -C "$CHECKOUT" status --porcelain --untracked-files=all)" ]]; then
  echo "工作区有未提交改动，已拒绝回滚以保护你的代码。确认后设置 C2C_ROLLBACK_FORCE=1。" >&2
  exit 1
fi
git -C "$CHECKOUT" reset --hard "$COMMIT"
if [[ -f "$BACKUP_PATH/SKILL.md" ]]; then
  mkdir -p "$HOME/.codex/skills/codex-with-chatgpt"
  cp "$BACKUP_PATH/SKILL.md" "$HOME/.codex/skills/codex-with-chatgpt/SKILL.md"
fi
echo "已恢复上一版：$COMMIT"
