#!/bin/bash
# turn-mode · UserPromptSubmit
# 來源：2026-09-04 使用者指示——「問題／分析型」提問一律單代理，只有真正的開發任務才編排 Workflow。
#       2026-09-05 使用者選定方案 C——settings.json 的 ultracode 改 false，Workflow 回到 harness 原生
#       「只在明示 opt-in 才可用」；本 hook 對開發型樣式注入「本回合視同 opt-in」，其餘提示靜默＝不開。
#       預設翻轉的理由：heuristic 一定會漏。漏判開發型只是少開一次 Workflow（補打 ultracode 即可）；
#       漏判非開發型（安裝 plugin 那次）卻是 12 agent、18 分鐘。把失效方向壓到便宜的那一邊。
#       ultracode 關閉的連帶（settings.json 不能帶註解，記這裡）：effortLevel xhigh 不動但有效 effort 是否受模型
#       default hold 未驗，觀察到降級用 /effort xhigh 釘回；concurrent subagent 上限回 20（binary 確認），dev steer
#       只影響 model 層編排決定、恢復不了那個豁免。
# 規則只活在這支 hook（~/.claude/CLAUDE.md 受 byte 軟閘限制，餘裕放不下一條規則），注入文自帶出處供稽核回查。
# 行為：問題型樣式 → ask steer（單代理直答）；開發型樣式 → dev steer（視同 opt-in）；明示 opt-in
#       （ultracode／use a workflow）由 harness 自己認得，hook 靜默；其餘靜默——安裝／設定／更新等機械任務、
#       單檔小改、implement 都在此列，要編排就在提示打 ultracode。
# DEV 集合 = 方案 C 點名的四類（修 bug／refactor／review／migration）+ 稽核、掃描（限與 repo／codebase／專案／目錄
#       在同一提示內共現，.* 會跨行；「掃描這張 PDF」不算）。/code-review 靠連字號放行的字界自然命中，不另立分支。
#       每個 alternative 在 selftest 至少一條隔離正例（刪掉必紅）；字尾／冠詞這類可選成員未逐一隔離。範圍副詞（全面／徹底／
#       comprehensive／thorough／整個專案）刻意不單獨算：「全面更新所有 plugin」「整個專案 build 一次」是機械任務，
#       單靠副詞會把事故型提示判成 dev，正是要壓掉的貴側失效。已知殘留：`dotnet ef migrations add X`、
#       `git log --grep=refactor` 這種含 DEV 名詞的機械指令會判 dev——ERE 沒有 lookbehind，加指令前綴白名單是把
#       shell 知識塞進分類器，不做；靠 steer 的「單代理能收斂就不編排」兜底。
# 純 heuristic、advisory：不擋任何動作。失效方向：無 jq／payload 讀不到 → 靜默 → 不開 Workflow（便宜側）。
# 整串比對用 bash [[ =~ ]]（$ 錨串尾而非逐行；nocasematch 讓英文樣式不分大小寫）。ASK 先於 DEV：
# 「審查這個 PR 是否有問題」「審查過了嗎」「重構後會不會壞掉」是問句不是編排：DEV 進場後 ASK 漏判的代價從「靜默」
# 升為「開 Workflow」，所以 ASK 比 #47 寬——成員看 regex 本身，不在此重抄；句尾組列成 嗎|呢|沒|沒有 四個成員而不用
# 沒有?，因為真 C locale 下 ? 只綁「有」的末 byte。已知邊界（都是 heuristic 上限，不再擴）：問號後面還有尾綴
# （「審查過了嗎？謝謝」）不算句尾會落到 dev，$ 錨是 #47 為了「a ? b : c」與多段提示中段問句刻意選的；英文無問號的
# 助動詞問句（「Is the migration done」）
# 落到 dev，句首助動詞錨會把「Do a review」也變問句；英文 wh 詞不錨句首，「Review the PR when you get a chance」會被
# 判成 ask——便宜側，補打 ultracode 即可。
# 英文字界（ASK、DEV 皆同）寫成明示 ASCII 集合而不用 [[:alnum:]]：後者在 UTF-8 locale 把緊貼的 CJK 當字元，
# 「幫我review這個PR」「幫我看看why會掛」會漏判；DEV 前字界再排除 _./ 讓路徑、檔名、貼上的 log
# （~/.claude/audit-bash-metadata.log、hooks/review.sh）不被當成任務；裸檔名 review.sh、self-review 會算 dev，罕見。
# 字尾只收現在式，過去式是敘述不是任務；preview／reviewer／fix typo 這些反例見 silent 案例。
# --selftest：跑內建案例，由 tests/repo-integrity.sh 接線。
# locale：環境已是 UTF-8 就不動；否則只在本機真的有 UTF-8 locale 時才設（硬編碼不存在的 locale 會讓 bash
# 對 stderr 吐 setlocale 警告），找不到維持原樣——CJK 樣式是字面比對、英文字界是明示 ASCII 集合，C locale 下也能比對。
case "${LC_ALL:-${LC_CTYPE:-$LANG}}" in
  *[Uu][Tt][Ff]-8|*[Uu][Tt][Ff]8) ;;
  *) _utf8=$(locale -a 2>/dev/null | grep -i -m1 -E '^(en_US|C)\.utf-?8$' 2>/dev/null)
     [ -n "$_utf8" ] && export LC_ALL="$_utf8" ;;
