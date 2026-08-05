# Changelog

## 2.0.0

- Mihomo Controller API 改用明確 UTF-8 StreamReader，修復國旗、中文節點名稱在 Windows PowerShell 5.1 變成亂碼。
- CMD 輸入、輸出與 PowerShell 管線統一為 UTF-8。
- SVG 升級為 1920 寬科技儀表板，重新分配欄寬、截斷過長節點名稱並加入評分條，避免內容重疊。
- HTML 升級為科技封面、玻璃面板、SVG 看板、節點搜尋與響應式資料表。
- 新增真正的 `report.xlsx` 多工作表 Excel 報告，包含 Dashboard、Ranking、Services、Speed、Stability、Topology、TLS 與 SwitchLog。
- 新增無 IP、無品牌、無敏感資料的 AI 科技封面。

## 1.0.3

- 修復解壓縮路徑含空格或括號（例如 `Downloads\Package (1)\`）時，CMD 括號區塊被路徑展開破壞的問題。
- 兩個 CMD 改為純 ASCII、標籤跳轉結構，不再於括號區塊中展開使用者路徑。
- YAML/YML 自動偵測移至 PowerShell，避開 CMD 字元解析與編碼問題。
- Windows CI 會在含空格與 `(1)` 的實際路徑執行兩個 CMD 自檢。

## 1.0.2

- 修復 Windows PowerShell 5.1 在參數初始化階段無法取得 `$PSScriptRoot`，導致 Mihomo 安裝路徑為空的問題。
- CMD 未帶參數時會自動使用同資料夾內唯一的 YAML/YML 配置。
- 多配置時停止並提示拖放指定配置，避免選錯節點包。
- 加強安裝與測試 CMD 的錯誤代碼、繁體中文提示與防閃退暫停畫面。

## 1.0.1

- 公開範例改用 RFC 5737 文件專用 IP / ASN，不再包含任何使用者真實出口 IP。
- 新增 `-RedactReportIp` 與 `settings.json` 的 `redact_report_ip` 分享脫敏模式。

## 1.0.0

- 新增 YAML 拖放與既有 FLClash/Mihomo 兩種模式。
- 新增 ANSI/ASCII CMD 封面、鍵盤選單、節點進度條與最終排行榜。
- 新增全節點 API 延遲、HTTP 穩定性、單線/多線/峰值上下行容量測試。
- 新增 26 個 AI、串流與開發者平台矩陣。
- 新增公開出口 IP、地區、ASN、ISP、預期出口比對與 Fake-IP 防誤判。
- 新增 TLS/HTTPS、群組成員、切換日誌、SVG、HTML、CSV 與 JSON 報告。
- 新增 Windows PowerShell 5.1 GitHub Actions 語法與離線渲染測試。
