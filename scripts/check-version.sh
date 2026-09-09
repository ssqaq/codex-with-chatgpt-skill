#!/usr/bin/env bash
set -euo pipefail

REPOSITORY="${1:-ssqaq/codex-with-chatgpt-skill}"
VERSION_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/VERSION"
CURRENT="$(tr -d '[:space:]' < "$VERSION_FILE")"
LATEST="$(curl -fsSL "https://api.github.com/repos/$REPOSITORY/releases/latest" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))')"
needs_update="$(python3 - "$CURRENT" "$LATEST" <<'PY'
import re, sys

def version(value):
    parts = re.findall(r"\d+", value)
    return tuple(int(part) for part in (parts + ["0", "0", "0"])[:3])

print("yes" if version(sys.argv[1]) < version(sys.argv[2]) else "no")
PY
)"
echo "本机版本：$CURRENT"
echo "GitHub 最新版本：$LATEST"
if [[ "$needs_update" == "yes" ]]; then
  echo "是否需要更新：是"
  exit 10
fi
echo "是否需要更新：否"