esac
shopt -s nocasematch
OPTIN='ultracode|use a workflow|run a workflow'
ASK='(\?|？)[[:space:]]*$|(嗎|呢|沒|沒有)[[:space:]]*$|為何|為什麼|是否|會不會|要多久|有沒有|是不是|要不要|能不能|可不可以|需不需要|該不該|對不對|怎麼|怎樣|如何|什麼原因|可能是什麼|幫我分析|幫我說明|幫我比較|幫我評估|你會建議|分析一下|解釋一下|說明一下|(^|[^A-Za-z0-9_])(why|how come|should (i|we)|is it|what|where|which|when|how (do|to|can)|does|explain)([^A-Za-z0-9_]|$)'
BD='[^A-Za-z0-9_./]'        # DEV 英文前字界：排除 _./ 讓路徑、檔名不算；連字號放行讓 /code-review、code-review 算
BE='([^A-Za-z0-9_-]|$)'     # DEV 尾字界：句末句點算（code review.）；review.sh 這種裸檔名會算 dev，罕見、便宜側
DEV="審查|稽核|掃描.*(repo|codebase|專案|目錄)|遷移|重構|修復|修(正|掉|好|一下)?(這個|那個)? ?bug|(^|$BD)((review|audit|refactor)(s|ing)?|migrat(es?|ing|ions?)|bug ?fix(es)?|fix(es|ing)?[[:space:]]+((the|a|this|that)[[:space:]]+)?bugs?)$BE"
STEER_ASK='[turn-mode] 問題／分析型提問（使用者規則，來源 ~/.claude/hooks/turn-mode.sh）：單代理直答，需要佐證自行並行查證；本回合不新開 Workflow、不等 Workflow，已啟動的 delegation 不受影響。若回答過程確認必須改檔，改檔部分仍依 dev-workflow。'
STEER_DEV='[turn-mode] 開發型任務（使用者規則，來源 ~/.claude/hooks/turn-mode.sh）：本回合視同 ultracode opt-in——審查／遷移／重構／修 bug 這類需獨立對抗驗證的多檔工作可編排 Workflow，仍同步自查、不閒等，529 一次即棄；單代理能收斂就不編排。若這其實是問句／分析請求（regex 漏判），仍單代理直答、不視同 opt-in。'

classify() {  # $1 = prompt → ask | dev | silent
  # 背景 agent／workflow 的 task-notification 也走 UserPromptSubmit，內文常含 review／審查；那不是使用者的提示，
  # 不能因此「視同 opt-in」。之前沒現形只是因為通知裡剛好都有 ultracode 字面被 OPTIN 靜默掉。
  [[ $1 == *'<task-notification>'* || $1 == *'[SYSTEM NOTIFICATION'* ]] && { echo silent; return; }
  [[ $1 =~ $OPTIN ]] && { echo silent; return; }
  [[ $1 =~ $ASK ]] && { echo ask; return; }
  [[ $1 =~ $DEV ]] && { echo dev; return; }
  echo silent
}

