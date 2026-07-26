# 中国三网入口去程／TCP应答与专线映射核对

版本：v1.1.0  
脚本：[`ix-route.sh`](ix-route.sh)

## 1. 适用架构

```text
中国电信／联通／移动探针
          ↓ 同一入口、同一业务端口
中国侧公网入口
          ↓ NAT／IPLC／IEPL／中转隐藏内段
出口 VPS 上的业务服务
          ↓
公网出口
```

脚本应在出口 VPS 上执行。适用于 Mieru、Trojan、AnyTLS 或其他以中国侧公网入口映射到出口 VPS 的 TCP 服务。Mieru／Mita 检查是可选附加项；未安装 Mieru 不影响入口去程与 TCP 应答确认。

## 2. 测试口径

### 去程

从北京、上海、广东、安徽、江苏、浙江的中国电信、联通、移动探针，对用户填写的中国侧入口业务端口执行 TCP traceroute。

### 原探针 TCP 应答确认

每组应答确认复用该去程的：

- 同一个 Globalping 中国探针
- 同一个中国侧入口
- 同一个业务端口

脚本使用该探针收到的 TCP 终点应答，或锁定原 measurement ID 追加三次 TCP 业务端口测量，确认原探针已收到入口端应答。

这只证明原探针能收到入口端口应答。它不是一条独立测得的反向 traceroute，也不能显示反向逐跳路由。因此报告明确标为“TCP应答确认（非反向路由）”，不计算回程分数。

### 同路径私网回程

若填写入口端专线内网对端，或出口 VPS 的业务端口存在可识别的私网 `ESTABLISHED` 对端，脚本会执行：

- `ip route get` 私网对端
- 20次 ICMP
- 可用时执行 MTR 或 traceroute

这部分用于验证出口 VPS 返回入口私网对端是否仍走专线／私网路由。

### 明确排除

正式版不会运行“出口 VPS → 其他中国公共 IP”的默认公网 traceroute 来充当专线回程。那种测试只能说明出口 VPS 的普通互联网回程，不能代表当前入口映射连接的反向路径。

## 3. 一键执行

在出口 VPS 的 Linux 终端执行：

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/souldance7-ai/vps-speedtest/refs/heads/agent/fix-ix-forward-probes/ix-route.sh") --full
```

## 4. 下载 `.sh` 后执行

```bash
curl -fsSL "https://raw.githubusercontent.com/souldance7-ai/vps-speedtest/refs/heads/agent/fix-ix-forward-probes/ix-route.sh" \
  -o /root/ix-route.sh

chmod +x /root/ix-route.sh
bash /root/ix-route.sh --full
```

需要保留本地脚本、稍后重复测试时，推荐使用这一方式。

## 5. 交互输入顺序

脚本会依次询问：

1. 中国侧公网入口 IPv4。
2. 实际协议业务端口，不要填写 SSH 或管理端口。
3. 预期公网出口；未知可直接回车。
4. 出口端专线内网 IPv4；没有或未知可直接回车。
5. 入口端专线内网对端；未知可直接回车，脚本会尝试从业务端口的活动私网连接识别。

默认测试北上广三地区×三网。公开评测建议加 `--full`，覆盖六地区×三网：

```text
18组TCP去程 + 18组原探针TCP应答确认（非反向路由）
```

## 6. 非交互执行

```bash
bash /root/ix-route.sh \
  --entry 你的中国侧入口IPv4 \
  --port 你的业务端口 \
  --expected-exit 你的预期出口IPv4 \
  --local-private 你的出口端内网IPv4 \
  --peer 你的入口端内网对端IPv4 \
  --client-verified-exit 中国客户端连接后实测出口IPv4 \
  --full
```

未知的可选值可以整项删除。`--client-verified-exit` 主要用于 Mieru 真实握手核对。

## 7. 本地模式与公共报告

默认生成本地 HTML、JSON、Markdown，并尝试上传脱敏公共报告：

```text
/root/Chain 3Net/ix-route-report-日期时间/
├── report.html
├── report.json
└── report.md
```

终端底部会显示公共页链接。只想保存在 VPS，不上传公共页：

```bash
bash /root/ix-route.sh --full --no-publish
```

## 8. 状态说明

| 状态 | 含义 |
|---|---|
| `PASS` | 原省指定运营商探针到达入口，或原探针已收到入口 TCP 应答 |
| `PASS_FALLBACK` | 原省无可用探针，跨省同运营商探针到达；计入运营商可达，不计入原省精准覆盖 |
| `REFERENCE` | 同省第三方机房到达，只作省级可达参考，不冒充三网 |
| `INCONCLUSIVE` | 有测量但运营商、省份、终点或返回证据不足 |
| `NO_PROBE` | 当前在线清单没有合法候选，不代表线路中断 |
| `N/A` | 缺少探针、权限、依赖、私网对端或其他必要证据 |

## 9. 隐私规则

下列用户相关 IPv4 与业务端口会在本地和公共报告写入前统一脱敏：

- 中国侧入口
- 自动识别或用户填写的出口公网
- 出口端内网
- 入口端私网对端
- 客户端连接后实测出口
- 上述地址同前两段的路由文字

输出只保留：

```text
IPv4：前两段.*.*
业务端口：保留末三位以前的数字，末三位显示为***
```

例如五位业务端口 `23456` 会显示为 `23***`；三位或更短端口全部显示为 `***`。

脚本内不预置任何用户入口、出口、私网地址或业务端口。

## 10. 判定边界

- TCP traceroute 的终点应答只证明原探针收到回应，不等于取得反向逐跳拓扑。
- 中间路由器不回应不等于业务丢包。
- 没有入口私网对端或活动私网连接时，同路径内段回程必须显示 `N/A`，不能用普通公网回程代替。
- `PASS_FALLBACK` 证明该运营商可达，不代表原省网络质量。
- 入口可达与出口监听能形成映射链证据，但只有实际客户端连接后出口一致，才能进一步确认真实协议握手。

## 11. 离线自检

```bash
bash /root/ix-route.sh --self-test --full --no-publish
```

自检会验证：

- 六地区×三网18组去程结构
- 对应18组原探针TCP应答确认结构
- 省份与运营商选点规则
- `PASS_FALLBACK` 与原省精准覆盖分离
- 公共报告三网映射
- JSON、HTML、Markdown生成
- 用户相关 IPv4 与业务端口脱敏
