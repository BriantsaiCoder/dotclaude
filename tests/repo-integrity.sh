#!/usr/bin/env bash
#
# repo-integrity.sh — ~/.claude 的機械守衛（P3-8）
#
# 為什麼是這五項：每一項都對應一種「壞掉但不會有錯誤訊息」的失效模式。
# 會噴錯的東西不需要 CI 擋，會靜默失效的才需要。
#
#   1. JSON 解析     settings.json 壞掉時整份被靜默忽略，不是報錯
#   2. symlink 形狀  斷鏈或指錯 kind 會讓 skill/rule 內容靜默換掉或消失
#   3. agent 定義    frontmatter 有 name 但缺 description 的檔案永遠不會載入
#   4. routing stamp 標記殘缺會讓 agents-sync 無法定位注入區塊
#   5. shellcheck    hook 是 PreToolUse 攔截器，語法錯等於防線失效
#
# 用法: bash tests/repo-integrity.sh
# 從 repo 根目錄跑；CI 與本機皆可。
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." || exit 1

pass=0; fail=0
ok()   { printf '  PASS  %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }

# ── 1. 所有追蹤中的 JSON 可解析 ────────────────────────────────
# settings.json 解析失敗不會有任何提示，整份設定被當成不存在。
while IFS= read -r f; do
  [ -f "$f" ] || continue
  if err=$(jq empty "$f" 2>&1); then ok "JSON 可解析: $f"
  else bad "JSON 解析失敗: $f — ${err%%$'\n'*}"; fi
done < <(git ls-files '*.json')

# settings.json 的 defaultMode 必須是已知值（未知值會靜默退回預設）
if [ -f settings.json ]; then
  mode=$(jq -r '.permissions.defaultMode // "unset"' settings.json 2>/dev/null)
  case "$mode" in
    unset|acceptEdits|auto|bypassPermissions|default|dontAsk|plan|manual)
      ok "permissions.defaultMode 合法: $mode" ;;
    *) bad "permissions.defaultMode 非已知值: $mode" ;;
  esac
fi

# ── 2. symlink 形狀 ────────────────────────────────────────────
# 不變量：每個 symlink 必為 ../../.agents/<所在目錄>/<與自己同名>。
# CI 環境沒有 ~/.agents，所以只驗形狀不驗目標存在——形狀錯才是會靜默
# 換掉內容的那一種（絕對路徑、指到別的 kind、改名後沒重連）。
link_n=0; link_bad=0
while IFS= read -r f; do
  link_n=$((link_n+1))
  target=$(readlink "$f") || { bad "無法讀取 symlink: $f"; link_bad=$((link_bad+1)); continue; }
  expect="../../.agents/$(dirname "$f")/$(basename "$f")"
  if [ "$target" = "$expect" ]; then :
  else bad "symlink 目標不符: $f -> ${target}（應為 ${expect}）"; link_bad=$((link_bad+1)); fi
done < <(git ls-files -s | awk '$1=="120000"{ $1=""; $2=""; $3=""; sub(/^ +/,""); print }')
# 只有零失敗才宣稱一致——否則摘要會與上方剛印的 FAIL 自相矛盾
if [ "$link_n" -gt 0 ] && [ "$link_bad" -eq 0 ]; then
  ok "symlink 形狀一致: $link_n 個全部為 ../../.agents/<kind>/<同名>"
fi

# ── 3. agent 定義可載入 ────────────────────────────────────────
# frontmatter 有 name 但缺 description 的 agent 檔永遠不會被載入，且無提示。
# 同目錄同名會靜默丟棄其中一個，勝出者依 readdir 順序（跨機器可能不同）。
agent_names=""
while IFS= read -r f; do
  [ -f "$f" ] || continue
  fm=$(awk 'NR==1 && $0=="---"{inb=1;next} inb && $0=="---"{exit} inb{print}' "$f")
  name=$(printf '%s\n' "$fm" | sed -n 's/^name:[[:space:]]*//p' | head -1)
  [ -n "$name" ] || continue          # 無 name = 併放的文件，非 agent
  if printf '%s\n' "$fm" | grep -q '^description:[[:space:]]*[^[:space:]]'; then
    ok "agent 可載入: $name ($f)"
  else
    bad "agent 缺 description，永遠不會載入: $name ($f)"
  fi
  case " $agent_names " in
    *" $name "*) bad "agent 同名衝突: ${name}（同目錄下重複，勝出者依 readdir 順序）" ;;
    *) agent_names="$agent_names $name" ;;
  esac
done < <(git ls-files 'agents/*.md')

# ── 4. CLAUDE.md 的 routing stamp 標記完整 ─────────────────────
# agents-sync 靠這對標記定位注入區塊；殘缺時它會拒絕寫入或寫錯位置。
if [ -f CLAUDE.md ]; then
  b=$(grep -c '<!-- agents-routing:begin' CLAUDE.md)
  e=$(grep -c '<!-- agents-routing:end' CLAUDE.md)
  bl=$(grep -n '<!-- agents-routing:begin' CLAUDE.md | head -1 | cut -d: -f1)
  el=$(grep -n '<!-- agents-routing:end'   CLAUDE.md | head -1 | cut -d: -f1)
  if [ "$b" = 1 ] && [ "$e" = 1 ] && [ -n "$bl" ] && [ -n "$el" ] && [ "$bl" -lt "$el" ]; then
    ok "routing stamp 標記完整（begin@$bl < end@${el}）"
  else
    bad "routing stamp 標記殘缺: begin×$b end×${e}（各須恰好 1 個且 begin 在前）"
  fi
fi

# ── 5. shellcheck ─────────────────────────────────────────────
# 只檢查本 repo 自己的實體 .sh；symlink 進來的由 ~/.agents 的 CI 負責。
if command -v shellcheck >/dev/null 2>&1; then
  sh_files=()
  while IFS= read -r f; do [ -L "$f" ] || sh_files+=("$f"); done < <(git ls-files '*.sh')
  if [ ${#sh_files[@]} -eq 0 ]; then ok "shellcheck: 無本地 .sh 需檢查"
  elif shellcheck -S error "${sh_files[@]}"; then ok "shellcheck: ${#sh_files[@]} 個本地 .sh 無 error"
  else bad "shellcheck 發現 error 級問題"; fi
else
  printf '  SKIP  shellcheck 未安裝\n'
fi

printf '\n%d PASS / %d FAIL\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
