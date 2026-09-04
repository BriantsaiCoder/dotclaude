#!/bin/bash
# turn-mode · UserPromptSubmit
# 問題／分析型提示才輸出一行使用者層級 steer（單代理直答、不編排 Workflow）；
# 開發型提示與明示 opt-in（ultracode／use a workflow）一律靜默，維持 ultracode 常駐行為。
# 只是 heuristic：誤判成問題型的代價是先答再依 dev-workflow 改檔，不會擋任何動作。
export LC_ALL=en_US.UTF-8
p=$(jq -r '.prompt // empty' 2>/dev/null)
[ -n "$p" ] || exit 0
printf '%s' "$p" | grep -qiE 'ultracode|use a workflow|run a workflow' && exit 0
if printf '%s' "$p" | grep -qE '(\?|？)[[:space:]]*$|為何|為什麼|是否|什麼原因|可能是什麼|幫我分析|幫我說明|幫我比較|幫我評估|你會建議|why |how come|should i|is it '; then
  echo '[turn-mode] 問題／分析型提問（使用者規則）：單代理直答，需要佐證自行並行查證；本回合不編排、不等 Workflow。若回答過程確認必須改檔，改檔部分仍依 dev-workflow。'
fi
exit 0
