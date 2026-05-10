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
- Controller-based Web API（Minimal API 限 prototype）
- Host：`WebApplication.CreateBuilder`（API）/ `Host.CreateApplicationBuilder`（Worker / Console）
- EF Core + PostgreSQL；FluentValidation；Serilog

## API Error Format
- `{ error: string, code: string, details?: any }`

## 維運既有 .NET Framework
- 沿用既有風格不主動現代化
- Logging 沿用 NLog / log4net
