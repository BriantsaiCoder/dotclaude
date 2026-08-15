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

先看 repo 既有的（`.csproj` / `Directory.Build.props` / CI yml）；下表是什麼都沒有時的預設。**選型判準是 exit code**：印數字卻 exit 0 的指令是報表，不是 gate，不得作為 evidence 的把關層。

| Layer | 指令 | Gate？ |
|---|---|---|
| Tests | `dotnet test -c Release` | ✅ |
| Compile / types | `dotnet build -c Release -warnaserror` | ✅ |
| Format | `dotnet format --verify-no-changes --severity warn` | ✅ |
| Coverage | `dotnet test -p:CollectCoverage=true -p:Threshold=<n> -p:ThresholdType=line,branch`（**coverlet.msbuild**） | ✅ |
| Coverage | `dotnet test --collect:"XPlat Code Coverage"`（**coverlet.collector**） | ❌ 不做 threshold，永遠 exit 0 |
| Changed-line coverage | `diff-cover coverage.cobertura.xml --compare-branch=origin/main --fail-under=<n>` | ✅ |
| Mutation | `dotnet stryker --since:main --break-at <n>`（於測試專案目錄） | ✅ 少了 `--break-at` 就只是報表 |
| Property-based | `CsCheck`（純 C# API）或 `FsCheck.Xunit` 的 `[Property]`，隨 `dotnet test` 跑 | ✅ |
| 依賴弱點 | `Directory.Build.props` 設 `<WarningsAsErrors>$(WarningsAsErrors);NU1903;NU1904</WarningsAsErrors>` → `dotnet restore` | ✅ |
| 依賴弱點 | `dotnet list package --vulnerable --include-transitive` | ❌ 有發現仍 exit 0 |
| Secrets | `gitleaks git --staged --redact` | ✅ |

.NET Framework 專案的三個差異：

- **BCL 可攜性**可以機械化——`<TargetFrameworks>net8.0;net4x</TargetFrameworks>` + `Microsoft.NETFramework.ReferenceAssemblies`（`PrivateAssets="all"`，不進輸出），用到目標版本沒有的 API 就編譯失敗。寫確切 moniker，不要寫超集（`net46` ≠ `net462`）。多目標後 `dotnet run` 需要 `-f <tfm>`。
- **NuGet audit 在 `packages.config` 專案上是 `UNAVAILABLE`**：MSBuild 的訊息嚴重度屬性不支援該專案格式。先遷 `PackageReference`，否則標 `UNAVAILABLE` 附 probe。
- **Stryker 在 .NET Framework 上需要 nuget.exe 與 VS 的 NuGet build tasks**（實務上 Windows-only）。若 build target 是 net8.0、4.x 只是源碼層約束，直接對 net8.0 那個 target 跑即可。`<LangVersion>6</LangVersion>` 對應 `stryker-config.json` 的 `"language-version": "Csharp6"`（未實跑驗證）。

無一級測試隨機序工具（要自寫 `ITestCaseOrderer`）；單執行緒、無共享狀態的專案標 `SKIPPED` 附理由即可。
