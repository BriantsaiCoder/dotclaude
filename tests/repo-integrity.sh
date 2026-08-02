#!/usr/bin/env bash
#
# repo-integrity.sh — ~/.claude 的機械守衛（P3-8）
#
# 為什麼是這五項：每一項都對應一種「壞掉但不會有錯誤訊息」的失效模式。
# 會噴錯的東西不需要 CI 擋，會靜默失效的才需要。
#
#   1. JSON 解析     settings.json 壞掉時整份被靜默忽略，不是報錯
#   2. skill symlink 斷鏈或指錯位置會讓共用 skill 靜默換掉或消失
#   3. agent 定義    frontmatter 有 name 但缺 description 的檔案永遠不會載入
#   4. shellcheck    hook 是 PreToolUse 攔截器，語法錯等於防線失效
#   5. ownership     非 skill config 不可重新連回 ~/.agents control plane
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

# ── 2. skill symlink 形狀 ─────────────────────────────────────
# 不變量：每個 symlink 必為 ../../.agents/skills/<與自己同名>。
# CI 環境沒有 ~/.agents，所以只驗形狀不驗目標存在——形狀錯才是會靜默
# 換掉內容的那一種（絕對路徑、指到別的 skill、改名後沒重連）。
link_n=0; link_bad=0
while IFS= read -r f; do
  link_n=$((link_n+1))
  target=$(readlink "$f") || { bad "無法讀取 symlink: $f"; link_bad=$((link_bad+1)); continue; }
  expect="../../.agents/skills/$(basename "$f")"
  if [ "$target" = "$expect" ]; then :
  else bad "symlink 目標不符: $f -> ${target}（應為 ${expect}）"; link_bad=$((link_bad+1)); fi
done < <(find skills -maxdepth 1 -type l | LC_ALL=C sort)
# 只有零失敗才宣稱一致——否則摘要會與上方剛印的 FAIL 自相矛盾
if [ "$link_n" -gt 0 ] && [ "$link_bad" -eq 0 ]; then
  ok "skill symlink 形狀一致: $link_n 個全部為 ../../.agents/skills/<同名>"
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

# ── 4. shellcheck ─────────────────────────────────────────────
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

# ── 5. global config ownership ────────────────────────────────
for dir in core rules hooks; do
  if find "$dir" -maxdepth 1 -type l -print -quit | grep -q .; then
    bad "$dir 仍含非 skill symlink"
  else
    ok "$dir 由 Claude repo 擁有"
  fi
done

# 這一節比對 link 與 shared source 是否一一對應，只有 ~/.agents 在場時成立。
# CI 環境沒有 ~/.agents（見 .github/workflows/ci.yml 的分工說明）：那裡只驗 symlink
# 形狀（第 43-56 行），目標存在性由本機 `agents-sync --doctor` 負責。缺這道守衛時
# 94 條 link 會全數誤判 FAIL——2026-08-01 run 30671830610 實證。
shared_skills="${SHARED_SKILLS_ROOT:-$HOME/.agents/skills}"
if [ ! -d "$shared_skills" ]; then
  printf '  SKIP  shared source 不可得（%s）；link 目標存在性由本機 agents-sync --doctor 負責\n' "$shared_skills"
else
  skill_bad=0
  while IFS= read -r source; do
    name=$(basename "$source")
    link="skills/$name"
    if [ ! -L "$link" ]; then
      bad "Claude skill link 缺失: $name"
      skill_bad=$((skill_bad+1))
    elif [ "$(readlink "$link")" != "../../.agents/skills/$name" ]; then
      bad "Claude skill target 不符: $name"
      skill_bad=$((skill_bad+1))
    fi
  done < <(
    find "$shared_skills" -mindepth 1 -maxdepth 1 -type d \
      ! -path "$shared_skills/.claude" | LC_ALL=C sort
  )
  while IFS= read -r link; do
    [ -d "$shared_skills/$(basename "$link")" ] || {
      bad "Claude skill link 無 shared source: $link"
      skill_bad=$((skill_bad+1))
    }
  done < <(find skills -mindepth 1 -maxdepth 1 -type l | LC_ALL=C sort)
  [ "$skill_bad" -eq 0 ] && ok "Claude skill links 與 shared source exact"
fi

if rg -q '\.agents/(core|rules|hooks)(/|`|$)' CLAUDE.md settings.json; then
  bad "active config 仍引用 .agents control plane"
else
  ok "active config 的 .agents refs 僅限 skills"
fi

if rg -q '<!-- agents-routing:(begin|end)' CLAUDE.md; then
  bad "CLAUDE.md 仍受 routing stamp generator 管理"
else
  ok "CLAUDE.md routing 已由 Claude repo 擁有"
fi

if jq -e '
  .hooks.SessionStart[]?.hooks[]?
  | select(.command == "bash ~/.claude/hooks/drift-check.sh")
' settings.json >/dev/null; then
  ok "SessionStart 使用 Claude-local drift check"
else
  bad "SessionStart 未使用 Claude-local drift check"
fi

# ── 6. Matt thin kernel ────────────────────────────────────────
if [ "$(wc -c < CLAUDE.md | tr -d ' ')" -le 5000 ]; then
  ok "CLAUDE.md thin budget <= 5000B"
else
  bad "CLAUDE.md 超過 thin budget"
fi

