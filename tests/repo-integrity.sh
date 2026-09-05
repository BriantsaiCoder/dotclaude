#!/usr/bin/env bash
#
# repo-integrity.sh — ~/.claude 的機械守衛（P3-8）
#
# 為什麼是這九項：每一項都對應一種「壞掉但不會有錯誤訊息」的失效模式。
# 會噴錯的東西不需要 CI 擋，會靜默失效的才需要。編號與內文 section 一一對應。
#
#   1. settings 契約 settings.json 壞掉時整份被靜默忽略，鍵漂移也不報錯
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

# rg 是本檔多數斷言的比對引擎。缺 rg 時 `rg -q` 一律回非 0，斷言依極性分裂：正向式誤紅、反向式
# （`! rg -q BAD`）假綠——2026-08-01 run 30671830610 就是這樣 19 PASS／106 FAIL 卻把防線整段跳過。
# 假綠沒有任何訊號可救，所以缺 rg 直接停：不讓後面任何一條印出 PASS，訊息指名工具。CI 的
# 「工具就緒」step 已先擋（ci.yml），這裡守本機與非 CI 環境。形狀同檔尾的「至少跑到了」自證行：
# suite 層級中止用無前導空白的 FAIL ＋ 直接 exit 1（hooks/drift-check.sh 的 FAIL 篩選兩種縮排都收），
# 不走 bad()——exit 1 是這條的 load-bearing 部分，拿掉它就變成印著 FAIL 的假綠。
if ! command -v rg >/dev/null 2>&1; then
  printf 'FAIL  rg 不可用——本檔反向斷言在缺 rg 時會假綠，整份不執行；裝好 ripgrep 後重跑\n'
  exit 1
fi

# ── 1. 追蹤中的 JSON 可解析，settings.json 的鍵契約 ─────────────
# settings.json 解析失敗不會有任何提示，整份設定被當成不存在。
# 本區與 §9 的 settings 斷言共用一條判準：harness 會寫回的鍵（/config、/model、/fast、啟動時的
# 正規化）一律只釘語意不釘單一值——unset-or-good（ultracode、alwaysThinkingEnabled）或 allowed set
# （model、effortLevel）；釘死字面值等於把使用者的正常操作當 drift，每次寫回都是紅燈。
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

  # ultracode 曾與 workflowSizeGuideline 一起釘在這裡當成本閘門，2026-08-06 移除，當時理由是「使用者可經 /config
  # 或 prompt 逐次開關，開了之後 Claude Code 會寫回 settings.json，每次調整都變 CI 紅燈」。2026-09-05 釘回（下方
  # 獨立一條）：2.1.259 binary 實證 /effort ultracode 是 session-only 不落檔、/config 無 ultracode 列，檔案值變 true
  # 只會是手改／git／--settings 的 drift，紅燈正是該有的訊號；#48 讓 hooks/turn-mode.sh 的「靜默＝不開 Workflow」
  # 建立在這個鍵為 false 上，執行期訊號見該 hook 的守衛註解（#50）。失效方向：jq 缺席／壞 JSON／非 false 值皆紅，
  # settings.json 缺檔由 §9 補紅。workflowSizeGuideline 維持釘在這裡。
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

  if jq -e '(has("ultracode") | not) or .ultracode == false' settings.json >/dev/null; then
    ok "ultracode 未被設成 true（unset 或 false）"
  else
    bad "settings.json 的 ultracode 必須 unset 或 false（現值不是 false，或檔案不可解析）——repo-state drift，改回 false；理由見上方註解"
  fi

  # fast mode 只在 Opus 5／4.8 生效且訂閱制下全走 usage credits；每個 session 以 standard 起跑，
  # 要快就在 session 第一回合 /fast。依本區開頭的判準只釘 opt-in 鍵：起跑判定在此鍵為 true 時忽略
  # fastMode（2.1.259 實證），而 /fast 會把 fastMode: true 寫回。失效方向：jq 缺席／壞 JSON／非 true 值皆紅。
  if jq -e '.fastModePerSessionOptIn == true' settings.json >/dev/null; then
    ok "fast mode 需每 session 明示 opt-in（fastModePerSessionOptIn）"
  else
    bad "settings.json 的 fastModePerSessionOptIn 必須為 true（現值非 true、缺鍵、jq 缺席或檔案不可解析）——否則 fast mode 會以 usage credits 自動起跑"
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
  # 這個 SKIP 是刻意的 fail-open，不要順手改成 bad。本檔也由 SessionStart 的
  # drift-check 在本機跑，那裡 shellcheck 未必裝；改 bad 會讓本機每次都紅。
  # CI 端的洞由 ci.yml 的工具就緒步驟堵住——它在跑本檔之前就硬擋 shellcheck
  # 缺席。fail-closed 由 CI 承擔、本機保持寬鬆，是分工不是漏改。
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
# 形狀（§2），目標存在性由本機 `agents-sync --doctor` 負責。缺這道守衛時
# 全部 skill link 會一併誤判 FAIL——2026-08-01 run 30671830610 實證（當時 94 條）。
shared_skills="${SHARED_SKILLS_ROOT:-$HOME/.agents/skills}"
if [ ! -d "$shared_skills" ]; then
  printf '  SKIP  shared source 不可得（%s）；link 目標存在性由本機 agents-sync --doctor 負責\n' "$shared_skills"
else
  skill_bad=0
  # shared 側已 gitignore 的 skill 不參與一一對應斷言。這類 skill 是刻意永久不進版控
  # （個人工作脈絡，見本 repo .gitignore 的 exec-briefing 段），所以「source 在、link
  # 不在」是正常狀態而非斷鏈。沒有這個出口的話，本機恆紅而 CI 恆綠（CI 走上面的
  # SKIP 分支），且無法用任何既有機制消除——守衛失去訊號就是這樣開始的。
  # 用 if 不用 `&&`：這裡是條件跳過不是序列執行，`cmd && continue` 讀起來像後者。
  # 本檔是 `set -uo pipefail`（無 -e），所以 `&&` 當下不會中止；但它讓該行在條件不成立時
  # 回非 0，一旦日後被移到迴圈末尾、或本檔改開 -e，就會從「不跳過」變成「中止」。
  # repo root 由 $shared_skills 推導而非硬寫 $HOME/.agents：SHARED_SKILLS_ROOT 可覆寫來源，
  # 寫死會在覆寫時對「錯的 repo（或非 repo）」做 check-ignore，讓該跳過的 skill 仍進斷言。
  # 探測只做一次，不在迴圈內每圈呼叫 rev-parse。
  shared_root=$(cd "$shared_skills/.." 2>/dev/null && pwd -P) || shared_root=""
  shared_is_repo=0
  if [ -n "$shared_root" ] && git -C "$shared_root" rev-parse --git-dir >/dev/null 2>&1; then
    shared_is_repo=1
  fi
  while IFS= read -r source; do
    name=$(basename "$source")
    link="skills/$name"
    if [ "$shared_is_repo" -eq 1 ]; then
      if git -C "$shared_root" check-ignore -q "skills/$name"; then continue; fi
    fi
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
  # 訊息說的是「未引用 control plane」而不是「僅限 skills」：本斷言只擋 core|rules|hooks，
  # 而 CLAUDE.md 確實有非 skills 的 .agents ref（@~/.agents/profile.md）——那是三 host 都以
  # 絕對路徑讀的 runtime asset，不是 control plane，本來就該放行。舊措辭會讓下一個人以為
  # 有一道不存在的守衛。
  ok "active config 未引用 .agents control plane"
fi

# CLAUDE.md 的 @import 目標存在性。新增動機（2026-08-29）：@~/.agents/profile.md 指向一個
# 在別的 repo 被 gitignore 的檔案，換機還原後必然不存在，而 @import 失敗是**靜默**的——
# 上面那條 rg 斷言只驗「那行文字在」，不驗目標檔在。缺個人背景是 graceful degradation，
# 但 tier0-safety.md 同樣走 @import，斷鏈就是安全網靜默消失。
# 跳過指向 $HOME/.agents 的行（沿用本檔 shared_skills 段的同一個理由：CI 無 ~/.agents）。
# 逐類解析，不能一律展開成 `${HOME}`：CI 的 checkout 不在 `${HOME}/.claude`（runner 的家目錄是
# /home/runner，repo 在 /home/runner/work/dotclaude/dotclaude），所以 `~/.claude/x` 要相對
# **repo 根**解析才驗得到；一律用 $HOME 展開會讓 CI 恆紅——2026-08-29 run 33248987799 實證
# （FAIL: @import 目標不存在: ~/.claude/core/tier0-safety.md，而該檔就在 checkout 內且 tracked）。
# `~/.agents/x` 則相反：那是本機才有的外部依賴，CI 無該目錄時跳過。
# 跳過的判準是 `${HOME}/.agents` 本身而**不是** `${shared_skills}`，後者可被 SHARED_SKILLS_ROOT
# 指到別處，那時「shared skills 可得」與「~/.agents 可得」是兩件事，用前者判斷會在
# ~/.agents 不存在時仍去 -f 檢查它底下的檔案並誤報。判斷條件必須跟被判斷的路徑同源。
import_bad=0
import_skipped=0
while IFS= read -r line; do
  target=${line#@}
  case "$target" in
    "~/.claude/"*)
      probe=${target#\~/.claude/}   # repo 根就是 ~/.claude 的內容
      ;;
    "~/.agents/"*)
      if [ ! -d "$HOME/.agents" ]; then
        import_skipped=$((import_skipped+1))
        continue
      fi
      probe=${target/#\~/$HOME}
      ;;
    *)
      probe=${target/#\~/$HOME}
      ;;
  esac
  [ -f "$probe" ] || {
    # profile.md 給專屬訊息：它是 gitignored 且無異地備份的唯一一份，換機還原後
    # repo clone 得回來、它回不來——這是 graceful degradation（三家 runtime 的
    # 「缺檔則跳過」）加上「請手動重建」，不是 tier0-safety.md 那種安全網斷鏈。
    # 共用訊息會讓還原後的紅被誤讀成後者。
    case "$target" in
      "~/.agents/profile.md")
        bad "使用者背景檔不存在：~/.agents/profile.md（不進版控、無異地備份，需手動重建；三家 runtime 皆會 graceful 跳過）"
        ;;
      *)
        bad "CLAUDE.md @import 目標不存在: $target"
        ;;
    esac
    import_bad=$((import_bad+1))
  }
