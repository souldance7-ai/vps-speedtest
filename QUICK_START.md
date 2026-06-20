# 快速下载执行

## 标准综合测试

**VPS/Linux 执行：**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/souldance7-ai/VPS-/main/cn3_vps_net_test_plus.sh) --standard
```

## 首次安装依赖并测试

**VPS/Linux 执行：**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/souldance7-ai/VPS-/main/cn3_vps_net_test_plus.sh) --install --standard
```

## 深度测试

**VPS/Linux 执行：**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/souldance7-ai/VPS-/main/cn3_vps_net_test_plus.sh) --deep
```

## 仅延迟 / 回程骨干

**VPS/Linux 执行：**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/souldance7-ai/VPS-/main/cn3_vps_net_test_plus.sh) --route-only
```

## 下载后运行，推荐留档

**VPS/Linux 执行：**

```bash
curl -fsSL -o cn3_vps_net_test_plus.sh https://raw.githubusercontent.com/souldance7-ai/VPS-/main/cn3_vps_net_test_plus.sh
chmod +x cn3_vps_net_test_plus.sh
bash cn3_vps_net_test_plus.sh --standard
```
