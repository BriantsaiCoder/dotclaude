#!/usr/bin/env bash
#
# repo-integrity.sh — ~/.claude 的機械守衛（P3-8）
#
# 為什麼是這九項：每一項都對應一種「壞掉但不會有錯誤訊息」的失效模式。
# 會噴錯的東西不需要 CI 擋，會靜默失效的才需要。編號與內文 section 一一對應。
#
#   1. JSON 解析     settings.json 壞掉時整份被靜默忽略，不是報錯
#   2. skill symlink 斷鏈或指錯位置會讓共用 skill 靜默換掉或消失
#   3. agent 定義    frontmatter 有 name 但缺 description 的檔案永遠不會載入
#   4. shellcheck    hook 是 PreToolUse 攔截器，語法錯等於防線失效
#   5. ownership     非 skill config 不可重新連回 ~/.agents control plane
#   6. thin kernel   CLAUDE.md 的 budget／route／授權政策漂移不會有人察覺
#   7. hook 行為     阻擋型 hook 讀不懂 payload 時放行，是無聲失去防線
#   8. 變數名邊界   `$var` 緊接全形字元被吃進變數名，shellcheck 各級別都不報
#   9. Opus 5 設定   autonomy／audit／permission／effort 漂移不會主動報錯
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

  # ultracode 曾與 workflowSizeGuideline 一起釘在這裡當成本閘門，2026-08-06 移除：它是使用者
  # 可經 /config 或 prompt 逐次開關的偏好，開了之後 Claude Code 會寫回 settings.json，於是每次
  # 調整都變成 CI 紅燈。workflowSizeGuideline 留著——那個鍵不會被互動操作自動寫回，釘死不會誤傷。
  # 代價講明：ultracode 被調開不再有任何警告，成本控制改由 /config 與使用者自己把關。
  if jq -e '
    ((has("workflowSizeGuideline") | not) or .workflowSizeGuideline == "unrestricted") and
    (.enabledPlugins["context7@claude-plugins-official"] == true) and
    (.permissions.allow | index("mcp__plugin_context7_context7__resolve-library-id") != null) and
    (.permissions.allow | index("mcp__plugin_context7_context7__query-docs") != null) and
    (.permissions.allow | index("mcp__plugin_context7_context7__*") == null)
  ' settings.json >/dev/null; then
    ok "Context7 只預先核准兩個 read-only tools"
  else
    bad "Context7 plugin 必須 enabled 且 permission 為兩個 exact tools；workflowSizeGuideline 須 unrestricted／unset"
  fi
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

# [S5-3]（~/.agents/skills/dev-workflow/SKILL.md）要求 house over-engineering baseline 兩條
# 逐字進「每一個」reviewer prompt，含 host-local review agent。2026-08-03 之前零測試守它，
# 同日 reviewer-template.md 被編輯注入 [S5-4] 時這兩條仍被漏掉——單純是注意力都在 S5-4，
# 沒有機械守衛擋。規則沒有守衛就會在下一次編輯再漏一次。
#
# closed-world set 而非 pattern 過濾：檔名 glob 兩頭都會出錯——`*code*` 會把 `Decoder.md`
# 這種偶然含 "code" 的檔掃進來（吵，但 fail-closed），更糟的是 `security-reviewer.md`、
# `csharp-reviewer.md` 這類真 code reviewer 完全掃不到（靜默 fail-open，正是本條要修的
# 失效型態換位置重現）。frontmatter 的 name／description 更糟：description 是 trigger
# routing 面，會為了 invocation accuracy 被調整，把 correctness gate 綁上去等於改一次
# description 就靜默換掉守備範圍。改為列舉必須帶規則的檔案集，發現集不符即 FAIL——新增
# 或改名 review agent 時測試會強迫你回來更新這份清單。
#
# uiux-reviewer 刻意不在集合內：它審渲染後的頁面（視覺層級、可讀性、操作直覺），「手刻
# 標準庫」與「多餘依賴」是 code 層判斷，超出其職權。註記：[S5-3] 條文寫「不論 reviewer
# 型別…皆適用」，本排除是測試側的收窄，尚未反映進條文本身——待 kernel 側裁決。
#
# 比對兩條的「全文」而非只比英文 label：[S5-3] 驗證條款寫的是「含該兩條全文」，只放
# `Reinvented Stdlib` 六個字的 stub 會過。與 ~/.agents/tests/mattpocock-workflow.sh 的
# 同名斷言強度對齊。
S53_AGENTS='agents/code-reviewer.md agents/DotNet-Code-Reviewer.md'
S53_EXEMPT='agents/uiux-reviewer.md'
actual_agents="$(git ls-files 'agents/*.md' | LC_ALL=C sort | tr '\n' ' ')"
expected_agents="$(printf '%s %s' "$S53_AGENTS" "$S53_EXEMPT" | tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort | tr '\n' ' ')"
if [ "$actual_agents" = "$expected_agents" ]; then
  ok "agents/ 清單與 [S5-3] 分類一致"
else
  bad "agents/ 清單已變動，[S5-3] 分類需更新：實際=[$actual_agents] 已分類=[$expected_agents]"
fi
# 2026-08-08：[S5-3] 的 baseline 由兩條擴為五條。這裡同步擴充——host-local agent 由本
# repo 自檢，~/.agents 的斷言跨 repo 抓不到，不擴的話新三條在這兩支上零守衛，而那正是
# 上面整段註解在講的失效型態。
#
# 五條都放整行 bullet 原文，不只放動作句：只釘 `→` 之後那半句時，把 label 換成隨便的字、
# 或把定義文字整段刪掉，守衛照樣回報「含五條全文」PASS（2026-08-08 實測）——那正是上面
# 118-120 行寫「只放 `Reinvented Stdlib` 六個字的 stub 會過」要擋的事，stub 只是換到另
# 一半而已。整行比對順帶釘住兩支之間的逐字一致。
S53_RULES=(
  '- **Reinvented Stdlib** — 手刻標準庫或平台已提供的功能 → 指名該 API 取代。'
  '- **Redundant Dependency** — 為平台／既有模組已有的能力新增依賴 → 依選型階梯（原生 > 標準庫 > 既有模組 > 第三方 > 手寫）回退。'
  '- **Unused Local Reuse** — 這個 repo 裡已經有的 helper／type／pattern 被重寫一份。與「同一 diff 內重複」不同，這條看的是 diff 對**既有資產**的重複 → 指名既有符號並改呼叫它。'
  '- **Needless Indirection** — 單一使用點的抽象層、只做轉發的中間層、或為 spec 沒有的需求預留的參數與 hook → 內聯回去，等真的第二個使用點出現再抽。'
  '- **Wrong Altitude** — 抽象層級錯置：實作細節洩漏進高層介面，或高層策略埋進低層工具 → 把該決策移回它該在的層。'
)
for f in $S53_AGENTS; do
  if [ ! -f "$f" ]; then
    bad "[S5-3] 分類指向不存在的 agent: $f"
    continue
  fi
  s53_missing=0
  for rule in "${S53_RULES[@]}"; do
    # `-e` 不可省：pattern 是整行 bullet、以 `-` 開頭，沒有 `-e` 時 grep 會把它當選項。
    grep -Fq -e "$rule" "$f" || s53_missing=$((s53_missing + 1))
  done
  if [ "$s53_missing" -eq 0 ]; then
    ok "code review agent 含 [S5-3] baseline 五條全文: $f"
  else
    bad "code review agent 缺 [S5-3] over-engineering baseline $s53_missing 條全文: $f"
  fi
done

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

# 結構性 marker 留在 CLAUDE.md：它們是 host adapter 自己的骨架，不是 shared method。
for marker in dev-workflow S4 S6 code-review; do
  rg -q "$marker" CLAUDE.md || bad "CLAUDE.md thin route 缺失: $marker"
done

# routing 明細的正本在 shared kernel 的 S0 ROUTE 表；CLAUDE.md 只留指標（見上方 thin 要求）。
# 在這裡查 CLAUDE.md 會反過來強制它複述 kernel，與 thin 要求互相矛盾。
# CI 沒有 ~/.agents，kernel 缺席時改驗指標仍在——指標斷掉才是會靜默失效的那一種。
kernel="$HOME/.agents/skills/dev-workflow/SKILL.md"
if [ -r "$kernel" ]; then
  for marker in grilling domain-modeling implement tdd diagnosing-bugs codebase-design; do
    rg -q "$marker" "$kernel" || bad "dev-workflow kernel routing 缺失: $marker"
  done
  ok "dev-workflow kernel 持有 routing 明細"
elif rg -q 'skills/dev-workflow/SKILL\.md' CLAUDE.md; then
  ok "kernel 不在此環境；CLAUDE.md 仍持有 dev-workflow 指標"
else
  bad "kernel 不在此環境且 CLAUDE.md 缺 dev-workflow 指標（routing 完全斷鏈）"
fi

if rg -q 'superpowers:|mp-(diagnose|grill-with-docs|improve-codebase-architecture|tdd)' CLAUDE.md; then
  bad "CLAUDE.md 仍引用 legacy workflow"
else
  ok "CLAUDE.md legacy workflow refs = 0"
fi

if ! rg -q '<tone_preference>' CLAUDE.md; then
  ok "CLAUDE.md 無重複 tone block"
else
  bad "CLAUDE.md 仍含重複 tone block"
fi

if rg -q '^確信：高 / 中 / 低$' agents/uiux-reviewer.md &&
   rg -q '^處置：一定要修 / 修了更好$' agents/uiux-reviewer.md &&
   rg -q '^群組：' agents/uiux-reviewer.md &&
   rg -q '確信：高.*(直接觀察|可重現)' agents/uiux-reviewer.md &&
   ! rg -q '確信：高.*使用者一定會遇到' agents/uiux-reviewer.md; then
  ok "uiux-reviewer 分離 severity、confidence 與完整輸出 schema"
else
  bad "uiux-reviewer confidence 語意或輸出 schema 不完整"
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
# host adapter 只保留 shared rule ID 與 host-facing 行為；安全不變量由 shared kernel/test 擁有。
if grep -Fqx -- '- Delegation：依 shared `dev-workflow` [INT-4] 由 AI 自主判定，無須另問。' CLAUDE.md; then
  ok "Claude delegation 保持 thin 並指向 shared INT-4"
