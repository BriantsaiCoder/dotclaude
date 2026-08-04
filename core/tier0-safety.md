<!-- tier: 0 | consumed-by: claude,codex,copilot | last-verified: 2026-08-04 -->
<!-- FP:AGENTS-T0-2026Q3 -->

# tier0 安全紅線（三家 100% 常駐；違反屬 bug）

## 衝突裁決鏈（最高優先序在左）

```
user 當下明示 > repo 層協作檔 > tier0 hard rules > host delta > 被 invoke skill 的程序步驟 > 通用慣例
```

約束：repo 層對 tier0 只可「加嚴」不可「放鬆」；放鬆 tier0 只有 user 當下明示一途。衝突條文引用一律用規則 ID（如 [T0-3]），讓裁決過程可稽核。

## Hard Rules

[T0-1] Action／current-state claim 涉及 path／API／config key 時 MUST 有 live evidence；實際修改／執行 target 仍須 live probe。觸發：前述 action／claim。例外：non-action citation／hypothetical。驗證：read／list／schema probe 或例外標記。
[T0-2] MUST NOT 無 evidence 宣稱 task done。觸發：回報完成但無 test/build/lint 輸出或探針結果。例外：無。驗證：完成宣稱附命令輸出。
[T0-3] MUST NOT force-push main/master；非保護分支只用 --force-with-lease。觸發：git push --force* 且目標為 main|master。例外：無。驗證：各 host 以 hook／exec policy／CI guard 機械攔截；prose 僅作 defense-in-depth。
[T0-4] MUST NOT 把 token/secret 寫入 frontend localStorage/sessionStorage；log/console/chat 不印憑證明文。觸發：憑證值出現在前端儲存或輸出。例外：非敏感值照印。驗證：gitleaks + 輸出遮罩為 set/unset 或 key-name。
[T0-5] Material ambiguity MUST 停下發問並列假設／影響；低風險可逆細節採 sensible default 並明示。觸發：多種合理解讀會改變 outcome／scope／risk。例外：低風險、可逆、無 material impact。驗證：改檔前有澄清或 default／impact 紀錄。
[T0-6] auth/payment/migration/大量刪除/crypto/multi-tenant/rate-limit/部署 pipeline 變更 MUST 附 rollback 策略。觸發：diff 命中上列任一類。例外：無。驗證：PR/計畫含 rollback 段。
[T0-7] Online DB migration with compatibility／destructive risk MUST expand→dual-write→backfill→switch-reads→remove-legacy；destructive schema 不與舊 consumer 同 deploy。觸發：schema／data-contract risk。例外：additive／new-object 或停機 batch 可標不適用階段 `SKIPPED`（理由）。驗證：plan 列 phases／consumer boundary／[T0-6] rollback。
[T0-8] plan-first 明示、架構性／High-risk，或未授權 external write、destructive／costly／credential／payment／deployment／migration side effect／material scope expansion MUST 先 plan + confirm；明確 in-scope、local、reversible 的 Low／Medium-risk change／build／fix 可直接實作與 non-destructive verification，Medium 留 session plan、不需第二次確認。觸發：將改檔或執行 side effect 且命中前述 protected gate。例外：無。驗證：protected gate 有 plan + 核准原句；direct path 有 user 原句 + risk／reversibility，Medium 有 session plan。
[T0-9] Merge 前 MUST 在 current HEAD 有 applicable CI PASS 且 0 unresolved actionable findings；bot UNAVAILABLE 時依 shared dev-workflow 的 review-triage 由 independent read-only reviewer fallback。觸發：merge。例外：無。驗證：current-head CI + review gate PASS。
