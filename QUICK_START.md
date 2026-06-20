# QUICK START / 快速执行

## VPS/Linux：交互式菜单模式，推荐人工操作

**VPS/Linux 执行：**

```bash
bash cn3_vps_server_test.sh
```

支持：

```text
1) 快速体验测试
2) 标准综合测试
3) 深度三网测试
4) 仅延迟路由测试
5) 安装/补齐依赖
6) 帮助说明
0) 退出
```

可直接按数字，也可用 ↑ ↓ 方向键选择，Enter 确认。

---

# QUICK START / Windows CMD 正确执行版

## 重点说明

Windows CMD 不能直接运行：

```bash
bash <(curl -fsSL URL) --standard
```

这是 Linux Bash 语法。Windows CMD 正确方式是通过 `ssh root@VPS "bash -lc '...'"` 让 VPS 去执行 Linux 命令。

---

## 1. Windows CMD：远程触发 VPS 标准回程测试

**Windows CMD 执行：**

```cmd
ssh root@你的VPS_IP "bash -lc 'curl -fsSL -o /root/cn3_vps_server_test.sh https://raw.githubusercontent.com/souldance7-ai/VPS-/main/cn3_vps_server_test.sh && chmod +x /root/cn3_vps_server_test.sh && bash /root/cn3_vps_server_test.sh --standard'"
```

## 2. Windows CMD：远程安装依赖并测试

**Windows CMD 执行：**

```cmd
ssh root@你的VPS_IP "bash -lc 'curl -fsSL -o /root/cn3_vps_server_test.sh https://raw.githubusercontent.com/souldance7-ai/VPS-/main/cn3_vps_server_test.sh && chmod +x /root/cn3_vps_server_test.sh && bash /root/cn3_vps_server_test.sh --install --standard'"
```

## 3. Windows CMD：远程深度测试

**Windows CMD 执行：**

```cmd
ssh root@你的VPS_IP "bash -lc 'curl -fsSL -o /root/cn3_vps_server_test.sh https://raw.githubusercontent.com/souldance7-ai/VPS-/main/cn3_vps_server_test.sh && chmod +x /root/cn3_vps_server_test.sh && bash /root/cn3_vps_server_test.sh --deep'"
```

## 4. Windows CMD：本地端去程 + 代理体感

**Windows CMD 执行：**

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr -UseBasicParsing https://raw.githubusercontent.com/souldance7-ai/VPS-/main/cn3_client_probe.ps1 -OutFile .\cn3_client_probe.ps1; .\cn3_client_probe.ps1 -VpsHost 你的VPS_IP -Ports 22,443 -Proxy http://127.0.0.1:7890"
```

## 5. Windows CMD：本地端只测去程 / TCP 端口

**Windows CMD 执行：**

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr -UseBasicParsing https://raw.githubusercontent.com/souldance7-ai/VPS-/main/cn3_client_probe.ps1 -OutFile .\cn3_client_probe.ps1; .\cn3_client_probe.ps1 -VpsHost 你的VPS_IP -Ports 22,443"
```

## 6. 如果已经进入 VPS/Linux

**VPS/Linux 执行：**

```bash
curl -fsSL -o cn3_vps_server_test.sh https://raw.githubusercontent.com/souldance7-ai/VPS-/main/cn3_vps_server_test.sh
chmod +x cn3_vps_server_test.sh
bash cn3_vps_server_test.sh --standard
```

或：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/souldance7-ai/VPS-/main/cn3_vps_server_test.sh) --standard
```

> 这一条只适合 Linux Bash，不适合 Windows CMD。