if rg -q '^@~/.claude/core/tier0-safety\.md$' CLAUDE.md &&
   ! rg -q '^@~/.claude/core/tier[12]-' CLAUDE.md; then
  ok "只常駐載入 Claude-local tier0"
else
  bad "Claude core import 尚未 thin"
fi

for marker in dev-workflow S4 S5 S6 grilling domain-modeling implement tdd diagnosing-bugs code-review codebase-design; do
  rg -q "$marker" CLAUDE.md || bad "CLAUDE.md thin route 缺失: $marker"
done

if rg -q 'superpowers:|mp-(diagnose|grill-with-docs|improve-codebase-architecture|tdd)' CLAUDE.md; then
  bad "CLAUDE.md 仍引用 legacy workflow"
else
  ok "CLAUDE.md legacy workflow refs = 0"
fi

# superpowers 是刻意移除的（2026-08-02 確認）。原斷言要求 enabledPlugins 裡必須有一筆
# 明確的 false，但停用項目被 prune 掉之後 key 就不存在了——那是「更徹底的移除」，不是
# 退步，斷言卻報紅。真正要守的不變量是「沒有被重新啟用」：absent 與 false 都算數，只有
# true 才是退步。marketplace 仍註冊在 extraKnownMarketplaces，所以這條不能直接刪掉。
if jq -e '.enabledPlugins["superpowers@superpowers-marketplace"] != true' settings.json >/dev/null; then
  ok "Superpowers 未啟用（absent 或 false）"
else
  bad "Superpowers 已被重新啟用——應為 absent 或 false"
fi

if rg -q 'same-conversation.*`?/compact`?' templates/compact.md &&
   ! rg -q '跨 session|cross-session|handoff' templates/compact.md; then
  ok "compact template 只處理 same-conversation /compact"
else
  bad "compact template 與 cross-session handoff 語意重疊"
fi
if rg -q 'Same-conversation.*compact.*templates/compact\.md' CLAUDE.md &&
   rg -q 'Cross-session handoff.*`?/handoff`?' CLAUDE.md; then
  ok "CLAUDE.md 分流 /compact 與 /handoff"
else
  bad "CLAUDE.md 未分流 /compact 與 /handoff"
fi
# delegation 政策在 0ccbf98 改寫為「指向 shared [INT-4]，上界內自主判定」。原斷言比對的
# 是改寫前的「未由授權即不使用 subagent」，政策換掉後這條就永遠紅——斷言比它要守的東西
# 活得久，是這類文字比對測試的固定失效模式。
#
# 改為守新政策裡「被靜默拿掉也不會有人發現」的四個不變量：授權來源、無條件約束不因授權
# 放寬、兩個並行上界。少任一個，delegation 的實際行為就變了。
#
# 上界只比對子句不比對數字（'併發 ≤' 而非 '併發 ≤2'）：本檔的收錄判準是「會靜默失效的
# 才擋」。整個子句被拿掉是靜默的，把 ≤2 調成 ≤3 是擁有者的明示決定——寫死數字只會在
# 每次調參時製造假警報，換不到額外的鑑別力。
if rg -q 'Delegation 依 shared .*\[INT-4\]' CLAUDE.md &&
   rg -q '不因任何授權而放寬' CLAUDE.md &&
   rg -q '併發 ≤' CLAUDE.md &&
   rg -q '單階段累計 ≤' CLAUDE.md &&
   rg -q 'main context 重驗' CLAUDE.md &&
   rg -q 'code-review.*shared.*\[INT-4\]' CLAUDE.md; then
  ok "Claude delegation 授權與 shared INT-4 一致"
else
  bad "Claude delegation 與 shared INT-4 不一致——需含：依 shared [INT-4]、不因任何授權而放寬、併發上界、單階段累計上界、main context 重驗、code-review fan-out 依 shared [INT-4]"
fi

# CONVENTIONS 規則 11 的 host 一側。必須用 find 不得用 ls + glob：後者在 zsh 下任一
# 目錄無匹配即 nomatch 中止並回 0＝假合規（2026-07-30 實測同指令 zsh 回 0、bash 回 4）。
# dotfile 排除＝規則 11 的「app 自管 runtime state 備份」例外。
bak_list="$(find . -maxdepth 1 -name '*.bak*' -not -name '.*' 2>/dev/null | tr '\n' ' ')"
[ -z "$bak_list" ] &&
  ok "無手工 .bak（CONVENTIONS 規則 11）" ||
  bad "手工 .bak 殘留：$bak_list"

# hooks/drift-check.sh 若呼叫共用的 parity checker，必須先以 [ -x ] 守護——那支 helper
# 在 ~/.agents 未 clone 或該變更未 merge 時不存在，無守護會讓 SessionStart 噴錯。
# 這條放本 repo 而非 ~/.agents 的 test：drift-check.sh 是本 repo 擁有的檔（ownership 邊界）。
if grep -q 'bash "\$HOME/\.agents/bin/hook-parity-check"' hooks/drift-check.sh 2>/dev/null; then
  grep -q '\[ -x "\$HOME/\.agents/bin/hook-parity-check" \]' hooks/drift-check.sh &&
    ok "parity checker 呼叫有 [ -x ] 守護" ||
    bad "parity checker 呼叫缺 [ -x ] 守護——helper 缺檔時 SessionStart 會噴錯"
fi

printf '\n%d PASS / %d FAIL\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
