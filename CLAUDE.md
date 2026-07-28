# Global Preferences

<!-- last audited 2026-07-25（Claude 5 context-engineering 對齊：刪 dev-workflow SKILL.md 已覆蓋的路由複述）；next review: 2027-01-03 或主檔 > 150 行（拆 path-scoped rule）；> 200 行重構整體 -->
<!-- 三 tier 由 ~/.claude/core 擁有並以 @import 常駐載入；跨 host workflow 由 ~/.agents/skills 共用 -->
<!-- 本檔只放「Claude 專屬且必須常駐」的判斷；細則走 skill / 文末 @import 漸進揭露 -->
@~/.claude/core/tier0-safety.md
@~/.claude/core/tier1-workflow.md
@~/.claude/core/tier2-style.md

## Defaults
- Package manager：npm（CI 用 `npm ci`）
- Runtime：follow `global.json` / `.nvmrc`；無則取最新 LTS。各棧版本 pin 見對應 `~/.claude/rules/*.md`
- macOS case-insensitive FS：改檔名大小寫用 `git mv`

## Tooling 優先序
- 文件查詢優先 MCP > web search；Microsoft / Azure / .NET → microsoft-learn（Context7 的觸發條件由其 MCP server instructions 自帶，勿再複述）

## Skill Routing（只放 dev-workflow SKILL.md 未覆蓋的 Claude 專屬條目；覆蓋到的一律不在此複述）
- **Workflow default**：開發任務的 skill routing 以 dev-workflow 當場讀取結果與下方 managed routing stamp 為準；本段不重複跨主機 skill mapping。
- **CI gate**：repo 託管 GitHub 且無 `.github/workflows/` 時，首次開 PR 前主動提議加 CI workflow（至少 build + test，依 stack 與目標平台選 runner / matrix）；同意後加在「會進目標分支的 branch」（既有開著的 PR 須加在其 head 分支才觸發）。既有 CI 不主動重寫。
- **瀏覽器 / E2E 工具分工**（互補不互斥）：探索式互動 + 生成測試骨架 → `agent-browser`；E2E 回歸固化進 CI → Playwright；效能 / 偵錯 → Chrome DevTools MCP；前端 UI/UX 視覺審查 → `uiux-reviewer` agent

## Security
- Secrets：env var 或 secret manager；提供 `.env.example`（只 key name）；遮罩與禁印規則見 [T0-4]

## Workflow（規則正本在 tier0-2 @import；此處只放 Claude 專屬補充）
- Push back 判準：更簡單做法落在 [T1-7] 層級內才提（附 trade-off）；一般 implementation detail 不擴成選項討論
- 新增外部套件前評估維護狀態、license、版本相容與專案既有 dependency policy（CVE 由 `dependency-security-scan` 把關）
- 非 git repo 既有專案動手前先提議 `git init` + baseline commit（throwaway sandbox / 一次性 script 例外）
- Subagent 平行探索限「單一目標 + 結構化交付物」；跨檔重構別拆
- [R-4] Ponytail（plugin 注入的 lazy prose）只約束「解法規模」（最小可行實作），MUST NOT 凌駕 tier0 / [R-1] / [R-2] gates；review / verify / debug 類 subagent 的徹底性不受其約束。觸發：ponytail prose 與任一 gate 或審查深度衝突。驗證：gate 產物齊全才放行。例外：無。

## Self-Maintenance（同錯第二次 → 沉澱；規則進常駐層，教訓進 auto memory）
- **MUST** 同錯第二次發生 → 主動提議把「規則／約束」加進對應 CLAUDE.md / rules（用戶確認後再寫）；只記「為何」+「下次如何避免」。規則需常駐才有攔截力故留本檔；純教訓／事實不留本檔，走下一條
- 學到教訓：專案特定 → `tasks/lessons.md`（隨 git）；跨專案 → auto memory（單一落點，勿寫回本檔）
- 沉澱前評估「能否機械化」：預防檢查可寫成 hook / test / lint 者，考慮落地為機械守護（如 hookify）取代 prose；判斷類知識才寫 prose

