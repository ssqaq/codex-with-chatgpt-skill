#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/backup.sh"
if ! "$SCRIPT_DIR/install.sh"; then
  echo "更新失败，正在恢复上一版..." >&2
  "$SCRIPT_DIR/rollback.sh"
  exit 1
fi
echo "更新完成。"
