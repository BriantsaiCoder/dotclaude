#!/usr/bin/env bash
# PostToolUse(Bash) hook：偵測到 `git push` 或 `gh pr create` 後，注入 additionalContext，
# 提醒模型依使用者全域偏好「每次 push / 開 PR 後自動盯 CI 結果」，並在 squash-merge 前
# 補查 Copilot / bot review（COMMENTED state 不計入 `gh pr checks`，只看 CI 會漏接）。
#
# 只注入提醒、不阻擋工具流程；非 push/PR 指令安靜結束（無輸出、exit 0）。
# stdin 為 PostToolUse 的 JSON，取 .tool_input.command 比對；用 grep 而非 if 條件鎖前綴，
# 以便涵蓋複合指令（例如 `git add . && git push`）。
#
# 比對前先剝除引號內的字面字串：只有「執行」push/PR 才該提醒，「提及」不該——
# 例如 `git commit -m "prep for git push"` 或 `grep 'git push' hooks/` 都只是字面出現。
# 詞界用 shell 分隔字元對稱鎖住頭尾，避免 mygit push / git pushd 之類誤命中。

cmd=$(jq -r '.tool_input.command // ""' 2>/dev/null)
stripped=$(printf '%s' "$cmd" | sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g')

if printf '%s' "$stripped" | grep -Eq '(^|[;&|(]|[[:space:]])(git[[:space:]]+push|gh[[:space:]]+pr[[:space:]]+create)([[:space:];&|)]|$)'; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: "[全域設定] 偵測到 git push / gh pr create。請自動盯 CI：對剛 push 的分支或剛建立的 PR 執行 `gh pr checks --watch`（可先 `gh pr view` 確認該分支有對應 PR，無則略過），待所有 check 結束後主動回報通過或失敗（失敗時列出失敗 job 名稱與原因摘要），毋須等使用者再次要求。【Merge gate】squash-merge 前除 CI 綠燈外，另須查 Copilot / bot review（`gh pr view <n> --json reviews`）——它是 COMMENTED state、不計入 `gh pr checks`，只看 CI 會漏接（PR #34 即因此漏 8 條建議）；有未處理建議須先走 receiving-code-review 評估處理完才 merge。"
    }
  }'
fi

exit 0
