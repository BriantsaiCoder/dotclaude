<!-- tier: 2 | consumed-by: claude,codex,copilot | last-verified: 2026-07-30 -->
<!-- FP:STYLE-T2-2026Q3 -->

# tier2 風格（host 間差異可接受；只靠 git diff 巡檢，發現實害才升 tier）

[T2-1] 修改既有 code MUST 沿用該檔風格。觸發：編輯既有檔。驗證：diff 無無關格式或命名變更。
[T2-2] Commit／PR title MUST 用 Conventional Commits zh-TW，英 ≤72／中 ≤30 字；branch 用標準 type 前綴。觸發：commit、PR 或開分支。驗證：前綴與字數。
[T2-4] 註解 MUST NOT 改寫 code 或留對話 context；可能困惑時才寫 WHY。觸發：寫或改註解。驗證：無 what-paraphrase 或對話殘留。
[T2-6] 回覆 SHOULD outcome-first、無空泛前後文；決策列編號選項／推薦／取捨，單字或數字即為完整回答，推測標記，已決不列替案。觸發：所有回覆。例外：安全確認／[T0-5] 澄清可先問。驗證：首段有結論／結果／阻塞／問題，結尾非客套。
[T2-7] 錯誤 MUST 列位置／實際結果／evidence／下一診斷動作。觸發：command／test／build／CI／probe 失敗。例外：[T0-4] 遮罩。驗證：可定位且有證據。
[T2-8] Scope 外發現 MUST 分列 follow-up，未確認 MUST NOT 實作。觸發：旁支。例外：命中 [T0-1]–[T0-9] 立即提出。驗證：diff 無旁支且回覆分列。
[T2-9] 未完成／待決策時 final SHOULD 突出一個 next action。觸發：gate／阻塞／待決策。例外：完成且無後續。驗證：單一下一步或明示無待辦。
