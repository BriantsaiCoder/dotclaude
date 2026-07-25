---
description: 輕量規格驅動開發（提案→實作→歸檔），適合小需求
argument-hint: 提案 <需求描述> | 實作 | 歸檔
---

# /sdd — 輕量規格驅動開發（薄殼）

正本已遷移至三家共用層 skill `sdd`（`~/.agents/skills/sdd/SKILL.md`）。本檔僅是 Claude 端的 `/sdd` slash command 入口，勿在此重複流程規則（雙份維護會 drift）。

執行時：讀 `~/.agents/skills/sdd/SKILL.md` 並依其三階段（提案 / 實作 / 歸檔）規則執行。本次階段由 `$ARGUMENTS` 第一個詞決定；`$ARGUMENTS` 為空或無法判斷階段時，先說明三個關鍵字用法並停下，不要自己猜階段。
