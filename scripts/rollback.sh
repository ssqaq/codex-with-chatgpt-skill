#!/usr/bin/env bash
set -euo pipefail

BACKUP_PATH="${1:-}"
BACKUP_ROOT="${CODEX_BACKUP_ROOT:-$HOME/.codex/backups/codex-with-chatgpt}"
FORCE="${C2C_ROLLBACK_FORCE:-0}"
if [[ -z "$BACKUP_PATH" ]]; then BACKUP_PATH="$(cat "$BACKUP_ROOT/latest.txt")"; fi
CHECKOUT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["checkout"])' "$BACKUP_PATH/manifest.json")"
COMMIT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$BACKUP_PATH/manifest.json")"
SKILL_DIRECTORY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("skillDirectory", ""))' "$BACKUP_PATH/manifest.json")"
SKILL_DIRECTORY="${SKILL_DIRECTORY:-${CODEX_SKILL_DIRECTORY:-$HOME/.codex/skills/codex-with-chatgpt}}"
[[ -n "$CHECKOUT" && -n "$COMMIT" ]] || { echo "备份清单缺少项目路径或提交号。" >&2; exit 1; }
[[ -d "$CHECKOUT/.git" ]] || { echo "找不到项目：$CHECKOUT" >&2; exit 1; }
if [[ "$FORCE" != "1" && -n "$(git -C "$CHECKOUT" status --porcelain --untracked-files=all)" ]]; then
  echo "工作区有未提交改动，已拒绝回滚以保护你的代码。确认后设置 C2C_ROLLBACK_FORCE=1。" >&2
  exit 1
fi
git -C "$CHECKOUT" reset --hard "$COMMIT"
if [[ -f "$BACKUP_PATH/SKILL.md" ]]; then
  mkdir -p "$SKILL_DIRECTORY"
  skill_tmp="$SKILL_DIRECTORY/.SKILL.md.$$.$RANDOM.tmp"
  cp "$BACKUP_PATH/SKILL.md" "$skill_tmp"
  mv -f -- "$skill_tmp" "$SKILL_DIRECTORY/SKILL.md"
fi
for directory_name in references agents; do
  if [[ -d "$BACKUP_PATH/$directory_name" ]]; then
    rm -rf "$SKILL_DIRECTORY/$directory_name"
    mkdir -p "$SKILL_DIRECTORY"
    cp -R "$BACKUP_PATH/$directory_name" "$SKILL_DIRECTORY/$directory_name"
  fi
done
echo "已恢复上一版：$COMMIT"
