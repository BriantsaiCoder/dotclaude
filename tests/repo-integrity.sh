#!/usr/bin/env bash
#
# repo-integrity.sh — ~/.claude 的機械守衛（P3-8）
#
# 為什麼是這七項：每一項都對應一種「壞掉但不會有錯誤訊息」的失效模式。
# 會噴錯的東西不需要 CI 擋，會靜默失效的才需要。編號與內文 section 一一對應。
#
#   1. JSON 解析     settings.json 壞掉時整份被靜默忽略，不是報錯
#   2. skill symlink 斷鏈或指錯位置會讓共用 skill 靜默換掉或消失
#   3. agent 定義    frontmatter 有 name 但缺 description 的檔案永遠不會載入
#   4. shellcheck    hook 是 PreToolUse 攔截器，語法錯等於防線失效
#   5. ownership     非 skill config 不可重新連回 ~/.agents control plane
#   6. thin kernel   CLAUDE.md 的 budget／route／授權政策漂移不會有人察覺
#   7. hook 行為     阻擋型 hook 讀不懂 payload 時放行，是無聲失去防線
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

if jq -e '.enabledPlugins["superpowers@superpowers-marketplace"] == false' settings.json >/dev/null; then
  ok "Superpowers registration 在 candidate 明確 disabled"
else
  bad "Superpowers registration 尚未 disabled"
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

# ── 7. 阻擋型 hook fail-closed ─────────────────────────────────
#
#
# 這是行為檢查不是語法檢查：guard-cookbook-orphan.sh 的語法一直是對的，但解析器缺席
# 或 payload 非法時 file_path 變空字串，而空字串直接 exit 0——守衛對整個缺 python3
# 的環境靜默失效。2026-08-02 稽核實測 rc=0（放行）；同型缺陷同日在 ~/.agents 的
# protect-files.sh 也找到（agents-config PR #37）。
#
# 符合本檔的收錄判準：會噴錯的東西不需要 CI 擋，這種靜默失效才需要。
cookbook_guard=hooks/guard-cookbook-orphan.sh
if [ ! -f "$cookbook_guard" ]; then
  ok "cookbook 守衛不存在，略過 fail-closed 檢查"
else
  # 印 "rc:reason" 或 "rc:silent"。只斷言 exit code 不夠：把守衛的 `cat >&2` 換成
  # `: <<EOF`（拒絕但不說原因）時三條斷言仍會全綠，而使用者只會看到 Claude 無聲拒工。
  # 拒絕必須附理由，這是斷言的一部分。
  _cb_probe() {  # $1=PATH $2=payload
    _cb_err=$(printf '%s' "$2" | env PATH="$1" HOME="$HOME" bash "$cookbook_guard" 2>&1 >/dev/null)
    _cb_rc=$?
    [ -n "$_cb_err" ] && printf '%s:reason\n' "$_cb_rc" || printf '%s:silent\n' "$_cb_rc"
  }
  # mktemp 失敗不能 exit——那會跳過下面的總結與「至少跑到了」自證，讓整份測試靜默短路。
  _nopy=$(mktemp -d) || _nopy=""
  _cb_dir=$(mktemp -d) || _cb_dir=""
  if [ -z "$_nopy" ] || [ -z "$_cb_dir" ]; then
    bad "cookbook 守衛：無法建立暫存目錄，fail-closed 檢查未執行"
    [ -n "$_nopy" ] && rm -rf "$_nopy"
    [ -n "$_cb_dir" ] && rm -rf "$_cb_dir"
  else
  for _t in bash cat basename mktemp env printf; do
    _p=$(command -v "$_t" 2>/dev/null) && ln -sf "$_p" "$_nopy/$_t"
  done
  mkdir -p "$_cb_dir/docs/cookbook"
  _cb_payload="$(printf '{"tool_input":{"file_path":"%s/docs/cookbook/n.md"}}' "$_cb_dir")"

  _rc_nopy=$(_cb_probe "$_nopy" "$_cb_payload")
  _rc_badjson=$(_cb_probe "$PATH" '{"tool_input":{"file_path":"docs/cookbook/n.md"')
  # 守備範圍：解析失敗時只能擋提到 docs/cookbook 的請求。少了這條，把守衛寫成
  # 「解析失敗一律 exit 2」也會讓上面兩條全綠，代價是缺 python3 的環境什麼都寫不了。
  _rc_offscope=$(_cb_probe "$_nopy" '{"tool_input":{"file_path":"/tmp/x/README.txt"}}')
  # positive control：正常路徑仍須能區分 block 與 allow，否則上面幾條不具鑑別力
  _rc_block=$(_cb_probe "$PATH" "$_cb_payload")
  printf '# MOC\n' > "$_cb_dir/docs/cookbook/MOC.md"
  _rc_allow=$(_cb_probe "$PATH" "$_cb_payload")
  rm -rf "$_nopy" "$_cb_dir"

  [ "$_rc_nopy" = 2:reason ] &&
    ok "cookbook 守衛：解析器缺席時 fail-closed 並附理由" ||
    bad "cookbook 守衛：解析器缺席時未帶理由拒絕（${_rc_nopy}，應 2:reason）——守衛靜默失效"
  [ "$_rc_badjson" = 2:reason ] &&
    ok "cookbook 守衛：payload 非法時 fail-closed 並附理由" ||
    bad "cookbook 守衛：payload 非法時未帶理由拒絕（${_rc_badjson}，應 2:reason）"
  [ "$_rc_offscope" = 0:silent ] &&
    ok "cookbook 守衛：解析失敗但與 cookbook 無關的檔案仍放行" ||
    bad "cookbook 守衛：過度阻擋（${_rc_offscope}，應 0:silent）——缺 python3 時任何檔案都寫不了"
  { [ "$_rc_block" = 2:reason ] && [ "$_rc_allow" = 0:silent ]; } &&
    ok "cookbook 守衛：正常路徑仍能區分 block/allow" ||
    bad "cookbook 守衛：正常路徑失準（無 MOC ${_rc_block} 應 2:reason、有 MOC ${_rc_allow} 應 0:silent）"
  fi
fi

printf '\n%d PASS / %d FAIL\n' "$pass" "$fail"
# 「至少跑到了」自證：所有檢查都提前 return 時上面會印 0 PASS / 0 FAIL 卻 exit 0，
# 那是本測試自己的 fail-open（同 agents-config PR #32 的處置）。
[ "$pass" -gt 0 ] || { printf 'FAIL  沒有任何檢查執行成功\n'; exit 1; }
[ "$fail" -eq 0 ]
