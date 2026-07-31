<!-- tier: 1 | consumed-by: claude | last-verified: 2026-08-01 -->
<!-- FP:WORKFLOW-T1-2026Q3 -->

# tier1 工作流紀律（容忍一個 session 延遲；正本規則見 dev-workflow skill）

[T1-1] 改高扇入共用檔、名稱、signature、位置或 public API 前 MUST 列依賴方。觸發：編輯共用介面。驗證：deps-check 或 grep 證據。
[T1-2] 計畫 MUST 標低／中／高風險；中、高附 rollback、加強驗證，並與 [T0-6] 疊加。觸發：輸出計畫。驗證：風險與 rollback 欄。
[T1-3] 除 feature branch 的 `[wip]` 探索外，每個 commit MUST 可獨立 checkout 且 build 通過。觸發：拆 commit。驗證：無 transient broken state。
[T1-4] 中、高風險變更 MUST 附 before/after 基線。觸發：中、高風險 diff。驗證：API response、query count 或輸出樣本。
[T1-5] 除非任務明確要求重構，MUST NOT 順手改既有 code 的格式、命名或註解。觸發：交付前簡化。驗證：diff 無無關變更。
[T1-6] MUST 清除自己造成的 dead code；pre-existing 只提及，取得用戶確認才刪。觸發：產生 unused symbol。驗證：無新增 dead code。
[T1-7] 選型 MUST 依序為 repo 既有模組／模式 > 標準函式庫／原生平台 > 已安裝成熟第三方 > 新增成熟第三方 > 手寫。觸發：新增依賴或手寫 ≥50 行。驗證：記錄選型理由。
[T1-8] 建立 PR MUST 預設為 Ready for review；只有用戶當下明示 Draft／WIP 才可建立 Draft PR。觸發：建立 PR。驗證：`isDraft=false`；例外時引用用戶 Draft／WIP 原句。
[T1-9] HTML/CSS/Mermaid 視覺修復 MUST 自派 Chrome DevTools 查 DOM/SVG/style/尺寸/對比/console;禁只讀碼。觸發：上述修復。驗證：before/after 探針/截圖；受限標 `UNAVAILABLE` + 證據。
[T1-10] 共享 checkout、並行 task，或 branch switch 會改變 host 讀取的 skill/config 時 MUST 用 `bin/agents-branch` 建 isolated worktree；~/.agents live checkout MUST 保持 main。觸發：任一 isolation 條件。例外：已驗證單一 session 獨占。驗證：編輯前記錄 resolved path／repo root／branch／ownership，並跑 local conformance 與 `tests/agents-branch.sh`。
[T1-11] Ready PR 建立後 task MUST 保持 active；任何 push 都使前次 CI／Copilot review gate 失效。觸發：建立 Ready PR 或其後 push。驗證：latest Copilot review commit_id 等於 PR head SHA、requested Copilot reviewer 已清除、unresolved review threads 為 0、CI 全綠，才可提示 Squash merge；非 PASS 只能標 WAITING／FAIL／UNAVAILABLE 並附證據。
