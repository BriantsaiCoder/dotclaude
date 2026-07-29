---
paths:
  - "**/*.cs"
  - "**/*.csproj"
  - "**/*.sln"
  - "**/*.razor"
  - "**/*.cshtml"
  - "**/appsettings*.json"
---

# .NET 規則

## 新專案 Backend API 預設
- 目標框架 .NET 10（LTS → 2028-11）；過期後先以 Context7 / microsoft-learn 確認當前 LTS
- Controller-based Web API（Minimal API 限 prototype）
- Host：`WebApplication.CreateBuilder`（API）/ `Host.CreateApplicationBuilder`（Worker / Console）
- EF Core + PostgreSQL；FluentValidation；Serilog

## 專案結構
- 每個 .NET 專案一律建立 solution（`.sln`）方案檔，即使只有單一專案；測試專案一併加入同一 `.sln`

## API Error Format
- `{ error: string, code: string, details?: any }`

## 維運既有 .NET Framework
- 沿用既有風格不主動現代化
- Logging 沿用 NLog / log4net
- 新建獨立工具 / 服務若需 Framework，預設 .NET Framework 4.8.1