else
  bad "Claude delegation adapter 必須只保留 shared [INT-4]、AI 自主判定與無須另問"
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
  #
  # template 不可省（本檔七處皆同）：macOS 的 mktemp 在沒有 template 時走
  # confstr(_CS_DARWIN_USER_TEMP_DIR)（/var/folders/…/T/）而**忽略 $TMPDIR**，於是在
  # 只放行 $TMPDIR 的 sandbox 下七處全部 mkdtemp 失敗。fail-closed 分支會照實報，
  # 但整份測試因此產出 16 個假 FAIL（2026-08-08 實測），等於在 sandbox 內不可用——
  # 而「在 sandbox 內跑不動」會直接讓自動化執行點無法採用這支測試。
  _nopy=$(mktemp -d "${TMPDIR:-/tmp}/repo-integrity.XXXXXX") || _nopy=""
  _cb_dir=$(mktemp -d "${TMPDIR:-/tmp}/repo-integrity.XXXXXX") || _cb_dir=""
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

# ── 8. shell 變數名後緊接非 ASCII ──────────────────────────────
#
# `$var` 後面直接接全形字元時，bash 把後續 byte 一起吃進變數名。本 repo 訊息幾乎全是
# zh-TW，`$var` 後面直接接 `）` `。` `，` 是高頻寫法，而 shellcheck 各級別都不報。
# （本註解刻意不寫出連在一起的字面形式——那會被下面的實掃抓到，而豁免註解等於挖洞。）
#
# 兩種失效方向，都不會有錯誤訊息指向真正的原因：
#   有 set -u  → unbound variable 中止，後續檢查完全不執行（pre-commit-claude.sh:47
#                在 cafd8ab 之前就是這樣：黑名單命中時整支 hook 死掉，同檔的明文
#                secret 掃描從來沒跑過）
#   無 set -u  → 變數展開成空字串，診斷訊息把值吞掉（watch-ci-after-push.sh 的
#                訊息把 `$GATE` 緊接句號，實際印出「找不到可執行的 」，路徑不見）
#
# 兩種都只在失敗分支發作，正常路徑永遠測不到——所以必須是機械守護而非人工複查。
# 2026-08-02 本 session 共踩 9 次。agents-config 的 tests/conformance.sh 有同型守護，
# 那邊寫死掃描目錄因而漏過 skills/ 21 支；這裡改掃第 4 項已在用的檔案集（追蹤中的
# 非 symlink .sh），新增檔案自動納入。
VARNAME_PAT='\$[a-zA-Z_][a-zA-Z0-9_]*\P{ASCII}'
if ! command -v rg >/dev/null 2>&1; then
  bad "shell 變數名檢查需要 rg，但 rg 不可用（缺工具的失敗方向是假綠）"
