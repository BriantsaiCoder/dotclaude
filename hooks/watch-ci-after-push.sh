#!/usr/bin/env bash
# PostToolUse(Bash) hook：偵測到 `git push` 或 `gh pr create` 後，**實際執行** merge gate
# 並把結果注入 additionalContext。
#
# 為什麼是「執行」而不是「提醒」（2026-08-01 改）：
# 舊版只注入一段文字要模型自己去盯 CI、自己去查 bot review。實測那不夠——同一個 session 裡
# 模型照做了前半（盯 CI）卻漏了後半（跑 gate），結果 PR 上有 5 條未解決的 review thread 一路
# 到 merge 前才被發現。`~/.agents/bin/pr-review-gate` 從頭到尾都在、而且判斷全對；缺的從來
# 不是工具，是「推送後有東西去叫它」。散文靠模型自律，這裡改成機械產出。
#
# 設計約束：
#   * 永不阻擋工具流程。任何一步失敗都退回文字提醒並 exit 0。
#   * 非 push/PR 指令安靜結束（無輸出）。
#   * gate 會在 review 落後於 head 時自動請求 Copilot 重審——那正是推送後想要的副作用。
#
# stdin 為 PostToolUse 的 JSON。用 .cwd 而非 $PWD 解析 repo：指令常寫成
# `cd "$WT" && git push`，hook 自身的 cwd 是 session 目錄而非那個 worktree，用 $PWD 會查到
# 別的 repo（或不是 repo）。
#
# 比對前先剝除引號內的字面字串：只有「執行」push/PR 才該觸發，「提及」不該——
# 例如 `git commit -m "prep for git push"` 或 `grep 'git push' hooks/` 都只是字面出現。
# 詞界用 shell 分隔字元對稱鎖住頭尾，避免 mygit push / git pushd 之類誤命中。

if [ "${1:-}" = "--selftest" ]; then
  # 每個 STATE 都必須對到一段具體的下一步，且沒有任何 STATE 會被說成「可以 merge」除了 PASS。
  # 用假 gate 驗這段對應：真實 push 時要撞到 FAIL_MERGE 或 UNAVAILABLE 很難，等到撞上才發現
  # 對應寫錯就太晚了。
  tmp=$(mktemp -d) || exit 1
  trap 'rm -rf "$tmp"' EXIT
  repo="$tmp/repo"; mkdir -p "$repo"
  git -C "$repo" init -q 2>/dev/null
  pass=0; fail=0
  for st in PASS FINDINGS WAIT_CI WAIT_REVIEW REQUESTED FAIL_CI FAIL_MERGE WAIT_READY UNAVAILABLE BOGUS; do
    printf '#!/bin/sh\nprintf "STATE=%s pr=1 head=abc\\n"\n' "$st" > "$tmp/gate"; chmod +x "$tmp/gate"
    got=$(printf '%s' "{\"tool_input\":{\"command\":\"git push\"},\"cwd\":\"$repo\"}" |
      PR_REVIEW_GATE="$tmp/gate" GH_FORCE_PR=1 "$0" 2>/dev/null |
      jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
    case "$got" in
      *"下一步："*) ;;
      *) printf '  FAIL  %s：未產生下一步指引\n' "$st"; fail=$((fail+1)); continue ;;
    esac
    # 只有 PASS 可以說「可進入 merge 決策」；其餘一律不得出現該字串。
    if [ "$st" = PASS ]; then
      case "$got" in *"可進入 merge 決策"*) printf '  PASS  %s\n' "$st"; pass=$((pass+1)) ;;
                     *) printf '  FAIL  PASS 未指向 merge 決策\n'; fail=$((fail+1)) ;; esac
    else
      case "$got" in *"可進入 merge 決策"*) printf '  FAIL  %s 竟指向 merge 決策\n' "$st"; fail=$((fail+1)) ;;
                     *) printf '  PASS  %s\n' "$st"; pass=$((pass+1)) ;; esac
    fi
  done
  printf '總計：PASS=%s FAIL=%s\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit $?
fi

