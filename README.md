# LazyVPS VPS 测速正式 v1.0


## 独立工具：沪日专线／IX-style 三层检测

`ix-route.sh` 是与 `3net-route.sh` 完全独立的专线检测器，适用于“上海公网入口 → NAT／IPLC／IEPL 隐藏内段 → 日本出口”架构。名称中的 IX-style 不代表已经证明经过某个 IXP。

### 在日本出口 VPS 一键执行

```bash
    bash <(curl -fsSL "https://raw.githubusercontent.com/souldance7-ai/vps-speedtest/main/ix-route.sh?ver=IX0.5-RC2")
```

交互输入示例：

- 上海公网入口：`211.136.162.184`
- 协议业务端口：`10101`（AnyTLS）或 `10102`（Trojan），不是 SSH `22`／管理端口 `10100`
- 预期日本公网出口：`114.111.176.37`
- 日本端专线内网：`172.16.2.101`
- 上海端专线内网对端：已知时填写；未知直接回车，纯内段结果显示 N/A

默认测试北京、上海、广东 × 中国电信／联通／移动；加 `--full` 扩展安徽、江苏、浙江。v0.5 RC2 改为“省会＋运营商名称／省级接入 ASN”定向找探针；省会无探针时只允许退到同省城市，并标明实际城市与退选原因，禁止跨省替代。回程同时尝试 TCP/443、ICMP、UDP，先按骨干证据等级选择，等级相同才比较回覆跳数。回程分数来自 CN2／AS9929／CMIN2 等实际骨干证据，不再把“traceroute 有跳点”直接计为 100 分。

---

## RC4.2.7 动态回程测点池版

适用于在 VPS 内检测中国电信、联通、移动的去程与回程质量，覆盖北京、上海、广东、安徽、江苏、浙江六省三网，并生成 CMD、HTML、JSON、公共报告及 NodeSeek 格式。

RC4.2.7 将两个方向严格分开：去程仍使用 Globalping 的中国外部探针，有真实探针才纳入判断；无在线探针时显示 `INCONCLUSIVE`，不以回程反推去程。回程改为运行时取得“省份＋运营商＋固定 IP＋真实 TCP 端口＋备用 IP/端口”的动态节点资料，主节点健康检查失败才切换同省同运营商备用节点；动态池缺项或整体不可用时才使用内置静态目标。