done < <(rg -N '^@' CLAUDE.md || true)
if [ "$import_bad" -eq 0 ]; then
  if [ "$import_skipped" -gt 0 ]; then
    ok "CLAUDE.md @import 目標皆存在（${import_skipped} 條指向 ~/.agents 者跳過：該目錄不可得）"
  else
    ok "CLAUDE.md @import 目標皆存在"
  fi
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
# 硬閘之外另設軟閘。2026-08-28 之前這裡只有硬閘，而 CLAUDE.md 距它只剩二十幾個 byte——
# 下一次改 anchor 或加一行條文就直接撞上，而硬閘沒有預警，只會在 PR 當下才紅。另兩家
# host 早就是兩層（Codex 與 Copilot 都是硬閘加 95% 軟閘），只有 Claude 這邊缺。
#
# 不在註解裡記當下的 byte 數與餘裕：那些每改一個字就過期，而兩道閘都還是綠的，沒有東西
# 會提醒你註解已經不對。實測數字進 commit message（那是有日期、不會被誤讀成現況的地方）。
#
# 兩者都是 FAIL 不是 warning：軟閘的作用是在還有空間時就逼人處理，而不是等撞上設計上限
# 才發現。失敗訊息帶實際 byte 數，因為「超過了多少」是決定要瘦身還是要重新檢視上限的依據。
_claude_md_bytes=$(wc -c < CLAUDE.md | tr -d ' ')
if [ "$_claude_md_bytes" -le 5000 ]; then
  ok "CLAUDE.md thin budget <= 5000B"
else
  bad "CLAUDE.md 超過 thin budget（${_claude_md_bytes}B）"
fi

if [ "$_claude_md_bytes" -lt 4750 ]; then
  ok "CLAUDE.md 在軟閘之內"
else
  bad "CLAUDE.md 已越過軟閘（${_claude_md_bytes}B）：距硬閘所剩無幾，先瘦身或重新檢視上限，不要等撞硬閘"
fi

if rg -q '^@~/.claude/core/tier0-safety\.md$' CLAUDE.md &&
   ! rg -q '^@~/.claude/core/tier[12]-' CLAUDE.md; then
  ok "只常駐載入 Claude-local tier0"
else
  bad "Claude core import 尚未 thin"
fi

# 使用者背景的載入必須留在 CLAUDE.md。三 host 都讀 ~/.agents/profile.md，但沒有任何
# 東西在守這件事——而它已經靜默消失過一次（2026-08-29：16:26 加入、17:00 依當時明示
# 移除、17:17 使用者改變決定要求補回）。前面的 @import 存在性迴圈驗的是「目標檔在不在」，
# 驗不到「這一行在不在」；整行被刪掉時那個迴圈只會少跑一圈，不會出聲。
# 對稱斷言：Codex 側在 ~/.codex/tests/global-config-ownership.sh 的 $contract 迴圈，
# Copilot 側在 ~/.copilot/tests/global-config-ownership.sh。三家各自獨立、零 byte 成本。
if rg -q '^@~/\.agents/profile\.md$' CLAUDE.md; then
  ok "CLAUDE.md 保留使用者背景載入"
else
  bad "CLAUDE.md 缺使用者背景載入：@~/.agents/profile.md"
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

# CLAUDE.md 禁用片語：曾被刪掉、不得回流的條文。一份清單一個迴圈，紅了點名是哪一條回流；新增禁用片語
# ＝清單多一項，不是多開一個 if 區塊（2026-09-05 前四處各自一段，其中一條藏在 Opus 5 autonomy 的合取裡，
# 紅了只印「delegation routing 漂移」）。用 grep -F 不用 rg：固定字串比對不需要 regex，且本段不依賴外部
# 工具、自行處理 rc≥2 而 fail-closed，與檔頭的 rg 守衛在不在無關。失效方向：命中即紅；grep rc≥2（CLAUDE.md 不可讀）也紅、
# 不冒充通過（同 §8 的掃描失敗處置）；只有全數未命中才印一條彙總 ok（同 §2／§5 的 per-item bad 形狀）。
# 只擋逐字回流，換句話會靜默放行——那要靠審查。各條來源：
#   superpowers: / mp-*              legacy workflow 名，已由 dev-workflow kernel 取代
#   <tone_preference>                曾與 harness 重複的 tone block
#   宣告接下來要做什麼               narration suppressor，與 harness progress line 衝突（#53）
#   …不派 subagent / 不拆多個 subagent / S5 以外不另派 subagent
#                                    Opus 5 delegation 特例，已由 shared [INT-4] routing 取代
forbidden_phrases=('superpowers:' 'mp-diagnose' 'mp-grill-with-docs' 'mp-improve-codebase-architecture' 'mp-tdd'
                   '<tone_preference>' '宣告接下來要做什麼'
                   '幾個 tool call 可完成的工作不派 subagent' '單一小任務不拆多個 subagent' 'S5 以外不另派 subagent')
phrase_bad=0
for phrase in "${forbidden_phrases[@]}"; do
  grep -Fq -- "$phrase" CLAUDE.md
  grep_rc=$?
  case "$grep_rc" in
    0) bad "CLAUDE.md 回流禁用片語: $phrase"; phrase_bad=$((phrase_bad+1)) ;;
    1) ;;
    *) bad "禁用片語掃描失敗（grep rc=${grep_rc}）——不當作通過: $phrase"; phrase_bad=$((phrase_bad+1)) ;;
  esac
done
[ "$phrase_bad" -eq 0 ] && ok "CLAUDE.md 無禁用片語：${#forbidden_phrases[@]} 條全數未回流"

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

# 2026-09-05 對照官方 Fable 5.1／Opus 5 prompting guide 的兩處 delta。正向：surgical-edit 行是官方
# 「targeted edits over whole-file rewrites」的 host 落點（auto mode 的 heredoc 改檔正推向整檔重寫）。
# 反向檢查（narration suppressor 不得回流）併在 §6 的禁用片語清單裡，理由寫在那裡。改寫 surgical-edit 行時同步本斷言。
if grep -Fqx -- '- 改檔以 surgical edit 為準；結果相同時不整檔重寫。' CLAUDE.md; then
  ok "CLAUDE.md 保留 surgical-edit 行"
else
  bad "CLAUDE.md 缺 surgical-edit 行（官方 Fable 5.1 targeted-edit delta）"
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

# drift-check.sh 的 stdout 契約（理由見該檔註解）；HOME 指到 fixture 讓 parity checker 因缺檔跳過。
dc_dir="$(mktemp -d "${TMPDIR:-/tmp}/repo-integrity.XXXXXX")" || dc_dir=""
if [ -n "$dc_dir" ] && mkdir -p "$dc_dir/hooks" "$dc_dir/tests" && cp hooks/drift-check.sh "$dc_dir/hooks/"; then
  # stub 吐 7 條 FAIL 夾 PASS（第二條是無縮排的 fail-open 自證行）並往 stderr 吐雜訊：釘「stdout 恰 = WARNING + 5 行、
  # 全是 FAIL、含無縮排那條、stderr 不外漏」——把 grep 拿掉、改數字、樣式從 ^ *FAIL 退回 ^  FAIL、拿掉 2>/dev/null 都得紅。
  printf '%s\n' 'echo noise >&2' \
    'printf "%s\n" "  PASS  a" "  FAIL  f1" "FAIL  unindented" "  PASS  b" "  FAIL  f2" "  FAIL  f3" "  FAIL  f4" "  FAIL  f5" "  FAIL  f6"' \
    'exit 1' > "$dc_dir/tests/repo-integrity.sh"
  dc_out=$(HOME="$dc_dir" bash "$dc_dir/hooks/drift-check.sh" 2>"$dc_dir/stderr"); dc_rc=$?
  dc_err=$(cat "$dc_dir/stderr")
  dc_lines=$(printf '%s\n' "$dc_out" | wc -l | tr -d ' ')
  dc_fails=$(printf '%s\n' "$dc_out" | grep -c '^ *FAIL')
  if [[ $dc_rc -eq 0 && $dc_out == WARNING* && $dc_out == *'FAIL  unindented'* && $dc_lines -eq 6 && $dc_fails -eq 5 && -z $dc_err ]]; then
    ok "drift-check 失敗時 stdout 恰為 WARNING + 5 條 FAIL（含無縮排 fail-open 行）、stderr 空、exit 0"
  else
    bad "drift-check 失敗輸出形狀不符 rc=${dc_rc} lines=${dc_lines} fails=${dc_fails} stdout=«${dc_out:0:80}» stderr=«${dc_err:0:80}»"
  fi
  printf 'exit 0\n' > "$dc_dir/tests/repo-integrity.sh"
  dc_out=$(HOME="$dc_dir" bash "$dc_dir/hooks/drift-check.sh" 2>"$dc_dir/stderr"); dc_rc=$?
  dc_err=$(cat "$dc_dir/stderr")
  if [[ $dc_rc -eq 0 && -z $dc_out && -z $dc_err ]]; then
    ok "drift-check 成功時無輸出"
  else
    bad "drift-check 成功時仍有輸出 rc=${dc_rc} stdout=«${dc_out:0:80}» stderr=«${dc_err:0:80}»"
  fi
else
  bad "drift-check 探針：無法建立 fixture"
fi
[ -n "$dc_dir" ] && rm -rf "$dc_dir"   # mktemp 成功但 mkdir／cp 失敗也要清

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
  # template 不可省，本檔每一處 mktemp 皆同。不寫處數：這行前一版寫「七處」，2026-08-28
  # 改寫時又寫成「六處」，兩個都錯（實際九處，`mktemp -d` 八處加一處帶字面 template 的
  # `mktemp`）——同一行在兩次修訂裡各數錯一次，正是「註解一複述可枚舉的數量就會漂移」
  # 這條的示範。理由同本檔那條寫著「上限只寫一次、三處引用」的註解（引句不引行號：
  # 行號會隨每次改動漂移，這行原本引的 :968 在同一個 commit 裡就已經被推移）。
  #
  # macOS 的 mktemp 在沒有 template 時走 confstr(_CS_DARWIN_USER_TEMP_DIR)（/var/folders/…/T/）而**忽略 $TMPDIR**，
  # 於是在只放行 $TMPDIR 的 sandbox 下全部 mkdtemp 失敗。fail-closed 分支會照實報，
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
# 檔頭的全域守衛在時本分支不會執行；本節的 rc≥2 處置本來就把 rg 缺席（rc=127）判成掃描錯誤，
# 這個分支歷來只負責讓訊息指名工具。留作全域守衛日後被移除時的訊息品質備援，不是安全網。
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

