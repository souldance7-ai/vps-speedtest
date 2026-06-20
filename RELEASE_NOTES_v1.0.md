# Release Notes · VPS 测速正式 v1.0

## 版本定位

`VPS 测速正式 v1.0` 是 LazyVPS CN3 综合测速工具包的第一个正式封版版本。

本版本聚焦：

- VPS 回程测试
- 中国本地去程测试
- 代理体感测试
- 三网骨干识别
- CMD BBS 信息板可视化
- Markdown / CSV / MTR / Traceroute 留档

## 界面与文档

- README 已加入脱敏界面图：
  - `docs/interactive-menu-sanitized.png`
  - `docs/result-dashboard-sanitized.png`
  - `docs/workflow-closed-loop.png`
- 截图使用文档保留 IP、示例 ASN 与示例供应商，不包含真实 VPS 信息。

## 核心功能

### VPS 端

- 中国电信 / 联通 / 移动三网 Ping
- 丢包率
- TCP Connect
- MTR / Traceroute
- Speedtest Down / Up
- CN2 / 163 / 169 / 9929 / CMNET / CMI 骨干识别
- BBS 信息板结果页

### 本地端

- Windows PowerShell 本地探测
- Linux/macOS 本地探测
- Ping VPS
- TCP 端口
- Tracert / Traceroute
- 代理体感测试

### 报告

- VPS 端 Markdown 报告
- 本地端 Markdown 报告
- 合并闭环报告

## 注意

- Windows CMD 用户请使用 README 中的 `ssh root@VPS "bash -lc '...'"` 方式远程触发 VPS 执行。
- 不要在 Windows CMD 直接运行 `bash <(curl ...)`。
- 评分仅供 VPS 中国方向参考，建议普通时段与晚高峰各测一轮。
