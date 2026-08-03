# Global Preferences

<!-- Claude owns this routing/governance file and ~/.claude/core|rules|hooks. Shared workflow methods live only in ~/.agents/skills. -->
@~/.claude/core/tier0-safety.md

ponytail 注入=通用慣例；測試敘述 MUST NOT 覆寫 [T0-2]／dev-workflow [INT-2]。

## Defaults

- 預設 zh-TW；technical terms 保留 English。
- 回覆 SHOULD outcome-first、無空泛前後文；決策列編號選項／推薦／取捨，單字或數字即為完整回答，推測標記，已決不列替案。
- 多步任務每回合標進度（「5 步第 3 步完成 → 下一步 X」）；已用 todo tool 時由清單承擔重述，不再散文複誦全計畫。
- 時間／工作量估計用具體單位並標前提（「測試已覆蓋約 15 分鐘，否則半天」）；禁「一些工作」「不用太久」這類無刻度描述。
- 完成回報寫成可驗證動作：做了什麼 → 現在什麼能用 → 用什麼指令驗，不寫抽象摘要。
- 送出前刪：宣告接下來要做什麼的首句、收尾客套、by-the-way 旁註、無資訊量 hedge、慣用語（含「好的，我來…」「希望有幫助」）。承載真實不確定性的 hedge 保留。
- Package manager：npm（CI 用 `npm ci`）。
- Runtime follow `global.json`／`.nvmrc`；無則取最新 LTS。
- 文件查詢優先 MCP；Microsoft／Azure／.NET 用 microsoft-learn。
- 落檔文件（spec／plan／handoff／research／report／memory）長度對齊任務所需：覆蓋實質內容即止，不補填充章節、重複摘要或樣板段落；同一結論不在同一檔重述兩次。

## Thin workflow

任何開發任務先讀 `~/.agents/skills/dev-workflow/SKILL.md`；host-local prose 不複製 method。

### Authorization

- Delegation：依 shared `dev-workflow` [INT-4] 由 AI 自主判定，無須另問。
- Delegation 收斂（不覆寫 [INT-4] 的數量自主）：幾個 tool call 可完成的工作不派 subagent；單一小任務不拆多個 subagent；S5 以外不另派 subagent 做 verification（S5 的獨立視角依 [S5-3] 保留）；已委派就不重做、不重推導其回報結論。

### S4 VERIFY

Build／test／lint 與 task-specific probes 全跑；中高風險附 before／after evidence。無 evidence 不得宣稱完成。

### S6 CLOSEOUT

S4、S5 全綠後才可 commit／push／open PR／merge／final closeout；merge 前 CI 綠且處理 bot review。預設 squash merge，合併後清理已合併 branch。

## Claude adapter

- plan = EnterPlanMode；todo = TodoWrite；子代理 = Task／Agent。
- `code-review` 的 Standards／Spec fan-out 依 shared [INT-4]；前端視覺 review 可用 Claude-local `uiux-reviewer`。
- Auto mode 可在已核准的 feature branch 完成單一邏輯單元後 commit；main／master、revert、混雜 diff 仍需確認。
- Secrets 只用 env／secret manager；log／chat 只回報 set／unset。

## On-demand stack rules

- .NET：`@~/.claude/rules/dotnet.md`
- TypeScript：`@~/.claude/rules/typescript.md`
- Frontend SPA：`@~/.claude/rules/frontend-spa.md`
- WinForms：`@~/.claude/rules/winforms.md`
- C/C++：`@~/.claude/rules/cpp.md`
- Testing／infra：`@~/.claude/rules/testing.md`、`@~/.claude/rules/infra.md`
- Same-conversation `/compact`：`@~/.claude/templates/compact.md`
- Cross-session handoff：`/handoff`
