<div align="center">

# LazyVPS CN3 SpeedTest v2.0

### 霓虹万马 · 中国三网 VPS 综合测速与 SVG 可视化报告

<p>
  <img alt="release" src="https://img.shields.io/badge/release-v2.0.0-22d3ee?style=for-the-badge">
  <img alt="shell" src="https://img.shields.io/badge/shell-Bash-60a5fa?style=for-the-badge&logo=gnubash&logoColor=white">
  <img alt="report" src="https://img.shields.io/badge/report-SVG%20%2B%20Markdown%20%2B%20CSV-a78bfa?style=for-the-badge">
  <img alt="license" src="https://img.shields.io/badge/license-MIT-34d399?style=for-the-badge">
</p>

**一套脚本看清 VPS → 中国电信／联通／移动的延迟、丢包、TCP、上下行能力与回程骨干。**

[快速开始](#一分钟开始) · [模式差异](#三档测试怎么选) · [SVG 报告](#svg-可视化报告) · [完整输出](#输出文件)

</div>

---

## 这次升级了什么

v2.0 保留原有「快速／标准／深度」三档测试核心，重点重做了交互与报告层：

- ANSI 渐变 `LAZYVPS` 字幕＋“万马奔腾”ASCII 封面，首次进入轻量动画。
- 支持数字直选、`↑/↓`、`W/S`、`Enter`、`Q` 的 BBS 风格互动菜单。
- 终端结果页统一显示三网评分、Ping、丢包、TCP、Down／Up 与回程骨干。
- 每次完成测试自动生成 `report.svg`，可直接用浏览器打开或放进 GitHub README。
- 保留 Markdown、CSV、MTR、Traceroute 原始数据，图好看，底层数据也可复核。
- 修正旧 README 下载地址误指向 `souldance7-ai/VPS-` 的问题；正式地址统一为本仓库。

## SVG 可视化报告

下面这张图由测速脚本依据 CSV 自动生成，不是截图；每次测试会输出同结构的 `report.svg`。

![LazyVPS CN3 SVG 测试报告示例](docs/sample-report.svg)

## 一分钟开始

### 方法一：VPS 直接进入互动菜单

**VPS/Linux 执行：**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/souldance7-ai/vps-speedtest/main/cn3_vps_server_test.sh)
```

> 首次运行若缺少 MTR 或 Ookla Speedtest，请在菜单选择 `[5] 安装依赖`。

### 方法二：Windows CMD 远程触发标准测试

**Windows CMD 执行：**

```cmd
ssh root@你的VPS_IP "bash -lc 'curl -fsSL -o /root/cn3_vps_server_test.sh https://raw.githubusercontent.com/souldance7-ai/vps-speedtest/main/cn3_vps_server_test.sh && chmod +x /root/cn3_vps_server_test.sh && /root/cn3_vps_server_test.sh --install --standard'"
```

### 方法三：下载后长期使用

**VPS/Linux 执行：**

```bash
curl -fsSL -o /root/cn3_vps_server_test.sh https://raw.githubusercontent.com/souldance7-ai/vps-speedtest/main/cn3_vps_server_test.sh
chmod +x /root/cn3_vps_server_test.sh
/root/cn3_vps_server_test.sh
```

## 互动界面

```text
██╗      █████╗ ███████╗██╗   ██╗██╗   ██╗██████╗ ███████╗
██║     ██╔══██╗╚══███╔╝╚██╗ ██╔╝██║   ██║██╔══██╗██╔════╝
██║     ███████║  ███╔╝  ╚████╔╝ ██║   ██║██████╔╝███████╗
███████╗██║  ██║███████╗   ██║    ╚████╔╝ ██║     ███████║

