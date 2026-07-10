# Release Notes · LazyVPS CN3 SpeedTest v2.0.0

发布日期：2026-07-10

## 核心升级

- 重做 ANSI / ASCII 终端封面：渐变 `LAZYVPS` 字幕、“万马奔腾”线稿与首次启动动画。
- 重做互动菜单：数字直选、方向键、W/S、Enter 与 Q；默认仍为标准综合模式。
- 保留快速、标准、深度与仅路由四种既有测试路径，不改变三网采样口径。
- 新增纯 SVG 可视化报告 `report.svg`，自动呈现三网排名、评分、Ping、丢包、TCP、Down / Up 与回程骨干。
- 终端结果页新增 SVG 输出路径，Markdown 与 CSV 原始数据继续保留。
- README 全面重排，新增 SVG 示例、模式矩阵、输出结构与执行环境标注。
- 修正所有一键命令的仓库地址：由错误的 `souldance7-ai/VPS-` 改为 `souldance7-ai/vps-speedtest`。
- `cn3_vps_net_test_plus.sh` 改为历史兼容入口，统一转到正式主脚本，减少双版本漂移。

## 兼容性

- Bash 4+
- Python 3（仅使用标准库）
- Debian / Ubuntu、RHEL 系、Alpine 可运行；依赖安装覆盖范围以脚本菜单 `[5]` 为准。
- 无色输出可使用 `NO_COLOR=1` 或 `--no-color`。
- 非互动环境自动关闭首次封面动画。

## 输出变化

v2.0 新增：

```text
cn3_test_YYYYmmdd_HHMMSS/report.svg
```

其余 CSV、Markdown、MTR、Traceroute 文件名保持兼容。

## 数据边界

评分仍为 VPS 中国方向参考模型，并非家宽满速模型。请结合普通时段、晚高峰、原始路由与实际业务体感综合判断。
