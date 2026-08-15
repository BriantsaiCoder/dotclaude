---
paths:
  - "**/*.{test,spec}.{ts,tsx,js,jsx,mjs,cjs}"
  - "**/*Tests.cs"
  - "**/*Spec.cs"
  - "**/*.Tests/**"
  - "**/__tests__/**"
  - "**/tests/**"
  - "**/test/**"
  - "**/playwright.config.*"
  - "**/vitest.config.*"
  - "**/jest.config.*"
  - "**/e2e/**"
  - "**/*.csproj"
  - "**/Directory.Build.props"
  - "**/.github/workflows/*.{yml,yaml}"
---

# Testing 行為錨

> Stack 工具選擇（xUnit / Vitest / GoogleTest / Playwright config 細則）+ Deployment Gate 細則 → 對應 `*-best-practices` / `*-release-verification` skill。

- E2E 工具分工：**Playwright MCP**（headed）跑 user journey；**Chrome DevTools MCP** 用於 HTML / CSS / Mermaid 視覺問題與 perf / network / Web Vitals 除錯，不替代 E2E
- E2E 義務：frontend UI / user-facing 變更後 **MUST** 跑 Playwright MCP（headed）；缺 GUI 環境（CI / 遠端 / Docker）明確回報 fallback headless，不靜默降級
- RWD viewport：mobile（375）+ desktop（1280）baseline；critical flow（auth / 結帳 / 表單 / 資料變更 / 路由）加 tablet（768）
- **MUST** 每 viewport 截圖 + console / page error log；缺一視同未驗證
- 瀏覽器清理：MCP `--isolated`（已配置 `~/.claude/playwright-mcp-config.json`）+ 顯式關 page / context；session 結束不應殘留 chromium
- Selector 優先序：getByRole / getByLabel / visible text / getByTestId；CSS selector avoid（third-party 元件無 a11y 等明確理由除外）
- Naming：`MethodName_Scenario_ExpectedResult`（.NET）、`describe/it` 自然語言（frontend）
- Integration tests 涵蓋 critical paths（auth / payment / 持久化 / 外部整合）
- Timing / concurrency bug 的 regression test 須針對 race 條件（重複執行 / stress），單次通過不算證據
- 設計面優先以 idempotency / transaction boundary 消除 race，不以 sleep / retry 掩蓋

## .NET verification layer 對照（哪些指令是 gate、哪些只是報表）

先看 repo 既有的（`.csproj` / `Directory.Build.props` / CI yml）；下表是什麼都沒有時的預設。**選型判準是 exit code**：印數字卻 exit 0 的指令是報表，不是 gate，不得作為 evidence 的把關層。「證據」欄記本表每列的查證方式——`實跑` = 觀察過 exit code，`文件` = 官方文件明載，未標者未經查證。

| Layer | 指令 | Gate？ | 證據 |
|---|---|---|---|
| Tests | `dotnet test -c Release` | ✅ | — |
| Compile | `dotnet build -c Release -warnaserror` | ✅ | 註 1 |
| Format | `dotnet format --verify-no-changes --severity warn` | ✅ | 文件 |
| Coverage | `dotnet test -p:CollectCoverage=true -p:CoverletOutputFormat=cobertura -p:Threshold=<n> -p:ThresholdType=line,branch`（**coverlet.msbuild**） | ✅ | 文件 |
| Coverage | `dotnet test --collect:"XPlat Code Coverage"`（**coverlet.collector**） | ❌ 不做 threshold validation | 文件 |
| Changed-line coverage | `diff-cover coverage.cobertura.xml --compare-branch=origin/main --fail-under=<n>`（Python 工具，需 pip；XML 由上一列的 `CoverletOutputFormat=cobertura` 產出，collector 則落在 `TestResults/**/coverage.cobertura.xml`） | ✅ | 文件 |
| Mutation | `dotnet stryker --since:main --break-at <n>`（於測試專案目錄） | ✅ 少了 `--break-at` 只是報表 | 文件 |
| Property-based | `CsCheck`（無框架綁定）或 `FsCheck.Xunit` 的 `[Property]`，隨 `dotnet test` 跑 | ✅ | 文件 |
| 依賴弱點 | `Directory.Build.props` 設 `<NuGetAuditMode>all</NuGetAuditMode>` + `<WarningsAsErrors>$(WarningsAsErrors);NU1903;NU1904</WarningsAsErrors>` → `dotnet restore` | ✅ | 實跑 exit 1 |
| 依賴弱點 | `dotnet list package --vulnerable --include-transitive` | ❌ 印出 High／Critical 仍 exit 0 | 實跑 exit 0 |
| Secrets | 依 `~/.agents/skills/dev-workflow/references/dirty-review-package.md`（三段掃描 + 三類 exit code），不要只跑 `gitleaks git --staged` | ✅ | — |

註 1：`-warnaserror` 是 MSBuild switch，提升的是所有 MSBuild-logged warning（含 NuGet 的 `NU` 碼），與編譯器層的 `<TreatWarningsAsErrors>`（可用 `NoWarn`／`WarningsNotAsErrors` 細調）語意不同。要的是型別 gate 就用後者，否則一個無關的 `NU1701` 會讓 build 紅。

`NuGetAuditMode` 在專案 target 低於 `net10.0` 時預設 `direct`，只稽核直接相依；多目標時任一 target 選 `all` 即全體適用。不寫這一行，gate 的覆蓋範圍會小於讀者假設。

.NET Framework 專案的三個差異：

- **BCL 可攜性可以機械化**——`<TargetFrameworks>net8.0;net48</TargetFrameworks>` + `Microsoft.NETFramework.ReferenceAssemblies`（`PrivateAssets="all"`，`Condition` 限定該 TFM，不進輸出也不污染另一個 target 的相依），用到目標版本沒有的 API 就編譯失敗。第二個 moniker 換成專案實際要搬進去的版本（`net48` 只是範例，新建專案的預設見 `dotnet.md`）；寫確切 moniker，不要寫超集（`net46` ≠ `net462`）。三個代價：多目標後 `dotnet run` 需要 `-f <tfm>`，而**加了 `-f` 就跳過 gate**（只會朝更綠偏，不會表現成紅燈）；目標為已停止支援的版本時新版 Visual Studio 載不進該 `.csproj`；首次 restore 需連 nuget.org。
- **`packages.config` 專案上 audit 本身仍會出 warning，但把它變成 gate 是 `UNAVAILABLE`**：MSBuild 的訊息嚴重度屬性（`NoWarn`／`TreatWarningsAsErrors`）不支援該專案格式。先遷 `PackageReference`，否則標 `UNAVAILABLE` 附 probe。
- **Stryker 在 .NET Framework 上需要 nuget.exe 在 PATH 與 VS 的 NuGet targets/build tasks**（文件未明言平台限制，實務上推測 Windows-only）。若 build target 是 net8.0、4.x 只是源碼層約束，直接對 net8.0 那個 target 跑即可。`<LangVersion>6</LangVersion>` 對應 `stryker-config.json` 的 `"language-version": "Csharp6"`（文件已列為合法值；只能寫 config 檔，無 CLI 旗標）。

測試隨機序無 first-party 工具（xUnit 要自寫 `ITestCaseOrderer`，NUnit 走 `[Order]`／`Randomizer`）；單執行緒、無共享狀態的專案標 `SKIPPED` 附理由即可。
