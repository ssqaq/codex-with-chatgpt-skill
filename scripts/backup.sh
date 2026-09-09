#!/usr/bin/env bash
set -euo pipefail

CHECKOUT="${CODEX_CHECKOUT:-$HOME/codex-with-chatgpt}"
SKILL_DIRECTORY="${CODEX_SKILL_DIRECTORY:-$HOME/.codex/skills/codex-with-chatgpt}"
BACKUP_ROOT="${CODEX_BACKUP_ROOT:-$HOME/.codex/backups/codex-with-chatgpt}"
[[ -d "$CHECKOUT/.git" ]] || { echo "找不到项目：$CHECKOUT" >&2; exit 1; }
commit="$(git -C "$CHECKOUT" rev-parse HEAD)"
if [[ -n "$(git -C "$CHECKOUT" status --porcelain --untracked-files=all)" ]]; then
  echo "检测到未提交改动，已停止更新以保护你的代码。请先提交改动，或在确认后手动处理。" >&2
  exit 1
fi
stamp="$(date +%Y%m%d-%H%M%S)"
backup_path="$BACKUP_ROOT/$stamp"
if command -v python3 >/dev/null 2>&1; then
  stamp="$(python3 - <<'PY'
from datetime import datetime
from secrets import token_hex
now = datetime.now().astimezone()
print(f"{now:%Y%m%d-%H%M%S-%f}"[:-3] + "-" + token_hex(4))
PY
)"
fi
backup_path="$BACKUP_ROOT/$stamp"
mkdir -p "$backup_path"
python3 - "$backup_path/manifest.json" "$CHECKOUT" "$SKILL_DIRECTORY" "$commit" <<'PY'
import json
import os
import sys
import tempfile
from datetime import datetime, timezone

target, checkout, skill_directory, commit = sys.argv[1:]
payload = {
    "checkout": checkout,
    "skillDirectory": skill_directory,
    "commit": commit,
    "createdAt": datetime.now(timezone.utc).isoformat(),
}
directory = os.path.dirname(target)
fd, temporary = tempfile.mkstemp(prefix=".manifest.", suffix=".tmp", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, separators=(",", ":"))
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, target)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
PY
if [[ -f "$SKILL_DIRECTORY/SKILL.md" ]]; then cp "$SKILL_DIRECTORY/SKILL.md" "$backup_path/SKILL.md"; fi
for directory_name in references agents; do
  if [[ -d "$SKILL_DIRECTORY/$directory_name" ]]; then
    cp -R "$SKILL_DIRECTORY/$directory_name" "$backup_path/$directory_name"
  fi
done
latest_tmp="$BACKUP_ROOT/.latest.$$.$RANDOM.tmp"
printf '%s\n' "$backup_path" > "$latest_tmp"
mv -f -- "$latest_tmp" "$BACKUP_ROOT/latest.txt"
echo "备份完成：$backup_path"
