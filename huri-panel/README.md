# HuRi Link Console｜沪日合规隧道交付面板

面向新购沪日 NAT / VDS 套餐的 Debian 12、Debian 13 交付工具。使用纯 Bash 绘制 16 色 BBS 风格终端面板，支持 `← / → / ↑ / ↓ / Enter` 操作，不依赖 `dialog`。v1.1.0 起采用大号渐层 ANSI 标志、硬件/网络双栏状态区，并在窄终端自动降级为紧凑抬头。

> 本工具只自动部署 **Mieru** 与 **WireGuard**。不会创建供应商明确禁止的 SS、HTTP、HTTPS、TLS、VLESS、VMess、Trojan、TUIC、Hysteria 等入口协议。

## 面板功能

| 分页 | 功能 |
|---|---|
| 系统 | Debian 版本、NAT、公网/内网 IP、时间同步、端口、服务体检；可回滚 BBR + FQ 保守优化 |
| Mieru | 从官方 Release 安装/升级 `mita`，校验 SHA-256，建立 TCP/UDP 节点并备份原配置描述 |
| WireGuard | 建立多实例服务端、首个客户端、追加客户端、生成二维码与配置文件 |
| 集群 | 登记多台沪日 Mieru，生成 FLClash/Mihomo 自动、轮巡、一致性哈希配置 |
| 测速 | 连接同仓库 `ix-route.sh`、`3net-route.sh`、`3net-route-speed.sh` 固定 main 入口 |
| 维护 | 安装/更新 `huri` 命令、查看备份与导出、回滚优化、查看边界说明 |

