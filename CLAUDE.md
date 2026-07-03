# Global Preferences

<!-- last audited 2026-05-15; next review: 2026-11-15 或主檔 > 150 行（拆 path-scoped rule）；> 200 行重構整體 -->
<!-- 技術棧細則於 ~/.claude/rules/*.md，需要時用 @import 顯式載入（見文末附錄） -->

## 優先序
衝突時：專案 CLAUDE.md > 全域 > Skills 通用規則。Skill 規則與用戶明確偏好衝突時以用戶偏好為準。

## Hard Rules
非 negotiable，違反屬 bug。
- **NEVER** 假設未驗證 file paths / APIs / config keys
- **NEVER** 無 evidence 標 task done
- **NEVER** force-push 到 `main` / `master`
- **NEVER** 把 token / 敏感資料放 frontend `localStorage` / `sessionStorage`
- **MUST** 模糊時停下發問——先攤開「我的假設是 X、影響範圍 Y」等確認再動手，不靜默推進、不悶頭假設後自走（偏向問，不偏向做）
- **MUST** auth / payment / migration / crypto / multi-tenant 資料邊界 / rate limiting / 部署 pipeline 等高風險變更附 rollback 策略
- **MUST** DB migration 分段：expand → backfill → switch reads → remove legacy；破壞式 schema 變更不與消費端變更同一次 deploy
- **MUST** 非 trivial 任務（3+ 步 / 多檔 / 架構性）進 plan mode；auto mode 雖減確認，仍 MUST plan
- **MUST** frontend UI 變更交付前以 Playwright MCP（headed）驗證；缺 GUI 環境（CI / 遠端 / Docker）明確回報 fallback headless

## Defaults
- Package manager：npm（CI 用 `npm ci`）
- Runtime：follow `global.json` / `.nvmrc`；無則取最新 LTS。各棧版本 pin 見對應 `~/.claude/rules/*.md`
- macOS case-insensitive FS：改檔名大小寫用 `git mv`

## Tooling 優先序
- 文件查詢優先 MCP > web search：library / framework → Context7；Microsoft / Azure / .NET → microsoft-learn

## Skill Routing
- **Stack 實作 MUST invoke 對應 skill**（即使你以為知道；不在主檔重複 skill 規則）：後端 .NET / EF / Dapper / SQL / Node、前端 React / Vue / TS / CSS → `*-best-practices`
  - 專屬 skill：React Router → `react-router-framework-mode`；Tailwind v4 + shadcn → `tailwind-v4-shadcn`；Auth → `auth-implementation-patterns`；Docker → `containerization`；C/C++ → `c-cpp-best-practices`；Pinia / VueUse / Nuxt / Vitest / Jest / Playwright / Vite → 同名 skill
- **Workflow（mp-* 為 escalation 不是 default）**：
  - Bug / debug → default `superpowers:systematic-debugging`；重現率 < 50% / flaky / 效能 regression 找不到根因才 escalate `mp-diagnose`；修復完成後知識沉澱收尾 → `bug-fix-settlement`
  - TDD / red-green-refactor → default `superpowers:test-driven-development`；user 指名 vertical-slice tracer bullet 才升 `mp-tdd`
  - Architecture / refactor / testability 改善 → `mp-improve-codebase-architecture`；變更後收尾 `code-simplifier` agent（注意：依賴專案 CLAUDE.md 的 stack coding standards，缺則會 fallback 內建 JS/React 慣例、對其他 stack 套錯標準且不警告）
  - Code review → 流程走 `superpowers:requesting-code-review`（dispatch 一個 `general-purpose` reviewer subagent + 套 `code-reviewer.md` 模板給乾淨 context，回饋接 `receiving-code-review`）；需 stack 專精深審時改 dispatch 對應 agent（.NET → `dotnet-code-reviewer`，其餘 → `code-reviewer`），與前者擇一非並用
  - 改高扇入共用檔（重構 / 改名 / 改 public API / 搬檔）前 → `deps-check` 先列依賴方（支援 TS/JS + .NET）
  - 整庫上手 / 接手既有專案 → `acquire-codebase-knowledge`；進陌生 code area 需 system map → `/mp-zoom-out`（無 `CONTEXT.md` / domain glossary 時自動降級為泛用詞彙描述，不會壞但少了領域對齊；剛接手尚未做需求釐清時屬正常）
  - 架構視覺化（兩層制）：**Default（每 repo 必交付）** = `docs/codebase/ARCHITECTURE.md` 內嵌 `design-doc-mermaid` 產的 mermaid 架構圖——純文字、可 git diff / review、GitHub 原生 inline render，列為 onboarding / init 的明示必交付物（不再是隱性產物）。**Opt-in 升級** = self-contained 互動 HTML，僅命中甜蜜點才**提議**（用戶同意才產，預設不產）：(a) 有複雜狀態機 / bitmask / 流程互動，靜態圖講不清；(b) 交付對象含非技術 stakeholder；(c) 專案夠大且生命週期長。**Rot 守護**：改架構（新增模組 / 改資料流 / 改狀態機）時同步更新 mermaid 圖，diagram rot 視同 bug；若採用 HTML，HTML 應視為從 mermaid 衍生的產物、勿手改（要嘛重生成要嘛保持 mermaid 為單一真實來源）。理由：HTML 無機械守護（編譯器 / 測試 / lint 都看不到它腐爛）、難 diff / review，無條件 default 會違反 cookbook「寧缺勿濫」；mermaid 當 default 既滿足「每 repo 都有視覺化」又無 rot 風險，HTML 留給真需互動的場景
  - 輕量小需求（單檔 / 單一行為 / 1 天內、不值得動下方重鏈）→ 主動提議走 `/sdd`（提案→實作→歸檔，產 `sdd/<短名>/proposal.md` + `tasks.md`）；判不準走輕量或重型就停下問，勿自選
  - 需求釐清 → 計畫 → 實作 鏈：`mp-grill-with-docs` 拷問細節、邊談邊產出 / 更新 `CONTEXT.md` + ADR（lazily 建，非前提）→ `superpowers:brainstorming` 探索 approach + 產 design spec（`docs/superpowers/specs/`；其 terminal state 強制接 writing-plans，勿 invoke 其他 skill）→ `superpowers:writing-plans` 產實作計畫 doc（`docs/superpowers/plans/`，bite-sized task 已內嵌 TDD 紅綠循環）→ 實作驅動 `superpowers:executing-plans`（inline 批次 + checkpoint）或 `superpowers:subagent-driven-development`（每 task 開新 subagent + 兩段審查）
  - doc 分工互補非重複：`CONTEXT.md` + `docs/adr/` = 領域語言 / 決策；`specs/` = 設計；`plans/` = 執行步驟
- **Verification gate**：部署前 → 前端變更跑 `frontend-release-verification`；後端變更跑 `backend-release-verification`；**無論前後端皆必跑 `dependency-security-scan`（與前後端正交，非三選一）**
- **CI gate**：repo 託管 GitHub 且無 `.github/workflows/` 時，首次開 PR 前主動提議加 CI workflow（至少 build + test，依 stack 與目標平台選 runner / matrix），讓每次 PR 自動驗證；同意後加在「會進目標分支的 branch」（既有開著的 PR 須加在其 head 分支才觸發）。既有 CI 不主動重寫。
- **瀏覽器 / E2E 工具分工**（互補不互斥）：探索式互動 + 生成測試骨架 → `agent-browser`；E2E 回歸測試固化進 CI → Playwright；效能 / 偵錯 → Chrome DevTools MCP；前端實作後 UI/UX 視覺品質審查 → `uiux-reviewer` agent
- **新專案初始化** → `init-project-docs`

## Workflow Playbooks
> 進入點 + 階段序；各階段 skill 觸發細則見 Skill Routing。**MUST** 每完成一階段主動回報「目前階段 / 下一步」一行，不靜默跳步。
> **跨流程通則**：實作型流程（新增功能 / 修復錯誤）進實作前先開對應分支（`feat/` / `fix/`，見 Git Preferences）；baseline / 骨架階段可直接在當前分支。**收尾**：`executing-plans` / `subagent-driven-development` 跑完會強制接 `superpowers:finishing-a-development-branch`（REQUIRED 終態 sub-skill，內含 test-gate → 偵測 worktree → 呈現 merge/PR/cleanup 選單 → worktree 清理），故 plan-driven 實作的 commit → PR（預設 squash）+ worktree 清理一律走該 skill，勿另自訂收尾與之重複；非 plan-driven 的輕量改動才手動 commit → PR。
- **新空專案**：`git init` → `mp-grill-with-docs` / `brainstorming` 釐清需求（brainstorming terminal 接 `writing-plans` 產骨架計畫 doc）→ 依計畫寫出最小可跑骨架（manifest + 基本結構；**骨架以手動實作落地，不走 `executing-plans` / `subagent-driven`——否則會被其強制終態推向 `finishing-a-development-branch` 的 PR/merge，與本流程「當前分支 baseline commit」相牴觸；writing-plans 跑完若提示 execution 二選一，此階段明確跳過**）→ **驗證骨架能 build / run（拿到 evidence 才算骨架成立，不可未跑就標 done）** → `init-project-docs`（**此時才跑**：該 skill 為 detect-from-real-files 導向，空專案無真實檔案可偵測只會產 fallback 骨架且 README/ARCHITECTURE 需求相依文件空殼）→ init 已產出 host 協作檔（CLAUDE.md）骨架，於其上手動補 stack rules `@import` refine（非重建，是接著精修 init 產出的檔）→ **baseline commit（骨架 + docs + 協作檔一起進版控，建立可 reproduce 的起點）** → 進「新增功能」
- **舊 / 接手專案**：`git init`（若無）→ `acquire-codebase-knowledge`（整庫測繪，**收尾須解決它輸出的 numbered [ASK USER] 問題 + Intent-vs-Reality 分歧，再往下**）或 `/mp-zoom-out`（單一區塊）→ **銜接 gate（放 acquire 之後，非開頭）：偵測缺當前 host 的 AI 協作檔（CLAUDE.md / AGENTS.md）→ 缺則提議跑 `init-project-docs` 補，並提供 acquire 的 `docs/codebase/` 成果當參考脈絡（init 為 detect-from-real-files，無消費外部輸入的規格，仍會自行全量偵測、無法跳過掃描；docs/codebase 僅供品質對齊與避免結論衝突，不省偵測步驟。放開頭會把 init 拉回失效時點：測繪前無真實脈絡 / glossary，協作檔品質最差）。注意分支差異：只有 acquire 會落地 `docs/codebase/` 可當參考；走 `/mp-zoom-out` 分支只產對話內地圖、無持久檔，init 連參考脈絡都沒有，全靠自行偵測。補完 init 後同新空專案：於 init 產出的協作檔上手動補 stack rules `@import` refine（否則接手專案的 CLAUDE.md 沒掛 stack rules，後續 `code-simplifier` 會 fallback 內建慣例套錯標準）** → **驗證既有專案 build / test 全綠（綠燈基線；拿到 evidence 才動手，否則分不清「自己改壞」還是「接手即壞」）；若本步是首次 `git init`，`docs/codebase` + 協作檔一併 baseline commit** → **架構視覺化（收尾必交付）：產出 / 更新 `docs/codebase/ARCHITECTURE.md` 內的 mermaid 架構圖；命中甜蜜點再**提議**升級互動 HTML（opt-in、用戶同意才產，判準與 rot 守護見 Skill Routing「架構視覺化」條，勿在此重述）** → 進對應流程
- **新增功能**：**入口 gate（輕量）：偵測 CLAUDE.md / stack rules 是否存在，缺則先判專案成熟度——已有足量 code→補 `init-project-docs`；近乎空 / 無 manifest→改走「新空專案」playbook（在近乎空專案補 init-project-docs 會撞它自身失效）。否則 `code-simplifier` 套錯 stack 標準、計畫缺技術慣例權威來源。並判定 code 是否足量到讓 `deps-check` 有意義（近乎空專案多為純新增，本次標記不觸發 deps-check，避免空轉噪音）** → `mp-grill-with-docs`（拷問需求 → 產出 / 更新 `CONTEXT.md` + ADR）→ `brainstorming`（探索 approach + 產 design spec；**含 spec user-review 簽核 ⏸,需用戶確認 spec 才接 writing-plans**）→ `writing-plans`（產實作計畫 doc：影響檔案 + 編號 bite-sized task，TDD 紅綠已內嵌每步）→ ⏸ 等確認（**此 gate 對應 writing-plans 的 execution 二選一:subagent-driven / inline**）→ 實作以 `executing-plans` / `subagent-driven-development` 驅動（TDD 在 plan task 內，不另掛；高扇入檔先 `deps-check`、自動套 stack skill）→ `code-simplifier` agent → 前端另跑 Playwright headed + `uiux-reviewer`（後者硬依賴 `claude-in-chrome` MCP，無 headless fallback，缺則明確回報跳過、不臆測畫面）→ code review → `*-release-verification` + `dependency-security-scan`（後者必跑、與前後端正交，非三選一）→ **最後才 `finishing-a-development-branch` 做 PR/merge/cleanup**（**攔截策略**：task 全綠後**不要**讓 executing-plans / subagent-driven 直接呼叫 finishing——它一被 invoke 就在 test-gate 後立即呈現 merge/PR 選單、無暫停點；應先 break out 跑完上述 code-simplifier → review → release-verification + dep-scan，**全綠後才手動 invoke** finishing 收尾。重點是「延後 finishing 的呼叫時機」非「延後 finishing 內部的 merge step」；勿一跑完 task 就讓 finishing 直接 merge、跳過品質關卡）
- **修復錯誤**：`systematic-debugging`（reproduce → root cause → **動共用檔前先 `deps-check`** → **先寫 failing regression test（紅）→ fix 讓它轉綠**——測試必須先於修復，三個 sub-skill 一致：systematic-debugging Phase 4「test before fixing」、mp-diagnose Phase 5「regression test before the fix」、TDD Iron Law。切勿先 fix 再補測試；**同一 bug ≥3 次修復都失敗 → 停手質疑架構（systematic-debugging Phase 4.4–4.5），與用戶確認後交接 `mp-improve-codebase-architecture`，與下方 mp-diagnose 的 seam 路徑構成兩條對稱的架構升級出口**）；**重現率 < 50% / flaky / 效能 regression 找不到根因 → escalate `mp-diagnose`（reproduce-minimise-instrument 迴圈；注意其 Phase 5 的 seam 例外：有 correct seam 才寫 regression test，無 seam 則允許以「記錄架構問題」替代並明確標記為例外，不算違反 test-first 鐵則；**且依其契約,fix landed 後須交接 `mp-improve-codebase-architecture` 把該架構問題收進改善流程,勿只停在「記錄」；**交接前若無 `CONTEXT.md` / `docs/adr/`（bug-fix 常未走 grill，而 mp-improve 以此為前提且無自動降級），先補最小領域脈絡或明確標記降級，勿讓 mp-improve 在無前提下空跑**）→ 前端 UI bug 另跑 Playwright headed 驗證（Hard Rule，缺 GUI 環境 fallback headless 並回報）→ **`code-simplifier`（前置 gate 同新增功能：先確認 CLAUDE.md 掛了對應 stack rules，缺則 simplifier 會靜默 fallback 內建 JS/React 慣例、對其他 stack 套錯標準且不警告 → 先補 `@import` 或跳過 simplifier）→ code review** → **沉澱前 gate（debug 階段零依賴，開頭不設 gate）：偵測 cookbook 慣例是否已初始化（`docs/cookbook/` + `MOC.md` + CLAUDE.md 有 `@~/.claude/rules/cookbook.md`）；已採用→照常寫入並更新 MOC；未採用但根因值得沉澱→提議補慣例或改寫 memory 並等確認，勿自建無 MOC / README 的孤兒檔（會造成 cookbook rot）** → `bug-fix-settlement` 沉澱 → **若修復會部署到 production：上線前過 `*-release-verification` + `dependency-security-scan`（沉澱 ≠ 上線驗證，兩者都要；dep-scan 必跑、與前後端正交）**

## Security
- Secrets：env var 或 secret manager；提供 `.env.example`（只 key name）

## Workflow
Plan first, code second. Verify before claim.
- **MUST** Plan mode 輸出編號步驟、影響檔案、預期結果、風險等級（低/中/高；中高須含 rollback 策略與加強驗證），等用戶確認再動手
- Push back：用戶需求有更簡單做法 → 直說並建議，不盲從複雜實作。Trigger：(a) 標準函式庫已有卻引新依賴；(b) 50+ 行可由 10 行內建函式取代；(c) 抽象層只有單一使用點；(d) 平台 / 語言原生功能已涵蓋卻自寫或引依賴（HTML `<input type="date">` 勝過 picker lib、CSS 勝過 JS、DB 約束勝過 app 層、框架內建勝過手刻）；指出更簡單做法時給 trade-off，但別把一般 implementation detail 擴成選項討論
- 選型優先序：**原生（語言 / 框架 / 平台內建，如 CSS／HTML 原生元素／DB 約束）＞ 標準函式庫 ＝ repo 既有模組／已安裝套件 ＞ 成熟可靠第三方套件 ＞ 自己手寫**。依此序由上往下找，只有在找不到合適方案、依賴成本高於效益、或需求非常小且自寫更直接時才自行實作。新增外部套件前 MUST 評估維護狀態、license、安全性、版本相容與專案既有 dependency policy（CVE 另由 `dependency-security-scan` 把關）。與 Push back (a) 不衝突：(a) 禁「原生／標準庫已有卻引新依賴」，本條規範「前面層級皆無」時套件優先於手刻
- 自我簡化只動「自己當前正在寫的新 code」，不動既有 code；交付前自問「資深工程師會覺得 overcomplicated 嗎」（典型訊號：可壓縮 ≥ 50% 行數、抽象層只有單一 caller、提早泛型化），是則 rewrite
- **MUST** 修改既有 code 沿用該檔風格（縮排 / 命名 / 註解寫法 / pattern）即使個人偏好不同；不順手改不相關格式 / 命名 / 註解（發現另開 task）
- **MUST** 自己變更造成的 dead code（unused imports / variables / functions）必清；pre-existing dead code 提及但不刪，等 user 確認
- 非 git repo 既有專案動手前先提議 `git init` + baseline commit（throwaway sandbox / 一次性 script 例外）
- Subagent 平行探索限「單一目標 + 結構化交付物」；跨檔重構別拆

## Self-Maintenance（Boris 原則：Claude 做錯就加進 CLAUDE.md）
- **MUST** 同錯第二次發生 → 主動提議加進對應 CLAUDE.md / rules（用戶確認後再寫）；只記「為何」+「下次如何避免」
- 學到教訓：專案特定 → `tasks/lessons.md`（隨 git）；跨專案 → auto memory 或本檔
- 沉澱前評估「能否機械化」：預防檢查可寫成 hook / test / lint 者，考慮落地為機械守護（如 hookify）取代 prose；判斷類知識才寫 prose

## Git Preferences
- Conventional Commits zh-TW（commit & PR title 皆 zh-TW）：`feat(api): 新增 xxx`、`fix(ui): 修正 xxx`、`chore(deps): 更新 xxx`
- Branch：`feat/`、`fix/`、`chore/`、`refactor/`
- PR merge：預設 squash（atomic commits 才用 rebase，需明確指定）；合併後自動刪除該 PR 分支（remote + 已併入的 local），無須再問
- **Merge gate（squash-merge 前必查，非只看 CI）**：除 `gh pr checks` 綠燈外，**另須**查 PR 的 Copilot / bot review——它是 COMMENTED state、non-blocking、**不計入 `gh pr checks`**（每 PR 自動請求一次，但**異步產出**：開 PR 後約 2–3 分鐘才提交，開 PR 當下查 `reviews` 為空是延遲不是「無」，**勿據此斷言此 repo 無 bot review**；應等 Copilot review 提交或重查再下結論），只看 CI 會漏接（PR #34 即因此漏掉 8 條建議）。查法：`gh pr view <n> --json reviews` 或 `gh api repos/{owner}/{repo}/pulls/<n>/comments`。有未處理建議 → 走 `receiving-code-review` 技術評估（採納或有據 pushback + 於 thread 回覆），處理完才 merge；review 尚未產出則等待，勿提前 merge。**且 bot 複審只覆蓋反模式的「子集」，處理完 findings ≠ 根因已在所有 caller 修好**（PR #36：Copilot 只點名 6 個 `ReadBig5File` 消費端中的 4 個 deref-before-null，漏掉 2 個 → 對抗式全 caller 掃描才補齊）：改共用函式的反模式時，把 bot findings 當「起點子集」，收斂前另跑 `deps-check` / grep 枚舉全部 caller 自行核對（見上方「改高扇入共用檔前先列依賴方」），勿以 bot 清單為完整
- Force push 只用 `--force-with-lease`（main / master 禁止見 Hard Rules）
- Commit 訊息第一行字數限制：英 ≤ 72 / 中 ≤ 30
- Reproducible commit：每個 commit 須能獨立 checkout build 通過；寧可大 commit 也別留 transient broken state
- 套件安裝：package.json + lockfile 同 commit；純設定（lint / 格式化）獨立 commit
- WIP：失敗探索 commit 訊息加 `[wip]` 限 feature branch；PR 前 interactive rebase / squash 整理
- 不 commit：AI 生成 plan / scratch、`.claude/settings.local.json`

## Auto-mode Commit 規則（default mode 維持「請求才 commit」）
- 觸發：完成邏輯單元（feature / fix / refactor / 套件安裝 / 設定變更 / 文件更新）主動 commit 無須問
- 仍需用戶確認：main / master / 受保護分支、revert、邏輯混雜（提議拆）、累積 5+ 未 push 的自動 commit

## Comment Policy（system override：覆蓋系統 default no-comments）
- **NEVER** 寫 what-paraphrase / 對話 context（例：「fixed in PR X」、「used by Y flow」、「added for the Z flow」）
- Public API（exported function / class / type）必寫 docstring：.NET XML doc / TS JSDoc，含用途、param、return、throws
- WHY 註解判準放寬到「兩年經驗工程師可能困惑」即寫（業務規則來源、踩過的坑、不變條件、為何選 A 不選 B）
- 修改既有 code 同步更新註解；註解 rot 視同 bug

## Code Review
- 優先序：breaking changes → security → performance regression → correctness
- Conventional comments：`suggestion:`、`nitpick:`、`issue:`、`question:`
- PR 描述需含：變更目的、變更理由（為何這樣改、對應哪個需求 / bug）、影響範圍、測試方式；commit / PR 描述須能回溯需求，決策以描述交代、不靠逐步旁白
- Diff 自審：每行變更可對應原始需求；無法追溯的順手改 → 移除或另開 task

## Verification
- Evidence 形式：test / build / lint pass 紀錄；無法跑時明確記錄原因
- 中高風險變更附 baseline capture：改動前先抓 before/after 對照（API response / query count / 輸出樣本）
- 任務轉成可驗證 goal：「修 bug」→「寫 reproduce test 並通過」、「加 validation」→「寫 invalid input test 並通過」、「refactor」→「修改前後 test 全綠」
- Goal 夠明確 → verify-loop 可獨立跑；模糊 → 回去補 goal
- 修改前確認 git status clean；不直接覆寫 production config

## Communication
- 提問時列選項 + 推薦預設 + trade-off，並說明答案如何影響結果（何時該問見 Hard Rules）；已決事項不畫蛇添足建議 alternatives；speculation OK 但要標記

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