else
  # rg 的三種退出碼必須分開處理：0=有命中、1=無命中、≥2=真錯誤。實測 rc=2 涵蓋
  # 「檔案不可讀」「路徑不存在」「PCRE pattern 失效」三種，而 `rg … || echo 0` 會把
  # 它們全部算成「0 處命中」，與乾淨檔無法區分——一條專門防 fail-open 的守護自己
  # fail-open。掃描失敗必須報紅，不得冒充通過。
  # `--count-matches` 而非 `-c`：後者數的是「命中的行數」，但下面的訊息以「N 處」
  # 回報 occurrence，同一行有兩個 `$var` 時會低估（Copilot 於 PR #4 指出）。改用
  # --count-matches 後數字語意與訊息一致。不影響 pass/fail——判準是「有無命中」。
  _vn_scan() {  # $1=檔案 → 印 "hits:<n>" 或 "err:<rc>"，n 為 occurrence 數
    local _out _rc
    _out="$(rg --count-matches -P "$VARNAME_PAT" "$1" 2>/dev/null)"; _rc=$?
    case "$_rc" in
      0) printf 'hits:%s\n' "$_out" ;;
      1) printf 'hits:0\n' ;;
      *) printf 'err:%s\n' "$_rc" ;;
    esac
  }

  # canary：pattern 寫壞就永遠是綠的。與實掃共用同一個 VARNAME_PAT 與 _vn_scan，
  # 改壞任一邊這裡先紅。三態都驗——正向抓得到、反向不誤報、掃描失敗會被辨識為錯誤
  # （用不存在的路徑當錯誤 fixture，比 chmod 000 穩定且不受執行身分影響）。
  # fixture 放 mktemp 不放 repo 內，否則會被下面的實掃掃到；全形字元用 printf octal
  # 組出來不寫字面，同理。
  canary_dir="$(mktemp -d "${TMPDIR:-/tmp}/repo-integrity.XXXXXX")" || canary_dir=""
  if [ -z "$canary_dir" ]; then
    bad "shell 變數名 pattern canary 無法建立 fixture"
  else
    fw="$(printf '\357\274\211')"
    printf 'echo "x$v%sy"\n' "$fw" > "$canary_dir/bad.sh"
    printf 'echo "x${v}%sy"\n' "$fw" > "$canary_dir/good.sh"
    canary_bad="$(_vn_scan "$canary_dir/bad.sh")"
    canary_good="$(_vn_scan "$canary_dir/good.sh")"
    canary_err="$(_vn_scan "$canary_dir/nosuch.sh")"
    rm -rf "$canary_dir"
    if [ "$canary_bad" = hits:1 ] && [ "$canary_good" = hits:0 ] &&
       [ "${canary_err%%:*}" = err ]; then
      ok "shell 變數名 pattern canary（正向／反向／掃描錯誤三態）"
    else
      bad "shell 變數名 pattern canary 失效（bad=${canary_bad} 應 hits:1、good=${canary_good} 應 hits:0、err=${canary_err} 應 err:*）"
    fi
  fi

  varname_hits=0; varname_files=0; varname_err=0
  while IFS= read -r f; do
    [ -L "$f" ] && continue
    varname_files=$((varname_files+1))
    r="$(_vn_scan "$f")"
    case "$r" in
      hits:0) ;;
      hits:*) varname_hits=$((varname_hits + ${r#hits:}))
              bad "shell 變數名後緊接非 ASCII: ${f}（${r#hits:} 處，須改 \${var}）" ;;
      *)      varname_err=$((varname_err+1))
              bad "shell 變數名檢查無法掃描 ${f}（rg ${r}）——不當作通過" ;;
    esac
  done < <(git ls-files '*.sh')
  # 掃到 0 個檔案時上面的迴圈不會 bad，摘要卻會顯示通過——那是假綠
  if [ "$varname_files" -eq 0 ]; then
    bad "shell 變數名檢查沒有掃到任何檔案（git ls-files '*.sh' 為空）"
  elif [ "$varname_hits" -eq 0 ] && [ "$varname_err" -eq 0 ]; then
    ok "shell 變數名後未緊接非 ASCII: ${varname_files} 個 .sh 全數通過"
  fi
fi

# ── 9. Opus 5 autonomy / audit metadata / permission regressions ─────────────
tier0_rule_has() {
  local rule="$1" line needle
  shift
  line="$(grep -E "^\\[T0-${rule}\\]" core/tier0-safety.md)"
  [ "$(printf '%s\n' "$line" | grep -c .)" -eq 1 ] || return 1
  for needle in "$@"; do
    [[ "$line" == *"$needle"* ]] || return 1
  done
}

if tier0_rule_has 1 \
  'Action／current-state claim 涉及 path／API／config key 時 MUST 有 live evidence' \
  '實際修改／執行 target 仍須 live probe' \
  '觸發：前述 action／claim' \
  '例外：non-action citation／hypothetical' \
  '驗證：read／list／schema probe 或例外標記'; then
  ok "[T0-1] 只對 action/current-state 與實際 target 要求 live evidence"
else
  bad "[T0-1] 缺 action boundary、non-action/hypothetical 例外或 target live probe"
fi

if tier0_rule_has 5 \
  'Material ambiguity MUST 停下發問並列假設／影響' \
  '低風險可逆細節採 sensible default 並明示' \
  '觸發：多種合理解讀會改變 outcome／scope／risk' \
  '例外：低風險、可逆、無 material impact' \
  '驗證：改檔前有澄清或 default／impact 紀錄'; then
  ok "[T0-5] 只有 material ambiguity 停問；低風險可逆細節可自主"
else
  bad "[T0-5] 仍是 blanket ambiguity gate 或缺 sensible-default 邊界"
fi

if tier0_rule_has 7 \
  'Online DB migration with compatibility／destructive risk MUST expand→dual-write→backfill→switch-reads→remove-legacy' \
  'destructive schema 不與舊 consumer 同 deploy' \
  '觸發：schema／data-contract risk' \
  '例外：additive／new-object 或停機 batch 可標不適用階段 `SKIPPED`（理由）' \
  '驗證：plan 列 phases／consumer boundary／[T0-6] rollback'; then
  ok "[T0-7] 完整 migration phases 限 online compatibility/destructive risk"
else
  bad "[T0-7] 仍對所有 schema change 強制完整 phases 或缺 SKIPPED boundary"
fi

if tier0_rule_has 8 \
  'plan-first' \
  '架構性' \
  'High-risk' \
  'external write' \
  'destructive／costly／credential／payment／deployment／migration' \
  'material scope expansion' \
  'in-scope、local、reversible' \
  'Low／Medium-risk' \
  'session plan' \
  '不需第二次確認' \
  '觸發：將改檔或執行 side effect 且命中前述 protected gate' \
  '例外：無' \
  '驗證：protected gate 有 plan + 核准原句'; then
  ok "[T0-8] Medium local reversible 工作不因 risk tier 再次等待確認"
else
  bad "[T0-8] 缺 Medium autonomy 或 High/protected stop boundary"
fi

if tier0_rule_has 9 \
  'current HEAD 有 applicable CI PASS' \
  '0 unresolved actionable findings' \
  'bot UNAVAILABLE' \
  'shared dev-workflow 的 review-triage' \
  'independent read-only reviewer fallback' \
  '觸發：merge' \
  '例外：無' \
  '驗證：current-head CI + review gate PASS'; then
  ok "[T0-9] merge gate 保留 current-head CI/findings outcome 並允許 bot-unavailable fallback"
else
  bad "[T0-9] 缺 current-head outcome 或 bot UNAVAILABLE independent-review fallback"
fi

if rg -q 'push／open PR／merge／final closeout.*\[T0-9\].*review-triage' CLAUDE.md; then
  ok "Claude S6 只引用 [T0-9]/review-triage，不另加 blanket bot gate"
else
  bad "Claude S6 未指向 [T0-9]/review-triage"
fi

if grep -Fqx 'set -ufo pipefail' hooks/guard-git-push.sh; then
  ok "git push guard 啟用 pipefail"
else
  bad "git push guard 缺 pipefail，pipeline error 可能被後段命令遮蔽"
fi

push_probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/repo-integrity.XXXXXX")" || push_probe_dir=""
# 上面的 subshell 會 cd 走，相對路徑會失效
_guard_push_abs="$PWD/hooks/guard-git-push.sh"
_push_probe() { # $1=allow|deny $2=command [$3=執行時的 cwd，預設 repo root]
  local want="$1" cmd="$2" run_cwd="${3:-$PWD}" rc actual label=""
  [ -n "$push_probe_dir" ] ||
    { bad "git push guard 無法建立輸出檢查目錄"; return; }
  [ "$run_cwd" = "$PWD" ] || label="（唯讀 cwd）"
  if jq -nc --arg command "$cmd" '{tool_input:{command:$command},cwd:"."}' |
    ( cd "$run_cwd" && bash "$_guard_push_abs" --format=claude ) \
      >"$push_probe_dir/stdout" 2>"$push_probe_dir/stderr"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 0 ] && [ ! -s "$push_probe_dir/stdout" ] &&
    [ ! -s "$push_probe_dir/stderr" ]; then
    actual=allow
  elif [ "$rc" -eq 2 ] && [ ! -s "$push_probe_dir/stdout" ] &&
    [ -s "$push_probe_dir/stderr" ] &&
    jq -se '
      length == 1 and
      .[0].decision == "block" and
      (.[0].reason | type == "string" and length > 0)
    ' "$push_probe_dir/stderr" >/dev/null 2>&1; then
    actual=deny
  elif [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then
    actual=BADOUTPUT
  else
    actual="BADEXIT($rc)"
  fi
  if [ "$actual" = "$want" ]; then
    ok "git push guard ${want}${label}: $cmd"
  else
    bad "git push guard want=$want got=$actual rc=${rc}${label}: $cmd"
  fi
}
_push_probe allow 'git push --all origin'
_push_probe allow 'git push --multiple origin backup'
_push_probe deny  'git push --force --all origin'
_push_probe deny  '{git,push,--force,origin,main}'
_push_probe deny  '"C:\Program Files\Git\bin\git.exe" push --force origin main'
_push_probe deny  '"C:\Program Files\Git\bin\GIT.EXE" push --force origin main'
_push_probe deny  '"C:\Program Files\Git\bin\GIT.EXE" p\ush --for\ce origin main'
_push_probe deny  'GIT push --force origin main'
_push_probe allow 'legit.exe push --force origin main'
_push_probe deny  'git push --force-with-lease --all origin'
_push_probe deny  'git push --mirror origin'

# ── 守衛不得依賴暫存檔 redirect（2026-08-08，dotclaude PR #21 review）──────────
#
# 缺陷：macOS 的 bash 3.2 把 here-doc／here-string 的暫存檔放在 /tmp（忽略 TMPDIR），
# /tmp 不可寫時才退回 cwd。兩者皆不可寫時 redirect 失敗——守衛的切詞陣列留空、掃描
# 迴圈一次都不跑、落到檔尾 exit 0＝放行。實測 sandbox 內（/tmp 被擋、本 repo 唯讀）
# 同一個 force-push payload 由 rc=2 變成 rc=0，且無聲。
#
# 這條刻意是**靜態**斷言：行為測試在一般環境重現不了（/tmp 可寫時缺陷不發作，chmod
# 一個 cwd 也擋不住），寫成行為案例就會在 CI 上恆綠——那正是本檔要抓的假綠形狀。
# 靜態斷言則到哪都成立：只要切詞路徑重新出現 here-doc／here-string 就紅。
#
# 只掃非註解行：本 repo 的守衛註解本身會提到這些字元，掃進去會恆紅。
#
# pattern 不對 delimiter 的字元集合做任何假設。第一版寫成 `.?[A-Za-z_]`，漏掉
# delimiter 以數字開頭的 `<<1` 與 `<<'1'`；第二版改成 `[^=[:space:]]`，又漏掉
# `<<=EOF` 與 `<< =`（兩者都是合法 here-doc）。兩次都是可繞過的守衛
# （2026-08-08 agents-config #71／dotclaude #23 review 指出並實測確認）。
# 不排除任何 delimiter 字元，連 `=` 也不排除。第一版寫成 `[^=[:space:]]`，理由是避開
# 算術左移 `$((a <<= 2))` 的誤報——那是錯的：shell 沒有 `<<=` 這個 redirect 運算子，
# `cmd <<=EOF` 是 delimiter 為 `=EOF` 的**合法 here-doc**（實測 `read -r -a arr <<=EOF`
# 確實填滿陣列），`cmd << =` 同理。為了少一個誤報而在安全斷言上開一個可用的繞過口，
# 方向剛好相反。誤報是噪音，繞過是靜默失去防線。
# 代價是算術左移會誤報；守備的是安全閘。
_no_tempfile_redirect() { # $1=守衛檔
  local hits
  # 檔名前的 `--` 不可省：路徑以 `-` 開頭時 grep 會當成 option，輸出自己的說明而非
  # 守衛內容，hits 為空 → 靜態斷言靜默通過（2026-08-08 agents-config #71 review）。
  # 本檔的呼叫端是字面清單、不由環境覆寫，但同一形狀不留兩種寫法。
  # grep 的 rc 必須分辨（rc>=2 是錯誤，不是「無命中」），且兩個 grep 要拆開跑：
  # pipefail 回的是最右的非零狀態，第一個 grep 的 rc=2 會被第二個的 rc=1 遮掉，
  # 於是「讀不到」被當成「乾淨」（2026-08-08 agents-config #71 review 實測確認）。
  local src="" rc=0 hits_rc=0
  hits=""
  src="$(grep -vE '^[[:space:]]*#' -- "$1")" || rc=$?
  if [ "$rc" -ge 2 ]; then
    bad "靜態掃描讀不到守衛內容（grep rc=${rc}）: $1"
    return
  fi
  hits="$(printf '%s\n' "$src" | grep -E '<<-?[[:space:]]*[^[:space:]]')" || hits_rc=$?
  if [ "$hits_rc" -ge 2 ]; then
    bad "靜態掃描自身失敗（grep rc=${hits_rc}）: $1"
  elif [ -z "$hits" ]; then
    ok "守衛不依賴暫存檔 redirect: $1"
  else
    printf '%s\n' "$hits" | head -3
    bad "守衛仍有 here-doc／here-string（上列），/tmp 與 cwd 皆不可寫時會 fail-open: $1"
  fi
}
# 2026-08-26 補入 pre-commit-claude.sh：它同樣是阻擋型 gate、同樣受此缺陷影響，卻不在
# 原清單內——所以三個 here-string 在這條斷言鎖死同一缺陷 18 天後仍然存活。判準因此從
# 「host 註冊的 PreToolUse 攔截器」放寬為「阻擋型 gate」。實測：把修前的版本餵給本函式
# 會命中三行並報紅，修後 PASS，鑑別力完整。
for _g in hooks/guard-git-push.sh hooks/guard-pr-merge.sh hooks/guard-cookbook-orphan.sh hooks/guard-s5-ledger.sh hooks/pre-commit-claude.sh; do
  [ -f "$_g" ] && _no_tempfile_redirect "$_g"
done

# guard-pr-merge 的行為覆蓋（同一次 review 指出本檔完全沒有）。
#
# 不另寫 payload 案例：該守衛自帶 --selftest，用假 PR_REVIEW_GATE 把每個 STATE 對到
# 明確的放行／拒絕。缺的從來不是測試，是沒有人呼叫它——接線比重寫一份會漂移的副本
# 便宜，也不會有兩份對不上的期望值。
if [ -f hooks/guard-pr-merge.sh ]; then
  if _prm_out=$(bash hooks/guard-pr-merge.sh --selftest 2>&1); then
    ok "pr-merge 守衛 selftest: $(printf '%s' "$_prm_out" | tail -1)"
  else
    printf '%s\n' "$_prm_out" | tail -5
    bad "pr-merge 守衛 selftest 失敗（上列為輸出末段）"
  fi
fi

# guard-s5-ledger 同理：它自帶 selftest（含 SIGPIPE 競態回歸），但註冊上線時沒有
# 任何東西呼叫它。這支的失效模式是靜默 fail-open——PreToolUse 只有 exit 2 阻擋，任何
# 意外的 exit 1 都等於放行——沒接線就沒有東西會發現它退化。
# 不寫案數：這行原本寫「18 案」，之後每加一批就漂一次，光這輪就漂了兩回。案數由
# `grep -c '^  run_case '` 現查即得，寫進註解只是替未來製造 doc rot。
if [ -f hooks/guard-s5-ledger.sh ]; then
  if _s5l_out=$(bash hooks/guard-s5-ledger.sh --selftest 2>&1); then
    ok "s5-ledger 守衛 selftest: $(printf '%s' "$_s5l_out" | tail -1)"
  else
    printf '%s\n' "$_s5l_out" | tail -5
    bad "s5-ledger 守衛 selftest 失敗（上列為輸出末段）"
  fi
fi

# 行為案例只在條件真的成立時才跑：/tmp 可寫就重現不了，標 SKIP 而不是給一個
# 沒有意義的綠。sandbox 內 /tmp 被擋，這兩條才有鑑別力。
if [ -n "$push_probe_dir" ]; then
  # 用 mktemp 而非固定檔名：固定名有 symlink／hardlink 風險，root 執行時可能誤覆寫
  # 任意檔案。帶目錄的 template 而非 `mktemp -p`——後者語意在 BSD 與 GNU 之間有過差異。
  if _tmp_probe="$(mktemp /tmp/repo-integrity-tmpwrite.XXXXXX 2>/dev/null)"; then
    rm -f "$_tmp_probe"
    printf '  SKIP  唯讀 cwd 行為案例：/tmp 可寫，此環境重現不了 here-doc fallback\n'
  else
    _ro_cwd="$push_probe_dir/readonly-cwd"
    mkdir -p "$_ro_cwd" && chmod 500 "$_ro_cwd"
    if ( cd "$_ro_cwd" && : > .probe-write ) 2>/dev/null; then
      rm -f "$_ro_cwd/.probe-write"
      printf '  SKIP  唯讀 cwd 行為案例：chmod 500 仍可寫（root？），條件建不起來\n'
    else
      _push_probe deny  'git push --force origin main' "$_ro_cwd"
      _push_probe allow 'git push origin feat/safe'    "$_ro_cwd"
    fi
    chmod 700 "$_ro_cwd" 2>/dev/null || true
  fi
fi

[ -z "$push_probe_dir" ] || rm -rf "$push_probe_dir"

audit_home="$(mktemp -d "${TMPDIR:-/tmp}/repo-integrity.XXXXXX")" || audit_home=""
if [ -z "$audit_home" ]; then
  bad "Bash audit metadata canary 無法建立 temp HOME"
else
  mkdir -p "$audit_home/.claude"
  legacy_log="$audit_home/.claude/audit-bash.log"
  printf 'legacy-command-log-must-remain-byte-identical\n' > "$legacy_log"
  chmod 640 "$legacy_log"
  legacy_hash_before="$(git hash-object --no-filters -- "$legacy_log")"
  legacy_mode_before="$(stat -f%Lp "$legacy_log" 2>/dev/null || stat -c%a "$legacy_log" 2>/dev/null || true)"
  sentinel='AUDIT_COMMAND_MUST_NOT_PERSIST_7f91'
  payload="$(printf '{\"permission_mode\":\"auto\",\"cwd\":\"/tmp/audit-probe\",\"tool_input\":{\"command\":\"curl -H token:%s\"}}' "$sentinel")"
  printf '%s' "$payload" | HOME="$audit_home" bash hooks/audit-bash.sh
  audit_log="$audit_home/.claude/audit-bash-metadata.log"
  audit_mode="$(stat -f%Lp "$audit_log" 2>/dev/null || stat -c%a "$audit_log" 2>/dev/null || true)"
  if [ -f "$audit_log" ] && [ "$audit_mode" = 600 ] &&
     jq -e 'keys == ["cwd","permission_mode","timestamp","tool"] and .tool == "Bash" and .permission_mode == "auto" and .cwd == "/tmp/audit-probe"' "$audit_log" >/dev/null 2>&1 &&
     ! rg -q "$sentinel|tool_input|command" "$audit_log" &&
     [ "$(git hash-object --no-filters -- "$legacy_log")" = "$legacy_hash_before" ] &&
     [ "$(stat -f%Lp "$legacy_log" 2>/dev/null || stat -c%a "$legacy_log" 2>/dev/null || true)" = "$legacy_mode_before" ]; then
    ok "Bash audit 僅寫 metadata JSONL（0600），不持久化 command，且保留 legacy log"
  else
    bad "Bash audit 仍可能持久化 command、metadata schema/mode 不符，或改動 legacy log"
  fi
  if [ ! -f "$audit_log" ]; then
    bad "Bash audit invalid-payload canary 缺少既有 metadata log"
  else
    audit_hash_before_invalid="$(git hash-object --no-filters -- "$audit_log")"
    if printf '{' | HOME="$audit_home" bash hooks/audit-bash.sh >/dev/null 2>&1; then
      bad "Bash audit 對 invalid payload 靜默回成功"
    elif [ "$(git hash-object --no-filters -- "$audit_log")" = "$audit_hash_before_invalid" ]; then
      ok "Bash audit 對 invalid payload 回 non-zero，既有 metadata 不變"
    else
      bad "Bash audit invalid-payload failure 改動既有 metadata"
    fi
  fi
  # -f 不可省：暫存 repo 裡的 git object 是唯讀的，互動 shell 下 rm 會停下來問
  # `override r--r--r--?`，把測試卡住等輸入（非互動 shell 不會，所以很容易漏掉）。
  rm -rf -- "$audit_home"
fi

audit_link_home="$(mktemp -d "${TMPDIR:-/tmp}/repo-integrity.XXXXXX")" || audit_link_home=""
if [ -z "$audit_link_home" ]; then
  bad "Bash audit symlink canary 無法建立 temp HOME"
else
  mkdir -p "$audit_link_home/.claude"
  audit_target="$audit_link_home/target.txt"
  printf 'target-must-not-change\n' > "$audit_target"
  target_hash_before="$(git hash-object --no-filters -- "$audit_target")"
  ln -s "$audit_target" "$audit_link_home/.claude/audit-bash-metadata.log"
  if printf '{"permission_mode":"auto","cwd":"/tmp"}' |
       HOME="$audit_link_home" bash hooks/audit-bash.sh >/dev/null 2>&1; then
    bad "Bash audit 接受 symlink log path"
  elif [ "$(git hash-object --no-filters -- "$audit_target")" = "$target_hash_before" ]; then
    ok "Bash audit 拒絕 symlink log path，target bytes 不變"
  else
    bad "Bash audit symlink rejection 後仍改動 target"
  fi
  rm -rf -- "$audit_link_home"
fi

if ! rg -q 'Package manager：npm|無則取最新 LTS' CLAUDE.md &&
   ! jq -e '.autoMode.environment[] | select(test("no production database|All database work targets local|Package manager: npm only"))' settings.json >/dev/null &&
   rg -Fq 'Repo manifests／lockfiles／CI／task evidence 是 package manager 與 runtime 的 source of truth' CLAUDE.md &&
   jq -e '.autoMode.environment | index("Repository config, manifests, lockfiles, CI, and the current task are the source of truth for package manager, database target, and credential/environment boundaries; assume neither local-only nor production access without evidence.") != null' settings.json >/dev/null; then
  ok "package/runtime/database/credential 預設改由 repo evidence 決定"
else
  bad "仍有 npm-only、local-DB-only、no-production-credential 或 latest-LTS 全域假設"
fi

if jq -e '
  (.permissions.allow | index("Bash(git restore --staged -- *)") != null) and
  (.permissions.deny | index("Bash(git restore --staged *)") == null) and
  (.permissions.deny | index("Bash(git restore *--source*)") != null) and
  ([.autoMode.soft_deny[] | select(test("git restore[^\"]*--staged"))] | length == 0)
' settings.json >/dev/null; then
  unstage_dir="$(mktemp -d "${TMPDIR:-/tmp}/repo-integrity.XXXXXX")" || unstage_dir=""
  if [ -z "$unstage_dir" ]; then
    bad "git restore --staged canary 無法建立 temp repo"
  else
    git -C "$unstage_dir" init -q
    git -C "$unstage_dir" config user.email canary@example.invalid
    git -C "$unstage_dir" config user.name canary
    printf 'base\n' > "$unstage_dir/probe.txt"
    git -C "$unstage_dir" add -- probe.txt
    git -C "$unstage_dir" commit -qm baseline
    printf 'changed\n' > "$unstage_dir/probe.txt"
    git -C "$unstage_dir" add -- probe.txt
    before_unstage="$(git -C "$unstage_dir" hash-object probe.txt)"
    git -C "$unstage_dir" restore --staged -- probe.txt
    after_unstage="$(git -C "$unstage_dir" hash-object probe.txt)"
    if [ "$before_unstage" = "$after_unstage" ] &&
       git -C "$unstage_dir" diff --cached --quiet -- probe.txt &&
       ! git -C "$unstage_dir" diff --quiet -- probe.txt; then
      ok "git restore --staged -- <path> 只 unstage，不改 worktree bytes"
    else
      bad "git restore --staged allow 或行為 canary 不符"
    fi
    rm -rf -- "$unstage_dir"
  fi
else
  bad "git restore staged/source permission contract 不符"
fi

launchctl_ok=1
jq -e '
  (.permissions.deny | index("Bash(launchctl *)") != null) and
  (.permissions.deny | index("Bash(/bin/launchctl *)") != null) and
  (.permissions.deny | index("Bash(env launchctl *)") != null) and
  (.permissions.deny | index("Bash(env /bin/launchctl *)") != null) and
  (.permissions.deny | index("Bash(/usr/bin/env launchctl *)") != null) and
  (.permissions.deny | index("Bash(/usr/bin/env /bin/launchctl *)") != null) and
  ([.permissions.deny[] | select(. == "Bash(* launchctl *)" or . == "Bash(* /bin/launchctl *)")] | length == 0) and
  (.permissions.allow | index("Bash(~/.claude/hooks/launchctl-readonly.sh *)") != null) and
  ([.permissions.allow[] | select(test("launchctl"))] | length == 1) and
  # unsandbox 升級不得「無人把關地」發生。把關可以是三種形狀之一，斷言只認其中一種
  # 會把換成另一種誤判為防線退化：
  #   ask 規則                        — 每次 prompt，人工放行（無人值守會卡死）
  #   allowUnsandboxedCommands:false  — 參數被完全忽略，根本沒有升級路徑
  #   defaultMode:auto                — classifier 逐次評估，不 prompt 也不靜默放行
  # 三者皆無才是真的退化：那代表 unsandboxed retry 可以無條件執行。
  ((.permissions.ask | index("Bash(dangerouslyDisableSandbox:true)") != null)
    or (.sandbox.allowUnsandboxedCommands == false)
    or (.permissions.defaultMode == "auto")) and
  ([.sandbox.network.allowMachLookup[] | select(test("launchd|launchctl"))] | length == 0)
' settings.json >/dev/null || launchctl_ok=0
for unsafe_launchctl in \
  'getenv PATH' \
  'print gui/501' \
  'bootstrap gui/501 /tmp/unsafe.plist' \
  'setenv KEY VALUE' \
  'list extra'; do
  # shellcheck disable=SC2086 # deliberate argv fixture
  if bash hooks/launchctl-readonly.sh $unsafe_launchctl >/dev/null 2>&1; then
    launchctl_ok=0
  fi
done
if bash hooks/launchctl-readonly.sh version >/dev/null 2>&1; then
  :
elif [ "$?" -ne 69 ]; then
  launchctl_ok=0
fi
# ── ~/.claude 的 permission 邊界（獨立區塊，不寄生在 launchctl 的 ok/bad）────────────
#
# 2026-08-08：CLAUDE.md 與 hooks/** 的 permissions deny 由使用者裁決移除，settings.json
# 與 .github/workflows/** 保留。三件事必須寫清楚，因為第一版註解全寫錯了：
#
# 1. `Edit(<path>)` 這一條 deny **同時擋 Edit、Write、NotebookEdit** —— 三個工具的權限
#    檢查走同一個函式，而 bucket 解析只用 "Edit" 這個規則名做精確比對（Claude Code
#    2.1.223 的判定鏈）。所以清單裡的 `Write(<path>)` 對檔案路徑**永遠不會被查詢**。
#    留著它不是白留：deny 清單會逐字注入 auto-mode 的 Bash classifier prompt，它是
#    classifier 的輸入，不是 hard gate。刪掉之前先讀這段。
# 2. 移除那兩條 = 同時放棄三個工具的 hard block，剩下的是 harness 內建的 `.claude`
#    sensitive floor（回 ask、classifier 可核准）與下面的 sandbox denyWrite。不是全開，
#    但也不是鎖著。
# 3. hook 在 Bash 沙箱**之外**以完整 user 權限執行（實測：audit-bash.sh 寫得進不在
#    sandbox 白名單的路徑）。hooks/** 開放之後，改 hook 就是取得沙箱外執行路徑——這是
#    這個裁決的實際代價，由下方的 hooks 內容指紋守衛承接。
# 4. 2026-08-08 第二次裁決：`Edit(~/.claude/settings.json)` 由使用者明示移除，改走官方的
#    user-directed edit 路徑——`.claude` 屬 protected path，`permissions.allow` 無法預先核准
#    那道檢查（見 /docs/en/permission-modes#protected-paths；文件叫 protected path，harness
#    的使用者可見字串叫 sensitive file，上面第 2 點用的是後者，同一個機制）。所以這一條
#    **反過來斷言它不存在**：它被加回來才是回歸，會靜默取消使用者的裁決。
#    但反轉極性同時反轉了 fail-safety。`index()` 是精確字串比對：正極性下任何拼法變體都
#    讓測試紅（安全方向），反極性下任何變體都讓它綠。2026-08-08 mutation 實測三種 re-add
#    全部通過——`Edit(~/.claude/settings*.json)`（glob，harness 支援；本清單自己就在用）、
#    `Edit(/Users/pochientsai/.claude/settings.json)`（絕對路徑）、尾隨空白。所以改成 regex
#    掃整個陣列，比照下方 allowWrite 的集合比對，不用單一 literal。
#    但 regex 要求字面 `settings`，所以 `Edit(~/.claude/**)`、`Edit(~/.claude/*)` 這種 dir glob
#    同樣重新封鎖 settings.json 卻不含該字面——2026-08-08 apply pass 實測兩者都通過。所以
#    再加一條 prefix 形式並存：兩者覆蓋互補（regex 抓得到 `Edit(//**/settings.json)`，prefix
#    形式抓得到 dir glob），合起來嚴格強於任一單獨形式。
#    regex 的 `([^)]*/)?` 把 `settings` 綁在路徑段開頭，不是 `.*`：後者會把 `appsettings.json`
#    也算成 settings.json 回歸（`.*` 吃掉 `app`），而 `appsettings.*.json` 就寫在 settings.json
#    的 autoMode.soft_deny 裡，將來真的加一條那樣的 deny 會被誤紅。PR #25 的 Copilot review
#    在 suppressed 區抓到這點，實測 appsettings.json／appsettings.Production.json／
#    localsettings.json 三個誤擋點在收斂後全部解除，六種真回歸拼法仍全數抓到。
#    **上限，不宣稱閉合**：`Edit(~/**)` 這種更外層的 glob 兩條都漏。glob 的涵蓋關係是語意
#    關係，任何字串比對都表達不了「這條 pattern 是否仍讓 settings.json 可編輯」。這條斷言
#    按其本質是 proxy，不是完備判定；真要閉合得靠 PreToolUse(Edit) 攔截實際 diff。
#    `Write(~/.claude/settings.json)` 依上面第 1 點保留：它擋不住檔案工具，是 Bash classifier
#    prompt 的輸入而非 gate。那條路的份量來自 unsandboxed retry——2026-08-08 實測佔 Bash
#    呼叫 38.9%（1308/3359，4.5 天）。重推方式：掃 ~/.claude/projects/*/*.jsonl 的 Bash
#    tool_use，數 input.dangerouslyDisableSandbox == true 的佔比。該比例隨任務組成大幅波動
#    （逐日 0%～52%），而規則邏輯不依賴具體數值——非零即足以成立。所以數字只留在這裡，
#    classifier prose 那邊改成定性敘述，避免一個會腐化的數字釘在 live safety prompt 裡。
perm_ok=1
jq -e '
  ([.permissions.deny[] | select(test("^Edit\\(([^)]*/)?settings[^/]*\\.json\\s*\\)$"))] | length == 0) and
  ([.permissions.deny[]
     | select(startswith("Edit(~/.claude/") or startswith("Edit(/Users/pochientsai/.claude/"))
     | select(. != "Edit(~/.claude/.github/workflows/**)")] | length == 0) and
  (.permissions.deny | index("Write(~/.claude/settings.json)") != null) and
  (.permissions.deny | index("Edit(~/.claude/.github/workflows/**)") != null) and
  (.permissions.deny | index("Write(~/.claude/.github/workflows/**)") != null) and
  # 上面四條之外，還要釘住這個邊界存在的理由本身：deny 清單一次編輯可以被刪光，而
  # 只釘 4 條的話刪掉其餘 37 條測試照樣全綠（2026-08-08 mutation 實測）。
  # 原本這裡是 `(.permissions.deny | length) >= 48` 釘總數下限。那在寫下它的當時剛好零
  # slack（清單正好 48 條，刪一條就紅），但同日加了 rm 變體後清單長到 63，下限沒跟著動
  # → 15 條 slack。mutation 實測：可以刪光整個 secret-read 家族（9 條 Read(...)）或整個
  # git-destructive 家族（5 條）而測試全綠。改成按家族釘下限——新增不會紅、刪除才會，而且
  # 不隨清單總長漂移，不必每次加規則就回來調數字（調數字只是重啟同一個跑步機）。
  # rm 家族 2026-08-08 apply pass 由 17 條收成 6 條，且嚴格更強。三個官方 verbatim 語意：
  #   1. 官方：`Bash(ls*)`（`*` 前無空格）同時命中 `ls -la` 與 `lsof`，因為沒有 word boundary
  #      constraint。→ `Bash(rm -*)` 命中所有 `rm -…` 拼法。原本 13 條 flag 排列
  #      實測仍漏 `rm -rvf`／`rm -rv`／`rm -fv`／單獨的 `rm --recursive`——枚舉形狀本身就錯。
  #   2. stripped wrappers 明列 shell builtins `command`／`builtin`（以及 timeout/time/nice/
  #      nohup/stdbuf/noglob 與裸 xargs）→ `Bash(command rm *)` 可證冗餘，已刪；`env` 不在
  #      該清單，所以 env／絕對路徑那四條是真載重。裸 xargs 被 strip 的副效果是
  #      `Bash(rm -*)` 連 `xargs rm -rf` 一起蓋到。
  #   3. 「A rule must match each subcommand independently」，separator 含 && || ; | |& & 與
  #      newline → 複合指令（`cd /x && rm -rf y`）本來就逐段比對，不是漏洞。
  # 命令拼法軸補到與上方 launchctl 家族同一組六拼法（原本 regex 把 `(/bin/)?` 放在 env group
  # 之前，`env /bin/rm`、`/usr/bin/env /bin/rm` 永遠匹配不到，反而接受不存在的 `/bin/env rm`）。
  # env／絕對路徑那四條刻意是 blanket（不限 -rf），理由同 `Bash(/bin/launchctl *)`：那樣寫 rm
  # 本身就不尋常，誤擋成本近零。裸 `rm file` 依舊放行，交給 classifier 與 sandbox allowWrite。
  ([.permissions.deny[] | select(startswith("Read("))] | length >= 9) and
  ([.permissions.deny[] | select(startswith("Edit(~/"))] | length >= 20) and
  ([.permissions.deny[] | select(test("^Bash\\((env |/usr/bin/env )?(/bin/)?rm "))] | length >= 6) and
  ([.permissions.deny[] | select(test("^Bash\\(git (checkout|restore|reset)"))] | length >= 5) and
  (.permissions.deny | index("Read(~/.ssh/**)") != null) and
  (.permissions.deny | index("Bash(sudo *)") != null) and
  (.permissions.deny | index("Bash(rm -*)") != null) and
  # 移除 Edit deny 之後，settings.json 邊界的主要載體是 autoMode.hard_deny 那段 prose，而它
  # 原本零覆蓋——mutation 實測把整個 hard_deny 換成 ["$defaults"] 仍然全綠，正是本區塊
  # 開頭警告的「一次編輯可以被刪光」。釘住它存在、仍點名 settings.json、且仍帶那條禁令。
  # 用 >= 1 不用 == 1：== 1 會讓**強化式新增**（再加一條談 settings.json 的 hard_deny）變紅，
  # 與上面「新增不會紅、刪除才會」自相矛盾（2026-08-08 apply pass 實測）。
  # anchor 用 `widen a permission` 不用整句、也不用單字 `widen`。三者實測（2026-08-08 apply
  # pass）：整句對無害改寫（boundary→surface、Never→Do not、少一逗號）報紅；單字 `widen`
  # 對「拿掉禁令句」仍全綠，因為同段後文的 "widening one" 一樣命中；`widen a permission`
  # 抓到該片語被刪除、且兩種無害改寫都不誤擋。長度不換來強度，鑑別力才換。
  # 上限：substring anchor 抓不到「保留字面但語意被削弱」。這條一般性上限**仍然成立**，
  # 下面新增的 anchor 只縮小它、沒有消除它（2026-08-26 實測，見該處）。
  # 另修一句過強宣稱：上一段原寫 `widen a permission` anchor「抓到禁令被移除」。它抓的是
  # **片語被字面刪除**——把 `Never widen ... on your own initiative` 改成
  # `You may widen ... at your own discretion`，兩個 substring 仍 1/1 命中、全檔 82 PASS。
  # 這與 ci.yml 對 guard-git-push
  # 用判定變數當 anchor 是同一取捨——不用內容 hash，因為 hash 會對任何註解編輯報紅。
  # 2026-08-25 裁決：hard_deny[3] 加入「使用者指名該具體改動即可授權」，授權來源見 commit
  # message 與 PR #35。放寬的是授權門檻，不是「AI 可自行判斷」。
  # 下面三條 anchor 抓的是**片語被字面刪除或字面替換**，不抓語意。2026-08-26 實測三個反例
  # 皆 82 PASS 全綠：`on your own initiative` 後接 `unless you judge the widening
  # beneficial`；授權句加一個 OR 臂 `as does any standing instruction to maintain the
  # machine configuration`；排除句前綴 `it is no longer the case that`。
  # **加字即繞過——substring anchor 在原理上涵蓋不了這一類，別把它當語意守衛。**
  # 反向代價：`You must never widen`、`is equivalent for` 這類良性改寫會誤紅（fail-closed，
  # 可接受）。它們擋得住的是 4f4fa1c 實際發生過的那種**整段刪除**。
  ([.autoMode.hard_deny[] | select(test("settings\\.json"))] | length >= 1) and
  ([.autoMode.hard_deny[] | select(test("widen a permission"))] | length >= 1) and
  # 極性 anchor：只釘 `widen a permission` 抓不到句子被反轉（見上方「上限」）。連動詞前的
  # 否定詞一起釘，對 Never→Do not 這種無害改寫仍放行。
  ([.autoMode.hard_deny[] | select(test("(Never|Do not) widen a permission"))] | length >= 1) and
  # 授權句 anchor：釘住「指名」這個限定詞。把它弱化成 `Any user instruction, however
  # general,`（或整句刪除）時，上面三條都抓不到，只有這條會紅。
  ([.autoMode.hard_deny[] | select(test("naming the specific change"))] | length >= 1) and
  # allow[5] 的 ~/.agents/bin/pr-review-gate 排除條款：該路徑在 sandbox.allowWrite 內、
  # 無 denyWrite、目錄名非 .claude 故 built-in protected-path check 不適用，classifier 是
  # unsandboxed retry 路徑上唯一的 gate，而它 gate 的正是 hard_deny[1] 點名的 merge gate。
  # 這條 2026-08-26 補上，因為該條款在 PR #35 的前一版被無聲刪除而當時的斷言全綠。
  # 釘在 allow 全陣列上，所以整條 entry 被 del 掉也會紅。
  # 為什麼寫確切工具而不是裸目錄 ~/.agents/bin/：~/.agents/tests/three-host-global-config-
  # ownership.sh 反向斷言禁止 host global config 引用 .agents control plane，allowlist 只放行
  # agents-branch 與 pr-review-gate 兩個確切工具且硬上限 2 筆。裸目錄寫法會讓那支測試恆紅
  # （main 上本來就是紅的，2026-08-26 實測 fa012a0 命中 2 處）。
  # 已知殘留：agents-sync／hook-parity-check／ci-local 等同目錄下其他 binary 不在本排除句內。
  # 要涵蓋它們得改 ~/.agents 那支測試的 allowlist，屬跨 repo 改動，不在此處理。
  ([.autoMode.allow[] | select(test("~/\\.agents/bin/pr-review-gate counts as equivalent"))] | length >= 1) and
  # sandbox 這層要連開關一起釘：只釘 denyWrite 的內容而不釘 enabled，把 enabled 改成
  # false 整層失效而測試全綠（同批 mutation 實測）。
  (.sandbox.enabled == true) and
  (.sandbox.filesystem.denyWrite | index("~/.claude/CLAUDE.md") != null) and
  (.sandbox.filesystem.denyWrite | index("~/.claude/settings.json") != null) and
  (.sandbox.filesystem.denyWrite | index("~/.claude/hooks") != null) and
  # allowWrite 用集合比對而非單一字串：原本只擋 "/Users/pochientsai/.claude" 這個literal，
  # 換成 tilde 形式或直接加父目錄 "/Users/pochientsai" 都能繞過（實測皆全綠），而父目錄
  # 嚴格更糟——整個家目錄變成 sandbox 可寫。
  ([.sandbox.filesystem.allowWrite[]
     | select(. == "~/.claude" or . == "/Users/pochientsai/.claude"
              or . == "~" or . == "$HOME" or . == "/Users/pochientsai")]
   | length == 0)
' settings.json >/dev/null || perm_ok=0
if [ "$perm_ok" -eq 1 ]; then
  ok "~/.claude permission 邊界：settings.json 的 Edit deny 依裁決維持移除、Write deny 保留；.github/workflows 兩條保持 deny；deny 清單未被削減；sandbox 已啟用且 allowWrite 不含 ~/.claude 或其父層"
else
  bad "~/.claude permission 邊界退化（settings.json 的 Edit deny 被加回或 Write deny 被刪、workflows 的 deny、deny 清單規模、sandbox.enabled、或 allowWrite 範圍其中之一）"
fi

# ── gate-critical denyWrite 與 credential 封鎖面（PR #32 新增，Copilot review 指出無斷言）──
# 上面那條只釘了三條原始 denyWrite。PR #32 新增的四條與 .credentials.json 的兩層封鎖當時
# 零斷言——移除任何一條 CI 仍全綠，而它們正是 hard_deny 賴以成立的東西：
#   ~/.agents/bin              hard_deny[1] 點名 pr-review-gate 為 merge gate，改寫它即可印 PASS
#   ~/.agents/hooks            programmatic decision layer 本體
#   ~/.agents/skills/dev-workflow  [INT-*]／[S5-*]／authorization-matrix 的定義來源
#   ~/.claude/core             tier0-safety.md 本體（CLAUDE.md 第一行 @ 載入）
# 選入條件是「改它會擊穿一道 gate」，不是「是不是 config」——所以其餘 72 個 skill 與
# ~/.claude/rules/ 刻意不在此列（它們是內容，由 $defaults Self-Modification 承接），
# 不要「補齊」它們：denyWrite 沒有「除非使用者要求」的逃生口，會把合法編輯一起鎖死。
# 上限：這是 sandbox-scoped，unsandboxed retry 時降級為 classifier 判定而非硬擋。
gate_paths_ok=1
jq -e '
  (.sandbox.filesystem.denyWrite | index("~/.claude/core") != null) and
  (.sandbox.filesystem.denyWrite | index("~/.agents/bin") != null) and
  (.sandbox.filesystem.denyWrite | index("~/.agents/hooks") != null) and
  (.sandbox.filesystem.denyWrite | index("~/.agents/skills/dev-workflow") != null) and
  # .credentials.json 兩層都要在：permissions.deny 擋 Read 工具，sandbox.credentials.files
  # 擋 bash reader（cat/base64/…）。刪任一邊就開一條路，所以配對本身就是保護。
  # mode 一起釘：只釘 path 的話改成 "allow" 會整條失效而測試全綠。
  # 存在性用 >= 1 不用 == 1（與本檔 hard_deny anchor 同）：== 1 對真正該擋的失效模式
  # 沒有多給保護——重複一條同字面的 deny 是 config 異味不是保護流失——卻會把「加強式
  # 新增」誤判成退化。脆弱性換不到鑑別力就不要。
  ([.permissions.deny[] | select(. == "Read(~/.claude/.credentials.json)")] | length >= 1) and
  ([.sandbox.credentials.files[]
     | select(.path == "~/.claude/.credentials.json" and .mode == "deny")] | length >= 1) and
  # 但 >= 1 與 == 1 都漏同一個洞：同一 path 若另有一條 mode 非 deny，兩者皆放行，
  # 而哪一條生效未定義。所以另外釘「該 path 的所有條目 mode 一律是 deny」。
  ([.sandbox.credentials.files[]
     | select(.path == "~/.claude/.credentials.json" and .mode != "deny")] | length == 0)
' settings.json >/dev/null || gate_paths_ok=0
if [ "$gate_paths_ok" -eq 1 ]; then
  ok "gate-critical 路徑仍被釘住：denyWrite 四條（merge gate／hook decision layer／tier0／workflow kernel）與 .credentials.json 的 permissions.deny + sandbox.credentials.files 雙層"
else
  bad "gate-critical 封鎖面退化（denyWrite 的 ~/.claude/core／~/.agents/{bin,hooks}／~/.agents/skills/dev-workflow，或 .credentials.json 兩層之一被刪、或 credentials mode 不再是 deny）"
fi

# hooks 內容指紋。移除 Edit(~/.claude/hooks/**) 之後這是唯一的偵測面：CI 只驗形狀
# （selftest 有沒有過、anchor 在不在、bash -n），「在既有 hook 尾端附加一行」全部照過。
# 而 hook 在沙箱外執行，附加的那一行拿得到完整 user 權限。
# 釘內容雜湊讓「改 hook」變成明示動作——改完必須同步更新這個檔，忘了就紅。
#
# 比對「整份重算的指紋」而不是跑 `shasum -c`：後者只驗清單裡列到的檔案，**新增**一支
# hook 而不更新清單完全不會被發現——而新增的 hook 一樣會被執行，那正是這道守衛要擋的
# 事。等值比對同時抓內容變更與檔案集合變更（新增／刪除／改名）。
if [ ! -f tests/hooks.sha256 ]; then
  bad "tests/hooks.sha256 不存在——hooks/** 已無 Edit deny，內容指紋是唯一的偵測面"
else
  _hooks_now="$(cd hooks && shasum -a 256 -- *.sh *.py 2>/dev/null | sort -k2)"
  _hooks_pinned="$(cat tests/hooks.sha256)"
  if [ -z "$_hooks_now" ]; then
    bad "hooks/ 下掃不到任何 .sh／.py——指紋比對失去依據"
  elif [ "$_hooks_now" = "$_hooks_pinned" ]; then
    ok "hooks 內容與檔案集合皆與 tests/hooks.sha256 一致"
  else
    printf '%s\n' "$_hooks_now" > "${TMPDIR:-/tmp}/hooks-now.$$" 2>/dev/null &&
      diff "${TMPDIR:-/tmp}/hooks-now.$$" tests/hooks.sha256 2>/dev/null | head -6
    rm -f "${TMPDIR:-/tmp}/hooks-now.$$" 2>/dev/null
    bad "hooks 內容或檔案集合與 tests/hooks.sha256 不符（上列為差異）。改動後請同步更新：cd hooks && shasum -a 256 -- *.sh *.py | sort -k2 > ../tests/hooks.sha256"
  fi
fi

# ── 安裝過的 pre-commit 必須與 repo 來源一致 ────────────────────────────────────
# 上面那道指紋只釘 hooks/，不涵蓋 .git/hooks/。兩者可以無聲脫鉤：改了 hooks/ 卻忘了重跑
# install-pre-commit.sh，指紋全綠而**實際執行的是舊版**。2026-08-26 實測就撞到——安裝過的
# 那份落後 repo 一版（差一行文案），沒有任何守衛發現。
# 這條只在本機有意義：.git/hooks/ 不進版控，CI 的 fresh clone 沒有它，故缺檔時 SKIP 而非 FAIL。
# **exec bit 與內容同等承重**：git 對非 executable 的 hook 是靜默跳過（只有一行可被
# advice.ignoredHook 關掉的 hint），gate 等於沒在跑。只比 cmp 會在這種情況報綠——
# 2026-08-26 實測：把安裝檔 chmod 644 後，「逐 byte 一致」PASS、83 PASS / 0 FAIL，
# 而同時 staged 的黑名單檔照樣 commit 成功（rc=0）。那正是本斷言要抓的 failure class。
# 這與上方 2026-08-08 那條 exec-bit 斷言是同一個教訓；該條的清單推導自 settings.json 的
# hook 註冊，而 .git/hooks/pre-commit 是 git hook、不在註冊表內，故無人涵蓋。
# 上限：只比對 pre-commit 這一支——它是本 repo 唯一在 hooks/ 有版控來源可比對的 git hook。
#   安裝目錄下其他 hook（如 pre-push）沒有 in-repo 來源，無從比對，故不納入。
#   刻意不指名那些檔：它們只存在於未追蹤的安裝目錄，讀者與 CI 都查證不到。
# 缺檔的 SKIP 分支分不出「CI fresh clone」與「開發者從未安裝」，後者更危險卻不報紅——
# 已知取捨，因為 .git/hooks/ 不進版控，沒有可靠的第三種訊號可分流。
# 路徑用 git rev-parse --git-path 而非硬寫 .git/hooks：worktree 的 .git 是**檔案**不是目錄，
# 硬寫會讓本斷言在 worktree 內恆走 SKIP——包括本 repo 的 review 工具鏈用的 snapshot
# worktree，等於斷言剛好在最常用的環境裡失聲。同一個寫法也順帶處理 core.hooksPath
# 與 ${GIT_DIR}（2026-08-26 實測 git -c core.hooksPath=/nonexist 會正確回該路徑）。
# 不用 `|| echo .git/hooks/pre-commit` 兜底：那是 fail-open——git 不可用或這裡不是 repo 時
# 會靜默退回硬寫路徑，接著走到 SKIP 或比對錯的目標，整條斷言失去鑑別力而全綠。
# 本 commit 修的正是同一個病（here-string 失敗被吞掉），不該在守衛自己身上重犯。
_hookdst=""
_hookdst="$(git rev-parse --git-path hooks/pre-commit 2>/dev/null)" || _hookdst=""
if [ -z "$_hookdst" ]; then
  bad "取不到 git hooks 路徑（git rev-parse --git-path 失敗）——安裝一致性檢查失去依據。這不是 SKIP：請確認此處是 git repo 且 git 可用"
elif [ ! -f "$_hookdst" ]; then
  # 不用 ok()：沒驗到東西就不該計入 PASS（那正是本檔一貫反對的過度宣稱）。
  printf '  SKIP  %s\n' "安裝過的 pre-commit 與來源一致：$_hookdst 不存在（fresh clone／CI，非錯誤）"
elif [ ! -x "$_hookdst" ]; then
  bad "安裝過的 $_hookdst 缺 exec bit——git 會靜默跳過（只有一行可關掉的 hint），pre-commit gate 等於沒在跑。修：chmod +x '$_hookdst'"
else
  # cmp 的 rc 必須分三態：0=相同、1=內容不同、>=2 才是「比不了」（檔案不可讀、cmp 不存在
  # 而回 127…）。把 >=2 併進「內容不一致」會把排障方向指錯——這與本檔 _no_tempfile_redirect()
  # 對 grep rc 的處置是同一條教訓（rc>=2 是錯誤，不是「無命中」）。
  # 本檔是 set -uo pipefail（無 -e），但仍用 `|| _cmprc=$?` 明寫，不依賴那個前提。
  _cmprc=0
  cmp -s hooks/pre-commit-claude.sh "$_hookdst" || _cmprc=$?
  if [ "$_cmprc" -eq 0 ]; then
    ok "安裝過的 pre-commit 與 hooks/pre-commit-claude.sh 逐 byte 一致且可執行"
  elif [ "$_cmprc" -eq 1 ]; then
    bad "安裝過的 $_hookdst 與 hooks/pre-commit-claude.sh 內容不一致（哪一邊較新無法由 cmp 判斷）。重跑 bash hooks/install-pre-commit.sh 以來源為準；沙箱擋住寫入時需停沙箱"
  else
    bad "無法比對安裝過的 pre-commit 與來源（cmp rc=${_cmprc}，非 0／1）。這不是內容不一致——請檢查兩個檔是否可讀、cmp 是否存在：hooks/pre-commit-claude.sh 與 $_hookdst"
  fi
  unset _cmprc
fi
unset _hookdst

# ── 直接 exec 的 hook 必須保有 exec bit ──────────────────────────────────────────
#
# 2026-08-08：上面那道指紋守衛比對的是 `shasum` 的**內容**，看不到 file mode。這是它自稱
# 涵蓋「內容變更與檔案集合變更」之外的第三個維度，而且是有實害的那一個：
#   * 註冊時帶 `bash ` 前綴的 hook 不讀 exec bit，翻成 644 無害。
#   * 沒帶前綴的是直接 exec。翻成 644 就 exec 失敗，而 audit-bash.sh 註冊為 async——
#     失敗**完全靜默**：Bash audit trail 停止、指紋零差異、測試零差異、使用者零訊號。
#   * launchctl-readonly.sh 不是 hook 而是 permissions.allow 直接 exec 的路徑，是
#     CLAUDE.md 指定的唯一 launchctl 查詢管道，同一個曝險面。
#
# 從 settings.json 的註冊處推導而非硬編清單：將來任何未加 `bash ` 前綴註冊的 hook 自動
# 被涵蓋，不必記得回來加名字。比對走 repo 相對路徑（hooks/<basename>）而不是註冊字串裡的
# ~/.claude/…，因為 CI 的 checkout 不在 $HOME/.claude；git 有保存 100755 所以 CI 驗得到。
# 篩選只用一條「路徑前綴」規則，不用副檔名白名單、也不列舉 interpreter：
#   * 副檔名白名單（*.sh|*.py）會靜默漏掉 extensionless、.mjs 等註冊形狀，而本區塊自稱
#     「將來任何未加 bash 前綴註冊的 hook 自動被涵蓋」——白名單直接違背那句話。
#   * 列舉 interpreter（bash /sh /...）永遠列不完（env bash、zsh、python3），而且不必列：
#     帶前綴的指令第一個 token 是 interpreter，本來就不以 ~/.claude/hooks/ 開頭。
#   * 只認 ~/.claude/hooks/ 之下的路徑，順帶擋掉 basename 對撞——否則註冊
#     /opt/tools/audit-bash.sh 會被拿去驗 hooks/audit-bash.sh 的 exec bit 而假 PASS。
# 已知邊界（不宣稱涵蓋）：
#   * 註冊在 hooks/ 之外的直接 exec 腳本（例如 ~/.claude/scripts/、${CLAUDE_PLUGIN_ROOT}/…）
#     不在此斷言範圍內，本區塊只負責本 repo 的 hooks/。
#   * **部分** schema 漂移：若將來多出一種註冊形狀（plugin hooks、.hooks[][].hooks[] 旁邊
#     再多一個 key），舊形狀仍解析得出、_execbit_reg > 0，新形狀則完全隱形而報綠。
#     下面的 reg==0 只擋得住**全量**漂移。拿同一份 schema 去交叉驗證是循環論證，沒有便宜解。
# 為什麼不把 mode 併進 tests/hooks.sha256 而是另開一道：git 只保存 x bit（100644/100755），
# 從 working tree 算出的完整 mode manifest 在本機與 CI 之間不可重現——本 repo 現成三個反例
# （drift-check.sh 本機 700／git 755，patch-chrome-devtools-mcp.sh 與 patch-playwright-mcp.sh
# 本機 600／git 644）。只驗 x bit 正好是 git 保證得了的粒度，兩個正交性質分兩道守衛。
# jq 那側對 allow 只做**形狀**篩選（`^Bash\([~/$]`，即「看起來像路徑」），不做 .claude/hooks/
# 的前綴判定——路徑判定只留在下面的 shell case 一個地方。原本 jq 寫成
# `^Bash\((~|\$HOME)/\.claude/hooks/`，比 case 窄：絕對路徑寫法 `Bash(/Users/…/hooks/x.sh *)`
# 被 jq 靜默排除，case 明明收得到卻永遠拿不到它，於是 n 悄悄少一支而仍報 ok。兩個地方各自
# 判定同一件事就會漂移成這樣（PR #26 Copilot review 實測：絕對路徑 allow 配 644 報 ok、
# n 由 3 掉到 2）。形狀篩選也不會膨脹 _execbit_reg：現行 allow 只有 launchctl-readonly.sh
# 這一條以 ~ / / / $ 開頭，其餘（Bash(git status:*)、Bash(jq *)…）都不符合。
# allow 規則的尾綴用 sub 而非 rtrimstr：rtrimstr 只吃精確後綴，而 `Bash(cmd:*)` 是本檔
# 現行慣例（Bash(git status:*)、Bash(git add:*)、Bash(git commit:*)），`Bash(cmd)` 也是
# 合法的無參數寫法——兩者用 rtrimstr(" *)") 都會殘留字元而被靜默丟掉，丟掉的正好是
# launchctl-readonly.sh，CLAUDE.md 指定的唯一 launchctl 管道。2026-08-08 S5 兩軸實測。
_execbit_missing=""
_execbit_absent=""
_execbit_n=0
_execbit_reg=0
while IFS= read -r _cmd; do
  [ -n "$_cmd" ] || continue
  _execbit_reg=$((_execbit_reg + 1))
  # 三種拼法都要收：`~/…`、展開後的絕對路徑、以及**字面** `$HOME/…`。第三個用單引號
  # 防展開——雙引號的 "$HOME/.claude/hooks/"* 在比對前就變成絕對路徑，永遠對不到字面
  # `$HOME/...` 的註冊。而 jq 那側是放行它的，於是該註冊會計入 _execbit_reg、卻被這裡
  # 丟掉，湊出 reg>0 且 n==0 → 報「曝險面為零」而實際有未受檢的直接 exec 註冊。
  # 2026-08-08 apply pass 實測到這個反向誤綠；它與本區塊自稱修掉的是同一形狀。
  case "$_cmd" in
    "~/.claude/hooks/"*|"$HOME/.claude/hooks/"*|'$HOME/.claude/hooks/'*) ;;
    *) continue ;;
  esac
  _base="${_cmd%% *}"; _base="${_base##*/}"
  _execbit_n=$((_execbit_n + 1))
  if [ ! -f "hooks/$_base" ]; then
    _execbit_absent="$_execbit_absent hooks/$_base"
  elif [ ! -x "hooks/$_base" ]; then
    _execbit_missing="$_execbit_missing hooks/$_base"
  fi
