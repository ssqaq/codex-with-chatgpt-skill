#!/usr/bin/env bash
set -euo pipefail

CHECKOUT="${CODEX_CHECKOUT:-$HOME/codex-with-chatgpt}"
SKILL_DIRECTORY="${CODEX_SKILL_DIRECTORY:-$HOME/.codex/skills/codex-with-chatgpt}"
BACKUP_ROOT="${CODEX_BACKUP_ROOT:-$HOME/.codex/backups/codex-with-chatgpt}"
[[ -d "$CHECKOUT/.git" ]] || { echo "找不到项目：$CHECKOUT" >&2; exit 1; }
commit="$(git -C "$CHECKOUT" rev-parse HEAD)"
stamp="$(date +%Y%m%d-%H%M%S)"
backup_path="$BACKUP_ROOT/$stamp"
mkdir -p "$backup_path"
printf '{"checkout":"%s","commit":"%s","createdAt":"%s"}\n' "$CHECKOUT" "$commit" "$(date -Iseconds)" > "$backup_path/manifest.json"
if [[ -f "$SKILL_DIRECTORY/SKILL.md" ]]; then cp "$SKILL_DIRECTORY/SKILL.md" "$backup_path/SKILL.md"; fi
printf '%s\n' "$backup_path" > "$BACKUP_ROOT/latest.txt"
echo "备份完成：$backup_path"
