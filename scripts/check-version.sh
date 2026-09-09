#!/usr/bin/env bash
set -euo pipefail

REPOSITORY="${1:-ssqaq/codex-with-chatgpt-skill}"
VERSION_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/VERSION"
CURRENT="$(tr -d '[:space:]' < "$VERSION_FILE")"
LATEST="$(curl -fsSL "https://api.github.com/repos/$REPOSITORY/releases/latest" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))')"
if [[ "$CURRENT" == "$LATEST" ]]; then
  echo "已是最新版本：$CURRENT"
else
  echo "当前版本：$CURRENT；最新版本：$LATEST"
  exit 10
fi