payload=$(cat)
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)
hook_cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)
stripped=$(printf '%s' "$cmd" | sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g')

printf '%s' "$stripped" |
  grep -Eq '(^|[;&|(]|[[:space:]])(git[[:space:]]+push|gh[[:space:]]+pr[[:space:]]+create)([[:space:];&|)]|$)' ||
  exit 0

emit() { jq -n --arg c "$1" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'; exit 0; }

FALLBACK='[全域設定] 偵測到 git push / gh pr create，但自動 merge gate 無法執行（原因見下）。請手動：對該 PR 跑 `~/.agents/bin/pr-review-gate <n>`，並依 STATE 處置。【Merge gate】squash-merge 前除 CI 綠燈外，另須查 Copilot / bot review——它是 COMMENTED state、不計入 `gh pr checks`，只看 CI 會漏接。'

# 可覆寫是為了讓 --selftest 能在不碰真實 PR 的情況下驗 STATE→下一步的對應。那段 case 是本檔
# 唯一有分支的邏輯，也是最容易寫錯又最不容易在真實 push 時被發現的部分。
GATE="${PR_REVIEW_GATE:-$HOME/.agents/bin/pr-review-gate}"
[ -x "$GATE" ] || emit "$FALLBACK 原因：找不到可執行的 $GATE。"

# `cd` 到指令實際作用的目錄；失敗就退回文字提醒而不是猜。
[ -n "$hook_cwd" ] && [ -d "$hook_cwd" ] && cd "$hook_cwd" 2>/dev/null
git rev-parse --show-toplevel >/dev/null 2>&1 || emit "$FALLBACK 原因：cwd（${hook_cwd:-$PWD}）不在 git repo 內。"

if [ -n "${GH_FORCE_PR:-}" ]; then pr="$GH_FORCE_PR"      # --selftest：不打 GitHub
else pr=$(gh pr view --json number --jq .number 2>/dev/null); fi
# 單引號：字串內含 `~/.agents/bin/pr-review-gate` 的反引號，放在雙引號裡會被當成命令替換
# 執行（且 <n> 被解讀為重新導向）。bash -n 不會抓到——它只在執行到該行時才炸。
[ -n "$pr" ] || emit '[全域設定] 偵測到 git push，但此分支尚無對應 PR，merge gate 無從執行。開了 PR 之後跑 `~/.agents/bin/pr-review-gate <n>`。'

out=$("$GATE" "$pr" 2>&1 | head -1)
[ -n "$out" ] || emit "$FALLBACK 原因：pr-review-gate 無輸出。"

# STATE 決定下一步。文字只描述「這個 STATE 代表什麼、該做什麼」，判斷本身已經由 gate 做完。
case "$out" in
  STATE=PASS*)        next='CI 綠、review 對應到目前 head、無未解決 thread。可進入 merge 決策（merge 仍需使用者授權）。' ;;
  STATE=FINDINGS*)    next='有未解決的 review thread（見 unresolved=N）。逐條判定成立與否，成立的修並補回歸測試，然後在該 thread 回覆處置方式並 resolve。全部歸零前不得 merge。' ;;
  STATE=WAIT_CI*)     next='CI 尚未結束。跑 `gh pr checks <n> --watch` 等到結束再回報通過或失敗。' ;;
  STATE=WAIT_REVIEW*) next='等待 bot review 對應到目前 head。gate 已自動請求重審；到了之後逐條判定。' ;;
  STATE=REQUESTED*)   next='review 落後於 head，gate 已自動請求重審。等它產出後再判定，不要當作零意見通過。' ;;
  STATE=FAIL_CI*)     next='CI 失敗。取失敗 job 的 log、定位原因、修好再推，不要重試了事。' ;;
  STATE=FAIL_MERGE*)  next='有合併衝突。先 rebase 到最新 base 並解衝突，解完重跑完整測試集。' ;;
  STATE=WAIT_READY*)  next='PR 仍是 Draft。確認要送審才轉 Ready for review。' ;;
  STATE=UNAVAILABLE*) next='gate 無法判定（reason 見上）。這是「未知」不是「通過」，不得據此 merge。' ;;
  *)                  next='未預期的 STATE，當作未知處理，不得據此 merge。' ;;
esac

emit "[全域設定] 已於 push 後自動執行 merge gate（~/.agents/bin/pr-review-gate $pr）：

$out

下一步：$next

此結果由 gate 機械產出，非提醒；不要重複自行判斷 CI 或 review 狀態，以上面那行為準。"
