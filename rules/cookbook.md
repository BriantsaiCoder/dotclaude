---
paths:
  - "**/docs/cookbook/**"
---

# Cookbook 行為錨

> 專案知識庫規則。專案採用 cookbook 時，在該專案 CLAUDE.md 加 `@~/.claude/rules/cookbook.md` 顯式引入。
> 配套 skill：修復後沉澱走 `bug-fix-settlement`；扇入檢查走 `deps-check`。

## 定位

Cookbook（`docs/cookbook/`，隨 git 版控）只收**機械工具看不出來的隱性知識**：程式碼、型別、測試、依賴關係都表達不了的東西。

能被機械工具抓到的知識**不寫進 cookbook**——那些會隨程式腐爛，而機械工具不會。Cookbook 寫太多會沒人讀、跟著腐爛。寧缺勿濫。

## 目錄結構（三層漸進式揭露）

```
docs/cookbook/
├── README.md                  # 第 1 層：cookbook 是什麼、怎麼用、何時讀
├── MOC.md                     # 第 2 層：Map of Content — 全部條目的索引地圖
├── <module>/                  # 第 3 層：實際知識
│   ├── business-rules.md      #   業務規則（程式看不出 why）
│   └── pitfalls.md            #   踩坑紀錄（隱性耦合、library 陷阱）
├── architecture/
│   └── *.md                   #   架構決策的 why（選 A 不選 B 的理由）
└── types/
    └── *.md                   #   隱性型別 / 資料契約知識
```

- **README.md**：簡介 + 使用指引，讓人知道何時該翻 cookbook。
- **MOC.md**：所有條目的單頁索引，每條一行帶連結 + 一句 hook。進專案先讀 MOC 就知道有哪些坑。
- **categories/**：實際內容。先讀 MOC 定位，再點進對應檔。

## 三問判準（沉澱前的路由器）

寫入前先問三題，**任何一題答「是」就不寫 cookbook**：

1. **tsc / 編譯器 / eslint 會抓到嗎？** — 例「改 signature 要同步呼叫端」。會抓 → 不寫，型別就是文件。
2. **grep import 或 deps-check 看得出關係嗎？** — 例「改 OrderService 要同步 CheckoutHandler」。看得出 → 不寫，靠依賴檢查。
3. **測試會失敗嗎？** — 例「CalculateTotal 應排除已取消的項目」。會失敗 → 不寫，測試就是契約。

**三問判準是「路由器」不是「否決權」**：答「是」代表這知識該由機械工具守護（補型別、加 lint rule、補測試），不是丟掉不管。要明確把知識路由到正確的守護機制。

## 值得寫進 cookbook 的，只有這幾類

**A. Bug 與技術陷阱**
- 跨時序 / 跨 runtime 的隱性耦合：事件順序、debounce、race condition、DI scoped/transient 生命週期陷阱
- 外部 library / framework 陷阱：某 API 吃特殊輸入會崩、在特定環境行為不同
- 隱性資料契約：UI 必須同步某 constant 清單，但沒有型別連結

**B. 業務邏輯**
- 程式碼看不出 why 的商業規則：感測器離線 30 分鐘顯示 `--`（業務端定的，非技術限制）
- 領域特有計算邏輯：良率計算要排除前 10 分鐘暖機數據
- 流程約束：某 API 必須在另一 API 之後呼叫、某狀態轉換有前置條件

**C. 架構決策**
- 歷史決策的 why：為什麼這裡用 A 不用 B（不寫會一直被重新質疑）
- 技術選型理由：為什麼用 date-fns 不用 dayjs
- 難以自動驗證的設計規則

## 範例對照

| 內容 | 寫 cookbook 嗎 | 為什麼 |
|---|---|---|
| `OrderService.CalculateTotal` 回傳 `decimal` | ❌ | 型別已經寫了 |
| 改 `OrderService` 要改 `CheckoutHandler` | ❌ | deps-check 抓得到 |
| 重試會覆寫共用狀態，需 debounce | ✅ | 時序耦合，編譯器抓不到 |
| 某 library 函式吃到 `$` 會崩 | ✅ | 外部 lib 陷阱 |
| `OFFICIAL_TYPES` 清單要同步 UI 選單 | ✅ | 隱性資料契約 |
| 感測器離線 30 分鐘後顯示 `--` | ✅ | 業務規則，程式看不出為何是 30 分鐘 |
| 良率計算排除暖機數據 | ✅ | 領域知識，不知道就會算錯 |
| 這個 bug 改了 3 行就好 | ❌ | git log 有了 |
| Button 元件放在 `components/ui/` | ❌ | grep 就找得到，寫了會腐爛 |

## 寫入格式

每條知識用「問題 → 原因 → 正確 / 錯誤做法」結構，讓讀者一眼看懂踩了什麼坑、怎麼避免：

```markdown
### 標題（一句話講清楚這條知識）

**問題**：實際遇到的錯誤行為。

**原因**：根本原因——尤其是程式碼看不出來的那個 why。

✅ 正確做法：
（程式碼片段或步驟）

❌ 錯誤做法：
（程式碼片段或步驟）
```

寫完同步在 `MOC.md` 加一行索引。

## 維護

- 修改既有條目對應的程式碼時，同步更新 cookbook；cookbook rot 視同 bug。
- 發現 cookbook 已有相同記錄卻仍踩坑 → 反省為何沒被攔截（規則寫不清楚？沒人讀？MOC 沒索引到？），修規則本身。
