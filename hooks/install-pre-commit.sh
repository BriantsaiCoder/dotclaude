#!/bin/bash
# 將 pre-commit hook 安裝到 .git/hooks/（不變動 git config）。
# 新機器 clone 後執行：bash hooks/install-pre-commit.sh

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SRC="$REPO_ROOT/hooks/pre-commit-claude.sh"
DST="$REPO_ROOT/.git/hooks/pre-commit"

if [[ ! -f "$SRC" ]]; then
  echo "錯誤：找不到 $SRC" >&2
  exit 1
fi

cp "$SRC" "$DST"
chmod +x "$DST"
echo "已安裝 pre-commit hook → $DST"