┌──────────────────────────────────────────────────────────────────────┐
│ ▶ [2] 标准综合 │ 约 6–10 分钟 · 每网 2 个测速点 · 日常推荐        │
│ · [3] 深度三网 │ 约 12–20 分钟 · 每网 3 个测速点 · 高峰留档       │
└──────────────────────────────────────────────────────────────────────┘
READY  当前 [2]  ↑↓ / W/S · Enter · Q
```

按键说明：

| 按键 | 动作 |
|---|---|
| `1`～`6`、`0` | 直接执行对应选项 |
| `↑ / ↓` 或 `W / S` | 移动选择 |
| `Enter` | 确认当前选项 |
| `Q` | 安全退出 |

## 三档测试怎么选

| 模式 | 参考耗时 | Ping / TCP | 路由采样 | Speedtest | 适用场景 |
|---|---:|---:|---:|---:|---|
| 快速 `--quick` | 2–4 分钟 | 轻量 | 不跑 MTR | 每网 1 点 | 新 VPS 先看大方向 |
| 标准 `--standard` | 6–10 分钟 | 标准 | MTR 20 包 | 每网 2 点 | 日常判断，默认推荐 |
| 深度 `--deep` | 12–20 分钟 | 加强 | MTR 50 包 | 每网 3 点 | 晚高峰留档、横向对比 |
| 路由 `--route-only` | 4–8 分钟 | 标准 | MTR 30 包 | 不执行 | 只看回程、延迟与丢包 |

实际时间取决于 VPS 性能、三网测速点状态与网络超时情况。

## 测试内容

| 维度 | 输出内容 | 用途 |
|---|---|---|
| VPS 基础信息 | IPv4 / IPv6、ASN、地区、系统、BBR、拥塞控制 | 确认测试对象与出口身份 |
| 延迟与稳定性 | Ping 平均／最低／最高、抖动、丢包 | 判断交互体感与波动 |
| TCP 连通 | 53 / 443 等目标端口成功率与耗时 | 避免只看 ICMP 造成误判 |
| 三网速度 | Ookla Down / Up，统一使用 Mb/s | 观察当前样本的传输能力 |
| 回程骨干 | CN2 / 163 / CTG、AS4837 / 9929、CMI / CMNET | 快速识别三网回程特征 |
| 综合评分 | CT / CU / CM 排名、等级、使用建议 | 用于同口径横向筛选 |

## 常用命令

### 标准模式并自动安装依赖

**VPS/Linux 执行：**

```bash
bash cn3_vps_server_test.sh --install --standard
```

### 深度模式

**VPS/Linux 执行：**

```bash
bash cn3_vps_server_test.sh --deep
```

### 自定义采样与输出目录

**VPS/Linux 执行：**

```bash
bash cn3_vps_server_test.sh --standard --ping-count 15 --speed-count 3 --out cn3_tokyo_peak
```

### 关闭颜色或首次封面动画

**VPS/Linux 执行：**

```bash
bash cn3_vps_server_test.sh --standard --no-color --no-animation
```

## 输出文件

```text
cn3_test_YYYYmmdd_HHMMSS/
├── report.svg                  # GitHub / 浏览器可直接显示的主视觉报告
├── report.md                   # 完整 Markdown 报告
├── cn3_overview.csv            # 三网排名与综合评分
├── latency_summary.csv         # Ping / 丢包 / TCP 明细
├── speedtest_summary.csv       # Down / Up 与测速点明细
├── route_backbone_summary.csv  # 回程骨干摘要
├── base_info.md                # VPS、IP、ASN 与系统信息
├── ookla_cn_servers.csv        # 本轮使用的三网测速点
├── speedtest_json/             # Ookla 原始 JSON
├── mtr/                        # MTR 原始记录
└── traceroute/                 # Traceroute 原始记录
```

`report.svg` 使用纯 SVG 元素与系统字体，不需要 JavaScript，也不依赖额外绘图库。

## 本地端闭环探测

VPS 端脚本负责“VPS → 中国三网”。如果还要补齐“中国本地 → VPS”的去程、端口和代理体感，可使用仓库里的客户端脚本。

**Windows CMD 执行：**

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr -UseBasicParsing https://raw.githubusercontent.com/souldance7-ai/vps-speedtest/main/cn3_client_probe.ps1 -OutFile .\cn3_client_probe.ps1; .\cn3_client_probe.ps1 -VpsHost 你的VPS_IP -Ports 22,443 -Proxy http://127.0.0.1:7890"
```

**Linux/macOS 执行：**

```bash
bash cn3_client_probe.sh --host 你的VPS_IP --ports 22,443
```

再使用 `merge_lazyvps_report.py` 合并去程与回程：

```bash
python3 merge_lazyvps_report.py --server-dir cn3_test_xxx --client-dir cn3_client_test_xxx --out combined_report.md
```

## 评分与数据边界

- 评分是 **VPS 中国方向参考模型**，不是家宽跑满带宽考核。
- Speedtest 数值受测试节点、时段、路由与单连接状态影响，不代表线路绝对上限。
- DNS、官网目标可能禁 Ping 或受 CDN 调度影响；脚本同时参考 TCP，避免用单项结论替代整体判断。
- 回程识别基于 MTR / Traceroute 关键字自动归类，复杂路由请回看原始文件。
- 建议同一台 VPS 至少在普通时段与晚高峰各测一次，再比较稳定性。

## 项目结构

```text
vps-speedtest/
├── cn3_vps_server_test.sh      # 正式主入口 v2.0
├── cn3_vps_net_test_plus.sh    # 历史命令兼容入口
├── cn3_client_probe.ps1        # Windows 本地端探测
├── cn3_client_probe.sh         # Linux / macOS 本地端探测
├── merge_lazyvps_report.py     # 去程／回程报告合并
├── QUICK_START.md
├── RELEASE_NOTES_v2.0.md
├── tests/smoke.sh
└── docs/sample-report.svg
```

## License

[MIT](LICENSE) — 可自由使用、修改与分发；保留许可证与来源说明即可。

---

<div align="center">

**LazyVPS · 让测速结果不只是一串数字，而是一张能直接判断的工程看板。**

</div>
