# LazyVPS CN3 SpeedTest v2.0 · 快速开始

## 1. 直接打开互动菜单

**VPS/Linux 执行：**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/souldance7-ai/vps-speedtest/main/cn3_vps_server_test.sh)
```

菜单支持数字直选、`↑/↓`、`W/S`、`Enter` 与 `Q`。

## 2. Windows CMD 远程执行标准测试

**Windows CMD 执行：**

```cmd
ssh root@你的VPS_IP "bash -lc 'curl -fsSL -o /root/cn3_vps_server_test.sh https://raw.githubusercontent.com/souldance7-ai/vps-speedtest/main/cn3_vps_server_test.sh && chmod +x /root/cn3_vps_server_test.sh && /root/cn3_vps_server_test.sh --install --standard'"
```

## 3. 三档模式

**VPS/Linux 执行：**

```bash
# 快速：约 2–4 分钟
bash cn3_vps_server_test.sh --quick

# 标准：约 6–10 分钟，推荐
bash cn3_vps_server_test.sh --standard

# 深度：约 12–20 分钟，适合晚高峰留档
bash cn3_vps_server_test.sh --deep
```

## 4. 测试结果在哪里

脚本默认创建 `cn3_test_YYYYmmdd_HHMMSS/`，核心文件：

- `report.svg`：可直接在浏览器或 GitHub 显示的三网可视化报告。
- `report.md`：完整文本报告。
- `cn3_overview.csv`：三网排名与综合评分。
- `latency_summary.csv`：Ping、丢包与 TCP 明细。
- `speedtest_summary.csv`：Down／Up Mb/s 明细。
- `route_backbone_summary.csv`：回程骨干识别。
- `mtr/`、`traceroute/`：原始路由证据。

## 5. 常见情况

- 没有 Down／Up：先执行 `bash cn3_vps_server_test.sh --install --standard`。
- 不想显示 ANSI 颜色：加入 `--no-color`。
- 不想显示首次封面动画：加入 `--no-animation`。
- 只看回程与稳定性：使用 `--route-only`。
- Windows CMD 不要直接执行 `bash <(curl ...)`；该语法仅适用于 Linux Bash。

完整说明请看 [README.md](README.md)。
