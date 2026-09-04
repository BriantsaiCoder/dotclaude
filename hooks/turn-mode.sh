#!/bin/bash
# turn-mode · UserPromptSubmit
# 來源：2026-09-04 使用者指示——保留 ultracode，但「問題／分析型」提問一律單代理，只有真正的開發任務才編排 Workflow。
# 規則只活在這支 hook（~/.claude/CLAUDE.md 距 byte 軟閘僅剩 59 B，放不下），注入文自帶出處供稽核回查。
# 行為：提示命中問題型樣式才輸出一行使用者層級 steer；開發型提示與明示 opt-in（ultracode／use a workflow）靜默。
# 純 heuristic：誤判成問題型的代價是先答再依 dev-workflow 改檔，不擋任何動作。
# 整串比對用 bash [[ =~ ]]（$ 錨串尾而非逐行；nocasematch 讓英文樣式不分大小寫）。
# --selftest：跑內建案例，由 tests/repo-integrity.sh 接線。
# locale 只在本機真的有 UTF-8 locale 時才設（硬編碼不存在的 locale 會讓 bash 對 stderr 吐 setlocale 警告）；
# 找不到就維持環境原樣——樣式全是字面 CJK 與 ASCII 交替，C locale 下也能比對。
_utf8=$(locale -a 2>/dev/null | grep -i -m1 -E '^(en_US|C)\.utf-?8$')
[ -n "$_utf8" ] && export LC_ALL="$_utf8"
shopt -s nocasematch
OPTIN='ultracode|use a workflow|run a workflow'
ASK='(\?|？)[[:space:]]*$|為何|為什麼|是否|什麼原因|可能是什麼|幫我分析|幫我說明|幫我比較|幫我評估|你會建議|分析一下|解釋一下|說明一下|(^|[^[:alnum:]])(why|how come|should i|is it)([^[:alnum:]]|$)'
STEER='[turn-mode] 問題／分析型提問（使用者規則，來源 ~/.claude/hooks/turn-mode.sh）：單代理直答，需要佐證自行並行查證；本回合不新開 Workflow、不等 Workflow，已啟動的 delegation 不受影響。若回答過程確認必須改檔，改檔部分仍依 dev-workflow。'

classify() {  # $1 = prompt → steer | silent
  [[ $1 =~ $OPTIN ]] && { echo silent; return; }
  [[ $1 =~ $ASK ]] && { echo steer; return; }
  echo silent
}

if [ "$1" = "--selftest" ]; then
  fail=0
  check() {
    got=$(classify "$2")
    if [ "$got" = "$1" ]; then printf '  ok    %-6s %s\n' "$1" "${2//$'\n'/\\n}"
    else printf '  FAIL  want=%s got=%s  %s\n' "$1" "$got" "${2//$'\n'/\\n}"; fail=1; fi
  }
  check steer  '若將windows10安裝的mysql 5.7.19升級到最新的mysql 8.4 是否會解決此問題？但升級後原先的500萬筆資料是否會不見'
  check steer  '幫我分析同樣的開發任務疑問為何，你完成的比較慢，codex 比較快（你慢很多）'
  check steer  'Why is the build failing on CI?'
  check steer  'Why does the parser fail'
  check steer  'Should I upgrade to 8.4'
  check steer  '這樣做對嗎？'
  check steer  '分析一下這段 log 的錯誤來源'
  check silent '幫我把 DbAccess.TruncateRemark 的上限改成 255 並補 regression test'
  check silent 'ultracode 幫我全面審查這個 PR 是否有問題'
  check silent 'Go'
  check silent 'we should implement retry'
  check silent 'refactor the analysis it produced'
  check silent $'把 X 改成 Y\n這樣可以嗎？\n然後補測試'
  check silent $'請改成 const x = a ? b : c\n並補測試'
  [ "$fail" = 0 ] && echo "turn-mode selftest: all cases pass"
  exit "$fail"
fi

command -v jq >/dev/null || exit 0   # 沒 jq 就靜默不注入：advisory hook，fail-open 是刻意的
p=$(jq -r '.prompt // empty' 2>/dev/null)
[ -n "$p" ] || exit 0
[ "$(classify "$p")" = steer ] && echo "$STEER"
exit 0