回程质量用实际节点端口的 TCP connect 计算，并以 TCP traceroute、ICMP、UDP 三种路由交叉取证；CN2 GIA、AS9929、CMIN2 等等级仍只依实际跳点判断。CMD、HTML、JSON 与 NodeSeek 同步显示节点来源、实际端口、主备切换、骨干标签和中文路由注释。动态节点池设计参考公开项目 [ibsgss/TcpQuality](https://github.com/ibsgss/TcpQuality) 的 `getNodes` 数据格式；可用环境变量 `THREE_NET_RETURN_POOL` 指定兼容 TSV 节点源。

[AntPing](https://antping.com/) 继续仅用于人工交叉复核，不调用其未公开网页接口。

### VPS / Linux 一键执行（推荐）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/souldance7-ai/vps-speedtest/main/3net-route.sh)
```

运行后按提示输入：

- 目标 IP，例如 `203.55.99.88`
- 协议业务端口，例如 `443`（不是 SSH 端口 `22`）

### 下载到 VPS 后执行

```bash
curl -fsSL https://raw.githubusercontent.com/souldance7-ai/vps-speedtest/main/3net-route.sh -o /root/3net-route.sh && chmod +x /root/3net-route.sh && bash /root/3net-route.sh
```

### Windows CMD 远程触发

```cmd
ssh root@你的VPS_IP "bash -lc 'curl -fsSL https://raw.githubusercontent.com/souldance7-ai/vps-speedtest/main/3net-route.sh -o /root/3net-route.sh && chmod +x /root/3net-route.sh && bash /root/3net-route.sh'"
```

> 当前版本：RC4.2.7 动态回程测点池版。公开使用前请自行确认目标 IP、业务端口及当地法律与服务商条款。

---

<p align="center">
  <b>中国三网 VPS 综合闭环测速工具包</b><br>
  <sub>VPS 回程 · 中国本地去程 · 代理体感 · BBS 信息板 · Markdown / CSV / MTR / Traceroute 留档</sub>
</p>

<p align="center">
  <img alt="version" src="https://img.shields.io/badge/Release-VPS%E6%B5%8B%E9%80%9F%E6%AD%A3%E5%BC%8F%20v1.0-0ea5e9?style=flat-square">
  <img alt="bash" src="https://img.shields.io/badge/Shell-Bash-1f6feb?style=flat-square">
  <img alt="powershell" src="https://img.shields.io/badge/Windows-CMD%20%2B%20PowerShell-2563eb?style=flat-square">
  <img alt="output" src="https://img.shields.io/badge/Output-CMD%20%2B%20Markdown%20%2B%20CSV-22c55e?style=flat-square">
  <img alt="license" src="https://img.shields.io/badge/License-MIT-f59e0b?style=flat-square">
</p>

---

## 项目简介

`LazyVPS VPS 测速正式 v1.0` 是一个面向 **海外 VPS / 中转机 / 代理节点** 的中国三网综合测速工具包。

它不是单纯跑网速，也不是家宽满速模型，而是围绕 VPS 在中国联外网环境下的真实可用性做闭环观察：

```text
中国本地端  →  海外 VPS  →  中国三网目标
     去程          VPS端           回程
```

> **评分口径：** VPS 中国方向参考模型，评级仅供参考。建议普通时段 + 晚高峰各测一轮。

---

## 界面预览（已脱敏）

> 下方图片为 README 展示用脱敏示例，使用文档保留 IP、示例 ASN 与示例供应商，不暴露真实 VPS 信息。

### 1）交互菜单界面

![交互菜单界面](docs/interactive-menu-sanitized.png)

### 2）测速结果仪表盘

![测速结果仪表盘](docs/result-dashboard-sanitized.png)

### 3）完整闭环流程

![完整闭环流程](docs/workflow-closed-loop.png)

---

## 一句话快速使用

### Windows CMD：远程触发 VPS 标准测速

> 适合在 Windows CMD 里操作，让 VPS 自己下载并执行测试脚本。

**Windows CMD 执行：**

```cmd
ssh root@你的VPS_IP "bash -lc 'curl -fsSL -o /root/cn3_vps_server_test.sh https://raw.githubusercontent.com/souldance7-ai/VPS-/main/cn3_vps_server_test.sh && chmod +x /root/cn3_vps_server_test.sh && bash /root/cn3_vps_server_test.sh --standard'"
```

示例：

```cmd
ssh root@103.97.200.42 "bash -lc 'curl -fsSL -o /root/cn3_vps_server_test.sh https://raw.githubusercontent.com/souldance7-ai/VPS-/main/cn3_vps_server_test.sh && chmod +x /root/cn3_vps_server_test.sh && bash /root/cn3_vps_server_test.sh --standard'"
```

> Windows CMD 不要直接执行 `bash <(curl ...)`，那是 Linux Bash 语法。

---

## 快捷命令

### 1. Windows CMD：VPS 标准测速

```cmd
ssh root@你的VPS_IP "bash -lc 'curl -fsSL -o /root/cn3_vps_server_test.sh https://raw.githubusercontent.com/souldance7-ai/VPS-/main/cn3_vps_server_test.sh && chmod +x /root/cn3_vps_server_test.sh && bash /root/cn3_vps_server_test.sh --standard'"
```

### 2. Windows CMD：VPS 安装依赖并测速

```cmd
ssh root@你的VPS_IP "bash -lc 'curl -fsSL -o /root/cn3_vps_server_test.sh https://raw.githubusercontent.com/souldance7-ai/VPS-/main/cn3_vps_server_test.sh && chmod +x /root/cn3_vps_server_test.sh && bash /root/cn3_vps_server_test.sh --install --standard'"
```

### 3. Windows CMD：VPS 深度测速

```cmd
ssh root@你的VPS_IP "bash -lc 'curl -fsSL -o /root/cn3_vps_server_test.sh https://raw.githubusercontent.com/souldance7-ai/VPS-/main/cn3_vps_server_test.sh && chmod +x /root/cn3_vps_server_test.sh && bash /root/cn3_vps_server_test.sh --deep'"
```

### 4. Windows 本地端：去程 + TCP + 代理体感

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr -UseBasicParsing https://raw.githubusercontent.com/souldance7-ai/VPS-/main/cn3_client_probe.ps1 -OutFile .\cn3_client_probe.ps1; .\cn3_client_probe.ps1 -VpsHost 你的VPS_IP -Ports 22,443 -Proxy http://127.0.0.1:7890"
```

### 5. Windows 本地端：只测去程 / TCP 端口

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr -UseBasicParsing https://raw.githubusercontent.com/souldance7-ai/VPS-/main/cn3_client_probe.ps1 -OutFile .\cn3_client_probe.ps1; .\cn3_client_probe.ps1 -VpsHost 你的VPS_IP -Ports 22,443"
```

### 6. VPS/Linux：进入菜单模式

```bash
curl -fsSL -o cn3_vps_server_test.sh https://raw.githubusercontent.com/souldance7-ai/VPS-/main/cn3_vps_server_test.sh
chmod +x cn3_vps_server_test.sh
bash cn3_vps_server_test.sh
```

---

## 菜单模式

在 VPS 上直接执行：

```bash
bash cn3_vps_server_test.sh
```

进入交互菜单：

```text
0  退出脚本
1  快速体验
2  标准综合
3  深度三网
4  仅路由延迟
5  安装依赖
6  帮助说明
```

支持：

```text
- 直接按数字 1 / 2 / 3 / 4 / 5 / 6 / 0
- 使用 ↑ ↓ 方向键选择，Enter 确认
```

---

## 功能总览

| 模块 | 执行位置 | 主要测试 |
|---|---|---|
| VPS 端测速 | 海外 VPS | VPS → 中国三网，回程、骨干、延迟、丢包、TCP、Speedtest |
| 本地端探测 | Windows / Linux / macOS | 中国本地 → VPS，去程、端口、Traceroute、代理体感 |
| 合并报告 | Windows / VPS / Linux | 汇总回程、去程、代理体感，生成闭环 Markdown 报告 |

---

## VPS 端测试内容

脚本：`cn3_vps_server_test.sh`

- VPS 基础信息
- 出口 IP / ASN / 归属地
- 中国电信 / 联通 / 移动 Ping
- 丢包率
- TCP Connect 成功率
- MTR / Traceroute 原始路由
- 回程骨干识别：
  - 电信：`CN2 / 163 / CTG`
  - 联通：`169 / AS4837 / 9929 / CUII`
  - 移动：`CMNET / CMI`
- Speedtest 中国方向 Down / Up
- CMD BBS 信息板结果页
- Markdown / CSV 输出

---

## 本地端测试内容

脚本：

```text
cn3_client_probe.ps1    Windows 本地端
cn3_client_probe.sh     Linux / macOS 本地端
```

测试：

- 本地 Ping VPS
- 本地 Tracert / Traceroute VPS
- TCP 端口连通
- 可选代理体感：
  - Cloudflare
  - Google 204
  - GitHub
  - OpenAI

---

## 合并报告

脚本：`merge_lazyvps_report.py`

```bash
python merge_lazyvps_report.py --server-dir cn3_test_xxx --client-dir cn3_client_test_xxx --out combined_report.md
```

输出一个完整的闭环 Markdown 报告。

---

## 输出目录

### VPS 端输出

```text
cn3_test_YYYYmmdd_HHMMSS/
├── report.md
├── cn3_overview.csv
├── route_backbone_summary.csv
├── latency_summary.csv
├── speedtest_summary.csv
├── mtr/
└── traceroute/
```

### 本地端输出

```text
cn3_client_test_YYYYmmdd_HHMMSS/
├── client_report.md
├── client_summary.csv
├── tcp_ports.csv
├── proxy_experience.csv
└── tracert_to_vps.txt
```

---

## 推荐测试流程

### 第一步：VPS 测回程

```cmd
ssh root@你的VPS_IP "bash -lc 'curl -fsSL -o /root/cn3_vps_server_test.sh https://raw.githubusercontent.com/souldance7-ai/VPS-/main/cn3_vps_server_test.sh && chmod +x /root/cn3_vps_server_test.sh && bash /root/cn3_vps_server_test.sh --standard'"
```

### 第二步：本地测去程

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr -UseBasicParsing https://raw.githubusercontent.com/souldance7-ai/VPS-/main/cn3_client_probe.ps1 -OutFile .\cn3_client_probe.ps1; .\cn3_client_probe.ps1 -VpsHost 你的VPS_IP -Ports 22,443 -Proxy http://127.0.0.1:7890"
```

### 第三步：合并报告

```cmd
python merge_lazyvps_report.py --server-dir cn3_test_xxx --client-dir cn3_client_test_xxx --out combined_report.md
```

---

## 文件结构

```text
LazyVPS-VPS-SpeedTest-v1.0/
├── cn3_vps_server_test.sh
├── cn3_client_probe.ps1
├── cn3_client_probe.sh
├── merge_lazyvps_report.py
├── README.md
├── QUICK_START.md
├── RELEASE_NOTES_v1.0.md
├── LICENSE
└── docs/
    ├── interactive-menu-sanitized.png
    ├── result-dashboard-sanitized.png
    └── workflow-closed-loop.png
```

---

## 注意事项

- Windows CMD 不能直接执行 `bash <(curl ...)`。
- `bash <(curl ...)` 只适合 Linux Bash。
- Windows CMD 请使用 `ssh root@VPS "bash -lc '...'"` 远程触发 VPS 执行。
- Speedtest Down / Up 为 VPS 与测速节点之间的参考，不等于所有本地网络体感。
- 评分为 VPS 中国方向参考模型，不是家宽满速模型。
- 最终判断建议普通时段与晚高峰各测一轮。
- README 截图均为脱敏示例，不包含真实 VPS IP / ASN / 供应商。

---

## License

MIT
