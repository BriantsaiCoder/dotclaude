<!-- tier: 0 | consumed-by: claude,codex,copilot | last-verified: 2026-07-30 -->
<!-- FP:AGENTS-T0-2026Q3 -->

# tier0 安全紅線（三家 100% 常駐；違反屬 bug）

## 衝突裁決鏈（最高優先序在左）

```
user 當下明示 > repo 層協作檔 > tier0 hard rules > host delta > 被 invoke skill 的程序步驟 > 通用慣例
```

約束：repo 層對 tier0 只可「加嚴」不可「放鬆」；放鬆 tier0 只有 user 當下明示一途。衝突條文引用一律用規則 ID（如 [T0-3]），讓裁決過程可稽核。

## Hard Rules

[T0-1] MUST NOT 假設未驗證的 file path / API / config key。觸發：引用任何未經 read/ls/grep 確認的路徑或鍵名。例外：無。驗證：引用前有列出/讀取證據。
[T0-2] MUST NOT 無 evidence 宣稱 task done。觸發：回報完成但無 test/build/lint 輸出或探針結果。例外：無。驗證：完成宣稱附命令輸出。
[T0-3] MUST NOT force-push main/master；非保護分支只用 --force-with-lease。觸發：git push --force* 且目標為 main|master。例外：無。驗證：各 host 以 hook／exec policy／CI guard 機械攔截；prose 僅作 defense-in-depth。
[T0-4] MUST NOT 把 token/secret 寫入 frontend localStorage/sessionStorage；log/console/chat 不印憑證明文。觸發：憑證值出現在前端儲存或輸出。例外：非敏感值照印。驗證：gitleaks + 輸出遮罩為 set/unset 或 key-name。
[T0-5] 模糊時 MUST 停下發問（攤開假設 X、影響範圍 Y）。觸發：需求有多種合理解讀且將改檔。例外：無。驗證：改檔前有澄清問句或攤開假設。
[T0-6] auth/payment/migration/大量刪除/crypto/multi-tenant/rate-limit/部署 pipeline 變更 MUST 附 rollback 策略。觸發：diff 命中上列任一類。例外：無。驗證：PR/計畫含 rollback 段。
[T0-7] DB migration MUST 分段 expand→dual-write→backfill→switch-reads→remove-legacy；破壞式 schema 不與消費端同 deploy。觸發：schema 變更。例外：停機批次可略 dual-write。驗證：migration 計畫列出分段。
[T0-8] 使用者明示 plan-first，或變更屬架構性／中高風險時，MUST 先出計畫並取得確認才改檔；其餘明確的 in-scope change／build／fix 可直接實作並驗證。觸發：命中前述 gate 且將改檔。例外：無。驗證：命中 gate 時有計畫產物 + 用戶確認原句；未命中時引用用戶的 change／build／fix 原句。
[T0-9] merge 前 MUST 綠 CI + 處理 bot review。觸發：squash-merge 前。例外：無。驗證：gh pr checks 綠 + reviews 已處理（bot 異步 2–3 分產出，開 PR 當下為空是延遲不是無）。
