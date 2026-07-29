---
paths:
  - "**/*Form.cs"
  - "**/*Form.Designer.cs"
  - "**/*UserControl.cs"
  - "**/*UserControl.Designer.cs"
---

# WinForms 規則

- **MUST** UI 與商業邏輯分離（MVP / MVVM）
- **MUST** 全域錯誤攔截 `Application.ThreadException` + `AppDomain.CurrentDomain.UnhandledException`
- WinForms / Console local secrets：DPAPI / `ProtectedData`