界面使用 [Sixteen Colors](https://16colo.rs/) 所代表的经典 ANSI/BBS 文本模式作为配色与层次灵感，未复制站内作品。

```text
● HuRi Link Console │ SH→JP COMPLIANT TUNNEL │ D13 · v1.1.0
──────────────────────────────────────────────────────────────────────────────
    ██╗  ██╗    ██╗   ██╗    ██████╗     ██╗
    ██║  ██║    ██║   ██║    ██╔══██╗    ██║
    ██║  ██║    ██║   ██║    ██║  ██║    ██║
    ███████║    ██║   ██║    ██████╔╝    ██║
    ██╔══██║    ██║   ██║    ██╔══██╗    ██║
    ██║  ██║    ██║   ██║    ██║  ██║    ██║
    ██║  ██║    ╚██████╔╝    ██║  ██║    ██║
    ╚═╝  ╚═╝     ╚═════╝     ╚═╝  ╚═╝    ╚═╝
                 [ 沪日专线 · 日本 BGP 出口 · 合规隧道交付 ]
──────────────────────────────────────────────────────────────────────────────
  ▣ 即时动态硬件监控                 │  ◎ 专线网络与服务参数
  • 主机 / 系统 / CPU / 内存 / 磁盘   │  • 公网 / 本机 / NAT / BBR / 服务
──────────────────────────────────────────────────────────────────────────────
```

主面板在 78 栏及以上显示完整大字与双栏状态；小于 78 栏时自动使用紧凑抬头。进入体检、部署和维护动作后也会切换为紧凑抬头，保留更多终端空间给日志与输入项。

## 一键安装

在沪日 VDS 的 Debian 12 / 13 `root` 终端执行：

```bash
bash <(curl -fsSL --retry 3 "https://raw.githubusercontent.com/souldance7-ai/vps-speedtest/main/huri-panel/install.sh")
```

以后登录服务器后直接输入：

```bash
huri
```

临时进入、不安装命令：

```bash
bash <(curl -fsSL --retry 3 "https://raw.githubusercontent.com/souldance7-ai/vps-speedtest/main/huri-panel/huri-panel.sh")
```

## Windows CMD 一键远程进入

普通 SSH 端口：

```cmd
ssh -t root@你的服务器IP "bash -lc 'bash <(curl -fsSL --retry 3 https://raw.githubusercontent.com/souldance7-ai/vps-speedtest/main/huri-panel/install.sh)'"
```

沪日 NAT 套餐使用自定义 SSH 公网端口时：

```cmd
ssh -t -p 你的SSH公网端口 root@你的服务器IP "bash -lc 'bash <(curl -fsSL --retry 3 https://raw.githubusercontent.com/souldance7-ai/vps-speedtest/main/huri-panel/install.sh)'"
```

必须保留 `-t`，否则方向键面板没有 TTY。SSH 公网端口只用于登录，不要把它当成 Mieru 或 WireGuard 业务端口。

## 新购交机推荐顺序

1. 进入「系统」→「执行完整系统体检」。
2. 确认系统是 Debian 12/13、时间已同步，并记录公网 IP、本机 IP、NAT 状态。
3. 在商家后台确认可使用的公网 TCP/UDP 端口以及映射到 VDS 的本机端口。
4. 进入「Mieru」→「安装/升级官方 Mieru」，再选「新购交机：建立 Mieru」。
5. 主节点优先建立 TCP；确有移动弱网需求且商家开放 UDP 时，再追加 UDP。
6. 按需进入「系统」应用保守 BBR + FQ。该优化主要作用于 TCP Mieru，不会直接加速 UDP WireGuard。
7. 进入「集群」生成 FLClash 配置，导入后先测试单个节点，再测试自动与轮巡组。

## NAT 公网端口与本机端口

沪日套餐常见结构：

```text
客户端 → 公网IP:公网端口 → 商家NAT → VDS内网IP:本机监听端口
```

面板会分别询问：

- 公网端口：写入 FLClash、Mieru 分享链接或 WireGuard 客户端 `Endpoint`。
- 本机监听端口：写入 `mita` 或 `wg-quick` 服务端配置。

两者可以相同，也可以不同。面板只能配置 Linux 本机服务与 UFW，不能替代商家建立 NAT 映射。

## Mieru 安装与配置原则

- 只读取 `enfein/mieru` 官方最新 Release。
- 下载与 CPU 架构相符的 `mita_<version>_amd64.deb` 或 `arm64.deb`。
- 同时下载官方 `.sha256.txt` 并执行 `sha256sum -c`；校验不通过则停止安装。
- 使用官方 `mita apply config <FILE>` 合并语义，不静默清空旧端口或用户。
- 修改前把 `mita describe config` 保存到 `/var/backups/huri-panel/`。
- 默认输出 `MULTIPLEXING_LOW` 与 `HANDSHAKE_STANDARD`，适合先以稳定性封版。

官方依据：[Mieru 服务端安装与配置](https://github.com/enfein/mieru/blob/main/docs/server-install.md)、[Mihomo Mieru 字段](https://wiki.metacubex.one/en/config/proxies/mieru/)。

## 多沪日轮巡与“并发”的准确含义

面板生成以下 Mihomo 策略组：

| 组名 | 类型 | 作用 |
|---|---|---|
| 沪日自动 | `url-test` | 定期选择延迟较低的可用节点 |
| 沪日轮巡 | `load-balance / round-robin` | 把不同请求依次分配给不同节点 |
| 沪日并发 | `load-balance / consistent-hashing` | 同一目标尽量固定节点，不同目标分散到多台节点 |

这属于**连接/请求级负载分配**，不是 WireGuard ECMP，也不是单个下载连接的链路绑定。一个单线程下载不会因为加入两台沪日机器就自动变成两倍速度；多任务、多连接下载和多用户同时使用时，才更容易分散负载。

Mihomo 依据：[Load-Balance 策略](https://wiki.metacubex.one/en/config/proxy-groups/load-balance/)。

## WireGuard

面板建立：

- `/etc/wireguard/wg-huriN.conf` 服务端配置；
- 独立 `/24` IPv4 隧道网段；
- `iptables` 转发与出口 `MASQUERADE`；
- `net.ipv4.ip_forward=1`；
- 客户端配置与 ANSI 二维码；
- NAT 客户端 `PersistentKeepalive = 25`。

默认客户端仅路由 `0.0.0.0/0`，不会擅自加入 IPv6 全局路由，避免服务器无可用 IPv6 时产生断网或泄漏。官方依据：[WireGuard Quick Start](https://www.wireguard.com/quickstart/)。

## 测速内页

面板只从本仓库固定 `main` 地址下载，并在执行前进行 `bash -n`：

```text
IX 入口/NAT/隐藏内段：huri-panel → ix-route.sh --full --speed
China3Net 标准版：    huri-panel → 3net-route.sh
China3Net 测速版：    huri-panel → 3net-route-speed.sh
```

IX 项目填写 Mieru TCP 业务端口，不填 SSH 管理端口。测速会消耗实际流量，面板执行前会再次确认。

## 文件位置

| 路径 | 内容 | 权限 |
|---|---|---|
| `/usr/local/sbin/huri-panel` | 已安装面板 | `750` |
| `/usr/local/bin/huri` | 快捷命令 | 符号链接 |
| `/etc/huri-panel/` | 面板生成的服务端输入配置 | `700/600` |
| `/var/lib/huri-panel/` | Mieru 节点、WireGuard 实例与客户端清单 | `700/600` |
| `/var/backups/huri-panel/` | 配置描述、旧面板与 sysctl 备份 | `700/600` |
| `/root/huri-panel-exports/` | FLClash、分享链接、WireGuard 客户端、体检报告 | `700/600` |

导出文件含私钥或节点密码，不应上传到 GitHub、公开图床或聊天群。

## 命令行模式与测试

```bash
huri --health
huri --version
huri --help
huri --self-test
huri --preview-ui
```

仓库离线测试：

```bash
bash huri-panel/tests/test.sh
```

## 设计边界

- 不修改 SSH 端口。
- 不自动删除旧协议、旧用户或旧 WireGuard 配置。
- 不安装第三方 BBR 内核或 DKMS 模块。
- 不把 WireGuard UDP 误写成 BBR 可直接加速。
- 不预置任何真实沪日 IP、端口、用户名或密码。
- 不承诺商家 NAT 外网可达；公网映射必须由使用者在商家侧核对。
- 不把轮巡或一致性哈希描述为单连接带宽聚合。

## License

沿用仓库根目录 MIT License。
