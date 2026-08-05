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
- Repo manifests／lockfiles／CI／task evidence 是 package manager 與 runtime 的 source of truth；文件 routing 由 `dev-workflow` 依 provider-native official docs 優先。
- 落檔文件（spec／plan／handoff／research／report／memory）長度對齊任務所需：覆蓋實質內容即止，不補填充章節、重複摘要或樣板段落；同一結論不在同一檔重述兩次。

## Thin workflow

任何開發任務先讀 `~/.agents/skills/dev-workflow/SKILL.md`；host-local prose 不複製 method。

### Authorization

- Delegation：依 shared `dev-workflow` [INT-4] 由 AI 自主判定，無須另問。

### S4 VERIFY

Verification scope 與 risk tier 由 `~/.agents/skills/dev-workflow/SKILL.md` 定義；完成宣稱仍受 [T0-2]。

### S6 CLOSEOUT

Local checkpoint commit 僅依 shared `authorization-matrix`；push／open PR／merge／final closeout 仍依 shared [INT-1]、[T0-9] 與 `review-triage`。預設 squash merge，合併後清理已合併 branch。

## Claude adapter

- plan = EnterPlanMode；todo = TodoWrite；子代理 = Task／Agent。
- `code-review` 的 Standards／Spec fan-out 依 shared [INT-4]；前端視覺 review 可用 Claude-local `uiux-reviewer`。
- launchctl read-only 查詢只走受保護的 `~/.claude/hooks/launchctl-readonly.sh <subcommand>`；direct／common env-spelled launchctl deny，其他拼法不預先核准，任何 unsandbox retry 必須人工確認。
- 已核准 scope 內的 Low／Medium-risk、local、reversible 工作可自主完成；Medium 留 session plan；publication 與 protected side effect 仍走 `dev-workflow` authorization gate。
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