# ── 8b. 本檔註解內不得出現 ASCII 單引號 ──────────────────────────
#
# 本檔的斷言大量寫成 `jq -e QUOTE` … `QUOTE settings.json`，其中 QUOTE 是 ASCII 單引號，
# 中間整段（含 `#` 註解）都在同一個 bash 單引號字串內。註解裡再出現一個 ASCII 單引號就
# 提前結束該字串：後續的角括號變成 shell redirection、空白變成參數邊界，整支 jq 失效。
#
# 為什麼要機械守：這個失效不一定當場變紅。PR #38 的實例是引號**成對**出現在同一行
# （寫成 core.fsmonitor=＇［指令］＇ 的 ASCII 版），中間又剛好沒有 ASCII 空白，於是 bash
# 把三段串成同一個 word，jq 收到的程式只少了兩個位在 jq 註解內的字元——測試全綠，靠運氣。
# 對照實驗：在那對引號之間插入一個 ASCII 空白 → 83 PASS / 1 FAIL，整段 permission 檢查
# 失效。也就是「綠」與「守衛整段關掉」之間只隔一個空白字元，而 shellcheck 兩種都不報。
#
# 為什麼是「所有註解」而不是「jq 區塊內的註解」：後者要追蹤區塊起訖，而本檔的收尾行有
# 三種形狀（第 0 欄、縮排、以及 `… != "")QUOTE settings.json` 這種夾在行中間的），實作過
# 一版狀態機，三種形狀各漏一次、分別誤報 72 行與 12 行。無狀態規則沒有這個問題，代價是
# 對 jq 區塊外的註解也一併要求——那個代價很小（改用全形＇即可），而且是對的方向：程式碼
# 會被搬動，今天在區塊外的註解明天可能在區塊內。
#
# 上限（明講）：只管註解行。非註解行若在 jq 程式內出現 ASCII 單引號同樣會壞，但那裡是
# jq 程式碼，jq 的字串用雙引號，出現單引號本來就是錯的且多半會當場炸開，不靠這條。
# 同 §8：全域守衛在時本分支不執行；rc≥2 處置已 fail-closed，此分支只是訊息品質備援。
if ! command -v rg >/dev/null 2>&1; then
  bad "註解引號檢查需要 rg，但 rg 不可用（缺工具的失敗方向是假綠）"
else
  cq_rc=0
  cq_n=$(rg --count-matches "^\s*#.*'" tests/repo-integrity.sh) || cq_rc=$?
  if [ "$cq_rc" -eq 1 ]; then
    ok "本檔註解內無 ASCII 單引號（jq 的 bash 字串不會被提前截斷）"
  elif [ "$cq_rc" -ne 0 ]; then
    bad "註解引號檢查掃描失敗（rg rc=${cq_rc}）——不當作通過"
  else
    bad "本檔註解含 ASCII 單引號（${cq_n} 行）。它會提前結束 jq 所在的 bash 字串；即使目前成對而僥倖全綠，中間多一個 ASCII 空白就整支 jq 失效。改用全形單引號。定位：rg -n \"^\\s*#.*'\" tests/repo-integrity.sh"
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
# delimiter 以數字開頭的 `<<1` 與 `<<"1"`；第二版改成 `[^=[:space:]]`，又漏掉
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