done < <(jq -r '
  [ (.hooks // {} | to_entries[].value[]?.hooks[]?.command),
    (.permissions.allow[]? | select(test("^Bash\\([~/$]"))
                           | ltrimstr("Bash(") | sub("[ :*)]+$";"")) ]
  | .[] | select(. != null and . != "")' settings.json 2>/dev/null)
# 三個狀態要分開，不能合成一個 n==0：
#   * 讀不到任何註冊 → settings.json 壞了或 schema 漂移，bad。
#   * 有註冊但沒有直接 exec 的 → 全部改成 bash 前綴了，那是**強化**（曝險面歸零），
#     必須 ok。合成 n==0 會讓最理想的修法報紅，與本檔「新增不會紅、刪除才會」相牴觸，
#     也正是 PR #25 apply pass 對 `== 1` 的同一條批評。
if [ "$_execbit_reg" -eq 0 ]; then
  bad "讀不到任何 hook 註冊（settings.json 不可解析、jq 缺席、或註冊 schema 已變）——這道斷言失去依據，不是通過"
elif [ "$_execbit_n" -eq 0 ]; then
  ok "settings.json 沒有直接 exec 的 hook 註冊（共 $_execbit_reg 筆皆帶 interpreter 前綴）——exec bit 曝險面為零"
elif [ -n "$_execbit_absent" ] || [ -n "$_execbit_missing" ]; then
  bad "直接 exec 的 hook 有問題（一次列全）：檔案不存在[${_execbit_absent# }] 缺 exec bit[${_execbit_missing# }]（chmod +x 修復）"
else
  ok "直接 exec 註冊的 $_execbit_n 支 hook 皆保有 exec bit（清單推導自 settings.json 註冊處）"
fi

# ~/.claude/.claude/ 對 cwd=~/.claude 的 session 是完整的 settings source（可註冊
# PreToolUse hook、可加 permissions.allow），而 .gitignore 第 2 行的 `*` 讓 git 與 CI
# 完全看不見它。這比 hooks/*.sh 威力更大——settings 可以裝 hook。
if [ -e .claude/settings.json ] || [ -e .claude/settings.local.json ]; then
  bad ".claude/ 下出現 settings*.json：它對 cwd=~/.claude 的 session 生效、被 .gitignore 吃掉、CI 看不見，且可註冊 hook"
else
  ok ".claude/ 未含 settings*.json（gitignored 且對 cwd=~/.claude 的 session 生效，是隱形的 settings source）"
fi

# statusline 每次 render 都執行，卻沒有任何 deny、不在 sandbox denyWrite、CI 零斷言。
if [ ! -f statusline-command.sh ]; then
  ok "statusline-command.sh 不存在（無此執行面）"
elif bash -n statusline-command.sh 2>/dev/null; then
  ok "statusline-command.sh 語法可解析"
else
  bad "statusline-command.sh 語法錯誤——它每次 statusline render 都會執行"
fi

if [ "$launchctl_ok" -eq 1 ]; then
  ok "launchctl direct／common env spellings deny；protected read-only wrapper 與 unsandbox 把關（ask／strict sandbox／classifier 三者之一）阻止靜默升級"
else
  bad "launchctl protected wrapper／sandbox／unsandbox confirmation contract 不符"
fi

if rg -Fq 'Verification scope 與 risk tier 由 `~/.agents/skills/dev-workflow/SKILL.md` 定義' CLAUDE.md &&
   ! rg -Fq 'Build／test／lint 與 task-specific probes 全跑' CLAUDE.md; then
  ok "Opus 5 verification 指向 shared risk tiers，無 blanket rerun"
else
  bad "CLAUDE.md 重複 verification method 或仍強制 blanket verification"
fi

# S5 之後的 apply pass 綁定。兩條一起釘：綁定本身，以及「不複製 method」——CLAUDE.md 第
# 21 行自陳 host-local prose 不複製 kernel 的 method，而這條的第一版正是就地複製，且複製
# 得比 kernel 弱（漏了「只回 S4 等於讓一批 code 繞過 [S5-1]」與 no-op 明述義務）。只釘綁定
# 不釘後半，下一次就會有人把 method 抄回來、抄成另一個版本。
if rg -Fq 'MUST 跑 `simplify` 當 apply pass' CLAUDE.md &&
   rg -Fq '依 kernel `host-adapters.md` 的 Claude 節，此處不複製' CLAUDE.md; then
  ok "S5 apply pass 綁定存在且指向 kernel，未就地複製 method"
else
  bad "CLAUDE.md 缺 S5 apply pass 綁定，或改成就地複製 kernel 的 method"
fi

if rg -Fq '已核准 scope 內的 local、reversible 工作 MUST 一次執行至完成' CLAUDE.md &&
   rg -Fq '中斷條件依 shared [INT-8]' CLAUDE.md &&
   rg -Fq '工具被拒／環境不可用' CLAUDE.md &&
   rg -Fq 'publication 與 protected side effect 仍走 `dev-workflow` authorization gate' CLAUDE.md &&
   grep -Fqx -- '- Delegation：依 shared `dev-workflow` [INT-4] 由 AI 自主判定，無須另問。' CLAUDE.md &&
   ! rg -q '幾個 tool call 可完成的工作不派 subagent|單一小任務不拆多個 subagent|S5 以外不另派 subagent' CLAUDE.md; then
  ok "Opus 5 autonomy 為祈使句；中斷條件轉介 shared INT-8 且保留工具／環境阻塞；publication gate 保留；delegation 僅由 shared INT-4 routing"
else
  bad "Opus 5 risk-based autonomy 或 shared delegation routing 漂移"
fi

# model 與 effortLevel 是使用者可經 /model、/config 調整的 session 偏好，Claude Code 調完會
# 自動寫回 settings.json。釘死單一值會讓每次調整都變成 CI 紅燈——2026-08-05 起磁碟上已是
# claude-opus-5／xhigh，這條在下次 commit 就會 FAIL。改釘「允許集合」：仍擋得住掉回未指定
# 或降級到低 effort 的漂移，但不再把使用者的正常調整當成 drift。
#
# 2026-08-24：列舉的允許集合仍然漂了 —— `/model` 選 1M-context 變體時寫回的是 `opus[1m]`，
# 不在 {default, claude-opus-5} 裡，main 因此紅了一次。列舉本身就是那個 bug：每出一種新
# 命名（別名、context 變體、版本後綴）就要再補一次。改成 model family 前綴判定，
# 意圖不變（擋得住掉回未指定或降級），但不再需要維護清單。
#
# 錨點不可省。第一版寫成裸 `test("opus")`，S5 實測放行 `opusplan` —— 那是 `/model` 選單
# 裡的真實選項（binary 的 description 是 "Use Opus in plan mode, Sonnet otherwise"），
# 也就是 main loop 實際跑 Sonnet。無錨點的子字串會用**同一個 `/model` 寫回向量**打開這條
# 斷言唯一要擋的東西。`claude-3-opus`（舊世代）同理。
# 實測：default／opus／opus[1m]／claude-opus-5／claude-opus-4-1 → PASS；
#       opusplan／opusplan[1m]／claude-3-opus／sonnet／haiku／octopus／空字串 → FAIL。
#
# 明確兩件這條**不**保證的事，免得下一個人以為它保證了：
#   * 放行的是 Opus 家族任一世代（`claude-opus-4-1` 會過）。釘死世代等於把剛拆掉的
#     維護清單裝回來，下一個 Opus 出來又要補一次。
#   * `default` 分支自 v2.1.197 起實際解析成 Sonnet 5，所以「擋得住降級到 sonnet」只對
#     明示字串成立，對 `default` 不成立。這是 main 既有的逃生口，本次未動；要收緊是
#     獨立決定。
if jq -e '
  (.model == "default" or (.model | ascii_downcase | test("^(claude-)?opus([-\\[]|$)"))) and
  .advisorModel == "opus" and
  (.effortLevel == "high" or .effortLevel == "xhigh") and
  .alwaysThinkingEnabled == true
' settings.json 2>/dev/null >/dev/null; then
  ok "Claude main model 在允許集合內；advisor=opus；effort≥high；thinking 啟用"
else
  bad "Claude model／advisor／effort／thinking contract 漂移"
fi

# classifyAllShell 翻回 false 或整條消失，auto mode 的 Bash 判定就從 classifier 退回靜態
# allow 快速路徑——那是本 repo 刻意離開的方向，而且不會有任何東西發現。錨在這裡，
# 比照上下相鄰兩條的形狀。
if jq -e '.autoMode.classifyAllShell == true' settings.json 2>/dev/null >/dev/null; then
  ok "所有 shell 指令走 auto mode classifier（classifyAllShell）"
else
  bad "classifyAllShell 未啟用——auto mode 的 Bash 判定會退回靜態 allow 快速路徑"
fi

if jq -e '.enableAllProjectMcpServers == false' settings.json >/dev/null; then
  ok "Project MCP 不會未經個別啟用而全數載入"
else
  bad "enableAllProjectMcpServers 必須明示 false"
fi

if rg -Fq 'Local checkpoint commit 僅依 shared `authorization-matrix`' CLAUDE.md &&
   rg -Fq 'push／open PR／merge／final closeout 仍依 shared [INT-1]' CLAUDE.md &&
   rg -Fq '覆寫 harness 的「commit only when asked」預設' CLAUDE.md &&
   ! rg -q 'S4、S5 全綠後才可 commit|commit／PR／merge.*authorization gate' CLAUDE.md; then
  ok "Local checkpoint 與 publication gate 分離"
else
  bad "checkpoint 仍被 publication gate 綁住，或未指向 shared authorization matrix"
fi

printf '\n%d PASS / %d FAIL\n' "$pass" "$fail"
# 「至少跑到了」自證：所有檢查都提前 return 時上面會印 0 PASS / 0 FAIL 卻 exit 0，
# 那是本測試自己的 fail-open（同 agents-config PR #32 的處置）。
[ "$pass" -gt 0 ] || { printf 'FAIL  沒有任何檢查執行成功\n'; exit 1; }
[ "$fail" -eq 0 ]
