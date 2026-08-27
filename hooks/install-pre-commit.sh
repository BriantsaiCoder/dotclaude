#!/bin/bash
# 將 pre-commit hook 安裝到 git 實際會執行它的位置（不變動 git config）。
# 目標由 `git rev-parse --git-path hooks/pre-commit` 決定，**未必是 .git/hooks/**：
# 設了 core.hooksPath 就是那個目錄，worktree 下則是 common dir。腳本結束時會印出實際路徑。
# 新機器 clone 後執行：bash hooks/install-pre-commit.sh

set -euo pipefail

# repo root 由**腳本自身位置**推導，不用 `git rev-parse --show-toplevel`：後者取的是
# 當前 cwd 所在的 repo，從另一個 repo 裡執行 `bash /path/to/dotclaude/hooks/install-...`
# 會裝到**那個** repo 去。與 tests/repo-integrity.sh 檔頭同一形狀。
cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." || exit 1
# 切到 repo root 之後才算 DST：`git rev-parse --git-path` 回的是**相對於當前目錄**的路徑
# （實測：無論從哪裡呼叫都回 `.git/hooks/pre-commit`）。在別的 cwd 下算，下面的
# mkdir -p 與 cp 會落在當前目錄底下，裝到一個 git 永遠不會執行的位置——而且靜默成功。
SRC="hooks/pre-commit-claude.sh"
# git rev-parse --git-path 而非硬寫 .git/hooks：worktree 的 .git 是檔案，
# 硬寫會讓下方 mkdir -p 以 "Not a directory" 失敗（2026-08-26 實測）。同時處理
# core.hooksPath 與 ${GIT_DIR}。
DST="$(git rev-parse --git-path hooks/pre-commit)"

if [[ ! -f "$SRC" ]]; then
  echo "錯誤：找不到 $SRC" >&2
  exit 1
fi

# 裸 cp 在 .git/hooks/ 不存在時以 "No such file or directory" 失敗（2026-08-26 實測）。
# 成因是本機 global `init.templatedir` 指向一個空 template 目錄
# （git config --global --get init.templatedir → ~/.cache/git-templates-empty），
# 於是 init／clone 都不會建出 .git/hooks/。用 git 預設 template 則會建出來——
# 也就是說這在預設設定的機器上重現不了，不要據此判定本行多餘。
mkdir -p "$(dirname "$DST")"
cp "$SRC" "$DST"
chmod +x "$DST"
echo "已安裝 pre-commit hook → $DST"