# 跨檔 tripwire：本檔**直接驅動** hook，自己斷言 ci= 三態的決策。
#
# 為什麼上面那條不夠：它只呼叫 hook 自帶的 --selftest，而那些斷言與它們守的邏輯
# 同在一個檔案裡。把 hooks/guard-pr-merge.sh 整檔還原到分流之前，斷言會被一起帶走；
# 再依本檔 FAIL 訊息印出的指令重生 tests/hooks.sha256，整套就是 85 PASS / 0 FAIL
# 全綠，而 settings.json 仍宣稱 hook 會機械分流。S5 round 1 與 round 2 兩軸各自
# 實測過這條路徑。只還原 case 區塊（斷言留著）則是 83 PASS / 2 FAIL，抓得到——
# 抓不到的一直是**整檔**還原。
#
# 下面這幾條寫在本檔，所以還原 hook 不會連帶還原它們：整檔還原後 ci=ABSENT 與
# ci=CANCELLED 會變回放行，這裡就紅。這是唯一能守住那個方向的形狀。
# 探針形狀沿用同檔上方 _push_probe 的慣例，不另立一套。
merge_probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/repo-integrity.XXXXXX")" || merge_probe_dir=""
_guard_merge_abs="$PWD/hooks/guard-pr-merge.sh"
_merge_probe() { # $1=allow|deny $2=gate 印的第一行 $3=說明 [$4=deny 理由必含片語]
  local want="$1" line="$2" desc="$3" need="${4:-}" rc actual
  [ -n "$merge_probe_dir" ] ||
    { bad "pr-merge 守衛無法建立探針目錄"; return; }
  mkdir -p "$merge_probe_dir/repo"
  printf '#!/bin/sh\nprintf %%b %s\n' "'$line\n'" > "$merge_probe_dir/gate"
  chmod +x "$merge_probe_dir/gate"
  # fixture 有效性：gate 建不起來時 hook 走「找不到 pr-review-gate」，那也是 exit 2，
  # 於是每個 deny 案例都會假 PASS。這道檢查讓 fixture 壞掉表現為紅而不是綠。
  # 驗的是**逐字等於預期**而非「非空」：printf %b 會解釋反斜線，將來加一條含反斜線的
  # fixture 就會被靜默改寫，而非空檢查看不出來。同 commit 內 hook 的 runraw 同一理由。
  _mp_want=$(printf '%b' "$line")
  _mp_got=$("$merge_probe_dir/gate" 42 2>/dev/null || true)
  if [ ! -x "$merge_probe_dir/gate" ] || [ "$_mp_got" != "$_mp_want" ]; then
    bad "pr-merge 守衛探針 fixture 無效（fake gate 的輸出與預期不符）: $desc"; return
  fi
  if jq -nc --arg cmd 'gh pr merge 42' --arg cwd "$merge_probe_dir/repo" \
       '{tool_input:{command:$cmd},cwd:$cwd}' |
     PR_REVIEW_GATE="$merge_probe_dir/gate" bash "$_guard_merge_abs" \
       >"$merge_probe_dir/stdout" 2>"$merge_probe_dir/stderr"; then
    rc=0
  else
    rc=$?
  fi
  # hook 若讀不到 fixture gate，它會以「找不到可執行的 pr-review-gate」deny——那也是
  # exit 2，於是每個 deny 案例都會因為錯的理由而 PASS。selftest 的兩個 helper 都擋這條，
  # 這裡先前漏了。
  if grep -q '找不到可執行的 pr-review-gate' "$merge_probe_dir/stderr" 2>/dev/null; then
    bad "pr-merge 守衛探針：hook 沒讀到 fixture gate: $desc"
    return
  fi
  if [ "$rc" -eq 0 ] && [ ! -s "$merge_probe_dir/stderr" ]; then
    actual=allow
  elif [ "$rc" -eq 2 ] && [ -s "$merge_probe_dir/stderr" ] &&
    jq -se 'length == 1 and .[0].decision == "block"' \
      "$merge_probe_dir/stderr" >/dev/null 2>&1; then
    actual=deny
  elif [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then
    actual=BADOUTPUT
  else
    actual="BADEXIT($rc)"
  fi
  if [ "$actual" != "$want" ]; then
    bad "pr-merge 守衛 want=$want got=$actual rc=$rc: $desc"
    return
  fi
  # deny 的理由必須能分辨政策拒絕與格式漂移。只驗 exit code 的話，把政策分支整個
  # 刪掉、讓 ci=ABSENT 落到「缺欄」分支也是 exit 2，這裡完全看不出來。
  if [ -n "$need" ] &&
    ! jq -se --arg want "$need" '.[0].reason | index($want) != null' \
        "$merge_probe_dir/stderr" >/dev/null 2>&1; then
    bad "pr-merge 守衛 deny 理由未含「${need}」: $desc"
    return
  fi
  ok "pr-merge 守衛 ${want}: $desc"
}
_merge_probe allow 'STATE=PASS pr=42 head=abc ci=SUCCESS review=CURRENT unresolved=0' \
  'STATE=PASS'
_merge_probe allow 'STATE=PASS_NO_CI pr=42 head=abc ci=BILLING_QUOTA review=CURRENT unresolved=0' \
  'ci=BILLING_QUOTA（額度用盡是唯一被授權的降級）'
_merge_probe deny  'STATE=PASS_NO_CI pr=42 head=abc ci=ABSENT review=CURRENT unresolved=0' \
  'ci=ABSENT（CI 該跑而沒跑）' '不授權合併的降級狀態'
_merge_probe deny  'STATE=PASS_NO_CI pr=42 head=abc ci=CANCELLED review=CURRENT unresolved=0' \
  'ci=CANCELLED（CI 該跑而沒跑）' '不授權合併的降級狀態'
_merge_probe deny  'STATE=PASS_NO_CI pr=42 head=abc review=CURRENT unresolved=0' \
  'PASS_NO_CI 但無 ci= 欄' '沒有可辨識的 ci= 欄位'
_merge_probe deny  'STATE=FAIL_CI pr=42 head=abc review=CURRENT unresolved=0' \
  'STATE=FAIL_CI' 'merge gate 未通過'
# 上面那組的 ci= 全落在行中，那是每一版都處理正確的形狀，所以它們只抓得到
# 「ci= 分流被整套拿掉」。下面那組才是本 branch 每一版**各自**弄錯的形狀，
# （兩組都不寫條數：前一版寫「下面這四條」而實際是六條，2026-08-28 S5 指出。理由同
# 本檔那條寫著「不寫案數：這行原本寫『18 案』，之後每加一批就漂一次」的註解。）
# 抓的是「分流退回某個有 bug 的版本」——那才是真正會發生的迴歸。
#   ci= 落在行尾              第一版要求 ci 值右側有空白，於是唯一被授權的狀態被擋，
#                             而政策值拿到「找不到 ci= 欄」這個相反的理由。
#   值含空白／值裡有 tab       第二版補了前後空白與 tab 正規化，反而讓不存在的 ci= 欄
#                             被子字串冒充，方向是 fail-open。
_merge_probe allow 'STATE=PASS_NO_CI pr=42 head=abc review=CURRENT unresolved=0 ci=BILLING_QUOTA' \
  'ci=BILLING_QUOTA 落在行尾'
_merge_probe deny  'STATE=PASS_NO_CI pr=42 head=abc review=CURRENT unresolved=0 ci=ABSENT' \
  'ci=ABSENT 落在行尾' '不授權合併的降級狀態'
_merge_probe deny  'STATE=PASS_NO_CI pr=42 head=abc reason=fell back to ci=BILLING_QUOTA' \
  '值含空白時子字串不得冒充 ci= 欄' '不是純 KEY=VALUE'
_merge_probe deny  'STATE=PASS_NO_CI pr=42 head=abc note=see\tci=BILLING_QUOTA' \
  '值裡的 tab 不得製造出 ci= 欄' '第一行混用了 tab'
_merge_probe deny  'STATE=PASS_NO_CI pr=42 x=1\tci=ABSENT ci=BILLING_QUOTA' \
  '混用 tab 與空白時不得繞過政策值' '第一行混用了 tab'
_merge_probe deny  'STATE=PASS_NO_CI pr=42 head=abc ci=BILLING_QUOTA ci=RUNNER_OUTAGE review=CURRENT' \
  '授權值與未知值同行時保守拒絕' '一個以上的 ci= 欄位'
# 同 push_probe_dir 的慣例（本檔下方 rm -rf 那一行）：探針目錄用完即清，否則本機反覆
# 跑會在 TMPDIR 累積。CI 每次都是新 runner 所以看不出來，這是本機才會顯現的洩漏。
[ -z "$merge_probe_dir" ] || rm -rf "$merge_probe_dir"

# guard-s5-ledger 同理：它自帶 selftest（含 SIGPIPE 競態回歸），但註冊上線時沒有
# 任何東西呼叫它。這支的失效模式是靜默 fail-open——PreToolUse 只有 exit 2 阻擋，任何
# 意外的 exit 1 都等於放行——沒接線就沒有東西會發現它退化。
# 不寫案數：這行原本寫「18 案」，之後每加一批就漂一次，光這輪就漂了兩回。案數由
# `grep -c "^  run_case "` 現查即得，寫進註解只是替未來製造 doc rot。
if [ -f hooks/guard-s5-ledger.sh ]; then
  if _s5l_out=$(bash hooks/guard-s5-ledger.sh --selftest 2>&1); then
    ok "s5-ledger 守衛 selftest: $(printf '%s' "$_s5l_out" | tail -1)"
  else
    printf '%s\n' "$_s5l_out" | tail -5
    bad "s5-ledger 守衛 selftest 失敗（上列為輸出末段）"
  fi
fi

# turn-mode（UserPromptSubmit steer）的分類案例同樣自帶 --selftest：問題型 ask steer／開發型
# dev steer（ultracode 已關，dev 視同該回合 opt-in）／明示 opt-in 與機械任務靜默。S5 round 1 指出
# commit 宣稱「6 案例」但 diff 內無任何測試，regex 回歸無人守——接線後 case 跟著 hook 走，不另抄
# 一份會漂移的期望值。
if [ -f hooks/turn-mode.sh ]; then
  if _tm_out=$(bash hooks/turn-mode.sh --selftest 2>&1); then
    ok "$(printf '%s' "$_tm_out" | tail -1)"
  else
    printf '%s\n' "$_tm_out" | tail -5
    bad "turn-mode selftest 失敗（上列為輸出末段）"
  fi
  # 主路徑（stdin JSON → jq → classify → case 分派）不在 --selftest 射程內：S5 實測把 dev 分支
  # 換成 STEER_ASK，selftest 仍全綠。下面前三條從 hook 外面打 stdin，各釘住一個分支輸出的字面，
  # 第四條釘大提示截斷後的尾錨；失效方向：hook 崩潰或 jq 缺席都會讓 dev／ask 兩條拿到空輸出 → 紅，不會偏綠。
  # 形狀比照 _push_probe：section 一個 fixture 目錄、每 case 一行 ok／bad（bad 印 want／got／stderr）；只判 stdout。
  # 探針一律把 HOME 指到 fixture 目錄，本機真 settings.json 的 ultracode 值不參與這幾條的紅綠——那個鍵由
  # 上方 §1 的獨立斷言釘，這裡只驗 hook 對 true／false 各自的行為。
  tm_probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/repo-integrity.XXXXXX")" || tm_probe_dir=""
  _tm_probe() {  # $1 = 分類名 $2 = prompt $3 = 期望 stdout 含此片段，空字串＝期望 stdout 為空 [$4 = 不得含此片段]
    local want="$3" deny="${4:-}" out err
    [ -n "$tm_probe_dir" ] || { bad "turn-mode 主路徑 $1：無法建立 fixture 目錄"; return; }
    out=$({ jq -nc --arg p "$2" '{prompt:$p}' | HOME="$tm_probe_dir/home" bash hooks/turn-mode.sh; } 2>"$tm_probe_dir/stderr")
    err=$(cat "$tm_probe_dir/stderr" 2>/dev/null)
    if [[ ( -z "$want" && -z "$out" || -n "$want" && "$out" == *"$want"* ) && ( -z "$deny" || "$out" != *"$deny"* ) ]]; then
      ok "turn-mode 主路徑 $1 → ${want:-無輸出}${deny:+（且不含 ${deny}）}"
    else
      bad "turn-mode 主路徑 $1 want=«${want:-無輸出}»${deny:+ deny=«${deny}»} got=«${out:0:80}»${err:+ stderr=«${err:0:80}»}: ${2:0:60}"
    fi
  }
  _tm_probe dev    '審查這個 PR 的 Standards 與 Spec 兩軸' '開發型任務'
  _tm_probe ask    '為何 build 失敗' '問題／分析型'
  _tm_probe silent '安裝https://github.com/cathrynlavery/diagram-design' ''
  # 超過 8K 的提示只掃頭尾各 4K（效能），$ 錨必須留在真正的串尾：貼 9K log 再問「審查過了嗎」仍要是 ask
  _tm_probe big    "$(printf 'x%.0s' $(seq 1 9000))"$'\n審查過了嗎' '問題／分析型'
  # ultracode 守衛：settings.json 的 ultracode 為 true（repo-state drift）時，silent 類提示要多一行 steer；
  # dev／ask 不變，系統通知與明示 opt-in（skip）連 steer 都不給；false 時 silent 維持無輸出。
  if [ -n "$tm_probe_dir" ] && mkdir -p "$tm_probe_dir/home/.claude"; then
    printf '{"ultracode":true}\n' > "$tm_probe_dir/home/.claude/settings.json"
    _tm_probe 'ultracode=true silent' '安裝https://github.com/cathrynlavery/diagram-design' 'ultracode=true（'
    _tm_probe 'ultracode=true dev'    '審查這個 PR 的 Standards 與 Spec 兩軸' '開發型任務' 'ultracode=true（'
    _tm_probe 'ultracode=true ask'    '審查過了嗎' '問題／分析型' 'ultracode=true（'
    _tm_probe 'ultracode=true notice' $'[SYSTEM NOTIFICATION - NOT USER INPUT]\n<task-notification>x' ''
    _tm_probe 'ultracode=true optin'  'ultracode 幫我更新所有 plugin' ''
    printf '{"ultracode":false}\n' > "$tm_probe_dir/home/.claude/settings.json"
    _tm_probe 'ultracode=false silent' '安裝https://github.com/cathrynlavery/diagram-design' ''
  else
    bad "turn-mode ultracode 守衛：無法建立 fixture settings"
  fi
  [ -n "$tm_probe_dir" ] && rm -rf "$tm_probe_dir"
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

# ── environment 條目數上限（handoff E1 方向 ii）────────────────────────────────────
# 上面那條 blocklist 只比對三個硬編碼歷史字串，只認已經犯過的錯。這條補的是**條目數**：
# 上限 6 機械命中 3/3 個歷史失敗版本、對現況零誤擋（實測 4 ≤ 6）。那三個失敗版本的
# custom entry 數見下方 ENV_HIST——**來自前一 session 的 S5 退回紀錄，不在本 repo 歷史裡**，
# 所以那幾個數字是 session note，無法在此覆現，別把它們當可稽核量測引用。
#
# 為什麼走條目數而不是內容：內容路線實作過一版，被 S5 兩軸退回。量測與那條路的致命
# 缺陷完整記在下方「為什麼沒有同時做 open-world 內容偵測」整段，此處不複述。
#
# 已知取捨（明講）：`/auto-mode-setup` wizard 會把 proposal 寫回
# `autoMode.environment`（binary 實測 `autoMode:{environment:a.proposal.environment,…}`）。
# 跑完 wizard 若超過上限，這條會紅一次。那是刻意的——wizard 一次塞進來的內容本來就
# 該有人看過再決定留哪些。與 ultracode 當年被移除釘死（§1 註解；該前提 2026-09-05 已推翻、鍵已釘回，
# 類比只取「每次正當調整都紅」）不同：那是被當成使用者經 /config 或 prompt **逐次開關**的偏好，每次調整
# 都紅；wizard 是刻意執行的單次動作。
#
# **已知盲點：這條只數 entry 數，看不見 entry 內部的膨脹。** 2026-08-24 寫下這條時
# environment[4] 是 1268 字元，2026-08-27 已是 1473，而 count 從頭到尾都是 4——上限
# 完全沒動過。也就是說「少寫」這個激勵只作用在條目數上，把三條併成一條寫得更長反而
# 讓這道守衛更綠。
# 不補字數上限，理由與 ultracode 當年被移除（§1 註解）同形：字數會隨每次正當編輯漂移，設在 1473
# 稍上方等於下一次合理擴充就紅一次，而紅的次數多了就會被調高，調高幾輪後門檻失去意義。
# 那正是 ultracode 當年被移除的跑步機。要擋「一條寫成一整頁」得靠 review，不是靠數字。
#
# 上限只寫一次、三處引用。ci.yml:23 記過同一個反模式：「註解一旦複述腳本內容就會漂移
# （原本寫 12，實際已是 21）」——ok／bad 訊息字串也算複述，所以一併走變數。
ENV_CAP=6
# 歷史失敗版本的 custom entry 數同樣只寫一次。上一版把 ENV_CAP 抽成變數卻把這個數列
# 留在三處（本註解＋ok＋bad），是同一個 hunk 裡半套的修法（S5 round 2 指出）。
ENV_HIST="12／13／8（session note，不在本 repo 歷史，無法在此覆現）"
# type 檢查不可省，而且不能寫成 `select(type=="array")`。前一版是裸的
# `[.autoMode.environment[] | …] | length`，S5 Spec 軸實測：把該鍵換成
# `{"a":"x","b":"y"}` 時 jq 的 `.[]` 會迭代 **object 的值**，length 回 2，通過數字形狀
# 檢查且 2 ≤ 6 → 印 PASS。改成 select(type=="array") 也不行——非陣列時它產出空串流，
# length 變 0，一樣印 PASS，只是把 2 換成 0。要 fail-closed 必須讓 jq 自己**非零退出**，
# 所以用 error()：stdout 空 → 下面的形狀檢查不匹配 → bad。
# 2026-08-27 型別矩陣實測：object／string／number／null／鍵刪除 五種全部落到 bad。
env_count=$(jq '.autoMode.environment | if type == "array" then [.[] | select(. != "$defaults")] | length else error("not an array") end' settings.json 2>&1)
# 形狀檢查用 bash 內建 =~ 而非 `printf | grep -Eq`：省兩個 process，且不依賴 grep 的身分。
# 本機互動 shell 的 grep 是 ugrep function、script 裡是 BSD grep，兩者行為會飄（同型記載
# 見 ci.yml:21-22 對 ripgrep 缺席的處置，以及 memory grep-is-ugrep-silent-failure）。
# 九種輸入實測兩種寫法判定逐一相同：空字串／4／0／04／7／abc／-1／3.5／前導空白加 4。
# 形狀用 ^(0|[1-9][0-9]*)$ 而非 ^[0-9]+$，與 pr-review-gate:141 同：後者只驗「長得像數字」，
# 04 會通過，再進 [ -le ] 就被讀成八進位。目前 jq 的 length 不可能吐 04，所以這是對齊而非
# 修 bug——但上一行把 04 列在「已測輸入」裡，那個寫法會讓下一個人以為它被處理了。
# 這原本是本檔唯一的 `grep -Eq`。**不要據此寫成「其餘一律用 rg」**——前一版就是這樣寫的，
# 而枚舉一跑就破：本檔仍有 24 個 grep 呼叫點（-q／-Fq／-Fqx／-E／-c 等）。改的只是這一處
# 的數字形狀檢查，不是全檔遷移。這是本 session 第三次犯同一種未枚舉就下覆蓋面斷言的錯，
# memory coverage-claims-need-mechanical-enumeration 記的就是它。
if [[ ! "$env_count" =~ ^(0|[1-9][0-9]*)$ ]]; then
  # jq 失敗、鍵不存在、或型別不是陣列都會讓這裡拿不到數字。fail-closed：
  # 同檔其他檢查一律 `jq -e … ; then ok; else bad`，前一版這裡用
  # `$(jq … 2>/dev/null)` + 空字串判定，實測對壞掉的 JSON 與缺席的 jq 都印 PASS。
  # 收 stderr 而非丟棄：本檔第 1 節（:32）就是 `if err=$(jq empty … 2>&1)` 的形狀，
  # 失敗時把 jq 自己的第一行訊息帶進 bad。丟棄它會讓「型別錯」「JSON 壞」「jq 不存在」
  # 三種原因印出完全一樣的一行，而這正是同檔另一條 bad 訊息剛花力氣改掉的毛病。
  bad "autoMode.environment 條目數讀不出來，無法判定是否超過上限（jq: ${env_count%%$'\n'*}）"
elif [ "$env_count" -le "$ENV_CAP" ]; then
  ok "autoMode.environment custom entries = ${env_count}（上限 ${ENV_CAP}；歷史失敗版本 ${ENV_HIST}）"
else
  bad "autoMode.environment custom entries = ${env_count}，超過上限 ${ENV_CAP}。前一 session 被 S5 退回的三個版本分別是 ${ENV_HIST} —— 條目一多就開始塞進未經查證的環境斷言。若這批是 /auto-mode-setup wizard 寫入的，請逐條檢視後刪到上限以內，或在確認每條都有 live evidence 後調高 ENV_CAP 並說明理由。"
fi

# ── 為什麼沒有同時做 open-world 內容偵測（2026-08-24）──────────────────────────────
#
# 這裡的「那條」指本檔上方那個 blocklist（三個硬編碼歷史字串），不是它與本段之間的
# entry 數上限。看起來顯然該把 blocklist 換成「偵測全稱斷言的形狀」，實作過一版
# （正規表示式：全稱量詞命中且同一 entry 內無 hedge 詞則報紅），
# 被 S5 兩軸退回。實測數據，留著避免下一個人重走：
#
#   * 危險的無條件全稱斷言 9/10 漏抓；正當敘述 5/5 誤擋
#   * harness 自己的 $defaults.environment 20 條中誤 flag 16 條，全是
#     "**Cloud provider(s)**: None configured" 這種最安全的敘述
#   * 四條「該紅」案例每一條加一個 hedge 片語就轉綠。而 hedge 清單是**被檢查者自己
#     寫的文字**：這道守衛的對手模型就是 agent 自己，等於把豁免開關交給對手。
#     這是最要命的一條——上面的數字都可以靠更好的表達式改善，這條不行。
#   * 詞彙表本身也是 closed-world：any／cannot／impossible／exclusively／zero／sole
#     一個都不在內
#   * 前一 session 那句真正錯的斷言是
#     "Every repo under github.com/BriantsaiCoder is private EXCEPT …/gym-auth-api"
#     （實測 98 個 repo 有 74 個 PUBLIC）。它因為 EXCEPT 在 hedge 清單裡而被放行 ——
#     "Every X EXCEPT Y" 是帶 carve-out 的全稱，EXCEPT 是該斷言的構成部分，不是 hedge
#
# 兩個先前寫在這裡、後來被 S5 實測推翻的說法，更正如下（原文有誤，勿再引用）：
#   * 曾寫「真陽性集合 ⊆ blocklist，淨防護為零」——**錯**。blocklist 只比對三個字串，
#     而上面那句 EXCEPT 斷言不匹配其中任何一個；把 except 移出 hedge 清單後偵測器就
#     抓得到它。淨防護不為零。
#   * 曾寫「onboarding 接受後會寫回 environment，所以與 ultracode 同一個陷阱」——
#     **錯**。binary 實測：`tengu_auto_mode_env_onboarding_accept` 分支只發 telemetry
#     並清掉 local state，不寫 environment；且其顯示 gate 在 environment 非空時直接
#     return false。真正寫回的是刻意執行的 `/auto-mode-setup` wizard。當初只憑
#     telemetry 事件名推論就寫進註解，違反 [T0-1]。
#
# 這條路仍然不做，但理由要準確：不是「做不到」，是**做出來的東西對手可以關掉**。
# 上面的 entry 數上限沒有這個性質，所以走那條。

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
  ([.autoMode.hard_deny[] | select(index("settings.json") != null)] | length >= 1) and
  # 極性 anchor：只釘 `widen a permission` 抓不到句子被反轉（見上方「上限」）。連動詞前的
  # 否定詞一起釘，對 Never→Do not 這種無害改寫仍放行。
  ([.autoMode.hard_deny[] | select(test("(Never|Do not) widen a permission"))] | length >= 1) and
  # 授權句 anchor：釘住「指名」這個限定詞。把它弱化成 `Any user instruction, however
  # general,`（或整句刪除）時，上面三條都抓不到，只有這條會紅。
  ([.autoMode.hard_deny[] | select(index("naming the specific change") != null)] | length >= 1) and
  # ── hard_deny[1]（merge gate）的 anchor，2026-08-27 補 ─────────────────────────
  # 上面四條全部釘在談 settings.json 的那條（現為 hard_deny[3]）。merge gate 那條
  # （hard_deny[1]）在**補這幾條之前**是零覆蓋：2026-08-27 於 c2ee288 實測
  # del(.autoMode.hard_deny[1]) → 84 PASS / 0 FAIL，一條都沒紅（在 096cb51 之後同一個
  # 突變是 83 / 1，那正是本區塊的作用——在補完的樹上重跑會得到相反的數字，別誤讀）。
  # 整條「未經 pr-review-gate PASS 不得 merge」當時可以被一次編輯刪掉而 CI 全綠——與本
  # 區塊開頭對 hard_deny[3] 的警告是同一個破口，當時只補了其中一條。
  #
  # 釘四個片語，各對應該規則的一個獨立構成要件，任一被字面刪除都紅：
  #   1. 禁令極性     Never merge a pull request unless
  #   2. gate 身分    pr-review-gate reported STATE=PASS（工具名＋要求的狀態）
  #   3. 新鮮度       at the current head SHA in this session
  #   4. 封閉性       every other STATE remains forbidden
  # 第 4 條最要緊：沒有它，把描述放寬成「PASS 開頭的狀態都算」不會被察覺，而 gate 對
  # PASS_NO_CI 刻意回非 0 exit code，正是要逼呼叫端明確認得那個字串。
  #
  # 刻意**不**釘 `no CI run was ever created`：那句與
  # ~/.agents/skills/dev-workflow/references/review-triage.md 第 2 節不同步（見下方
  # 2026-08-27 的紀錄），本身是待裁決對象。拿待改的句子當 anchor，會讓修正它的那個
  # commit 被自己的守衛擋下。
  #
  # 上限與上面同源，但要說準（前一版說得太寬）：抓的是**被釘的那幾個片語**的字面刪除與
  # 替換，不是「字面刪除」一般。未被釘的整句照樣可以整段刪掉而全綠——S5 round 2 逐格實測，
  # 以下各種刪除各自 84 PASS / 0 FAIL（不寫項數：註解一複述可枚舉的數量就會漂移，
  # 前一版寫「五種」而列出的是四項）：hard_deny[1] 的
  # `Never merge when CI is pending…` 整句、`; hosted CI stays UNAVAILABLE…` 整段子句；
  # hard_deny[2] 的 `, and never delete releases or tags`；hard_deny[3] 的
  # `Route every settings.json change through the Edit tool…` 整句。
  # 語意反轉與加字則在原理上就抓不到，兩者都另有實測。
  # 上限二（S5 Spec 軸 S7）：這些條釘的是「**某一條** hard_deny 含該片語」，不是
  # 「hard_deny[1] 含該片語」。今天 del(.autoMode.hard_deny[1]) 會紅，只因這些片語別處
  # 都沒有；把整句搬進 hard_deny[3] 則 merge gate 那條仍可被刪而守衛全綠。與既有
  # hard_deny[3] anchor 同慣例，不另立形狀，但這個上限要寫出來。
  # 為什麼排除句 2（`no CI run was ever created`）卻釘句 3（封閉語）——這個區別上一版沒
  # 講（S5 Standards 軸 F5 指出）：句 2 描述**哪些狀態算數**，那正是待裁決的內容；句 3
  # 說**除此之外全部禁止**，那是這條規則的不變式，任何裁決結果都該保留它。判準是「這句
  # 話會不會因為裁決而改變」，不是「這句話離爭議多近」。
  # 給日後改寫的人：若順手把封閉語重寫成「These three are exhaustive; all other states
  # stay forbidden」會紅——那是守衛正常運作，改回字面或連同本行一起更新即可。
  # 2026-08-27 round 2 重測的完整矩陣。**套件總數不足以證明「各自承重」**：這些條都是同一
  # 個 jq -e 的合取，任何一條掛掉都印同一行，看不出是誰。所以主證據是**逐 anchor 的命中數**
  # （1 = 該片語仍在，0 = 已消失）；套件總數只放在最右欄佐證。前一版只有四欄、且是在補進
  # 第五條 anchor 之前量的，round 2 指出 a2 那列已失真（見下方 or-enum 與 gate 身分兩列）。
  #
  #  mutation                          A1 A2 A3 A4 A5 A6 A7 A8 A9 A10 A11  套件
  #  identity（負控制）                 1  1  1  1  1  1  1  1  1  1   1   85/0
  #  or-enum：插入 STATE=FINDINGS       0  1  1  1  1  1  1  1  1  1   1   84/1
  #  禁令極性：Merge only if            1  0  1  1  1  1  1  1  1  1   1   84/1
  #  gate 身分：reported→returned       0  1  0  1  1  1  1  1  1  1   1   84/1
  #  新鮮度：去掉 current               1  1  1  0  1  1  1  1  1  1   1   84/1
  #  封閉性：all other states           1  1  1  1  0  1  1  1  1  1   1   84/1
  #  ci=ABSENT 全數改名（gsub）         1  1  1  1  1  1  1  1  1  1   1   84/1
  #  ci=CANCELLED 全數改名（gsub）      1  1  1  1  1  0  1  1  1  1   1   84/1
  #  ci=BILLING_QUOTA 全數改名（gsub）  1  1  1  1  1  1  0  1  1  1   1   84/1
  #  evidence：拿掉兩軸                 1  1  1  1  1  1  1  0  1  1   1   84/1
  #  hook 事實：splits mechanically     1  1  1  1  1  1  1  1  0  1   1   84/1
  #  禁令句整句刪除                     1  1  1  1  1  1  1  1  1  0   1   84/1
  #  suppressed 整段刪除                1  1  1  1  1  1  1  1  1  1   0   84/1
  #
  #  A1 or-enum  A2 禁令極性  A3 gate 身分  A4 新鮮度  A5 封閉性  A6 ci=CANCELLED
  #  A7 ci=BILLING_QUOTA  A8 evidence  A9 hook 事實（片語 2026-08-27 由 STATE alone
  #  改為 splits them mechanically，因為 hook 那側真的改成機械分流了）  A10 禁令句
  #  A11 suppressed
  #  （A12 ci=ABSENT 為 PR #38 Copilot 補釘，不在上表欄位內；其突變列已加在上面，
  #    該列在 A1–A11 全為 1 而套件 84/1，正是「只有新加的那條抓得到」的形狀）
  #
  # 兩件要說準的事：
  #   * **A1 與 A3 重疊**：兩者都含 `reported STATE=PASS`，所以 gate 身分那列同時歸零兩欄。
  #     它們仍各自承重（or-enum 那列只殺 A1，`pr-review-gate`→`the gate` 只殺 A3），但
  #     「一格一欄」對這一對不成立。
  #   * **A6／A7 要用 gsub 才紅**：`ci=CANCELLED` 與 `ci=BILLING_QUOTA` 現在各出現兩次
  #     （狀態枚舉一次、禁令句一次），只改一處時另一處仍讓 index() 命中。也就是這兩條釘的
  #     是「這個狀態名還在文件裡」，**不是**「每一處都拼對」。單處錯字抓不到。
  # 負控制的份量也要說準：identity 之外那格替換的是**未被任何 anchor 覆蓋**的片語，證明的
  # 是「該處無關改寫不誤擋」，不是通則。要證通則得改動緊鄰 anchor 的文字。
  # 允許狀態的**完整枚舉**要一起釘，不能只釘 `reported STATE=PASS`。S5 Standards 軸實測
  # 的加字繞過：把 `STATE=PASS or STATE=PASS_NO_CI` 改成
  # `STATE=PASS, STATE=FINDINGS, or STATE=PASS_NO_CI` → 84 PASS / 0 FAIL 全綠，而
  # review-triage.md 第 3 節明列 FINDINGS 不得 fallback。也就是 merge gate 被改成放行一個
  # 明文禁止的狀態，守衛一聲不吭。釘整個 `or` 片語就抓得到插入。
  # 仍抓不到的（誠實列出）：在句末另起一句加豁免（`This rule does not apply when …`）、
  # 把新鮮度句改寫成 `…in this session, or at any earlier SHA if no code changed since`。
  # 兩者實測皆 84 PASS / 0 FAIL。substring anchor 對**加字**在原理上就沒有辦法。
  ([.autoMode.hard_deny[] | select(index("reported STATE=PASS or STATE=PASS_NO_CI") != null)] | length >= 1) and
  ([.autoMode.hard_deny[] | select(index("Never merge a pull request unless") != null)] | length >= 1) and
  ([.autoMode.hard_deny[] | select(index("pr-review-gate reported STATE=PASS") != null)] | length >= 1) and
  ([.autoMode.hard_deny[] | select(index("at the current head SHA in this session") != null)] | length >= 1) and
  ([.autoMode.hard_deny[] | select(index("every other STATE remains forbidden") != null)] | length >= 1) and
  # 2026-08-27 第二批：上面四條釘的是這條規則**原本就有**的四個要件；同日把 PASS_NO_CI
  # 的三個 ci 值與各自條件寫進 hard_deny[1] 之後，那段新內容自己又是零覆蓋（實測：改寫
  # "covers exactly three ci values" 84 PASS / 0 FAIL，整段刪除同理）。同一個破口不要再犯
  # 第三次，所以新內容當場補釘。
  #   ci=CANCELLED / ci=BILLING_QUOTA  兩個狀態名被刪 = 規則退回只認 ABSENT，而 gate 仍對
  #                                    三者印同一個 STATE，落差重新打開
  #   independent Standards and Spec review  local evidence 本體被**字面刪除**時會紅。
  #                                    前一版在這裡寫「刪掉它們就變成無條件放行」，暗示這條
  #                                    守得住那個義務——**守不住**。S5 round 2 實測：保留片語
  #                                    原字不動，把 `CANCELLED and BILLING_QUOTA may not: each
  #                                    additionally requires` 改成 `may as well: each ideally
  #                                    also benefits from` → 84 PASS / 0 FAIL，義務由必要變成
  #                                    可選而全綠。substring anchor 抓不到極性反轉，本檔別處
  #                                    已寫明這一點，那句話與自己的檔案牴觸。
  #   splits them mechanically         釘的是 settings.json 這一側的字面，**不是**兩邊的耦合。
  #                                    前一版釘的是 matches on the STATE field alone，並宣稱
  #                                    「哪天 hook 真的改成比對 ci=，這條會紅，逼兩邊同步」——
  #                                    S5 round 2 用一份會動的 patch 推翻：真的改了
  #                                    guard-pr-merge.sh 去分辨 ci=、依 FAIL 訊息指示重跑
  #                                    hooks.sha256，結果 84 PASS / 0 FAIL、hook selftest 全綠，
  #                                    而 settings.json 仍寫著 passes all three identically，
  #                                    此時它已是假的。2026-08-27 那次分流真的落地了，同一個
  #                                    commit 把該敘述換成本片語，假敘述就此消失——但**上限
  #                                    沒有變**：這條仍只在片語從 settings.json 消失時才紅。
  #                                    若有人把 guard-pr-merge.sh 的 ci= 分流退回無條件放行、
  #                                    settings.json 一字不動，這條照樣綠。耦合仍然是單向的。
  #                                    反向那一側能守到多少，S5 round 1 兩軸各做了一種還原，
  #                                    結果相反，兩個都要記：
  #                                      * 只還原 case 區塊、selftest 與 settings.json 不動
  #                                        → 本套件 83 PASS / 2 FAIL（hook selftest 紅 + 指紋
  #                                        不符），抓得到。
  #                                      * **整檔**還原 guard-pr-merge.sh 再依 FAIL 訊息的指示
  #                                        重生 tests/hooks.sha256 → 本套件 85 PASS / 0 FAIL
  #                                        全綠，而 settings.json 仍宣稱 hook 會分流。抓不到。
  #                                        兩道防線同時失效的原因不同：指紋是照它自己印出來的
  #                                        修復指令重生的；selftest 的斷言與它守的邏輯同在一個
  #                                        檔案，整檔還原會把斷言一起帶走。
  #                                    所以正確的說法是「**部分**還原抓得到」，不是「反向那一側
  #                                    由 selftest 與指紋負責」。本段前一版就是後者，已被實測
  #                                    推翻。要堵整檔還原，唯一有效的形狀是在**本檔**用假 gate
  #                                    實跑一次 hook 並斷言 ci=ABSENT 被擋——那是 hook 之外的
  #                                    斷言，不會跟著它一起被還原。2026-08-27 已實作，見本檔
  #                                    pr-merge 守衛 selftest 那段下方的 _merge_probe。
  #                                    數字必須標明還原到**哪一版**，否則會再次高估自己：
  #                                    第一版的 _merge_probe fixture 全把 ci= 放在行中，
  #                                    於是還原到 426b81f（分流落地前）是 88/3 抓得到，
  #                                    還原到 7aad9c1（分流有 bug 的第一版）卻是全綠——
  #                                    行中形狀每一版都對，測它等於沒測。同一段落至此
  #                                    第三次高估自己的覆蓋率。補上行尾與值含空白的
  #                                    fixture 之後，兩個方向才都會紅。
  # 這四條的實測結果併入上方那張逐 anchor 矩陣（A6～A9 欄），此處不重複。
  # A9 那一列的標籤已隨本次改名更新為新片語；其突變仍是「把該片語從 settings.json 刪掉」，
  # 與改名前同型，故沿用原本量到的 84/1，未重新量測的部分只有標籤本身。
  # ci=ABSENT 這條是 PR #38 的 Copilot 補的：三個狀態名裡只有它沒被釘，而規則文字自己
  # 宣稱「covers exactly three ci values」。實測 gsub 把 ci=ABSENT 全數改名 → 85 PASS /
  # 0 FAIL 全綠，也就是把 ABSENT 從規則裡拿掉不會被察覺，「內容與守衛不同步」原地復發。
  # 三條一起釘之後，任何一個狀態名整批消失都會紅。
  # 與 A6／A7 同一個上限：釘的是「這個狀態名還在文件裡」，不是「每一處都拼對」——現在
  # 三個名字各出現兩次（狀態枚舉一次、授權句一次），單處錯字仍抓不到。
  ([.autoMode.hard_deny[] | select(index("ci=ABSENT") != null)] | length >= 1) and
  ([.autoMode.hard_deny[] | select(index("ci=CANCELLED") != null)] | length >= 1) and
  ([.autoMode.hard_deny[] | select(index("ci=BILLING_QUOTA") != null)] | length >= 1) and
  ([.autoMode.hard_deny[] | select(index("independent Standards and Spec review") != null)] | length >= 1) and
  ([.autoMode.hard_deny[] | select(index("splits them mechanically") != null)] | length >= 1) and
  # 2026-08-27 round 2：改寫把 ABSENT／CANCELLED 從「可合併」收成「完全不授權合併」，並補進
  # suppressed=N 的義務。兩段新內容各自零覆蓋（實測整段刪除 84 PASS / 0 FAIL），當場補釘。
  #   禁令句：`do not authorize a merge at all` —— 這是本次收緊的本體，也是 [T0-9]
  #           「applicable CI PASS，例外：無」在本規則裡的落點。
  #   suppressed：review-triage 記載跨四 repo 六條 finding 有四條藏在該摺疊區，而
  #           gate 的 unresolved 看不到它們。hard_deny 先前對它一字未提。
  ([.autoMode.hard_deny[] | select(index("do not authorize a merge at all") != null)] | length >= 1) and
  ([.autoMode.hard_deny[] | select(index("suppressed=N") != null)] | length >= 1) and
  # 2026-08-27 第三批（S5 Standards 軸 F7）：把 hard_deny 剩下兩條的零覆蓋一併補上。
  # 實測 del(.autoMode.hard_deny[0]) 與 del(.autoMode.hard_deny[2]) 都是 84 PASS / 0 FAIL。
  #   [0] "$defaults" —— 刪掉它會靜默移除 harness 整組預設 hard_deny，那是這裡條目數最多
  #       的一批，而檔案看起來只是少了一個九字元的字串。用 index() 釘字面即可。
  #   [2] repo 刪除／轉移／visibility —— 這條守的是本 repo 真的發生過的失敗類別
  #       （memory: agents-config-visibility-incident）。釘 visibility 那個子句，因為
  #       「不小心放寬」最可能的形狀是刪掉 visibility 只留 delete。
  # 這幾格的實測：四種突變（插入 STATE=FINDINGS、del hard_deny[0]、del hard_deny[2]、
  # 只刪 visibility 子句而保留 delete）在補釘之前全部 84 PASS / 0 FAIL，補完後全部轉紅；
  # 負控制（jq identity 與無關改寫）維持全綠。逐 anchor 明細見上方那張矩陣。
  (.autoMode.hard_deny | index("$defaults") != null) and
  ([.autoMode.hard_deny[] | select(index("change the visibility of a GitHub repository") != null)] | length >= 1) and
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
  # allowWrite 用**整陣列等值比對**（實作見下方）。這裡記兩代前身為什麼都不夠：
  #   第一代「只擋五個 literal」：2026-08-26 mutation 實測被 "~/.claude/"、
  #     "/Users/pochientsai/.claude/"、"/Users/pochientsai/.claude/.."、"$HOME/.claude"
  #     四種拼法全數繞過而全套仍全綠。其中父目錄那條會讓整個家目錄變成 sandbox 可寫。
  #   第二代「rstrip + ${HOME}／Users 前綴改寫 + 第一個 * 處截斷」：實測淨值為負，
  #     詳見下方等值比對的理由段。
  # 教訓是「枚舉必然漏」這個結論本身下錯了——漏的是**部分**枚舉。allowWrite 是 15 條
  # 字面路徑的 security boundary，枚舉**全部**並要求逐項相同才是對的形狀。
  #
  # 2026-08-25 量測（settings.json 的 prose 只留定性敘述，數字留在這裡）：
  #   把 "/Users/pochientsai/.claude" 整棵加進 allowWrite，before/after touch 探針顯示
  #   delta 只有兩處——~/.claude 根目錄散檔、以及 .git/。以下全部仍 denied：
  #   projects/ hooks/ core/ agents/ commands/ skills/ plugins/ backups/ rules/
  #   shell-snapshots/ session-env/ jobs/ .github/workflows/ settings.json CLAUDE.md
  #   來源要分清楚，否則沒人知道哪幾條是承重的：其中**恰好四條**由本 repo 自己的
  #   denyWrite 提供——CLAUDE.md、settings.json、hooks、core——刪掉就真的沒了；其餘
  #   （projects/ agents/ commands/ skills/ plugins/ backups/ rules/ shell-snapshots/
  #   session-env/ jobs/）只來自 harness 預設，本 repo 無對應條目。.github/workflows/
  #   另計：可確認的只有 permissions.deny 的 Edit()/Write() 兩條（工具層，管不到 Bash
  #   寫入）；widened allowWrite 下 sandbox 層是否也擋，未經實證。
  #   結論：projects/ 靠任何 settings.json 改動都開不了，寫 memory 檔要用 Edit/Write
  #   工具或 unsandboxed retry；唯一值得的收穫是 .git/（沙箱內 git commit 可行），
  #   代價是根目錄散檔全開，含 statusline-command.sh（每次 render 執行）與遙測／歷史 log。
  #   故最終只加 "/Users/pochientsai/.claude/.git"。
  #
  # 同日另一組量測：sandbox.filesystem.allowRead 加 "/etc/ssl/cert.pem" 對 git HTTPS
  #   無效——git push 仍以 `error setting certificate verify locations` 失敗，重啟後亦然。
  #   **只記這個觀察，不記成因。** 曾寫成「denyRead 的 /**/*.pem 蓋過 allowRead」，但
  #   可觀測的 policy 把 allowRead 模型化成 allowWithinDeny（deny 之內的 carve-out），
  #   與該說法相反；且 http.sslCAInfo / http.sslCAPath 在 repo 與 global 皆 unset，
  #   未確認 git 實際讀哪個 CA 路徑。該條已移除並由下方斷言釘住；要重加請先重新探測。
  #   網路 git 目前一律走 unsandboxed retry。
  # 2026-08-27 改成**整陣列等值比對**，先前那套手刻正規化（rstrip + $HOME/Users 改寫 +
  #   glob 截斷）已整段移除。理由是實測：它關掉約 13 種拼法，卻同時
  #   (a) 讓三種完全正當的條目誤紅——`~/*.log`、`~/*/build`、`/Users/pochientsai/*/node_modules`
  #       都不授予 ~/.claude 任何東西，卻被判「邊界退化」；
  #   (b) 削弱 `..` 檢查——截斷發生在唯一一次比對之前，`~/x*/..` 被吃成 `~/x` 而放行；
  #   (c) 真正危險的 glob 全部漏掉——`~/.clau*`、`/Users/*`、`/Users/*/.claude`、`~/.claude/.*`
  #       每一條都能讓整棵 ~/.claude 沙箱可寫，而它們全綠。
  #   淨值為負，而且它的上限註解自稱「失效方向朝綠、不會誤紅」，被 (a) 直接證偽。
  #
  #   allowWrite 是 15 條字面路徑、極少變動的 security boundary，用等值比對才是對的形狀：
  #   任何新增、移除、改寫、glob、相對段、大小寫變體一律紅，包含 symlink 目標那個
  #   「字串比對到不了」的天花板——因為連新增一個條目本身就會紅。
  #   這也是本 repo 既有的釘法（tests/hooks.sha256 釘內容、denyWrite 用 index() 釘字面）。
  #   sort 兩側：harness 自己改寫過 settings.json 並重排 key（PR #34 的 /model 事件），
  #   純順序變動不該紅。
  #   代價（刻意）：任何 allowWrite 增刪都要同步改這裡。對 security boundary 而言，
  #   那正是要的行為——改動變成明示動作，而不是靜默通過。
  ((.sandbox.filesystem.allowWrite | sort) == ([
     "/Users/pochientsai/.nuget",
     "/Users/pochientsai/.dotnet",
     "/tmp/.dotnet",
     "/private/tmp/.dotnet",
     "/Users/pochientsai/.npm",
     "/Users/pochientsai/.cache",
     "/Users/pochientsai/Library/Caches",
     "/Users/pochientsai/.agents",
     "/Users/pochientsai/.claude/.git",
     "/Users/pochientsai/.copilot",
     "/Users/pochientsai/.codex",
     "/Users/pochientsai/Downloads/coding_agent_project",
     "/Users/pochientsai/.agent-browser",
     "/Users/pochientsai/Library/Application Support/Google/Chrome for Testing",
     "/Users/pochientsai/.Trash"
   ] | sort)) and
  # 釘的是 key 不存在，不只是值為空——allowRead: [] 與 null 同樣報紅（fail-closed）。
  (.sandbox.filesystem | has("allowRead") | not) and
  # .git 在 allowWrite 內之後，.git/hooks 變成 sandbox 可寫，而它裝著本 repo 自己的
  # pre-commit secret gate（[INT-10] gitleaks 那條的機械實作）。實測：加此條前
  # `touch .git/hooks/.probe` rc=0 檔案建立，加此條後 Operation not permitted。
  # tests/hooks.sha256 只釘 hooks/，不涵蓋 .git/hooks，所以這是唯一一層。
  (.sandbox.filesystem.denyWrite | index("~/.claude/.git/hooks") != null) and
  # .git/config 同樣是 code-execution 面（alias.<x> = !<cmd>、core.fsmonitor），只擋 hooks
  # 等於只擋一半。注意它是**單一檔案**路徑不是目錄：實測 touch .git/config.probe2 仍 rc=0，
  # touch .git/config 才回 Operation not permitted，而 .git 其餘路徑照常可寫（git commit
  # 只動 index／objects／refs，不受影響）。
  # 上限：與上一條同為字面枚舉，寫成 /Users/pochientsai/... 等效拼法會誤紅——與既有三條
  # denyWrite 斷言同慣例，不另立形狀。
  # 2026-08-27：把 .git/config 的**兄弟路徑**評估完，結論是不加第三條。實測三項——
  #   touch .git/config.lock       rc=0（可寫）
  #   touch .git/config.worktree   rc=0（可寫）
  #   git config --local k v       error: could not write config file .git/config:
  #                                Operation not permitted，rc=4，事後 ls .git/config.lock
  #                                回 No such file or directory（觀察，非推論）
  # 兩個兄弟檔可寫但都不構成繞道：
  #   * config.lock 只是鎖，寫它設不了任何 key，效果只有阻斷後續合法的 config 寫入
  #     （本次探針就自己撞上一次：先 touch 出 lock，隨後那輪 git config 回的是
  #     "could not lock config file: File exists" 而非權限錯，差點把結論讀反）。
  #     把它加進 denyWrite 沒有安全收益——config 本身已經擋死了。
  #   * config.worktree 只在 .git/config 裡 extensions.worktreeConfig=true 時才被 git 讀取
  #     （現況：git config --get extensions.worktreeConfig rc=1，未啟用）。要啟用得先寫
  #     config，而那正是被擋住的動作。所以它是一扇通往已鎖房間的門。
  # 不加的另一個理由是改動成本不對稱：多一條就得改 hard_deny[3] 裡「That enumeration is
  # exhaustive on purpose … both execute code」那句，而那正是 2026-08-26 被一次 mid-sentence
  # Edit 把語意改成 `.git/config … allowed` 的同一句。收益為零的改動不值得碰它。
  #
  # 【給下一個編輯本段的人】本段落在 jq -e 的**單引號 bash 字串內**。註解裡放一個 ASCII
  # 單引號就會提前結束該字串，後面的 < > 隨即變成 shell redirection，整支 jq 程式失效。
  # 2026-08-27 實測踩過一次：寫了 core.fsmonitor=＇［指令］＇ → 81 PASS / 3 FAIL，其中
  # 一項就是本區塊的 perm_ok 整段掛掉。方向是 fail-closed（紅而非假綠），但仍要避開：
  # 引號用全形，佔位符用［］不用 <>。本行原本自己就用了 ASCII 單引號——PR #38 的 Copilot
  # 抓到。當時測試是綠的，因為那兩個引號**成對**（1002↔此行、此行↔1306），而中間的
  # ［指令］不含 ASCII 空白，於是 bash 把三段串成同一個 word，jq 收到的程式只少了兩個
  # 位在 jq 註解內的字元。純屬僥倖：對照實驗把 ［指令］ 改成 ［指 令］（多一個 ASCII
  # 空白）立刻變 83 PASS / 1 FAIL。下面那條 canary 就是為了不再靠運氣。
  # **但那句話宣稱的封閉性本來就不成立，一併記下**（兩軸皆指出，2026-08-27 於本 session
  # 覆現）。denyWrite 擋的是**檔案**，不是 git 的執行面：
  #     git -c core.fsmonitor=［任意指令］ status → 該指令執行，.git/config 零寫入
  #     git -c core.hooksPath=［任意目錄］ commit → 該目錄的 pre-commit 執行，同樣零寫入
  #   兩者實測皆成功且事後 .git/config 內容不變。所以 denyWrite 對 .git/config 與
  #   .git/hooks 擋下的是**持久化**那一半——寫進去之後每次 git 呼叫都觸發，含 agent 沒有
  #   經手的那些；一次性的 `-c` 注入它蓋不到，那一層靠的是 Bash classifier 看得到整條
  #   指令。兩層職責不同，別把 denyWrite 讀成「git 不可能執行任意程式碼」。
  #
  # 枚舉的兩個缺口（同樣不改，但要列出來——「評估完」是覆蓋面宣稱，得先枚舉）：
  #   * linked worktree 讀的是 .git/worktrees/［名稱］/config.worktree，不是
  #     .git/config.worktree。本 repo 確實在用 linked worktree（S5 review snapshot 就是），
  #     所以這是常設路徑類別而非假設。
  #   * submodule 則是 .git/modules/［名稱］/config。目前無 .gitmodules，該路徑不存在。
  #   兩者都在 allowWrite 內、都不在 denyWrite 的九條字面裡，但結論與上面相同：仍要
  #   extensions.worktreeConfig（前者）或一個不存在的 submodule（後者）才生效。
  #
  # 順帶更正一則舊紀錄：曾記「hard_deny[3] 的 CLAUDE.md and hooks/ rely on sandbox
  # denyWrite 一句在收斂 allowWrite 後不再準確」——**錯**。denyWrite 現含
  # ~/.claude/CLAUDE.md、~/.claude/hooks、~/.claude/core 三條，tests/hooks.sha256 也存在
  # （1215 B），該句逐項成立，無須改。
  (.sandbox.filesystem.denyWrite | index("~/.claude/.git/config") != null)
' settings.json >/dev/null || perm_ok=0
if [ "$perm_ok" -eq 1 ]; then
  ok "~/.claude permission 邊界：settings.json 的 Edit deny 依裁決維持移除、Write deny 保留；.github/workflows 兩條保持 deny；deny 清單未被削減；sandbox 已啟用；allowWrite 與釘死的 15 條字面清單逐項相同（排序後等值；任何增刪改寫皆紅）；allowRead key 不存在；.git/hooks 與 .git/config 皆在 denyWrite 內；autoMode.hard_deny 的四組片語（settings.json 邊界、merge gate 允許狀態與條件、defaults 條目、repo visibility）與 autoMode.allow 的 pr-review-gate 排除條款俱在"
else
  bad "~/.claude permission 邊界退化。本條是 38 項合取（2026-08-27 實測），只印一行，所以紅了要逐類看：settings.json 的 Edit deny 被加回或 Write deny 被刪、workflows 的 deny、deny 清單規模、sandbox.enabled、allowWrite 範圍、allowRead 被重新加入、denyWrite 的 .git/hooks 或 .git/config、autoMode.hard_deny 談 settings.json 邊界的片語、談 merge gate 的片語（含允許狀態枚舉）、defaults 條目、repo visibility 條目、或 autoMode.allow 的 pr-review-gate 排除條款。定位方式：把下面那支 jq -e 的合取逐段拆開單跑，或先用 jq 讀 .autoMode.hard_deny 看整段是否還在。"
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
# 2026-08-27：「這幾條 denyWrite 是否條條承重」——**正向已建立 3/9，反向不做**。
# 先分清兩個方向；原待辦與本註解前一版都把它們混為一談（S5 Spec 軸指出）：
#
#   正向（「這條真的在擋東西」）**不需要 ablation**。~/.agents 整棵在 harness 的寫入
#   allowlist 內，所以同一棵樹內的差分本身就是證據。2026-08-27 實測：
#       DENIED    ~/.agents/bin
#       DENIED    ~/.agents/hooks
#       DENIED    ~/.agents/skills/dev-workflow
#       WRITABLE  ~/.agents/skills            ← 兄弟目錄，不在 denyWrite
#       WRITABLE  ~/.agents/proposals         ← 同上
#   同一棵可寫的樹裡只有列在 denyWrite 的三條被擋。九條中的三條就此成立，零 widening。
#
#   反向（「拿掉這條就會破」）才需要 ablation，而那條路確實封死：拿掉是 hard_deny[3]
#   明文禁止的 widening，且拿掉的正好是 gate 本體所在的路徑；就算願意承擔，sandbox 設定
#   在 session 內有快取，改了不對當前 session 生效、切回去也不恢復，before/after 量到的
#   是同一個舊狀態，只會產出看起來很綠的假結論。
#
#   剩下六條（~/.claude/*）用同一支差分探針**判不出來**：core、hooks、CLAUDE.md、
#   settings.json 全被擋，但沒列在 denyWrite 的 rules、tests、templates、commands 也全被
#   擋——那是 harness 預設，不是這幾條的功勞。這正是 hard_deny[3] 警告過的
#   「never conclude from that observation that the denyWrite entries are redundant」。
#   要對它們建立正向證據得新開 session 做一次性驗證，不是在既有 session 裡連續 ablate。
# 原待辦寫的是「四條」，現在是九條，條目本身也已過期。
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

# 「不派 subagent」三條特例的反向檢查已移到 §6 的禁用片語清單（紅了會點名是哪一條）；這裡只剩正向 pin，
# 所以訊息不再宣稱「僅」——那道「無其他特例」的守衛在 §6，不在此處。
if rg -Fq '已核准 scope 內的 local、reversible 工作 MUST 一次執行至完成' CLAUDE.md &&
   rg -Fq '中斷條件依 shared [INT-8]' CLAUDE.md &&
   rg -Fq '工具被拒／環境不可用' CLAUDE.md &&
   rg -Fq 'publication 與 protected side effect 仍走 `dev-workflow` authorization gate' CLAUDE.md &&
   grep -Fqx -- '- Delegation：依 shared `dev-workflow` [INT-4] 由 AI 自主判定，無須另問。' CLAUDE.md; then
  ok "Opus 5 autonomy 為祈使句；中斷條件轉介 shared INT-8 且保留工具／環境阻塞；publication gate 保留；delegation 指向 shared INT-4 routing（「僅」由 §6 禁用片語清單守）"
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
#
# 2026-09-05：thinking 改釘「unset 或 true」（§1 開頭的 unset-or-good 判準，形狀同 ultracode）。
# binary schema 原文 "When false, thinking is disabled. When absent or true, thinking is enabled"，
# /config 開啟 thinking 寫回的是刪鍵不是 true；官方 model-config 頁另載此鍵對 Fable 5.1 無效。
# 擋的仍是掉到 false（含手改成 "false"／0 之類非 true 的值）。
#
# 2026-09-05（同日，effort 分流；使用者決議）：effortLevel 回官方預設 high（所有無自帶保存值的模型，日常就是 Opus 5）；
# modelSettings["claude-fable-5-1"].effortLevel 釘 xhigh——Fable 只在最吃能力的任務手動切，正是官方「capability-sensitive
# 才升 xhigh」那桶。機制（binary 2.1.259）：`/effort` 寫回的是 `modelSettings[<canonical id>].effortLevel`，不碰頂層
# `effortLevel`；同檔內 per-model 蓋 default，ultracode=true 時整張 modelSettings 被丟棄；內層鍵是 effortLevel 不是 effort。
# key 未以測試釘住（釘 id 等於把上面剛拆掉的列舉裝回來），以 live 探針驗：ANTHROPIC_BASE_URL 指向本機 request logger、
# `claude -p --model <alias>`，五個別名（opus／opus[1m]／claude-opus-5→high；fable／claude-fable-5-1→xhigh）皆符。失效方向
# （使用者選定）：Fable id 換代→釘子失配→靜默落回 high，屆時在 Fable session 跑一次 /effort xhigh 即寫回新 id。
# 斷言連帶：只釘頂層等於釘一條 harness 已不走的路——對 staged 檔注入 `claude-opus-5: low` 實測舊斷言仍 PASS，改為
# 頂層與 modelSettings 內每個 model 一起落在允許集合（缺 effortLevel 視同 high）。
if jq -e '
  (.model == "default" or (.model | ascii_downcase | test("^(claude-)?opus([-\\[]|$)"))) and
  .advisorModel == "opus" and
  ([.effortLevel, (.modelSettings[]?.effortLevel // "high")] | all(. == "high" or . == "xhigh")) and
  ((has("alwaysThinkingEnabled") | not) or .alwaysThinkingEnabled == true)
' settings.json 2>/dev/null >/dev/null; then
  ok "Claude main model 在允許集合內；advisor=opus；effort≥high（頂層與 modelSettings 每個 model）；thinking 未關閉"
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
