# Release Notes · LazyVPS CN3 SpeedTest v2.1.0

发布日期：2026-07-10

## 全量容量压测

v2.1 将旧版 `tpe101_capacity_latency_loss_tester_pack_20260614` 的核心容量指标正式整合进 LazyVPS：

- 单线下行 Mbps
- 多线下行 Mbps
- 最大下行 Mbps
- 单线上行 Mbps
- 多线上行 Mbps
- 最大上行 Mbps
- HTTP 平均延迟 / P50 / P95
- HTTP 抖动
- HTTP 层丢包率
- ICMP 平均延迟 / 抖动 / 丢包率

## 测试方法

- 单线：1 个 HTTP 工作线程，在指定秒数内持续传输并计算平均 Mbps。
- 多线：N 个并发 HTTP 工作线程，计算整个阶段的聚合平均 Mbps。
- 最大能力：每 250 ms 读取 Linux 默认网卡 RX / TX 字节计数，以约 1 秒滚动窗口计算稳定峰值。
- HTTP 抖动：成功 HTTP 延迟样本的总体标准差。
- HTTP 层丢包率：失败请求数除以总请求数。
- 所有线程数、单线秒数、多线秒数、HTTP 样本数和测试端点均可通过参数调整。

## 新增输出

```text
capacity_summary.csv
capacity_timeseries.csv
capacity_raw.json
```

`report.svg` 已升级为容量曲线 + 六项上下行 KPI + HTTP / ICMP 品质 + 中国三网回程的综合看板。

## 新增模式与参数

```bash
--capacity-only
--no-capacity
--capacity-threads N
--capacity-single-seconds N
--capacity-multi-seconds N
--http-samples N
--capacity-endpoint URL
--capacity-ping-host HOST
```

## 数据边界

容量测试会产生实际上下行流量。测试结果受端点、时段、线路策略、TCP 拥塞控制和 VPS 性能影响；建议普通时段与晚高峰使用相同参数各测试一次。