## Git Preferences（commit 格式 / force-push / reproducible commit 見 [T2-2] [T0-3] [T1-3]）
- PR merge：預設 squash（atomic commits 才用 rebase，需明確指定）；合併後自動刪除該 PR 分支（remote + 已併入的 local），無須再問
- Merge gate：綠 CI + bot review 處理完才 merge（[T0-9]）；完整 triage 流程（異步等待、thread 回覆、全 caller 對抗掃描）見 dev-workflow S6 → review-triage.md
- 套件安裝：package.json + lockfile 同 commit；純設定（lint / 格式化）獨立 commit
- 不 commit：AI 生成 plan / scratch、`.claude/settings.local.json`

## Auto-mode Commit 規則（default mode 維持「請求才 commit」）
- 觸發：完成邏輯單元（feature / fix / refactor / 套件安裝 / 設定變更 / 文件更新）主動 commit 無須問
- 仍需用戶確認：main / master / 受保護分支、revert、邏輯混雜（提議拆）、累積 5+ 未 push 的自動 commit

## Comment Policy（規則正本 [T2-4]）
- 修改既有 code 同步更新註解；註解 rot 視同 bug

## Verification（evidence [T0-2]；baseline [T1-4]）
- 無法跑驗證時明確記錄原因＋事後可執行的補跑指令（含必要 env 前綴）
- 任務轉成可驗證 goal：「修 bug」→「寫 reproduce test 並通過」、「加 validation」→「寫 invalid input test 並通過」、「refactor」→「修改前後 test 全綠」；goal 夠明確 → verify-loop 可獨立跑，模糊 → 回去補 goal
- 不直接覆寫 production config

## 可選載入（按專案語境用 @import 顯式引入）
- .NET：`@~/.claude/rules/dotnet.md`
- TypeScript：`@~/.claude/rules/typescript.md`
- Frontend SPA：`@~/.claude/rules/frontend-spa.md`（含 Web API auth / SPA storage 細則）
- WinForms：`@~/.claude/rules/winforms.md`
- C/C++：`@~/.claude/rules/cpp.md`
- 測試任務：`@~/.claude/rules/testing.md`
- DevOps / 基礎設施：`@~/.claude/rules/infra.md`
- Cookbook 知識庫（專案採用 `docs/cookbook/` 時）：`@~/.claude/rules/cookbook.md`
- /compact 或 cross-session handoff：`@~/.claude/templates/compact.md`

<!-- FP:ROUTING-2026Q3 -->

# 開發任務路由（正本：dev-workflow）

- 先讀 ~/.agents/skills/dev-workflow/SKILL.md 並依 S0 路由。錯誤／測試失敗／regression → BUGFIX；單一 target file、≤3 tasks 且無風險攔截 → sdd。
- 三 host：dev-workflow、sdd、deps-check、bug-fix-settlement、frontend-release-verification、backend-release-verification、dependency-security-scan；需求壓測 → grilling + domain-modeling；架構 → codebase-design；診斷 → diagnosing-bugs；TDD → tdd；review → code-review。顯式：/grill-with-docs、/improve-codebase-architecture（Copilot prompt）。
- 通用：stack → `*-best-practices`；Auth → auth-implementation-patterns；Docker → containerization；Tailwind v4 → tailwind-v4-shadcn；新專案 → init-project-docs；整庫 → acquire-codebase-knowledge。
- 專項：Vite → vite；Vitest → vitest；安全稽核 → security-audit；PR 安全審查 → security-review；瀏覽器探索 → agent-browser；React Router → react-router-framework-mode；跨平台桌面 app → native-feel-cross-platform-desktop；skill 稽核 → auditing-skill-folder；VueUse → vueuse-functions。
- Stack 細則：`~/.claude/rules/<stack>.md`（dotnet、typescript、frontend-spa、winforms、cpp、testing、infra、cookbook）。

## 最高風險攔截

- [R-1] push／open PR／merge／final closeout MUST NOT 在 S4/S5 全綠前執行。觸發：任一收尾動作。驗證：S4 與 S5 各適用 gate PASS；SKIPPED／UNAVAILABLE 附理由或 probe。例外：無。
- [R-2] fix 之前 MUST 先有 failing regression test（紅→綠）；無可測 seam 須明確標記例外並附替代驗證。觸發：修 bug 的變更無先行紅測。驗證：紅燈輸出存在於證據。例外：無 seam（須標記）。