if [ "$1" = "--selftest" ]; then
  fail=0; n=0
  check() {
    n=$((n+1)); got=$(classify "$2")
    if [ "$got" = "$1" ]; then printf '  ok    %-6s %s\n' "$1" "${2//$'\n'/\\n}"
    else printf '  FAIL  want=%s got=%s  %s\n' "$1" "$got" "${2//$'\n'/\\n}"; fail=1; fi
  }
  check ask    '若將windows10安裝的mysql 5.7.19升級到最新的mysql 8.4 是否會解決此問題？但升級後原先的500萬筆資料是否會不見'
  check ask    '幫我分析同樣的開發任務疑問為何，你完成的比較慢，codex 比較快（你慢很多）'
  check ask    'Why is the build failing on CI?'
  check ask    'Why does the parser fail'
  check ask    'Should I upgrade to 8.4'
  check ask    '這樣做對嗎？'
  check ask    '分析一下這段 log 的錯誤來源'
  check ask    '幫我審查這個 PR 是否有問題'
  check ask    '審查過了嗎'
  check ask    '遷移完成了沒'
  check ask    '審查結果呢'
  check ask    '重構後會不會壞掉'
  check ask    '修復要多久'
  check ask    '審查這個 PR 有沒有問題'
  check ask    '這次遷移是不是有風險'
  check ask    '要不要重構'
  check ask    '幫我看看why會掛'
  check ask    'what changed in the migration'
  check ask    'where is the review checklist'
  check ask    'which migration ran last'
  check ask    'when did the audit run'
  check ask    'how do I run the migration'
  check ask    'does the migration need downtime'
  check ask    'should we refactor this'
  check ask    'explain the refactor'
  check ask    '審查完了沒有'
  check ask    '遷移要怎麼做'
  check ask    '審查流程怎樣走'
  check ask    '如何重構這段'
  check ask    'how to migrate lots_result'
  check ask    'how can I migrate safely'
  check ask    '能不能重構這段'
  check ask    '可不可以幫我審查這個 PR'
  check ask    '需不需要遷移'
  check ask    '該不該重構'
  check ask    '這樣重構對不對'
  check dev    'Please do a code review.'
  check dev    'run /code-review since origin/main'
  check dev    '修好這個 bug'
  check dev    '修掉那個 bug'
  check dev    '修一下 bug'
  check dev    '修正 bug'
  check dev    '掃描整個專案的 TODO'
  check dev    '掃描 hooks 目錄找 fail-open'
  check dev    '掃描 codebase 找重複程式碼'
  check dev    '審查這個 PR 的 Standards 與 Spec 兩軸'
  check dev    '稽核 hooks 目錄的 fail-open 路徑'
  check dev    'code review this branch against origin/main'
  check dev    'reviewing this branch before merge'
  check dev    '幫我review這個PR'
  check dev    '把 lots_result 的 schema 遷移到新表並更新所有 caller'
  check dev    'migrate lots_result to the new table'
  check dev    '全面掃描這個 repo 的 over-engineering'
  check dev    'Thoroughly audit the hooks directory'
  check dev    'fix the bug in DbAccess.TruncateRemark'
  check dev    'bugfix for the remark truncation'
  check dev    '修 bug：CoerceTypedEmptyToNull 把 0 當空值'
  check dev    '修復 CI 上的 build 失敗'
  check dev    '重構 FileProcess 與 DbAccess 的共用 seam'
  check dev    'refactor the analysis it produced'
  check silent '幫我把 DbAccess.TruncateRemark 的上限改成 255 並補 regression test'
  check silent 'ultracode 幫我全面審查這個 PR 是否有問題'
  check silent '安裝https://github.com/cathrynlavery/diagram-design'
  check silent '全面更新所有 plugin 到最新版'
  check silent '徹底清掉 node_modules 再重裝'
  check silent '整個專案 build 一次'
  check silent 'cat ~/.claude/audit-bash-metadata.log'
  check silent 'open hooks/review'
  check silent 'check audit-bash-metadata.log'
  check silent 'open docs.review.md'
  check silent '掃描這張 PDF 的文字'
  check silent 'we migrated last week, now fix the typo in README'
  check silent 'I reviewed it yesterday'
  check silent 'fix typo in README'
  check silent 'preview the landing page'
  check silent 'ask the reviewer to look again'
  check silent 'Go'
  check silent 'we should implement retry'
  check silent $'[SYSTEM NOTIFICATION - NOT USER INPUT]\n<task-notification>\n<summary>Agent "S5 Standards review" finished</summary>\n審查對象：a4f3aca'
  check silent $'把 X 改成 Y\n這樣可以嗎？\n然後補測試'
  check silent $'請改成 const x = a ? b : c\n並補測試'
  [ "$fail" = 0 ] && echo "turn-mode selftest: all $n cases pass"
  exit "$fail"
fi

command -v jq >/dev/null || exit 0   # 沒 jq 就靜默不注入：advisory hook，fail-open 是刻意的（靜默＝不開 Workflow）
p=$(jq -r '.prompt // empty' 2>/dev/null)
[ -n "$p" ] || exit 0
# 每支 regex 都是全長掃描，成本 ∝ bytes × alternation 數；貼上 1 MB log 要 0.86 s、2.3 MB 撞 2 s timeout。
# 分類只看頭尾各 4K（^ 與 $ 錨都保住，\n 接縫擋碎片黏成新 token）：1 MB 降到 0.1 s，selftest 全數不變。
[ ${#p} -gt 8000 ] && p="${p:0:4000}"$'\n'"${p: -4000}"
case "$(classify "$p")" in
  ask) echo "$STEER_ASK" ;;
  dev) echo "$STEER_DEV" ;;
esac
exit 0
