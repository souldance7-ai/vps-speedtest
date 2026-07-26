#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="v0.9 RC4.2.16 FINAL"
SCRIPT_NAME="$(basename "$0")"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'EOF'
中国三网 VPS 双程质量检测 v0.9 RC4.2.16 FINAL

用法：
  bash 3net-route.sh --port 443
  bash 3net-route.sh --extended --port 443
  bash 3net-route.sh --extended --speed --port 443
  bash 3net-route.sh --self-test
  bash 3net-route.sh --target 203.55.99.88 --port 443
  bash 3net-route.sh --target 203.55.99.88 --port 443 --forward-evidence /root/forward_evidence.json

说明：
  本脚本直接在被测 VPS 上运行，自动识别当前 VPS 公网 IPv4，不要求输入中国入口 IP。
  业务端口示例：443（Trojan／AnyTLS／REALITY 等 TCP 协议实际监听端口，不是 SSH 22）
  UDP-only 协议端口不能作为本脚本的 TCP 业务端口核对目标。
  --target：仅供高级用法手动覆盖自动识别结果；普通 VPS 本机检测不需要填写。
  默认：北京市／上海市／广州市 × 三网去程＋回程（18 组），恢复成熟北上广主矩阵。
  --extended：追加合肥市／南京市／杭州市，扩展为六地区 36 组。
  --speed：追加北上广三网公网单线程速度（9 组），约需 4～12 分钟并消耗测速流量。
  去程：优先读取中国本地端主动实测证据；缺项才使用 Globalping 同省远端探针。
  同省无探针时：一次收集中国境内同运营商多探针快照，按地区分配并避免重复。
  全国参考与指定地区分开统计，不会把 REFERENCE-PASS 写成指定地区 PASS。
  NOT-TESTED 与复用探针不计入指定省份矩阵；全国参考不会补足省份覆盖。
  最终结论以双程线路类型、延迟、吞吐与重传证据为主。
  CMD、HTML 与 JSON 均列出各省实测 AVG／P95、相对热度百分比及绿黄橙红渐层。
  单线程速度显示回程重传、回程 Mbps、去程 Mbps、相对百分位与绝对色带。
  回程：当前出口 VPS → 对应地区三网固定／动态目标。
  net.sh／TcpQuality 的节点均是 VPS→中国回程目标，不会被冒充为中国→VPS 去程。
  NAT 专线入口端口由三网外部 TCP traceroute 共同核对，不从出口反连入口。
  traceroute 跳点不回应只计为“路由回覆率”，不会伪装成业务丢包。
EOF
  exit 0
fi

SELF_TEST=0
TARGET=""
TARGET_PORT=""
NO_INSTALL=0
FORWARD_EVIDENCE=""
EXTENDED=0
SPEED_TEST=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) SELF_TEST=1; shift ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --port) TARGET_PORT="${2:-}"; shift 2 ;;
    --forward-evidence) FORWARD_EVIDENCE="${2:-}"; shift 2 ;;
    --extended) EXTENDED=1; shift ;;
    --speed) SPEED_TEST=1; shift ;;
    --no-install) NO_INSTALL=1; shift ;;
    *) echo "[ERROR] 未知参数：$1"; exit 2 ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "[ERROR] 找不到 python3；Debian 请先执行：apt-get update && apt-get install -y python3"
  exit 3
fi

if [[ "$SELF_TEST" -eq 0 && "$NO_INSTALL" -eq 0 ]]; then
  missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v traceroute >/dev/null 2>&1 || missing+=(traceroute)
  command -v dig >/dev/null 2>&1 || missing+=(dnsutils)
  if [[ ${#missing[@]} -gt 0 ]]; then
    if [[ "$(id -u)" -ne 0 ]]; then
      echo "[ERROR] 缺少组件：${missing[*]}；请使用 root 执行本脚本。"
      exit 4
    fi
    if command -v apt-get >/dev/null 2>&1; then
      echo "[INFO] 正在补齐原生探测组件：${missing[*]}"
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq "${missing[@]}"
    else
      echo "[ERROR] 当前系统不是 Debian/Ubuntu，请手动安装：curl traceroute dig"
      exit 4
    fi
  fi
fi

export THREE_NET_VERSION="$VERSION"
export THREE_NET_SCRIPT="$SCRIPT_NAME"
export THREE_NET_SELF_TEST="$SELF_TEST"
export THREE_NET_TARGET="$TARGET"
export THREE_NET_TARGET_PORT="$TARGET_PORT"
export THREE_NET_FORWARD_EVIDENCE="$FORWARD_EVIDENCE"
export THREE_NET_EXTENDED="$EXTENDED"
export THREE_NET_SPEED_TEST="$SPEED_TEST"

# 将 Python 源码放到独立文件描述符 3，保留标准输入给 input() 读取终端。
# 这样直接运行、curl 进程替换、管道输入三种方式都不会在交互提示处 EOF。
python3 /dev/fd/3 3<<'PY'
from __future__ import annotations

import csv
import datetime as dt
import html
import io
import ipaddress
import json
import math
import os
import re
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.error
import urllib.request
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any

VERSION = os.environ.get("THREE_NET_VERSION", "v0.9 RC4.2.16 FINAL")
SELF_TEST = os.environ.get("THREE_NET_SELF_TEST") == "1"
EXTENDED = os.environ.get("THREE_NET_EXTENDED") == "1"
SPEED_TEST = os.environ.get("THREE_NET_SPEED_TEST") == "1"
TARGET = os.environ.get("THREE_NET_TARGET", "").strip()
PORT_TEXT = os.environ.get("THREE_NET_TARGET_PORT", "").strip()
FORWARD_EVIDENCE_PATH = os.environ.get("THREE_NET_FORWARD_EVIDENCE", "").strip()
GLOBALPING_API = "https://api.globalping.io/v1/measurements"
PUBLIC_REPORT_API = "https://china-3net-route-report.souldance4.chatgpt.site/api/reports"
TCPQUALITY_COMMIT = "5852b9af8a94afe6299f355673f9e2090a55d8c4"
TCPQUALITY_RAW_BASE = (
    "https://raw.githubusercontent.com/ibsgss/TcpQuality/"
    f"{TCPQUALITY_COMMIT}"
)
TCPQUALITY_NODES_API = os.environ.get(
    "THREE_NET_RETURN_POOL",
    "https://tcpquality.ibsgss.uk/getNodes?format=tsv&scope=cdn",
).strip()
ICMP_TARGETS_API = os.environ.get(
    "THREE_NET_ICMP_POOL",
    "https://raw.githubusercontent.com/spiritLHLS/icmp_targets/main/nodes.json",
).strip()
WIDTH = min(max(shutil.get_terminal_size((112, 32)).columns, 92), 132)

RESET = "\033[0m"
GRAY = "\033[38;5;245m"
WHITE = "\033[97m"
BLUE = "\033[38;5;27m"
CYAN = "\033[96m"
RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
MAGENTA = "\033[95m"
CARRIER_COLOR = {"CT": CYAN, "CU": RED, "CM": GREEN}
CARRIER_NAME = {"CT": "中国电信", "CU": "中国联通", "CM": "中国移动"}
CARRIER_MARK = {"CT": "◈ CT", "CU": "∞ CU", "CM": "▰ CM"}
CARRIER_HEX = {"CT": "#00A8E0", "CU": "#E60012", "CM": "#008F3D"}


def carrier_label(carrier: str) -> str:
    return f"{CARRIER_MARK.get(carrier, carrier)} {CARRIER_NAME.get(carrier, carrier)}"

# 回程目标使用公开、明确的运营商 IP，避免第三方测试域名失效时把 DNS
# 故障误报成线路质量问题。北京／上海／广东沿用成熟目标；安徽／江苏／浙江
# 使用各省运营商 DNS 或公开路由测试目标。
PROBES = {
    "CT": [
        ("北京", "219.141.140.10"),
        ("上海", "202.96.209.133"),
        ("广东", "58.60.188.222"),
        ("安徽", "61.132.163.68"),
        ("江苏", "218.2.2.2"),
        ("浙江", "202.101.172.35"),
    ],
    "CU": [
        ("北京", "202.106.195.68"),
        ("上海", "210.22.97.1"),
        ("广东", "210.21.196.6"),
        ("安徽", "218.104.78.2"),
        ("江苏", "58.240.53.78"),
        ("浙江", "221.12.1.227"),
    ],
    "CM": [
        ("北京", "221.179.155.161"),
        ("上海", "211.136.112.200"),
        ("广东", "120.196.165.24"),
        ("安徽", "211.138.180.2"),
        ("江苏", "221.131.143.69"),
        ("浙江", "112.13.113.199"),
    ],
}
ALL_FORWARD_REGIONS = [
    ("北京", "Beijing"),
    ("上海", "Shanghai"),
    ("广东", "Guangzhou"),
    ("安徽", "Hefei"),
    ("江苏", "Nanjing"),
    ("浙江", "Hangzhou"),
]
FORWARD_REGIONS = ALL_FORWARD_REGIONS if EXTENDED else ALL_FORWARD_REGIONS[:3]
ACTIVE_REGION_NAMES = {region for region, _ in FORWARD_REGIONS}
ACTIVE_PROBES = {
    carrier: [
        (city, host) for city, host in entries if city in ACTIVE_REGION_NAMES
    ]
    for carrier, entries in PROBES.items()
}
EXPECTED_PER_DIRECTION = len(FORWARD_REGIONS) * 3
TOTAL_MATRIX_GROUPS = EXPECTED_PER_DIRECTION * 2
MATRIX_CITIES = "／".join(
    CAPITAL for CAPITAL in (
        "北京市", "上海市", "广州市", "合肥市", "南京市", "杭州市"
    )[:len(FORWARD_REGIONS)]
)
MATRIX_LABEL = "六地区扩展" if EXTENDED else "北上广主矩阵"
FORWARD_ASN = {"CT": 4134, "CU": 4837, "CM": 9808}
# 省会接入网不一定直接使用三大运营商的骨干 ASN。只锁 AS4134／AS4837／
# AS9808 会漏掉上海联通 AS4808、广州联通 AS17622、北京移动 AS56048 等
# 合法省网测点。下列 ASN 只用于确认“探针所属运营商”，线路等级仍由实际
# traceroute 中的骨干 ASN／特征 IP 判定，不能拿接入 ASN 冒充精品骨干。
FORWARD_ASN_FAMILIES = {
    "CT": {4134, 4812, 4816},
    "CU": {4837, 4808, 17621, 17622, 17623, 17816},
    "CM": {9808, 24445, 56040, 56041, 56042, 56044, 56046, 56047,
           56048, 56050, 56055, 56056, 56057, 56058},
}
FORWARD_NETWORK_HINTS = {
    "CT": ("chinanet", "china telecom", "telecom"),
    "CU": ("china unicom", "china169", "unicom"),
    "CM": ("china mobile", "mobile communications", "mobile communica"),
}
CAPITALS = {
    "北京": "北京市",
    "上海": "上海市",
    "广东": "广州市",
    "安徽": "合肥市",
    "江苏": "南京市",
    "浙江": "杭州市",
}
FORWARD_ISP_MAGIC = {
    "CT": "China Telecom",
    "CU": "China Unicom",
    "CM": "China Mobile",
}
# 省会必须先查；只有省会没有同运营商在线探针时，才允许退到同一省份的
# 其他城市。北京、上海不跨直辖市。实际使用城市会写进 CMD／HTML／JSON。
FORWARD_PROVINCE_CITIES = {
    "北京": ("Beijing",),
    "上海": ("Shanghai",),
    "广东": ("Guangzhou", "Shenzhen", "Foshan", "Dongguan"),
    "安徽": ("Hefei", "Wuhu", "Bengbu"),
    "江苏": ("Nanjing", "Suzhou", "Wuxi", "Changzhou", "Xuzhou"),
    "浙江": ("Hangzhou", "Ningbo", "Wenzhou", "Shaoxing", "Jiaxing"),
}
FORWARD_REGION_ASNS = {
    "CT": {
        "北京": (4134,), "上海": (4134, 4812), "广东": (4134, 4816),
        "安徽": (4134,), "江苏": (4134,), "浙江": (4134,),
    },
    "CU": {
        "北京": (4808, 4837), "上海": (17621, 4837),
        "广东": (17622, 4837), "安徽": (4837,),
        "江苏": (4837,), "浙江": (17623, 4837),
    },
    "CM": {
        "北京": (56048, 9808), "上海": (9808,), "广东": (9808,),
        "安徽": (9808,), "江苏": (9808,), "浙江": (9808,),
    },
}
FORWARD_NATIONAL_ASNS = {
    "CT": (4134, 4812, 4816),
    # 联通必须覆盖北上广省网 ASN，不能命中第一个 AS4808 后就停止。
    "CU": (4808, 17621, 17622, 17623, 4837, 17816),
    "CM": (56048, 9808, 24445),
}
NATIONAL_PROBE_LIMIT = len(ALL_FORWARD_REGIONS)


def normalize_city(value: str) -> str:
    return re.sub(r"[^a-z]", "", value.lower())


def probe_matches_carrier(probe: dict[str, Any], carrier: str) -> bool:
    try:
        probe_asn = int(probe.get("asn") or 0)
    except (TypeError, ValueError):
        probe_asn = 0
    network = str(probe.get("network") or "").lower()
    return (
        probe_asn in FORWARD_ASN_FAMILIES[carrier]
        or any(hint in network for hint in FORWARD_NETWORK_HINTS[carrier])
    )


def backbone_labels(carrier: str, route_class: str, route: str) -> tuple[list[str], str]:
    plain = route.replace("\r", "")
    tags: list[str] = []

    def add(label: str, patterns: list[str]) -> None:
        if any(re.search(pattern, plain, re.I) for pattern in patterns) and label not in tags:
            tags.append(label)

    if carrier == "CT":
        add("AS4809｜CN2 精品骨干", [r"AS4809", r"59\.43\."])
        add("AS23764｜CTGNet 国际精品", [r"AS23764", r"CTGNet", r"69\.194\."])
        add("AS4134｜ChinaNet 163 普通骨干", [r"AS4134", r"202\.97\."])
        carrier_text = "电信"
    elif carrier == "CU":
        add("AS9929｜CUII 联通精品骨干", [r"AS9929", r"CUII", r"218\.105\.", r"210\.(51|52|53|78)\."])
        add("AS10099｜CUG 联通国际网", [r"AS10099", r"CUG", r"202\.77\.", r"43\.252\.", r"61\.14\."])
        add("AS4837｜China169 联通普通骨干", [r"AS4837", r"219\.158\."])
        carrier_text = "联通"
    else:
        add("AS58807｜CMIN2 移动精品骨干", [r"AS58807", r"CMIN2", r"223\.118\.32\."])
        add("AS58453｜CMI 移动普通国际网", [r"AS58453", r"CMI-INT", r"223\.(118|119)\."])
        add("AS9808｜CMNET 移动国内骨干", [r"AS9808", r"CMNET", r"221\.183\.", r"111\.24\."])
        carrier_text = "移动"

    if not tags:
        tags = [f"未识别{carrier_text}骨干｜可见跳点证据不足"]

    joined = " → ".join(tags)
    if "测点不可用" in route_class or "探针不可用" in route_class:
        note = f"测点健康检查未通过；本组没有可判定的{carrier_text}路由，不参与评分。"
    elif "仅见" in route_class and "目的网" in route_class:
        note = f"可见跳点只证明目的省会的{carrier_text}接入／交付网，未形成连续骨干证据，不能据此判定完整回程。"
    elif route_class.startswith("INCONCLUSIVE"):
        note = f"当前可见跳点未形成可复核的{carrier_text}骨干链路；保持证据不足，不按普通线或精品线扣分。"
    elif "混合" in route_class or "GT" in route_class:
        note = f"混合路由：{joined}；骨干切换顺序以本次 traceroute 可见跳点为准。"
    elif any(word in route_class for word in ("GIA", "AS9929", "CMIN2")):
        note = f"精品路由：{joined}；判定来自可见 ASN／特征 IP，不以延迟倒推线路。"
    else:
        note = f"非精品路由：{joined}；本次只确认普通／国际骨干，不标记为精品。"
    return tags, note


def add_route_labels(item: dict[str, Any]) -> dict[str, Any]:
    tags, note = backbone_labels(
        item["carrier"], item.get("class", "INCONCLUSIVE"), item.get("route", "")
    )
    item["backboneTags"] = tags
    item["routeNote"] = note
    region = item.get("region") or item.get("city") or ""
    item["probeCapital"] = CAPITALS.get(region, region)
    return item


def visible_len(text: str) -> int:
    plain = re.sub(r"\x1b\[[0-9;]*m", "", text)
    return sum(2 if unicodedata.east_asian_width(char) in ("W", "F") else 1 for char in plain)


def trim(text: str, width: int) -> str:
    plain = re.sub(r"\x1b\[[0-9;]*m", "", text)
    if visible_len(plain) <= width:
        return text
    output = []
    used = 0
    for char in plain:
        char_width = 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
        if used + char_width > width - 1:
            break
        output.append(char)
        used += char_width
    return "".join(output) + "…"


def rule(char: str = "═", color: str = BLUE) -> None:
    print(color + char * WIDTH + RESET)


def banner(title: str, color: str = CYAN) -> None:
    inner = WIDTH - 4
    deco = "░▒▓█"
    title_width = visible_len(title)
    room = max(0, inner - title_width - 4)
    left = (deco * ((room // 2 + 3) // 4))[: room // 2]
    right = ("█▓▒░" * ((room - len(left) + 3) // 4))[: room - len(left)]
    print(BLUE + "╔" + "═" * (WIDTH - 2) + "╗" + RESET)
    print(BLUE + "║ " + color + left + "  " + title + "  " + right +
          " " * max(0, inner - len(left) - len(right) - title_width - 4) +
          BLUE + " ║" + RESET)
    print(BLUE + "╚" + "═" * (WIDTH - 2) + "╝" + RESET)


def field(label: str, value: Any, color: str = WHITE) -> None:
    value = trim(str(value), WIDTH - 22)
    print(f"  {GRAY}{label:<14}{RESET} {color}{value}{RESET}")


def logo() -> None:
    print(BLUE + r"""
   ██████╗ ███╗   ██╗███████╗████████╗    ██████╗  ██████╗ ██╗   ██╗████████╗███████╗
   ╚════██╗████╗  ██║██╔════╝╚══██╔══╝    ██╔══██╗██╔═══██╗██║   ██║╚══██╔══╝██╔════╝
    █████╔╝██╔██╗ ██║█████╗     ██║       ██████╔╝██║   ██║██║   ██║   ██║   █████╗
    ╚═══██╗██║╚██╗██║██╔══╝     ██║       ██╔══██╗██║   ██║██║   ██║   ██║   ██╔══╝
   ██████╔╝██║ ╚████║███████╗   ██║       ██║  ██║╚██████╔╝╚██████╔╝   ██║   ███████╗
   ╚═════╝ ╚═╝  ╚═══╝╚══════╝   ╚═╝       ╚═╝  ╚═╝ ╚═════╝  ╚═════╝    ╚═╝   ╚══════╝
""" + RESET)
    print(CYAN + f"{'CHINA 3NET ROUTE LAB · VPS NATIVE · NO SSH AUTH':^{WIDTH}}" + RESET)
    rule("─")


def mask_ip(value: str) -> str:
    try:
        parts = value.split(".")
        if len(parts) == 4:
            return f"{parts[0]}.{parts[1]}.*.*"
    except Exception:
        pass
    return "N/A"


def valid_public_ipv4(value: str) -> bool:
    try:
        ip = ipaddress.ip_address(value)
        return ip.version == 4 and ip.is_global
    except ValueError:
        return False


def ask_target(detected_ip: str) -> tuple[str, int]:
    global TARGET, PORT_TEXT
    if SELF_TEST:
        return "45.207.225.70", 10100
    banner("VPS NATIVE / 本机自动识别", MAGENTA)
    if not TARGET and valid_public_ipv4(detected_ip):
        TARGET = detected_ip
    field("当前 VPS IPv4", mask_ip(TARGET), CYAN)
    field("协议端口示例", "443", GREEN)
    field("重要提醒", "填写 Trojan／AnyTLS／REALITY 等 TCP 业务端口，不是 SSH 22；UDP-only 端口不适用", YELLOW)
    field("IP 输入", "已自动识别；普通 VPS 本机检测无需填写中国入口 IP", GREEN)
    while not valid_public_ipv4(TARGET):
        TARGET = input("自动识别失败，请输入当前 VPS 的公网 IPv4：").strip()
        if not valid_public_ipv4(TARGET):
            print(RED + "  IPv4 无效，请重新输入。" + RESET)
    while True:
        if not PORT_TEXT:
            PORT_TEXT = input("请输入协议业务端口〔例 443；不是 SSH 22〕：").strip()
        try:
            port = int(PORT_TEXT)
            if 1 <= port <= 65535:
                return TARGET, port
        except ValueError:
            pass
        print(RED + "  端口无效，请输入 1～65535。" + RESET)
        PORT_TEXT = ""


def http_json(url: str, method: str = "GET", payload: Any = None, timeout: int = 25) -> Any:
    data = None
    headers = {"User-Agent": f"3net-route-detector/{VERSION}", "Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


ASN_CACHE: dict[str, str] = {}


def http_text(url: str, timeout: int = 25) -> str:
    headers = {"User-Agent": f"3net-route-detector/{VERSION}", "Accept": "text/plain,*/*"}
    req = urllib.request.Request(url, headers=headers, method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return response.read().decode("utf-8-sig", "replace")


def origin_asn(ip: str) -> str:
    if ip in ASN_CACHE:
        return ASN_CACHE[ip]
    if not valid_public_ipv4(ip) or not shutil.which("dig"):
        return ""
    reversed_ip = ".".join(reversed(ip.split(".")))
    try:
        out = subprocess.check_output(
            ["dig", "+short", "TXT", f"{reversed_ip}.origin.asn.cymru.com"],
            text=True, timeout=4, stderr=subprocess.DEVNULL
        )
        match = re.search(r'"?\s*(\d+)\s*\|', out)
        result = f"AS{match.group(1)}" if match else ""
    except Exception:
        result = ""
    ASN_CACHE[ip] = result
    return result


def enrich_route(route: str, maximum: int = 24) -> str:
    seen: set[str] = set()
    evidence: list[str] = []
    for ip in re.findall(r"(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)", route):
        if ip in seen or not valid_public_ipv4(ip):
            continue
        seen.add(ip)
        asn = origin_asn(ip)
        if asn:
            evidence.append(f"{ip} {asn}")
        if len(seen) >= maximum:
            break
    return route + ("\n@@ASN_EVIDENCE " + " | ".join(evidence) if evidence else "")


def first_index(text: str, patterns: list[str]) -> int:
    indexes = [m.start() for p in patterns if (m := re.search(p, text, re.I))]
    return min(indexes) if indexes else -1


def matching_hop_count(text: str, patterns: list[str]) -> int:
    """Count matching route hops, not duplicate ASN/IP tags on one hop."""
    return sum(
        1 for line in text.splitlines()
        if re.search(r"^\s*\d+\s+", line)
        and any(re.search(pattern, line, re.I) for pattern in patterns)
    )


def classify(carrier: str, route: str, direction: str) -> tuple[str, int, str]:
    plain = route.replace("\r", "")
    if carrier == "CT":
        cn2 = [r"AS4809", r"59\.43\."]
        normal = [r"AS4134", r"202\.97\."]
        ci, ni = first_index(plain, cn2), first_index(plain, normal)
        cn2_hops = matching_hop_count(plain, cn2)
        normal_hops = matching_hop_count(plain, normal)
        if ci >= 0:
            if direction == "Forward":
                if cn2_hops < 2:
                    return "CN2 证据不足／混合", 3, (
                        "去程仅一个可见跳点命中 AS4809／59.43，"
                        "不足以单独判定 CN2 GIA"
                    )
                if ni < 0 or (ni < ci and normal_hops <= 1):
                    return "CN2 GIA", 5, "去程连续进入 AS4809／59.43，普通 163 仅为接入段或未出现"
                if ni < ci:
                    return "CN2 GT", 3, "去程先经过 AS4134／202.97 普通骨干，出口才切入 CN2"
                return "CN2／163 混合", 3, "去程进入 CN2 后又出现普通 163，骨干不纯"
            if cn2_hops < 2:
                return "CN2 证据不足／混合", 3, (
                    "回程仅一个可见跳点命中 AS4809／59.43，"
                    "不足以单独判定 CN2 GIA"
                )
            if ni < 0 or (ci < ni and normal_hops <= 1):
                return "CN2 GIA", 5, "回程优先进入 AS4809／59.43，普通 163 仅作目的网交付"
            if ci < ni:
                return "CN2／163 混合", 3, (
                    "回程先进入 CN2，但随后出现多个 163 骨干跳点，"
                    "不按纯 CN2 GIA 计算"
                )
            return "CN2 GT／混合", 3, "回程先走普通 163，随后才进入 CN2"
        if first_index(plain, [r"AS23764", r"CTGNet", r"69\.194\."]) >= 0:
            return "CTG GIA", 4, "检测到 AS23764／CTGNet 特征"
        if ni >= 0:
            if direction == "Return" and matching_hop_count(plain, normal) <= 1:
                return "INCONCLUSIVE｜仅见电信目的网", 0, (
                    "仅一个回程跳点命中 AS4134／202.97，可能只是目的网交付，"
                    "不足以证明全程走电信 163"
                )
            return "电信 163", 2, "仅检测到 AS4134／202.97 普通骨干"
        return "INCONCLUSIVE｜未见电信骨干", 0, (
            "ASN 已补查，仍未命中 AS4809、AS4134 或 AS23764；本组证据不足，不参与评分"
        )

    if carrier == "CU":
        ai = first_index(plain, [r"AS9929", r"CUII", r"218\.105\.", r"210\.(51|52|53|78)\."])
        ui = first_index(plain, [r"AS10099", r"CUG", r"202\.77\.", r"43\.252\.", r"61\.14\."])
        ni = first_index(plain, [r"AS4837", r"219\.158\."])
        if ai >= 0:
            if direction == "Forward" and ni > ai:
                return "AS9929／混合", 3, "去程进入 AS9929 后回落 AS4837 普通骨干"
            if direction == "Return" and 0 <= ni < ai:
                return "AS9929／混合", 3, "回程进入 AS9929 前已先走 AS4837 普通骨干"
            return "AS9929（CUII）", 5, f"{'去程' if direction == 'Forward' else '回程'}命中 AS9929／CUII，精品段后未回落普通骨干"
        if ui >= 0:
            return "CUG／非 AS9929", 3, "检测到 AS10099／CUG，但未确认 AS9929"
        if ni >= 0:
            if direction == "Return" and matching_hop_count(
                plain, [r"AS4837", r"219\.158\."]
            ) <= 1:
                return "INCONCLUSIVE｜仅见联通目的网", 0, (
                    "仅一个回程跳点命中 AS4837／219.158，可能只是目的网交付，"
                    "不足以证明全程走普通联通"
                )
            return "AS4837 普通联通", 2, "仅检测到 AS4837／219.158 普通骨干"
        return "INCONCLUSIVE｜未见联通骨干", 0, (
            "ASN 已补查，仍未命中 AS9929、AS10099 或 AS4837；本组证据不足，不参与评分"
        )

    cmin2 = first_index(plain, [
        r"AS58807", r"CMIN2", r"223\.118\.32\.",
        r"223\.119\.(?:[89]|1[0-5]|2[6-9]|3[24-7]|7[45]|8[89]|100|25[23])\.",
        r"223\.120\.(?:1(?:2[89]|[3-9]\d)|2[0-5]\d)\."
    ])
    cmi = first_index(plain, [
        r"AS58453", r"CMI-INT", r"223\.(?:118|119)\.",
        r"223\.120\.(?:[0-9]|[1-9]\d|1[01]\d|12[0-7])\."
    ])
    cmnet = first_index(plain, [r"AS9808", r"CMNET", r"221\.183\.", r"111\.24\."])
    if cmin2 >= 0:
        if direction == "Forward" and cmi > cmin2:
            return "CMIN2／混合", 3, "去程进入 AS58807／CMIN2 后回落普通 CMI"
        if direction == "Return" and 0 <= cmi < cmin2:
            return "CMIN2／混合", 3, "回程先走普通 CMI，随后才进入 CMIN2"
        return "CMIN2（CMI2）", 5, f"{'去程' if direction == 'Forward' else '回程'}命中 AS58807／CMIN2，精品段后未回落普通 CMI"
    if cmi >= 0:
        return "CMI 普通国际", 2, "检测到 AS58453／普通 223.119 或 223.120"
    if cmnet >= 0:
        return "CMNET 普通移动", 2, "仅检测到 AS9808／221.183 国内骨干"
    return "INCONCLUSIVE｜未见移动骨干", 0, (
        "ASN 已补查，仍未命中 AS58807、AS58453 或 AS9808；本组证据不足，不参与评分"
    )


@dataclass
class Stats:
    avg: float | None
    minimum: float | None
    maximum: float | None
    p95: float | None
    jitter: float | None
    loss: float | None
    success: int
    expected: int
    metric: str


def stats(values: list[float], expected: int, loss_valid: bool = True,
          metric: str = "TCP connect") -> Stats:
    if not values:
        return Stats(
            None, None, None, None, None,
            100.0 if loss_valid else None, 0, expected, metric
        )
    ordered = sorted(values)
    p95_pos = max(0, math.ceil(0.95 * len(ordered)) - 1)
    jitter = statistics.mean(abs(values[i] - values[i - 1]) for i in range(1, len(values))) if len(values) > 1 else 0
    return Stats(
        round(statistics.mean(values), 1), round(min(values), 1), round(max(values), 1),
        round(ordered[p95_pos], 1), round(jitter, 1),
        round((expected - len(values)) * 100 / expected, 1) if loss_valid and expected else None,
        len(values), expected, metric
    )


def score(rank: int, s: Stats) -> int:
    if rank <= 0:
        return 0
    route_score = {5: 60, 4: 54, 3: 42, 2: 28}.get(rank, 12)
    latency = 0
    if s.avg is not None:
        latency = 30 if s.avg <= 100 else 25 if s.avg <= 150 else 18 if s.avg <= 200 else 10 if s.avg <= 250 else 4
    stability = 5 if s.loss is None else 10 if s.loss == 0 else 6 if s.loss <= 20 else 0
    return min(100, route_score + latency + stability)


def stars(value: int) -> str:
    count = 5 if value >= 90 else 4 if value >= 75 else 3 if value >= 60 else 2 if value >= 40 else 1 if value > 0 else 0
    return "★" * count + "☆" * (5 - count)


def run(command: list[str], timeout: int = 45) -> str:
    try:
        return subprocess.run(command, text=True, capture_output=True, timeout=timeout).stdout
    except Exception as exc:
        return f"COMMAND_ERROR {exc}"


def resolve_ipv4(host: str) -> str:
    try:
        return socket.gethostbyname(host)
    except Exception:
        return ""


def route_hop_count(route: str) -> int:
    """Count responding traceroute hop lines, excluding the command header."""
    return sum(
        1 for line in route.splitlines()
        if re.search(r"^\s*\d+\s+(?:\d{1,3}\.){3}\d{1,3}(?:\s|$)", line)
    )


def traceroute_rtts(route: str) -> list[float]:
    values: list[float] = []
    for line in route.splitlines():
        if not re.search(r"^\s*\d+\s+", line):
            continue
        values.extend(float(x) for x in re.findall(r"(\d+(?:\.\d+)?)\s*ms", line))
    return values


def tcp_samples(host: str, port: int = 80, count: int = 5, timeout: float = 4.0) -> list[float]:
    values: list[float] = []
    for _ in range(count):
        started = time.perf_counter()
        try:
            with socket.create_connection((host, port), timeout=timeout):
                values.append(round((time.perf_counter() - started) * 1000, 1))
        except OSError:
            pass
        time.sleep(0.12)
    return values


def speed_value(value: str) -> float | None:
    value = value.strip()
    if not value or value.lower() in {"failed", "null", "n/a"}:
        return None
    try:
        number = float(value)
    except ValueError:
        return None
    return round(number, 1) if number >= 0 else None


def retrans_value(value: str) -> int | None:
    value = value.strip()
    if not value or value.lower() in {"failed", "null", "n/a"}:
        return None
    try:
        number = int(float(value))
    except ValueError:
        return None
    return max(0, number)


def speed_band(value: float | None) -> tuple[str, str]:
    if value is None:
        return "N/A", "#596579"
    if value < 30:
        return "<30 Mbps", "#ff4d5e"
    if value < 100:
        return "30–99 Mbps", "#ff9f43"
    if value < 300:
        return "100–299 Mbps", "#f5df4d"
    if value < 500:
        return "300–499 Mbps", "#8ee63f"
    return "≥500 Mbps", "#38e87b"


def retrans_band(value: int | None) -> tuple[str, str]:
    if value is None:
        return "N/A", "#596579"
    if value < 100:
        return "低", "#38e87b"
    if value < 500:
        return "中", "#f5df4d"
    if value < 1000:
        return "偏高", "#ff9f43"
    return "高", "#ff4d5e"


def speed_row(
    region: str,
    carrier: str,
    city: str,
    return_mbps: float | None,
    forward_mbps: float | None,
    return_retransmits: int | None,
) -> dict[str, Any]:
    carrier_codes = {"电信": "CT", "联通": "CU", "移动": "CM"}
    complete = return_mbps is not None and forward_mbps is not None
    partial = return_mbps is not None or forward_mbps is not None
    return {
        "region": region,
        "carrier": carrier_codes.get(carrier, ""),
        "carrierName": f"中国{carrier}",
        "nodeCity": city or region,
        "label": f"{city or region}{carrier}",
        "returnRetransmits": return_retransmits,
        "returnMbps": return_mbps,
        "forwardMbps": forward_mbps,
        "status": "PASS" if complete else "PARTIAL" if partial else "N/A",
        "measurement": "PUBLIC_TOS_SINGLE_STREAM",
        "testsCurrentVpsPublicNetwork": True,
        "pathIncludesBusinessEntry": False,
        "pathIncludesBusinessPort": False,
    }


def self_test_speed_rows() -> list[dict[str, Any]]:
    samples = [
        ("北京", "电信", "北京", 318.9, 422.0, 703),
        ("北京", "联通", "北京", 429.1, 430.2, 1644),
        ("北京", "移动", "北京", 90.2, 436.5, 1264),
        ("上海", "电信", "上海", 359.9, 446.7, 630),
        ("上海", "联通", "上海", 50.2, 429.0, 1245),
        ("上海", "移动", "上海", 59.9, 382.5, 132),
        ("广东", "电信", "广东", 50.3, 420.5, 814),
        ("广东", "联通", "广东", 134.9, 433.0, 37),
        ("广东", "移动", "广东", 156.1, 435.7, 81),
    ]
    return [speed_row(*sample) for sample in samples]


def newest_speed_csv(started: float, before: set[Path]) -> Path | None:
    candidates = [
        path
        for path in Path("/tmp").glob("zstatic_nping_*.csv")
        if path not in before and path.is_file()
    ]
    if not candidates:
        candidates = [
            path
            for path in Path("/tmp").glob("zstatic_nping_*.csv")
            if path.is_file() and path.stat().st_mtime >= started - 3
        ]
    return max(candidates, key=lambda path: path.stat().st_mtime) if candidates else None


def parse_tcpquality_speed_csv(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8-sig", errors="replace", newline="") as handle:
        for values in csv.reader(handle):
            if len(values) < 10 or values[0] != "三网单线程速度":
                continue
            region = values[1].strip()
            carrier = values[2].strip()
            city = values[3].strip()
            upstream_status = values[6].strip().upper()
            row = speed_row(
                region,
                carrier,
                city,
                speed_value(values[7]),
                speed_value(values[9]),
                retrans_value(values[8]),
            )
            if upstream_status != "OK" and row["status"] == "N/A":
                row["status"] = "N/A"
            rows.append(row)
    order = {"北京": 0, "上海": 1, "广东": 2}
    carrier_order = {"CT": 0, "CU": 1, "CM": 2}
    unique: dict[tuple[str, str], dict[str, Any]] = {}
    for row in rows:
        key = (str(row["region"]), str(row["carrier"]))
        previous = unique.get(key)
        if previous is None or (
            row["status"] == "PASS" and previous["status"] != "PASS"
        ):
            unique[key] = row
    return sorted(
        unique.values(),
        key=lambda row: (
            order.get(str(row["region"]), 99),
            carrier_order.get(str(row["carrier"]), 99),
        ),
    )


def annotate_speed_visuals(rows: list[dict[str, Any]]) -> dict[str, Any]:
    for key, visual_key in (
        ("returnMbps", "returnVisual"),
        ("forwardMbps", "forwardVisual"),
    ):
        values = [
            float(row[key]) for row in rows
            if isinstance(row.get(key), (int, float))
        ]
        low = min(values) if values else 0.0
        high = max(values) if values else 0.0
        for row in rows:
            value = row.get(key)
            if not isinstance(value, (int, float)):
                row[visual_key] = {
                    "measured": False, "mbps": None,
                    "relativePercentile": None, "absoluteBand": "N/A",
                    "color": "#596579", "reason": "未取得测速结果",
                }
                continue
            percentile_value = (
                50 if math.isclose(low, high)
                else round((float(value) - low) * 100 / (high - low))
            )
            band, color = speed_band(float(value))
            row[visual_key] = {
                "measured": True, "mbps": round(float(value), 1),
                "relativePercentile": percentile_value,
                "absoluteBand": band, "color": color, "reason": "",
            }
    for row in rows:
        retrans = row.get("returnRetransmits")
        band, color = retrans_band(
            int(retrans) if isinstance(retrans, (int, float)) else None
        )
        row["retransVisual"] = {
            "measured": isinstance(retrans, (int, float)),
            "count": int(retrans) if isinstance(retrans, (int, float)) else None,
            "band": band, "color": color,
        }

    complete = [row for row in rows if row.get("status") == "PASS"]
    return_values = [
        float(row["returnMbps"]) for row in complete
        if isinstance(row.get("returnMbps"), (int, float))
    ]
    forward_values = [
        float(row["forwardMbps"]) for row in complete
        if isinstance(row.get("forwardMbps"), (int, float))
    ]
    high_retrans = [
        row for row in complete
        if isinstance(row.get("returnRetransmits"), (int, float))
        and int(row["returnRetransmits"]) >= 1000
    ]
    bottleneck = min(
        complete,
        key=lambda row: min(float(row["returnMbps"]), float(row["forwardMbps"])),
        default=None,
    )
    return {
        "complete": len(complete),
        "total": 9,
        "returnAvgMbps": (
            round(statistics.mean(return_values), 1) if return_values else None
        ),
        "forwardAvgMbps": (
            round(statistics.mean(forward_values), 1) if forward_values else None
        ),
        "returnMinMbps": min(return_values) if return_values else None,
        "forwardMinMbps": min(forward_values) if forward_values else None,
        "highRetransmitRows": len(high_retrans),
        "bottleneck": (
            {
                "label": bottleneck["label"],
                "returnMbps": bottleneck["returnMbps"],
                "forwardMbps": bottleneck["forwardMbps"],
            }
            if bottleneck else None
        ),
        "policy": (
            "Mbps 采用绝对色带并显示同次九组相对百分位；"
            "重传为原始计数，只用于同次等时长样本比较。"
        ),
    }


def single_thread_speed() -> dict[str, Any]:
    boundary = (
        "本项直接测量当前出口VPS与北上广三网公共TOS测速端之间的单数据流能力；"
        "回程为VPS→中国测速端，去程为中国测速端→VPS。它与本报告的VPS公网双程用途一致，"
        "但测速节点不等同指定省份路由探针，也不补足省份矩阵。"
    )
    base = {
        "enabled": SPEED_TEST or SELF_TEST,
        "source": "ibsgss/TcpQuality pinned upstream",
        "upstreamCommit": TCPQUALITY_COMMIT,
        "boundary": boundary,
        "testsCurrentVpsPublicNetwork": True,
        "pathIncludesBusinessEntry": False,
        "pathIncludesBusinessPort": False,
        "rows": [],
        "summary": annotate_speed_visuals([]),
    }
    if not SPEED_TEST and not SELF_TEST:
        return {
            **base,
            "status": "N/A",
            "reason": "未使用 --speed；本项未执行",
        }
    if SELF_TEST:
        rows = self_test_speed_rows()
        return {
            **base,
            "status": "PASS",
            "reason": "SELF-TEST 北上广三网九组完整",
            "rows": rows,
            "summary": annotate_speed_visuals(rows),
        }
    if os.name != "posix" or not hasattr(os, "geteuid") or os.geteuid() != 0:
        return {
            **base,
            "status": "N/A",
            "reason": "三网单线程速度需要 Linux root 环境",
        }

    workdir = Path(tempfile.mkdtemp(prefix="cn3-speed-"))
    entry_script = workdir / "runTcpQuality.sh"
    before = set(Path("/tmp").glob("zstatic_nping_*.csv"))
    started = time.time()
    try:
        request = urllib.request.Request(
            f"{TCPQUALITY_RAW_BASE}/runTcpQuality.sh",
            headers={"User-Agent": f"3net-route/{VERSION}"},
        )
        with urllib.request.urlopen(request, timeout=40) as response:
            entry_script.write_bytes(response.read())
        entry_script.chmod(0o700)
        env = os.environ.copy()
        env.update({
            "TCPQUALITY_RAW_BASE": TCPQUALITY_RAW_BASE,
            "TOS_TIMEOUT": "15",
            "TOS_WARMUP": "5",
            "TERM": env.get("TERM") or "xterm",
        })
        process = subprocess.Popen(
            [
                "bash", str(entry_script), "--no-rootfs",
                "--only-speedtest", "--no-rank-upload",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            env=env,
            start_new_session=True,
        )
        try:
            output, _ = process.communicate(timeout=720)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.communicate(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
            return {
                **base,
                "status": "N/A",
                "reason": "三网单线程速度超过12分钟，已终止；建议稍后复测",
            }
        csv_path = newest_speed_csv(started, before)
        rows = parse_tcpquality_speed_csv(csv_path) if csv_path else []
        summary = annotate_speed_visuals(rows)
        complete = int(summary["complete"])
        status = "PASS" if complete == 9 else "PARTIAL" if rows else "N/A"
        reason = (
            f"北上广三网公网单线程完整 {complete}/9"
            if rows else "未取得可解析的三网单线程速度结果"
        )
        if process.returncode and not rows:
            tail = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", output or "")
            tail = " ".join(tail.splitlines()[-3:])[:220]
            reason += f"；上游退出码 {process.returncode}" + (
                f"：{tail}" if tail else ""
            )
        return {
            **base,
            "status": status,
            "reason": reason,
            "rows": rows,
            "summary": summary,
        }
    except Exception as exc:
        return {
            **base,
            "status": "N/A",
            "reason": f"测速辅助项异常 {type(exc).__name__}: {exc}",
        }
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def speed_ansi_color(visual: dict[str, Any]) -> str:
    palette = {
        "#38e87b": "\033[38;5;82m",
        "#8ee63f": "\033[38;5;118m",
        "#f5df4d": "\033[38;5;226m",
        "#ff9f43": "\033[38;5;208m",
        "#ff4d5e": "\033[38;5;196m",
    }
    return palette.get(str(visual.get("color")), GRAY)


def show_single_thread_speed(speed: dict[str, Any]) -> None:
    banner("SINGLE STREAM / 三网公网单线程速度", MAGENTA)
    field("测量边界", speed.get("boundary") or "N/A", GRAY)
    field(
        "状态",
        f"{speed.get('status', 'N/A')}｜{speed.get('reason', 'N/A')}",
        GREEN if speed.get("status") == "PASS" else YELLOW,
    )
    rows = speed.get("rows") or []
    if not rows:
        return
    current_region = ""
    for row in rows:
        region = str(row.get("region") or "N/A")
        if region != current_region:
            print()
            print(MAGENTA + f"  {region}" + RESET)
            print(
                GRAY
                + f"  {'地区':<14}{'回程重传':>12}{'回程速度／百分位':>25}"
                + f"{'去程速度／百分位':>25}"
                + RESET
            )
            current_region = region
        retrans = row.get("returnRetransmits")
        rv = row.get("returnVisual") or {}
        fv = row.get("forwardVisual") or {}
        retrans_text = (
            "N/A" if retrans is None
            else f"{int(retrans)}({(row.get('retransVisual') or {}).get('band', 'N/A')})"
        )
        return_text = (
            "N/A" if not rv.get("measured")
            else f"{rv['mbps']:.1f}M／{rv['relativePercentile']}%"
        )
        forward_text = (
            "N/A" if not fv.get("measured")
            else f"{fv['mbps']:.1f}M／{fv['relativePercentile']}%"
        )
        print(
            CARRIER_COLOR.get(str(row.get("carrier")), WHITE)
            + f"  {CARRIER_MARK.get(str(row.get('carrier')), '')} "
            + f"{str(row.get('label') or 'N/A'):<9}"
            + speed_ansi_color(row.get("retransVisual") or {})
            + f"{retrans_text:>12}"
            + speed_ansi_color(rv)
            + f"{return_text:>25}"
            + speed_ansi_color(fv)
            + f"{forward_text:>25}"
            + RESET
        )
    summary = speed.get("summary") or {}
    field(
        "吞吐摘要",
        f"完整 {summary.get('complete', 0)}/9｜"
        f"回程 AVG {summary.get('returnAvgMbps', 'N/A')} Mbps｜"
        f"去程 AVG {summary.get('forwardAvgMbps', 'N/A')} Mbps｜"
        f"高重传 {summary.get('highRetransmitRows', 0)} 组",
        CYAN,
    )


def build_improvements(
    grades: list[dict[str, Any]],
    forward: list[dict[str, Any]],
    returns: list[dict[str, Any]],
    speed: dict[str, Any],
) -> list[str]:
    notes: list[str] = []
    incomplete = [
        CARRIER_NAME[item["carrier"]]
        for item in grades if not item.get("matrixComplete")
    ]
    if incomplete:
        notes.append(
            f"{'、'.join(incomplete)}指定省份矩阵未完整；"
            "应补真实省份探针或导入中国本地端证据，全国参考不得代替省份结论。"
        )

    mixed = [
        CARRIER_NAME[item["carrier"]]
        for item in grades
        if "混合" in str(item.get("forwardRoute"))
        or "混合" in str(item.get("returnRoute"))
    ]
    if mixed:
        notes.append(
            f"{'、'.join(mixed)}存在地区或协议路径混合；"
            "建议在闲时与晚高峰各跑一次，确认是否为动态调度。"
        )

    high_latency = [
        item for item in forward + returns
        if isinstance(item.get("stats", {}).get("p95"), (int, float))
        and float(item["stats"]["p95"]) >= 200
    ]
    if high_latency:
        labels = "、".join(
            f"{CARRIER_NAME[item['carrier']]}{item.get('region') or item.get('city')}"
            for item in high_latency[:4]
        )
        notes.append(f"{labels} P95 已达 200 ms 以上，应优先检查跨境绕路或晚高峰拥塞。")

    lossy = [
        item for item in returns
        if isinstance(item.get("stats", {}).get("loss"), (int, float))
        and float(item["stats"]["loss"]) > 0
    ]
    if lossy:
        labels = "、".join(
            f"{CARRIER_NAME[item['carrier']]}{item.get('city')}" for item in lossy[:4]
        )
        notes.append(f"{labels}出现 TCP 连接失败；需分时段复测，不能只看单次 traceroute。")

    if not speed.get("enabled"):
        notes.append(
            "本次未执行单线程吞吐；如需核对三网实际速度与重传，请使用 --speed，"
            "并注意测速会消耗流量。"
        )
    else:
        rows = speed.get("rows") or []
        complete = [row for row in rows if row.get("status") == "PASS"]
        if len(complete) < 9:
            notes.append(
                f"北上广三网单线程只完整取得 {len(complete)}/9；"
                "N/A／PARTIAL 不按 0 Mbps 计，应换时段复测。"
            )
        slow = [
            row for row in complete
            if min(float(row["returnMbps"]), float(row["forwardMbps"])) < 50
        ]
        if slow:
            labels = "、".join(str(row["label"]) for row in slow[:4])
            notes.append(
                f"{labels}至少一个方向低于 50 Mbps；"
                "优先对照线路带宽上限、晚高峰与单线程拥塞。"
            )
        high_retrans = [
            row for row in complete
            if isinstance(row.get("returnRetransmits"), (int, float))
            and int(row["returnRetransmits"]) >= 1000
        ]
        if high_retrans:
            labels = "、".join(str(row["label"]) for row in high_retrans[:4])
            notes.append(
                f"{labels}回程重传达到 1000 次以上；"
                "建议重点检查 VPS→中国方向拥塞、限速与跨境链路波动。"
            )
        asymmetric = [
            row for row in complete
            if max(float(row["returnMbps"]), float(row["forwardMbps"]))
            / max(1.0, min(float(row["returnMbps"]), float(row["forwardMbps"])))
            >= 3
        ]
        if asymmetric:
            labels = "、".join(str(row["label"]) for row in asymmetric[:4])
            notes.append(
                f"{labels}去回程单线程速度相差 3 倍以上；"
                "应按方向分别判断，不能用较快一侧代表双向能力。"
            )

    if not notes:
        notes.append(
            "本次线路、延迟、TCP 成功率与单线程吞吐未见明显异常；"
            "建议保留闲时和晚高峰两份报告作对照。"
        )
    return notes


def public_ip() -> tuple[str, str]:
    for url in ("https://api.ipify.org?format=json", "https://ipwho.is/"):
        try:
            data = http_json(url, timeout=10)
            ip = str(data.get("ip", ""))
            identity = ""
            if "connection" in data:
                connection = data.get("connection") or {}
                identity = " ".join(str(connection.get(k, "")) for k in ("org", "isp", "asn")).strip()
            if valid_public_ipv4(ip):
                return ip, identity
        except Exception:
            pass
    return "", "公网出口识别失败"


GLOBALPING_SEARCH_CACHE: dict[
    tuple[str, int, str, int], tuple[list[dict[str, Any]], str]
] = {}
GLOBALPING_NATIONAL_POOL_CACHE: dict[
    tuple[str, int, str], tuple[list[dict[str, Any]], list[str]]
] = {}
GLOBALPING_NATIONAL_USED: dict[tuple[str, int, str], set[str]] = {}


def globalping_directed_results(
    target: str, port: int, magic_value: str, limit: int = 1
) -> tuple[list[dict[str, Any]], str]:
    """Request exactly one Globalping location condition.

    Globalping treats every item in ``locations`` as a required probe selection,
    not as an OR-list. RC4.2.8 bundled ISP and ASN alternatives in one request;
    one unavailable alternative could therefore reject the whole measurement.
    """
    cache_key = (target, port, magic_value, limit)
    if cache_key in GLOBALPING_SEARCH_CACHE:
        return GLOBALPING_SEARCH_CACHE[cache_key]

    payload = {
        "limit": limit,
        "target": target,
        "type": "traceroute",
        "locations": [{"magic": magic_value}],
        "measurementOptions": {"protocol": "TCP", "port": port},
    }
    try:
        created = http_json(GLOBALPING_API, "POST", payload)
        measurement_id = created.get("id")
        if not measurement_id:
            raise RuntimeError("Globalping 未返回 measurement id")
        measurement = None
        for _ in range(36):
            time.sleep(0.8)
            measurement = http_json(f"{GLOBALPING_API}/{measurement_id}")
            if measurement.get("status") == "finished":
                break
            if measurement.get("status") not in ("in-progress", None):
                raise RuntimeError(f"Globalping 状态 {measurement.get('status')}")
        if not measurement or measurement.get("status") != "finished":
            raise TimeoutError("等待省会远端结果超时")
        entries = [
            x for x in measurement.get("results", [])
            if x.get("result", {}).get("status") == "finished"
        ]
        summary = "、".join(
            (
                f"{x.get('probe', {}).get('city', '未知城市')} "
                f"AS{x.get('probe', {}).get('asn', 0)} "
                f"{x.get('probe', {}).get('network', '未知网络')}"
            )
            for x in entries
        ) or "没有返回可用探针"
        GLOBALPING_SEARCH_CACHE[cache_key] = (entries, summary)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        if exc.code == 422 and "no_probes_found" in detail:
            message = f"{magic_value} 无在线探针（Globalping no_probes_found）"
        else:
            message = f"Globalping HTTP {exc.code}｜{detail[:180]}"
        GLOBALPING_SEARCH_CACHE[cache_key] = ([], message)
    except Exception as exc:
        GLOBALPING_SEARCH_CACHE[cache_key] = (
            [], f"Globalping {type(exc).__name__}｜{exc}"
        )
    return GLOBALPING_SEARCH_CACHE[cache_key]


def probe_fingerprint(entry: dict[str, Any]) -> str:
    probe = entry.get("probe", {})
    return "|".join((
        str(probe.get("country") or "").upper(),
        normalize_city(str(probe.get("state") or "")),
        normalize_city(str(probe.get("city") or "")),
        str(probe.get("asn") or 0),
        str(probe.get("network") or "").strip().lower(),
    ))


def actual_region_for_probe(entry: dict[str, Any]) -> str:
    probe = entry.get("probe", {})
    actual_city = normalize_city(str(probe.get("city") or ""))
    for region, cities in FORWARD_PROVINCE_CITIES.items():
        if actual_city in {normalize_city(city) for city in cities}:
            return region
    return ""


def globalping_national_pool(
    target: str, port: int, carrier: str
) -> tuple[list[dict[str, Any]], list[str]]:
    """Build one shared China/carrier snapshot for both 18- and 36-group modes."""
    cache_key = (target, port, carrier)
    if cache_key in GLOBALPING_NATIONAL_POOL_CACHE:
        return GLOBALPING_NATIONAL_POOL_CACHE[cache_key]

    attempts: list[str] = []
    collected: dict[str, dict[str, Any]] = {}
    magic_values = [f"China+{FORWARD_ISP_MAGIC[carrier]}"]
    magic_values.extend(
        f"China+AS{asn}" for asn in FORWARD_NATIONAL_ASNS[carrier]
    )
    for magic_value in magic_values:
        entries, availability = globalping_directed_results(
            target, port, magic_value, NATIONAL_PROBE_LIMIT
        )
        attempts.append(f"{magic_value}：{availability}")
        for entry in entries:
            probe = entry.get("probe", {})
            if (
                str(probe.get("country") or "").upper() == "CN"
                and probe_matches_carrier(probe, carrier)
            ):
                collected.setdefault(probe_fingerprint(entry), entry)

    pool = list(collected.values())
    pool.sort(key=lambda entry: (
        "eyeball-network" not in (entry.get("probe", {}).get("tags") or []),
        str(entry.get("probe", {}).get("city") or ""),
        int(entry.get("probe", {}).get("asn") or 0),
    ))
    GLOBALPING_NATIONAL_POOL_CACHE[cache_key] = (pool, attempts)
    return GLOBALPING_NATIONAL_POOL_CACHE[cache_key]


def choose_national_candidate(
    pool: list[dict[str, Any]], carrier: str, region: str, used: set[str]
) -> tuple[dict[str, Any] | None, bool]:
    expected_asns = set(FORWARD_REGION_ASNS[carrier][region])

    def candidate_rank(entry: dict[str, Any]) -> tuple[Any, ...]:
        probe = entry.get("probe", {})
        fingerprint = probe_fingerprint(entry)
        actual_region = actual_region_for_probe(entry)
        reserved_for_other_region = (
            bool(actual_region)
            and actual_region != region
            and actual_region in ACTIVE_REGION_NAMES
        )
        return (
            actual_region != region,
            reserved_for_other_region,
            fingerprint in used,
            int(probe.get("asn") or 0) not in expected_asns,
            "eyeball-network" not in (probe.get("tags") or []),
            str(probe.get("city") or ""),
            fingerprint,
        )

    if not pool:
        return None, False
    entry = min(pool, key=candidate_rank)
    fingerprint = probe_fingerprint(entry)
    actual_region = actual_region_for_probe(entry)
    reserved_for_other_region = (
        bool(actual_region)
        and actual_region != region
        and actual_region in ACTIVE_REGION_NAMES
    )
    reused = fingerprint in used or reserved_for_other_region
    used.add(fingerprint)
    return entry, reused


def select_national_candidate(
    target: str, port: int, carrier: str, region: str
) -> tuple[dict[str, Any] | None, bool, list[str]]:
    pool, attempts = globalping_national_pool(target, port, carrier)
    used_key = (target, port, carrier)
    used = GLOBALPING_NATIONAL_USED.setdefault(used_key, set())
    entry, reused = choose_national_candidate(pool, carrier, region, used)
    return entry, reused, attempts


def directed_magic_values(city: str, carrier: str, region: str) -> list[str]:
    values = [f"{city}+{FORWARD_ISP_MAGIC[carrier]}"]
    values.extend(
        f"{city}+AS{asn}" for asn in FORWARD_REGION_ASNS[carrier][region]
    )
    return values


def globalping_trace(target: str, port: int, carrier: str,
                     region: str, probe_city: str) -> dict[str, Any]:
    preferred_asn = FORWARD_ASN[carrier]
    attempted: list[str] = []
    availability_notes: list[str] = []
    candidates: list[dict[str, Any]] = []
    selected_city = ""
    selection_scope = ""
    province_cities = FORWARD_PROVINCE_CITIES[region]
    for city_index, candidate_city in enumerate(province_cities):
        magic_values = directed_magic_values(candidate_city, carrier, region)
        for magic_value in magic_values:
            attempted.append(magic_value)
            entries, availability = globalping_directed_results(
                target, port, magic_value
            )
            availability_notes.append(f"{magic_value}：{availability}")
            candidates = [
                entry for entry in entries
                if (
                    normalize_city(str(entry.get("probe", {}).get("city") or ""))
                    == normalize_city(candidate_city)
                    and probe_matches_carrier(entry.get("probe", {}), carrier)
                )
            ]
            if candidates:
                selected_city = candidate_city
                selection_scope = (
                    "CAPITAL" if city_index == 0 else "PROVINCE_FALLBACK"
                )
                break
        if candidates:
            break
    national_reused = False
    # 同省缺探针时，RC4.2.11 不再用 limit=1 的首个全国探针重复填满矩阵。
    # 一次收集运营商名称及各省网 ASN 的共享快照，再按地区优先级分配。
    if not candidates:
        national_entry, national_reused, national_notes = select_national_candidate(
            target, port, carrier, region
        )
        availability_notes.extend(national_notes)
        if national_entry:
            candidates = [national_entry]
            actual_region = actual_region_for_probe(national_entry)
            if actual_region == region:
                actual_city = str(
                    national_entry.get("probe", {}).get("city") or ""
                )
                selected_city = actual_city
                selection_scope = (
                    "CAPITAL_POOL_DISCOVERY"
                    if normalize_city(actual_city) == normalize_city(probe_city)
                    else "PROVINCE_POOL_DISCOVERY"
                )
            else:
                selection_scope = (
                    "NATIONAL_SHARED_REFERENCE"
                    if national_reused else "NATIONAL_CARRIER_REFERENCE"
                )
    candidates.sort(key=lambda entry: (
        int(entry.get("probe", {}).get("asn") or 0) != preferred_asn,
        "eyeball-network" not in (entry.get("probe", {}).get("tags") or []),
    ))
    entry = candidates[0] if candidates else None
    if not entry:
        empty = stats([], 0, loss_valid=False, metric="TCP traceroute RTT（测点不可用）")
        return {
            "carrier": carrier, "region": region, "requestedCity": probe_city,
            "access": f"{CAPITALS.get(region, region)}｜{CARRIER_NAME[carrier]}",
            "actualProbeCity": "",
            "selectionScope": "NO_PROBE",
            "probeHealth": "NOT-AVAILABLE｜省会及同省当前无该运营商在线测点",
            "verified": False, "regionalVerified": False,
            "routeHops": None, "timeoutHops": None,
            "route": "", "class": "省会测点不可用", "rank": 0,
            "evidence": (
                f"已先定向查找 {CAPITALS.get(region, region)}，再查同省候选城市；"
                f"并尝试中国境内同运营商全国参考；仍未找到{CARRIER_NAME[carrier]}接入网。"
                f"尝试条件：{'、'.join(attempted)}。"
                f"返回摘要：{'；'.join(availability_notes)}。"
                "本组没有可用证据，不参与评分。"
            ),
            "targetReached": False,
            "reachability": "NOT-TESTED｜无探针，不代表入口不通",
            "stats": asdict(empty), "score": 0, "stars": "☆☆☆☆☆",
        }

    probe = entry.get("probe", {})
    route_lines: list[str] = []
    last_timings: list[float] = []
    target_timings: list[float] = []
    target_reached = False
    hop_entries = entry.get("result", {}).get("hops", [])
    visible_hops = 0
    for index, hop in enumerate(hop_entries, 1):
        ip = str(hop.get("resolvedAddress") or "")
        hostname = str(hop.get("resolvedHostname") or "")
        timings = [
            float(x["rtt"]) for x in hop.get("timings", [])
            if x.get("rtt") is not None
        ]
        if timings:
            last_timings = timings
        if ip or hostname or timings:
            visible_hops += 1
        if ip == target:
            target_reached = True
            target_timings = timings
        rtt_text = "  ".join(f"{x:.1f} ms" for x in timings) if timings else "*  *  *"
        asn_text = origin_asn(ip)
        identity = " ".join(x for x in (ip, asn_text, hostname) if x)
        route_lines.append(f"{index:2d}  {identity:<42} {rtt_text}")
    route = "\n".join(route_lines) or str(entry.get("result", {}).get("rawOutput", ""))
    route = enrich_route(route)
    route_class, rank, evidence = classify(carrier, route, "Forward")
    source_asn = int(probe.get("asn") or 0)
    actual_city = str(probe.get("city") or "")
    carrier_verified = probe_matches_carrier(probe, carrier)
    regional_verified = not selection_scope.startswith("NATIONAL_")
    city_verified = (
        normalize_city(actual_city) == normalize_city(selected_city)
        if regional_verified else False
    )
    verified = carrier_verified and (city_verified or not regional_verified)
    access = (
        f"{actual_city}, {probe.get('country', '')}｜"
        f"{probe.get('network', '')}｜AS{source_asn}"
    )
    route_timings = target_timings or last_timings
    result_stats = stats(
        route_timings, len(route_timings), loss_valid=False,
        metric="TCP traceroute RTT（不作为业务丢包）"
    )
    # 探针身份正确但没有到达入口时属于一次真实失败，必须以 0 分计入
    # 已执行样本；不能仅凭沿途骨干标签给出线路质量分。
    value = score(rank, result_stats) if verified and target_reached else 0
    if selection_scope in {"CAPITAL", "CAPITAL_POOL_DISCOVERY"}:
        health = f"ONLINE-CAPITAL｜省会直测｜AS{source_asn}"
        scope_note = (
            f"省会 {CAPITALS.get(region, region)} 探针命中。"
            + (
                "该探针由共享全国快照发现并按实际城市核验。"
                if selection_scope == "CAPITAL_POOL_DISCOVERY" else ""
            )
        )
    elif selection_scope in {"PROVINCE_FALLBACK", "PROVINCE_POOL_DISCOVERY"}:
        health = f"ONLINE-PROVINCE-FALLBACK｜同省 {actual_city}｜AS{source_asn}"
        scope_note = (
            f"省会 {CAPITALS.get(region, region)} 无可用探针，"
            f"按实际城市核验退到同省 {actual_city}；未跨省。"
        )
    else:
        health = (
            f"ONLINE-NATIONAL-SHARED-REFERENCE｜复用全国参考 {actual_city}｜AS{source_asn}"
            if national_reused
            else f"ONLINE-NATIONAL-REFERENCE｜全国同运营商 {actual_city}｜AS{source_asn}"
        )
        scope_note = (
            f"{CAPITALS.get(region, region)}及同省无在线探针；"
            f"退到中国境内{CARRIER_NAME[carrier]} {actual_city} 作为全国参考。"
            "该结果只证明同运营商网络到入口的线路与可达性，不代表请求省份。"
            + (
                "当前共享池唯一探针已用于其他地区，本项为复用参考，不重复计入参考覆盖。"
                if national_reused else ""
            )
        )
    evidence = scope_note + evidence
    if source_asn != preferred_asn:
        evidence = (
            f"测点健康检查通过：实际为{CARRIER_NAME[carrier]}省级接入网 AS{source_asn}，"
            f"不是骨干过滤 ASN AS{preferred_asn}；线路等级仍依据 traceroute 判定。"
        ) + evidence
    return {
        "carrier": carrier, "region": region, "requestedCity": probe_city,
        "actualProbeCity": actual_city, "selectionScope": selection_scope,
        "sourceAsn": source_asn, "nationalProbeReused": national_reused,
        "probeFingerprint": probe_fingerprint(entry),
        "regionalVerified": regional_verified,
        "routeHops": visible_hops,
        "timeoutHops": max(0, len(hop_entries) - visible_hops),
        "access": access, "probeHealth": health, "verified": verified,
        "route": route, "class": route_class, "rank": rank,
        "evidence": evidence, "targetReached": target_reached,
        "reachability": (
            (
                "PASS｜指定地区外部 TCP traceroute 到达入口"
                if regional_verified
                else "REFERENCE-PASS｜全国同运营商 TCP traceroute 到达入口"
            )
            if target_reached
            else "INCONCLUSIVE｜未显示终点，不等于端口关闭"
        ),
        "stats": asdict(result_stats), "score": value, "stars": stars(value),
    }


def load_client_forward_evidence(
    path_text: str, target: str, port: int
) -> tuple[dict[tuple[str, str], dict[str, Any]], str]:
    """Load real China-client -> target evidence without inventing remote probes."""
    if not path_text:
        return {}, "未提供中国本地端证据｜缺项使用 Globalping"
    path = Path(path_text).expanduser()
    if not path.is_file():
        return {}, f"证据文件不存在｜{path}"
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception as exc:
        return {}, f"证据文件解析失败｜{type(exc).__name__}: {exc}"
    if str(data.get("schema") or "") != "cn3-forward-evidence/v1":
        return {}, "证据格式不支持｜需要 cn3-forward-evidence/v1"
    evidence_target = str((data.get("target") or {}).get("host") or "").strip()
    evidence_port = parse_port((data.get("target") or {}).get("port"), 0)
    if evidence_target != target or evidence_port != port:
        return {}, (
            f"证据目标不匹配｜文件 {evidence_target}:{evidence_port}，"
            f"本次 {target}:{port}"
        )

    loaded: dict[tuple[str, str], dict[str, Any]] = {}
    rejected = 0
    for raw in data.get("samples") or []:
        carrier = str(raw.get("carrier") or "").upper()
        region = normalized_province(str(raw.get("region") or ""))
        if carrier not in CARRIER_NAME or region not in ACTIVE_REGION_NAMES:
            rejected += 1
            continue
        route = str(raw.get("route") or "").strip()
        route = enrich_route(route) if route else ""
        route_class, rank, route_evidence = classify(carrier, route, "Forward")
        tcp_values: list[float] = []
        for value in raw.get("tcpLatenciesMs") or []:
            try:
                tcp_values.append(float(value))
            except (TypeError, ValueError):
                continue
        attempts = max(
            int(raw.get("tcpAttempts") or 0),
            len(tcp_values),
        )
        target_reached = bool(raw.get("targetReached")) or bool(tcp_values)
        metric = f"中国本地端 TCP connect/{port}"
        result_stats = stats(
            tcp_values, attempts, loss_valid=attempts > 0, metric=metric
        )
        actual_city = str(raw.get("city") or CAPITALS[region])
        source_asn = str(raw.get("sourceAsn") or "待识别")
        source_network = str(raw.get("sourceNetwork") or CARRIER_NAME[carrier])
        evidence = (
            f"中国本地端主动实测：{actual_city} {source_network} {source_asn} → "
            f"{mask_ip(target)}:{port}。{route_evidence}"
        )
        # 中国本地端确实执行但业务端口未接通时，保留为失败样本并计 0 分。
        value = score(rank, result_stats) if target_reached else 0
        item = {
            "carrier": carrier, "region": region,
            "requestedCity": CAPITALS[region],
            "actualProbeCity": actual_city,
            "selectionScope": "CLIENT_ACTIVE",
            "regionalVerified": True,
            "access": f"{actual_city}｜{source_network}｜{source_asn}",
            "probeHealth": (
                f"ONLINE-CLIENT-ACTIVE｜TCP {len(tcp_values)}/{attempts}"
                if target_reached
                else f"CLIENT-ACTIVE-NO-CONNECT｜TCP 0/{attempts}"
            ),
            "routeHops": route_hop_count(route) if route else None,
            "timeoutHops": None,
            "verified": True,
            "route": route,
            "class": route_class,
            "rank": rank,
            "evidence": evidence,
            "targetReached": target_reached,
            "reachability": (
                "PASS｜中国本地端业务端口主动连接成功"
                if target_reached
                else "FAIL｜中国本地端业务端口主动连接未成功"
            ),
            "stats": asdict(result_stats),
            "score": value,
            "stars": stars(value),
            "evidenceSource": "CHINA_CLIENT_ACTIVE",
            "generated": str(raw.get("generated") or data.get("generated") or ""),
        }
        loaded[(carrier, region)] = item
    status = f"已载入真实去程 {len(loaded)}/{EXPECTED_PER_DIRECTION} 组"
    if rejected:
        status += f"｜拒绝无效记录 {rejected} 组"
    return loaded, status


def static_return_probe_pool() -> dict[str, list[dict[str, Any]]]:
    region_code = {
        "北京": "bj", "上海": "sh", "广东": "gd",
        "安徽": "ah", "江苏": "js", "浙江": "zj",
    }
    carrier_code = {"CT": "ct", "CU": "cu", "CM": "cm"}
    return {
        carrier: [
            {"city": city, "host": host, "ip": "", "port": 443,
             "backupHost": (
                 f"{region_code[city]}-{carrier_code[carrier]}-v4.ip.zstaticcdn.com"
             ),
             "backupIp": "", "backupPort": 80,
             "nodeSource": "STATIC+NETQUALITY_FALLBACK"}
            for city, host in entries
        ]
        for carrier, entries in ACTIVE_PROBES.items()
    }


def normalized_province(value: str) -> str:
    text = str(value or "").strip()
    aliases = {"北京市": "北京", "上海市": "上海", "广东省": "广东",
               "安徽省": "安徽", "江苏省": "江苏", "浙江省": "浙江"}
    return aliases.get(text, text.removesuffix("省").removesuffix("市"))


def carrier_from_node_isp(value: str) -> str:
    text = str(value or "").strip().lower()
    if text == "ct" or "电信" in text or "telecom" in text or "chinanet" in text:
        return "CT"
    if text == "cu" or "联通" in text or "unicom" in text or "china169" in text:
        return "CU"
    if text == "cm" or "移动" in text or "mobile" in text or "cmnet" in text:
        return "CM"
    return ""


def parse_port(value: Any, default: int = 443) -> int:
    try:
        port = int(str(value or "").strip())
        return port if 1 <= port <= 65535 else default
    except (TypeError, ValueError):
        return default


def load_icmp_alternatives() -> tuple[dict[tuple[str, str], list[str]], str]:
    """Load oneclickvirt/backtrace-compatible same-province carrier fallbacks."""
    if SELF_TEST:
        return {}, "SELF-TEST"
    try:
        rows = http_json(ICMP_TARGETS_API, timeout=12)
        alternatives: dict[tuple[str, str], list[str]] = {}
        for row in rows if isinstance(rows, list) else []:
            if str(row.get("ip_version") or "") != "v4":
                continue
            city = normalized_province(str(row.get("province") or ""))
            carrier = carrier_from_node_isp(
                str(row.get("isp_code") or row.get("isp") or "")
            )
            if city not in ACTIVE_REGION_NAMES or carrier not in ACTIVE_PROBES:
                continue
            values = [
                value.strip() for value in str(row.get("ips") or "").split(",")
                if valid_public_ipv4(value.strip())
            ][:3]
            if values:
                alternatives[(carrier, city)] = values
        return alternatives, (
            f"oneclickvirt ICMP 备用 {len(alternatives)}/{EXPECTED_PER_DIRECTION} 组"
        )
    except Exception as exc:
        return {}, f"oneclickvirt ICMP 备用不可用｜{type(exc).__name__}"


def load_return_probe_pool() -> tuple[dict[str, list[dict[str, Any]]], str]:
    """Load province/carrier nodes with real TCP ports; retain static fallbacks."""
    pool = static_return_probe_pool()
    if SELF_TEST:
        return pool, "SELF-TEST｜静态离线样本"
    alternatives, alternative_status = load_icmp_alternatives()
    for carrier, entries in pool.items():
        for spec in entries:
            spec["alternativeIps"] = alternatives.get(
                (carrier, str(spec["city"])), []
            )
    try:
        body = http_text(TCPQUALITY_NODES_API, timeout=20)
        reader = csv.DictReader(io.StringIO(body), delimiter="\t")
        candidates: dict[tuple[str, str], list[dict[str, Any]]] = {}
        wanted = {
            city for entries in ACTIVE_PROBES.values() for city, _ in entries
        }
        for row in reader:
            if str(row.get("type") or "").strip().lower() != "cdn":
                continue
            if str(row.get("family") or "").strip() != "4":
                continue
            city = normalized_province(str(row.get("prov") or ""))
            carrier = carrier_from_node_isp(str(row.get("isp") or ""))
            fixed_ip = str(row.get("ip") or "").strip()
            if (
                city not in wanted or carrier not in ACTIVE_PROBES
                or not valid_public_ipv4(fixed_ip)
            ):
                continue
            spec = {
                "city": city, "host": str(row.get("host") or fixed_ip).strip(),
                "ip": fixed_ip, "port": parse_port(row.get("port"), 80),
                "backupHost": str(row.get("backup_host") or "").strip(),
                "backupIp": str(row.get("backup_ip") or "").strip(),
                "backupPort": parse_port(row.get("backup_port"), 80),
                "nodeSource": "TcpQuality getNodes",
                "alternativeIps": alternatives.get((carrier, city), []),
            }
            candidates.setdefault((carrier, city), []).append(spec)
        dynamic_count = 0
        missing: list[str] = []
        for carrier, static_entries in ACTIVE_PROBES.items():
            resolved: list[dict[str, Any]] = []
            for city, static_host in static_entries:
                items = candidates.get((carrier, city), [])
                if items:
                    resolved.append(items[0])
                    dynamic_count += 1
                else:
                    resolved.append(pool[carrier][len(resolved)])
                    missing.append(f"{carrier}-{city}")
            pool[carrier] = resolved
        status = (
            f"ONLINE｜动态节点 {dynamic_count}/{EXPECTED_PER_DIRECTION}｜"
            f"{alternative_status}"
        )
        if missing:
            status += f"｜静态回退 {len(missing)} 组"
        return pool, status
    except Exception as exc:
        return pool, (
            f"DEGRADED｜动态节点池不可用，{EXPECTED_PER_DIRECTION} 组使用静态回退｜"
            f"{alternative_status}｜{type(exc).__name__}: {exc}"
        )


def return_probe(carrier: str, city: str, spec: dict[str, Any]) -> dict[str, Any]:
    host = str(spec.get("host") or "")
    fixed_ip = str(spec.get("ip") or "")
    target_port = parse_port(spec.get("port"), 443)
    backup_host = str(spec.get("backupHost") or "")
    backup_ip = str(spec.get("backupIp") or "")
    backup_port = parse_port(spec.get("backupPort"), target_port)
    alternative_ips = [
        str(value) for value in (spec.get("alternativeIps") or [])
        if valid_public_ipv4(str(value))
    ][:3]
    node_source = str(spec.get("nodeSource") or "STATIC+NETQUALITY_FALLBACK")
    fallback_used = False
    primary_ip = fixed_ip if valid_public_ipv4(fixed_ip) else resolve_ipv4(host)
    selected_host, ip, selected_port = host, primary_ip, target_port
    precheck = tcp_samples(ip, selected_port, count=2, timeout=2.5) if ip else []
    if not precheck and (backup_host or valid_public_ipv4(backup_ip)):
        candidate_ip = backup_ip if valid_public_ipv4(backup_ip) else resolve_ipv4(backup_host)
        candidate_samples = tcp_samples(candidate_ip, backup_port, count=2, timeout=2.5) if candidate_ip else []
        if candidate_samples:
            selected_host = backup_host or candidate_ip
            ip, selected_port, precheck = candidate_ip, backup_port, candidate_samples
            fallback_used = True
    if not ip and alternative_ips:
        ip = alternative_ips[0]
        selected_host = ip
        node_source += "+ONECLICKVIRT_ICMP"
        fallback_used = True
    if not ip:
        result_stats = stats([], 0, loss_valid=False, metric="回程探针不可用（DNS／目标解析失败）")
        return {
            "carrier": carrier, "city": city, "host": host, "probeIp": "",
            "targetPort": selected_port, "nodeSource": node_source,
            "fallbackUsed": fallback_used,
            "probeHealth": "OFFLINE｜主备目标均不可用",
            "route": "", "routeHops": 0,
            "class": "回程探针不可用", "rank": 0,
            "evidence": "目标无法解析；本组不参与线路类型与综合分数判定",
            "reachability": "INCONCLUSIVE｜DNS／目标解析失败",
            "stats": asdict(result_stats), "score": 0, "stars": "☆☆☆☆☆",
        }

    if shutil.which("traceroute"):
        # 同时尝试 TCP/443、ICMP、UDP。先选择骨干证据等级最高的结果；
        # 等级相同时才比较回覆跳点，避免“跳数较多但丢失精品骨干证据”的
        # 路由覆盖真正命中 CN2／AS9929／CMIN2 的结果。
        route_candidates = [
            (
                f"TCP/{selected_port}",
                run(["traceroute", "-n", "-T", "-p", str(selected_port), "-q", "1",
                     "-w", "1", "-m", "25", ip], 35),
            ),
            (
                "ICMP",
                run(["traceroute", "-n", "-I", "-q", "1", "-w", "1",
                     "-m", "25", ip], 35),
            ),
            (
                "UDP",
                run(["traceroute", "-n", "-q", "1", "-w", "1",
                     "-m", "25", ip], 35),
            ),
        ]
        evaluated_candidates = []
        for transport, raw_route in route_candidates:
            enriched_route = enrich_route(raw_route)
            candidate_class, candidate_rank, candidate_evidence = classify(
                carrier, enriched_route, "Return"
            )
            evaluated_candidates.append((
                candidate_rank,
                route_hop_count(raw_route),
                transport,
                enriched_route,
                candidate_class,
                candidate_evidence,
            ))
        initial_best = max(
            evaluated_candidates, key=lambda candidate: (candidate[0], candidate[1])
        )
        if initial_best[0] <= 0:
            for alt_index, alt_ip in enumerate(alternative_ips, 1):
                if alt_ip == ip:
                    continue
                raw_route = run([
                    "traceroute", "-n", "-I", "-q", "1", "-w", "1",
                    "-m", "25", alt_ip,
                ], 35)
                enriched_route = enrich_route(raw_route)
                candidate_class, candidate_rank, candidate_evidence = classify(
                    carrier, enriched_route, "Return"
                )
                evaluated_candidates.append((
                    candidate_rank,
                    route_hop_count(raw_route),
                    f"ICMP/ONECLICKVIRT-ALT{alt_index}",
                    enriched_route,
                    candidate_class,
                    (
                        f"主目标三协议证据不足，切换同省同运营商 ICMP 备用 "
                        f"{alt_ip}。{candidate_evidence}"
                    ),
                ))
                if candidate_rank > 0:
                    break
        (
            rank, hop_count, probe_transport, route, route_class, evidence
        ) = max(evaluated_candidates, key=lambda candidate: (candidate[0], candidate[1]))
        observed_classes = sorted({
            candidate[4] for candidate in evaluated_candidates
            if candidate[0] > 0
        })
        observed_ranks = {candidate[0] for candidate in evaluated_candidates}
        if rank >= 4 and 2 in observed_ranks:
            original_class = route_class
            route_class = f"{original_class}／动态混合"
            rank = 3
            evidence = (
                f"多协议路由存在动态分歧：{'、'.join(observed_classes)}；"
                "按保守口径降为混合线路。"
            )
    elif shutil.which("tracepath"):
        route = run(["tracepath", "-n", "-m", "25", ip], 35)
        probe_transport = "TRACEPATH"
        observed_classes = []
    else:
        route = "TRACEROUTE_UNAVAILABLE"
        probe_transport = "UNAVAILABLE"
        observed_classes = []

    hop_count = route_hop_count(route)
    if hop_count == 0:
        result_stats = stats([], 0, loss_valid=False, metric="回程 traceroute 无有效跳点")
        return {
            "carrier": carrier, "city": city, "host": selected_host, "probeIp": ip,
            "targetPort": selected_port, "nodeSource": node_source,
            "fallbackUsed": fallback_used,
            "probeHealth": f"OFFLINE｜{probe_transport} 无回覆跳点",
            "route": route, "routeHops": 0,
            "class": "回程探针无有效路由", "rank": 0,
            "evidence": "traceroute 未取得任何有效回覆跳点；不等同 100% 业务丢包，本组不参与评分",
            "reachability": "INCONCLUSIVE｜无有效 traceroute 跳点",
            "stats": asdict(result_stats), "score": 0, "stars": "☆☆☆☆☆",
        }

    rtts = traceroute_rtts(route)
    if not shutil.which("traceroute"):
        route = enrich_route(route)
        route_class, rank, evidence = classify(carrier, route, "Return")
    connect_values = precheck + tcp_samples(
        ip, selected_port, count=max(0, 5 - len(precheck)), timeout=3.0
    )
    sample = rtts[-3:]
    result_stats = (
        stats(connect_values[:5], 5, loss_valid=True, metric=f"TCP connect/{selected_port}")
        if connect_values
        else stats(sample, len(sample), loss_valid=False,
                   metric="TCP traceroute RTT（端口未回应，不作为业务丢包）")
    )
    value = score(rank, result_stats)
    source_note = f"{node_source}｜{'已切备用' if fallback_used else '主节点'}｜TCP/{selected_port}"
    return {
        "carrier": carrier, "city": city, "host": selected_host, "probeIp": ip,
        "targetPort": selected_port, "nodeSource": node_source,
        "fallbackUsed": fallback_used,
        "probeHealth": f"ONLINE｜{source_note}｜{probe_transport}｜{hop_count} 跳回覆",
        "route": route, "routeHops": hop_count,
        "observedClasses": observed_classes,
        "class": route_class, "rank": rank, "evidence": evidence,
        "reachability": f"PASS｜取得 {hop_count} 个有效回程跳点",
        "stats": asdict(result_stats), "score": value, "stars": stars(value),
    }


def self_test_forward(carrier: str, region: str, probe_city: str) -> dict[str, Any]:
    routes = {
        "CT": "1 202.97.90.1 AS4134\n2 59.43.181.145 AS4809\n3 59.43.80.141 AS4809",
        "CU": "1 219.158.8.1 AS4837\n2 218.105.2.205 AS9929\n3 210.51.16.9 AS9929",
        "CM": "1 221.183.55.110 AS9808\n2 223.120.128.18 AS58807\n3 223.120.141.9 AS58807",
    }
    route_class, rank, evidence = classify(carrier, routes[carrier], "Forward")
    result_stats = stats(
        [136.2, 138.4, 139.1, 137.7, 140.2], 5,
        loss_valid=False, metric="TCP traceroute RTT（不作为业务丢包）"
    )
    value = score(rank, result_stats)
    return {
        "carrier": carrier, "region": region, "requestedCity": probe_city,
        "access": f"{region}离线样本｜AS{FORWARD_ASN[carrier]}", "verified": True,
        "routeHops": 3, "timeoutHops": 0,
        "route": routes[carrier], "class": route_class, "rank": rank, "evidence": evidence,
        "targetReached": True, "reachability": "PASS｜离线外部端口样本",
        "stats": asdict(result_stats), "score": value, "stars": stars(value),
    }


def self_test_return(carrier: str, city: str, host: str) -> dict[str, Any]:
    routes = {
        "CT": "1 59.43.181.145 AS4809\n2 59.43.80.141 AS4809\n3 202.97.110.74 AS4134",
        "CU": "1 218.105.2.205 AS9929\n2 210.51.16.9 AS9929\n3 219.158.16.81 AS4837",
        "CM": "1 223.120.128.18 AS58807\n2 223.120.141.9 AS58807\n3 221.183.55.110 AS9808",
    }
    route_class, rank, evidence = classify(carrier, routes[carrier], "Return")
    base = {"CT": 140, "CU": 150, "CM": 160}[carrier]
    result_stats = stats(
        [base + x for x in (0.2, 1.4, 2.1, 0.7, 1.8)], 5,
        metric="TCP connect"
    )
    value = score(rank, result_stats)
    return {
        "carrier": carrier, "city": city, "host": host, "probeIp": "SELF-TEST",
        "route": routes[carrier], "routeHops": 3,
        "class": route_class, "rank": rank, "evidence": evidence,
        "reachability": "PASS｜离线样本取得有效回程跳点",
        "stats": asdict(result_stats), "score": value, "stars": stars(value),
    }


def self_test_regressions() -> None:
    cases = [
        ("CT", "1 8.8.8.8 AS15169", "Forward", 0, "电信无骨干证据"),
        ("CU", "1 8.8.8.8 AS15169", "Return", 0, "联通无骨干证据"),
        ("CT", "1 202.97.10.1 AS4134", "Return", 0, "电信仅目的网投递"),
        ("CU", "1 219.158.10.1 AS4837", "Return", 0, "联通仅目的网投递"),
        (
            "CT",
            "1 59.43.181.145 AS4809\n2 59.43.80.141 AS4809\n3 202.97.10.1 AS4134",
            "Return",
            5,
            "电信 CN2 GIA",
        ),
        (
            "CU",
            "1 218.105.2.205 AS9929\n2 210.51.16.9 AS9929\n3 219.158.10.1 AS4837",
            "Return",
            5,
            "联通 AS9929",
        ),
        (
            "CT",
            "1 59.43.181.145 AS4809\n2 202.97.10.1 AS4134",
            "Return",
            3,
            "单跳 CN2 不得判 GIA",
        ),
        (
            "CT",
            "1 59.43.181.145 AS4809\n2 59.43.80.141 AS4809\n"
            "3 202.97.10.1 AS4134\n4 202.97.20.1 AS4134",
            "Return",
            3,
            "多跳 163 交付不得判纯 GIA",
        ),
    ]
    for carrier, route, direction, expected_rank, label in cases:
        _, actual_rank, _ = classify(carrier, route, direction)
        if actual_rank != expected_rank:
            raise AssertionError(
                f"{label} 回归失败：期望 rank={expected_rank}，实际 rank={actual_rank}"
            )

    tags, note = backbone_labels(
        "CU", "INCONCLUSIVE｜仅见联通目的网", "1 219.158.10.1 AS4837"
    )
    if tags != ["AS4837｜China169 联通普通骨干"] or "交付网" not in note:
        raise AssertionError("联通目的网标签回归失败：必须显示 AS4837 标签与中文交付网注释")

    premium_tags, premium_note = backbone_labels(
        "CU", "AS9929（CUII）",
        "1 218.105.2.205 AS9929\n2 210.51.16.9 AS9929\n3 219.158.10.1 AS4837"
    )
    if "AS9929｜CUII 联通精品骨干" not in premium_tags or "精品路由" not in premium_note:
        raise AssertionError("联通 AS9929 标签回归失败")

    if normalize_city("Nanjing") != normalize_city("nanjing"):
        raise AssertionError("省会城市标准化回归失败")

    reference_forwards = []
    reference_returns = []
    for region, probe_city in FORWARD_REGIONS:
        item = self_test_forward("CT", region, probe_city)
        item["selectionScope"] = "NATIONAL_CARRIER_REFERENCE"
        item["regionalVerified"] = False
        reference_forwards.append(item)
        reference_returns.append(
            self_test_return("CT", region, f"reference-{region}")
        )
    reference_grade = grade("CT", reference_forwards, reference_returns)
    if reference_grade["bidirectionalPremium"]:
        raise AssertionError("全国同运营商参考不得触发精品双程 PASS")
    if reference_grade["forwardReference"] != len(FORWARD_REGIONS):
        raise AssertionError("全国同运营商参考计数回归失败")
    if reference_grade["routeGrade"]["label"] != "单向优化／混合":
        raise AssertionError("全国参考不得把样本级精品证据升级为完整双程精品")
    if not national_reference({"selectionScope": "NATIONAL_SHARED_REFERENCE"}):
        raise AssertionError("共享全国参考范围识别回归失败")

    one_reference_many_rows: list[dict[str, Any]] = []
    for index, (region, probe_city) in enumerate(FORWARD_REGIONS):
        item = self_test_forward("CU", region, probe_city)
        item["selectionScope"] = (
            "NATIONAL_CARRIER_REFERENCE"
            if index == 0 else "NATIONAL_SHARED_REFERENCE"
        )
        item["regionalVerified"] = False
        item["nationalProbeReused"] = index > 0
        item["probeFingerprint"] = "same-national-probe"
        one_reference_many_rows.append(item)
    no_duplicate_grade = grade("CU", one_reference_many_rows, [
        self_test_return("CU", region, f"reference-{region}")
        for region, _ in FORWARD_REGIONS
    ])
    if no_duplicate_grade["forwardReference"] != 1:
        raise AssertionError("同一全国探针不得重复计入独立参考")
    if no_duplicate_grade["forwardSharedReference"] != len(FORWARD_REGIONS) - 1:
        raise AssertionError("复用全国探针计数回归失败")
    if no_duplicate_grade["forwardValid"] != f"1/{len(FORWARD_REGIONS)}":
        raise AssertionError("复用全国探针不得拉高去程有效覆盖")
    if no_duplicate_grade["forwardMeasured"] != f"1/{len(FORWARD_REGIONS)}":
        raise AssertionError("复用全国探针不得拉高去程测量覆盖")
    if no_duplicate_grade["matrixStatus"] != "PARTIAL":
        raise AssertionError("存在复用探针时矩阵必须显示 PARTIAL")
    if no_duplicate_grade["sampleScore"] <= 0:
        raise AssertionError("部分矩阵仍应保留有效样本表现")

    # NOT-TESTED 完全排除；独立探针实际执行但未接通则计为 0 分失败。
    partial_forwards = [
        self_test_forward("CT", region, probe_city)
        for region, probe_city in FORWARD_REGIONS
    ]
    partial_forwards[-1] = {
        **partial_forwards[-1],
        "selectionScope": "NO_PROBE",
        "verified": False,
        "targetReached": False,
        "rank": 0,
        "score": 0,
    }
    full_returns = [
        self_test_return("CT", region, f"complete-{region}")
        for region, _ in FORWARD_REGIONS
    ]
    partial_grade = grade("CT", partial_forwards, full_returns)
    if partial_grade["forwardMeasured"] != f"{len(FORWARD_REGIONS) - 1}/{len(FORWARD_REGIONS)}":
        raise AssertionError("NOT-TESTED 排除测量覆盖回归失败")
    if partial_grade["matrixStatus"] != "PARTIAL":
        raise AssertionError("NOT-TESTED 存在时矩阵必须显示 PARTIAL")

    failed_forwards = [
        self_test_forward("CT", region, probe_city)
        for region, probe_city in FORWARD_REGIONS
    ]
    failed_forwards[-1] = {
        **failed_forwards[-1],
        "targetReached": False,
        "reachability": "FAIL｜离线失败样本",
        "score": 0,
        "stars": "☆☆☆☆☆",
    }
    failure_grade = grade("CT", failed_forwards, full_returns)
    if (
        not failure_grade["matrixComplete"]
        or failure_grade["matrixStatus"] != "COMPLETE"
    ):
        raise AssertionError("独立探针已执行的失败样本仍应完成矩阵")
    if failure_grade["forwardFailures"] != 1:
        raise AssertionError("独立探针未接通必须计为一次真实失败")
    if failure_grade["forwardScore"] >= reference_grade["forwardScore"]:
        raise AssertionError("真实失败样本必须以 0 分拉低有效样本表现")

    ordinary_forwards = [
        {
            **self_test_forward("CU", region, probe_city),
            "class": "AS4837 普通联通",
            "rank": 2,
        }
        for region, probe_city in FORWARD_REGIONS
    ]
    ordinary_returns = [
        {
            **self_test_return("CU", region, f"ordinary-{region}"),
            "class": "AS4837 普通联通",
            "rank": 2,
        }
        for region, _ in FORWARD_REGIONS
    ]
    if grade("CU", ordinary_forwards, ordinary_returns)["routeGrade"]["label"] != "普通公网":
        raise AssertionError("普通公网线路等级回归失败")

    mixed_returns = [
        {
            **self_test_return("CU", region, f"mixed-{region}"),
            "class": "AS4837 普通联通",
            "rank": 2,
        }
        for region, _ in FORWARD_REGIONS
    ]
    if grade(
        "CU",
        [self_test_forward("CU", region, city) for region, city in FORWARD_REGIONS],
        mixed_returns,
    )["routeGrade"]["label"] != "单向优化／混合":
        raise AssertionError("单向优化／混合线路等级回归失败")

    insufficient_forwards = [
        {
            **self_test_forward("CM", region, city),
            "class": "INCONCLUSIVE｜未见移动骨干",
            "rank": 0,
        }
        for region, city in FORWARD_REGIONS
    ]
    if grade(
        "CM",
        insufficient_forwards,
        [self_test_return("CM", region, f"unknown-{region}") for region, _ in FORWARD_REGIONS],
    )["routeGrade"]["label"] != "证据不足":
        raise AssertionError("证据不足线路等级回归失败")

    synthetic_pool = [
        {"probe": {"country": "CN", "city": city, "asn": asn,
                   "network": f"China Unicom {city}", "tags": ["eyeball-network"]}}
        for city, asn in (
            ("Beijing", 4808), ("Shanghai", 17621), ("Guangzhou", 17622),
            ("Hefei", 4837), ("Nanjing", 4837), ("Hangzhou", 17623),
        )
    ]
    if [actual_region_for_probe(x) for x in synthetic_pool] != [
        "北京", "上海", "广东", "安徽", "江苏", "浙江"
    ]:
        raise AssertionError("联通北上广共享探针池地区识别回归失败")
    if len({probe_fingerprint(x) for x in synthetic_pool}) != 6:
        raise AssertionError("共享探针池去重回归失败")
    default_used: set[str] = set()
    default_selected = [
        choose_national_candidate(synthetic_pool, "CU", region, default_used)[0]
        for region, _ in ALL_FORWARD_REGIONS[:3]
    ]
    extended_used: set[str] = set()
    extended_selected = [
        choose_national_candidate(synthetic_pool, "CU", region, extended_used)[0]
        for region, _ in ALL_FORWARD_REGIONS
    ]
    default_fingerprints = [probe_fingerprint(x or {}) for x in default_selected]
    extended_fingerprints = [probe_fingerprint(x or {}) for x in extended_selected[:3]]
    if default_fingerprints != extended_fingerprints:
        raise AssertionError("18／36 组共享探针池北上广分配一致性回归失败")
    if len(set(probe_fingerprint(x or {}) for x in extended_selected)) != 6:
        raise AssertionError("36 组共享探针池不得重复分配可用探针")
    # Globalping 每次返回顺序可能不同；三种顺序必须得到同一分配与计数。
    baseline = [
        probe_fingerprint(x or {}) for x in extended_selected
    ]
    for drift_pool in (
        list(reversed(synthetic_pool)),
        synthetic_pool[2:] + synthetic_pool[:2],
        synthetic_pool[::2] + synthetic_pool[1::2],
    ):
        drift_used: set[str] = set()
        drift_selected = [
            choose_national_candidate(drift_pool, "CU", region, drift_used)[0]
            for region, _ in ALL_FORWARD_REGIONS
        ]
        if [probe_fingerprint(x or {}) for x in drift_selected] != baseline:
            raise AssertionError("共享探针池返回顺序漂移不得改变 36 组分配")


def format_stats(data: dict[str, Any]) -> str:
    avg = data.get("avg")
    p95 = data.get("p95")
    jitter = data.get("jitter")
    loss = data.get("loss")
    loss_text = f"{loss}%" if loss is not None else "N/A（traceroute 不计丢包）"
    return (
        f"AVG {avg if avg is not None else 'N/A'} ms｜"
        f"P95 {p95 if p95 is not None else 'N/A'} ms｜"
        f"JITTER {jitter if jitter is not None else 'N/A'} ms｜LOSS {loss_text}"
    )


def latency_band(avg: float) -> tuple[str, int, str]:
    """Return an absolute RTT band, severity index and web colour."""
    if avg <= 80:
        return "≤80 ms", 0, "#38e87b"
    if avg <= 130:
        return "81–130 ms", 1, "#8ee63f"
    if avg <= 180:
        return "131–180 ms", 2, "#f5df4d"
    if avg <= 230:
        return "181–230 ms", 3, "#ff9f43"
    return ">230 ms", 4, "#ff4d5e"


def latency_visual_eligible(item: dict[str, Any], direction: str) -> tuple[bool, str]:
    avg = item.get("stats", {}).get("avg")
    if not isinstance(avg, (int, float)):
        return False, "未取得有效延迟"
    if direction == "Forward":
        if national_reference(item):
            return False, "仅全国参考，不冒充指定省份"
        if not item.get("verified") or item.get("selectionScope") == "NO_PROBE":
            return False, "未取得指定省份探针"
        if not item.get("targetReached"):
            return False, "已实测但目标未接通"
    elif not str(item.get("probeIp") or "").strip():
        return False, "未取得回程目标"
    return True, ""


def annotate_latency_visuals(
    forward: list[dict[str, Any]],
    returns: list[dict[str, Any]],
) -> dict[str, Any]:
    """Attach honest per-province RTT heat data without converting it to a score."""
    heatmap: dict[str, Any] = {
        "policy": "ROUTE_CLASS_FIRST｜AVG/P95 + RELATIVE_HEAT｜NO_SCORE",
        "legend": (
            "相对热度 0% 为本次同方向最快、100% 为最慢；"
            "颜色同时受绝对 RTT 区间约束，避免整组都慢时仍显示绿色。"
        ),
        "absoluteBands": [
            {"range": "≤80 ms", "color": "#38e87b"},
            {"range": "81–130 ms", "color": "#8ee63f"},
            {"range": "131–180 ms", "color": "#f5df4d"},
            {"range": "181–230 ms", "color": "#ff9f43"},
            {"range": ">230 ms", "color": "#ff4d5e"},
        ],
        "forward": [],
        "return": [],
    }
    for direction, items, key in (
        ("Forward", forward, "forward"),
        ("Return", returns, "return"),
    ):
        eligible: list[dict[str, Any]] = []
        for item in items:
            ok, reason = latency_visual_eligible(item, direction)
            if ok:
                eligible.append(item)
            else:
                item["latencyVisual"] = {
                    "measured": False,
                    "avgMs": item.get("stats", {}).get("avg"),
                    "p95Ms": item.get("stats", {}).get("p95"),
                    "relativeHeat": None,
                    "absoluteBand": "N/A",
                    "color": "#596579",
                    "reason": reason,
                }
        values = [float(x["stats"]["avg"]) for x in eligible]
        low = min(values) if values else 0.0
        high = max(values) if values else 0.0
        for item in eligible:
            avg = float(item["stats"]["avg"])
            relative_heat = (
                50 if math.isclose(low, high)
                else round((avg - low) * 100 / (high - low))
            )
            band, absolute_severity, absolute_color = latency_band(avg)
            relative_severity = min(4, max(0, relative_heat // 20))
            severity = max(absolute_severity, relative_severity)
            colors = ("#38e87b", "#8ee63f", "#f5df4d", "#ff9f43", "#ff4d5e")
            visual = {
                "measured": True,
                "avgMs": round(avg, 1),
                "p95Ms": item.get("stats", {}).get("p95"),
                "relativeHeat": relative_heat,
                "absoluteBand": band,
                "color": colors[severity],
                "absoluteColor": absolute_color,
                "reason": "",
            }
            item["latencyVisual"] = visual
        for item in items:
            region = (
                item.get("region", "中国")
                if direction == "Forward"
                else item.get("city", item.get("probeCapital", "中国"))
            )
            heatmap[key].append({
                "carrier": item["carrier"],
                "region": region,
                **item["latencyVisual"],
            })
    return heatmap


def latency_ansi_color(visual: dict[str, Any]) -> str:
    if not visual.get("measured"):
        return GRAY
    palette = {
        "#38e87b": "\033[38;5;82m",
        "#8ee63f": "\033[38;5;118m",
        "#f5df4d": "\033[38;5;226m",
        "#ff9f43": "\033[38;5;208m",
        "#ff4d5e": "\033[38;5;196m",
    }
    return palette.get(str(visual.get("color")), WHITE)


def latency_visual_text(visual: dict[str, Any], compact: bool = False) -> str:
    if not visual.get("measured"):
        return f"N/A｜{visual.get('reason', '未测')}"
    heat = int(visual.get("relativeHeat", 0))
    filled = min(10, max(1, math.ceil(heat / 10)))
    bar = "▰" * filled + "▱" * (10 - filled)
    if compact:
        return f"{visual['avgMs']}ms｜热度 {heat}% {bar}"
    return (
        f"AVG {visual['avgMs']} ms｜P95 {visual.get('p95Ms', 'N/A')} ms｜"
        f"相对热度 {heat}% {bar}｜绝对区间 {visual['absoluteBand']}"
    )


def show_latency_heatmap(
    forward: list[dict[str, Any]],
    returns: list[dict[str, Any]],
) -> None:
    banner("PROVINCE LATENCY / 各省实测延迟热图", MAGENTA)
    field(
        "图例",
        "0%＝本次同方向最快｜100%＝最慢｜颜色同时受绝对 RTT 区间约束",
        GRAY,
    )
    for carrier in ("CT", "CU", "CM"):
        banner(
            f"{carrier_label(carrier)}｜线路判定优先，延迟热度辅助",
            CARRIER_COLOR[carrier],
        )
        forward_by_region = {
            str(x.get("region")): x
            for x in forward if x["carrier"] == carrier
        }
        return_by_region = {
            str(x.get("city")): x
            for x in returns if x["carrier"] == carrier
        }
        for region, _ in FORWARD_REGIONS:
            f_visual = forward_by_region.get(region, {}).get(
                "latencyVisual", {"measured": False, "reason": "未测"}
            )
            r_visual = return_by_region.get(region, {}).get(
                "latencyVisual", {"measured": False, "reason": "未测"}
            )
            field(
                f"{region} 去程",
                latency_visual_text(f_visual),
                latency_ansi_color(f_visual),
            )
            field(
                f"{region} 回程",
                latency_visual_text(r_visual),
                latency_ansi_color(r_visual),
            )


def dedicated_line_assessment(target: str, port: int, exit_ip: str,
                              forward: list[dict[str, Any]]) -> dict[str, Any]:
    tested_all = [
        x for x in forward
        if x.get("verified") and x.get("selectionScope") != "NO_PROBE"
    ]
    tested: list[dict[str, Any]] = []
    seen_reference_probes: set[str] = set()
    for item in tested_all:
        if str(item.get("selectionScope", "")).startswith("NATIONAL_"):
            fingerprint = str(item.get("probeFingerprint") or "")
            if item.get("nationalProbeReused") or (
                fingerprint and fingerprint in seen_reference_probes
            ):
                continue
            if fingerprint:
                seen_reference_probes.add(fingerprint)
        tested.append(item)
    reached_samples = [
        f"{x['carrier']}-{x.get('region', '中国')}"
        for x in tested if x.get("targetReached")
    ]
    reached = sorted({x["carrier"] for x in tested if x.get("targetReached")})
    entry_asn = origin_asn(target)
    exit_asn = origin_asn(exit_ip) if valid_public_ipv4(exit_ip) else ""
    native_mode = target == exit_ip
    if reached_samples:
        port_status = (
            f"PASS｜已取得探针中 {len(reached_samples)}/{len(tested)} 组到达入口"
            f"｜独立证据覆盖 {len(tested)}/{len(forward)}"
        )
    elif tested:
        port_status = (
            f"INCONCLUSIVE｜已取得 {len(tested)}/{len(forward)} 组探针，"
            "但 traceroute 未显示终点；不能据此判定端口关闭"
        )
    else:
        port_status = "NOT-TESTED｜未取得去程探针；不能据此判定端口不通"
    return {
        "model": "VPS_NATIVE_PUBLIC" if native_mode else "NAT_FORWARDING",
        "topology": (
            "同一公网 VPS 原生双向测试"
            if native_mode else
            "中国入口端口映射／NAT → 出口 VPS"
        ),
        "entry": f"{mask_ip(target)}:{port}",
        "entryAsn": entry_asn or "ASN 未取得",
        "exit": mask_ip(exit_ip),
        "exitAsn": exit_asn or "ASN 未取得",
        "portStatus": port_status,
        "reachedBy": reached,
        "reachedSamples": reached_samples,
        "internalVisibility": (
            "NOT_APPLICABLE" if native_mode else "HIDDEN_BY_NAT"
        ),
        "internalVerdict": (
            "目标公网 IP 与脚本运行 VPS 的公网 IP 一致；本报告直接评估该 VPS "
            "对中国三网的公网友好度，不存在需要推测的前置入口或隐藏内段。"
            if native_mode else
            "入口到出口为端口映射／专线内部段，公共 traceroute 通常只看到中国入口，"
            "不能把隐藏段强判为 CN2、AS9929、CMIN2 或普通国际线路。"
        ),
    }


def representative_route(items: list[dict[str, Any]], direction: str) -> str:
    valid_items = [x for x in items if int(x.get("rank", 0)) > 0]
    if not valid_items:
        return f"{direction}未取得可判定测点（不参与线路评分）"
    unique = sorted({str(x["class"]) for x in valid_items})
    if len(unique) == 1:
        return unique[0]
    return f"多地区混合（{len(unique)} 类）"


def premium_route(carrier: str, item: dict[str, Any]) -> bool:
    route_class = str(item.get("class", ""))
    if carrier == "CT":
        return route_class in {"CN2 GIA", "CTG GIA"}
    if carrier == "CU":
        return route_class == "AS9929（CUII）"
    return route_class == "CMIN2（CMI2）"


def national_reference(item: dict[str, Any]) -> bool:
    return str(item.get("selectionScope", "")).startswith("NATIONAL_")


def route_evidence_kind(carrier: str, item: dict[str, Any]) -> str:
    """Reduce one route result to premium, mixed, ordinary or unknown evidence."""
    route_class = str(item.get("class", ""))
    if int(item.get("rank", 0)) <= 0 or route_class.startswith("INCONCLUSIVE"):
        return "UNKNOWN"
    if premium_route(carrier, item):
        return "PREMIUM"
    if "混合" in route_class or "GT" in route_class:
        return "MIXED"
    return "ORDINARY"


def carrier_route_grade(
    carrier: str,
    forward_items: list[dict[str, Any]],
    return_items: list[dict[str, Any]],
    bidirectional_premium: bool,
) -> dict[str, Any]:
    forward_kinds = [route_evidence_kind(carrier, item) for item in forward_items]
    return_kinds = [route_evidence_kind(carrier, item) for item in return_items]
    forward_known = [kind for kind in forward_kinds if kind != "UNKNOWN"]
    return_known = [kind for kind in return_kinds if kind != "UNKNOWN"]
    premium_count = forward_known.count("PREMIUM") + return_known.count("PREMIUM")
    mixed_count = forward_known.count("MIXED") + return_known.count("MIXED")
    ordinary_count = forward_known.count("ORDINARY") + return_known.count("ORDINARY")

    if bidirectional_premium:
        level = "BIDIRECTIONAL_PREMIUM"
        label = "双程精品"
        reason = "指定地区去程与全部回程均命中该运营商精品骨干，且没有回落普通骨干。"
    elif not forward_known or not return_known:
        level = "EVIDENCE_INSUFFICIENT"
        label = "证据不足"
        missing = []
        if not forward_known:
            missing.append("去程")
        if not return_known:
            missing.append("回程")
        reason = (
            f"{'、'.join(missing)}未取得可复核骨干证据；"
            "低延迟、端口可达或单一目的网跳点不能替代线路判定。"
        )
    elif premium_count or mixed_count:
        level = "ONE_WAY_OPTIMIZED_OR_MIXED"
        label = "单向优化／混合"
        reason = (
            f"可见样本含精品 {premium_count}、混合 {mixed_count}、普通 {ordinary_count} 组；"
            "至少一方向未形成纯净且完整的双程精品链路。"
        )
    else:
        level = "ORDINARY_PUBLIC"
        label = "普通公网"
        reason = (
            f"去、回程已取得普通骨干证据，共 {ordinary_count} 组；"
            "未见足以升级为精品骨干的 ASN／特征跳点。"
        )

    return {
        "level": level,
        "label": label,
        "reason": reason,
        "forwardEvidence": {
            "premium": forward_kinds.count("PREMIUM"),
            "mixed": forward_kinds.count("MIXED"),
            "ordinary": forward_kinds.count("ORDINARY"),
            "unknown": forward_kinds.count("UNKNOWN"),
        },
        "returnEvidence": {
            "premium": return_kinds.count("PREMIUM"),
            "mixed": return_kinds.count("MIXED"),
            "ordinary": return_kinds.count("ORDINARY"),
            "unknown": return_kinds.count("UNKNOWN"),
        },
    }


def overall_route_grade(grades: list[dict[str, Any]]) -> dict[str, Any]:
    carrier_levels = [item["routeGrade"]["level"] for item in grades]
    carrier_labels = {
        item["carrier"]: item["routeGrade"]["label"] for item in grades
    }
    if carrier_levels and all(
        level == "BIDIRECTIONAL_PREMIUM" for level in carrier_levels
    ):
        level, label = "BIDIRECTIONAL_PREMIUM", "三网双程精品"
        reason = "电信、联通、移动均已取得完整双程精品骨干证据。"
    elif "EVIDENCE_INSUFFICIENT" in carrier_levels:
        level, label = "EVIDENCE_INSUFFICIENT", "证据不足"
        reason = "至少一个运营商缺少必要方向的可复核骨干证据，不能给三网整体升级。"
    elif carrier_levels and all(
        level == "ORDINARY_PUBLIC" for level in carrier_levels
    ):
        level, label = "ORDINARY_PUBLIC", "三网普通公网"
        reason = "电信、联通、移动去回程均只确认普通公网骨干。"
    else:
        level, label = "ONE_WAY_OPTIMIZED_OR_MIXED", "三网单向优化／混合"
        reason = "三网中存在单向精品、混合路由，或不同运营商线路等级不一致。"
    return {
        "overallLevel": level,
        "overallLabel": label,
        "reason": reason,
        "policy": "ASN／特征跳点证据优先；延迟、速度与丢包不用于推定精品等级。",
        "carrierLabels": carrier_labels,
    }


def grade(carrier: str, forwards: list[dict[str, Any]],
          returns: list[dict[str, Any]]) -> dict[str, Any]:
    forward_items = [x for x in forwards if x["carrier"] == carrier]
    return_items = [x for x in returns if x["carrier"] == carrier]

    # “完成矩阵”看的是每一格是否真正由独立探针执行，而不是该格最后
    # 是否判出精品线路。NO_PROBE 不算执行；全国探针复用只显示一次参考，
    # 不能重复填高覆盖率。真实执行但未到达／未取得路由则是 0 分失败样本。
    measured_forwards: list[dict[str, Any]] = []
    seen_reference_probes: set[str] = set()
    for item in forward_items:
        if not item.get("verified") or item.get("selectionScope") == "NO_PROBE":
            continue
        if national_reference(item):
            fingerprint = str(item.get("probeFingerprint") or "")
            if item.get("nationalProbeReused") or (
                fingerprint and fingerprint in seen_reference_probes
            ):
                continue
            if fingerprint:
                seen_reference_probes.add(fingerprint)
        measured_forwards.append(item)
    measured_returns = [
        x for x in return_items if bool(str(x.get("probeIp") or "").strip())
    ]

    reached_forwards = [
        x for x in measured_forwards
        if int(x.get("rank", 0)) > 0 and x.get("verified") and x.get("targetReached")
    ]
    regional_forwards = [
        x for x in reached_forwards if not national_reference(x)
    ]
    reference_forwards = [
        x for x in reached_forwards
        if national_reference(x) and not x.get("nationalProbeReused")
    ]
    shared_reference_forwards = [
        x for x in forward_items
        if (
            national_reference(x)
            and x.get("nationalProbeReused")
            and x.get("verified")
        )
    ]
    # valid_* 只用于路线类别与“可判定证据”统计；样本分数的分母使用所有
    # 已执行独立测量，因此真正执行但失败的格子会以 0 分进入平均值。
    valid_forwards = regional_forwards + reference_forwards
    valid_returns = [x for x in return_items if int(x.get("rank", 0)) > 0]
    forward_score = (
        round(statistics.mean(
            int(x.get("score", 0))
            if x.get("targetReached") and int(x.get("rank", 0)) > 0 else 0
            for x in measured_forwards
        ))
        if measured_forwards else 0
    )
    return_score = (
        round(statistics.mean(
            int(x.get("score", 0)) if int(x.get("rank", 0)) > 0 else 0
            for x in measured_returns
        ))
        if measured_returns else 0
    )
    if measured_forwards and measured_returns:
        sample_score = round(forward_score * 0.4 + return_score * 0.6)
    elif measured_returns:
        sample_score = return_score
    elif measured_forwards:
        sample_score = forward_score
    else:
        sample_score = 0

    regional_measured_forwards = [
        x for x in measured_forwards if not national_reference(x)
    ]
    matrix_complete = (
        len(regional_measured_forwards) == len(forward_items)
        and len(measured_returns) == len(return_items)
    )
    matrix_status = "COMPLETE" if matrix_complete else "PARTIAL"
    measurement_coverage = round(
        (len(measured_forwards) + len(measured_returns))
        / max(1, len(forward_items) + len(return_items)),
        3,
    )
    scorable_coverage = round(
        (len(valid_forwards) + len(valid_returns))
        / max(1, len(forward_items) + len(return_items)),
        3,
    )
    forward_failures = sum(
        1 for x in measured_forwards
        if not x.get("targetReached") or int(x.get("rank", 0)) <= 0
    )
    return_failures = sum(
        1 for x in measured_returns if int(x.get("rank", 0)) <= 0
    )
    forward_premium = sum(1 for x in valid_forwards if premium_route(carrier, x))
    regional_forward_premium = sum(
        1 for x in regional_forwards if premium_route(carrier, x)
    )
    return_premium = sum(1 for x in valid_returns if premium_route(carrier, x))
    bidirectional_premium = (
        len(regional_forwards) == len(forward_items)
        and len(valid_returns) == len(return_items)
        and regional_forward_premium == len(regional_forwards)
        and return_premium == len(valid_returns)
    )
    route_grade = carrier_route_grade(
        carrier, valid_forwards, valid_returns, bidirectional_premium
    )
    return {
        "carrier": carrier,
        "forwardRoute": representative_route(valid_forwards, "去程"),
        "returnRoute": representative_route(valid_returns, "回程"),
        "forwardScore": forward_score, "returnScore": return_score,
        "sampleScore": sample_score,
        "forwardMeasured": f"{len(measured_forwards)}/{len(forward_items)}",
        "forwardValid": f"{len(valid_forwards)}/{len(forward_items)}",
        "forwardRegional": f"{len(regional_forwards)}/{len(forward_items)}",
        "forwardReference": len(reference_forwards),
        "forwardSharedReference": len(shared_reference_forwards),
        "forwardReached": f"{len(reached_forwards)}/{len(forward_items)}",
        "forwardFailures": forward_failures,
        "returnMeasured": f"{len(measured_returns)}/{len(return_items)}",
        "returnValid": f"{len(valid_returns)}/{len(return_items)}",
        "returnFailures": return_failures,
        "forwardPremium": f"{forward_premium}/{len(valid_forwards)}",
        "returnPremium": f"{return_premium}/{len(valid_returns)}",
        "bidirectionalPremium": bidirectional_premium,
        "routeGrade": route_grade,
        "matrixStatus": matrix_status,
        "matrixComplete": matrix_complete,
        "evidenceCoverage": measurement_coverage,
        "measurementCoverage": measurement_coverage,
        "scorableCoverage": scorable_coverage,
    }


def show_forward(item: dict[str, Any], index: int, total: int) -> None:
    carrier = item["carrier"]
    color = CARRIER_COLOR[carrier]
    banner(
        f"FORWARD [{index}/{total}] {carrier} / {CARRIER_NAME[carrier]} · {item.get('region', '中国')}去程",
        color,
    )
    field("请求省会", f"{item.get('probeCapital', item.get('region', '中国'))}｜{item.get('requestedCity', '')}", color)
    field("测点健康", item.get("probeHealth", "SELF-TEST｜离线样本"), GREEN if item.get("verified") else YELLOW)
    field("来源核对", ("PASS｜" if item["verified"] else "WARN｜") + item["access"], GREEN if item["verified"] else YELLOW)
    field("入口可达性", item.get("reachability", "INCONCLUSIVE"), GREEN if item.get("targetReached") else YELLOW)
    field("去程线路", item["class"], color)
    field("骨干标签", " → ".join(item.get("backboneTags", [])), color)
    field("中文路由注释", item.get("routeNote", ""), GRAY)
    field("去程延迟", format_stats(item["stats"]), color)
    field("判定证据", item["evidence"], GRAY)


def show_return(item: dict[str, Any], index: int, total: int) -> None:
    carrier = item["carrier"]
    color = CARRIER_COLOR[carrier]
    valid = int(item.get("rank", 0)) > 0
    status = item.get("reachability", "INCONCLUSIVE")
    banner(
        f"RETURN [{index}/{total}] {carrier} / {CARRIER_NAME[carrier]} · {item.get('probeCapital', item['city'])}回程",
        color,
    )
    field("省会目标", f"{item.get('probeCapital', item['city'])}｜{item.get('probeIp') or item.get('host')}:{item.get('targetPort', 443)}", color)
    field("节点来源", f"{item.get('nodeSource', 'STATIC+NETQUALITY_FALLBACK')}｜{'已切备用' if item.get('fallbackUsed') else '主节点'}", GRAY)
    field("测点健康", item.get("probeHealth", "SELF-TEST｜离线样本"), GREEN if valid else YELLOW)
    field("回程线路", item["class"], color if valid else YELLOW)
    if item.get("observedClasses"):
        field("多协议路径", "、".join(item["observedClasses"]), GRAY)
    field("骨干标签", " → ".join(item.get("backboneTags", [])), color)
    field("中文路由注释", item.get("routeNote", ""), GRAY)
    field("回程延迟", f"{format_stats(item['stats'])}｜{status}", color if valid else YELLOW)
    field("判定证据", item.get("evidence", ""), GRAY)


def write_report(report: dict[str, Any]) -> tuple[Path, Path]:
    stamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    json_path = Path.cwd() / f"中国三网VPS双程质量报告_{stamp}.json"
    html_path = Path.cwd() / f"中国三网VPS双程质量报告_{stamp}.html"
    json_text = json.dumps(report, ensure_ascii=False, indent=2)
    json_path.write_text(json_text, encoding="utf-8")
    embedded = json.dumps(report, ensure_ascii=False).replace("</", "<\\/")
    html_path.write_text(f"""<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>中国三网 VPS 双程质量报告</title>
<style>
:root{{--bg:#070b12;--card:#101827;--line:#174ea6;--text:#dbe7ff;--muted:#8390aa;--ct:#35d8ff;--cu:#ff5263;--cm:#43e06f}}
*{{box-sizing:border-box}}body{{margin:0;background:radial-gradient(circle at top,#12213c,var(--bg) 42%);color:var(--text);font:14px/1.6 "Microsoft YaHei",system-ui,sans-serif}}
.wrap{{max-width:1280px;margin:30px auto;padding:0 18px}}header,.panel{{border:1px solid #2458aa;background:linear-gradient(145deg,rgba(17,28,48,.98),rgba(7,11,18,.98));box-shadow:0 18px 50px #0008;margin-bottom:18px}}
header{{padding:28px}}h1{{margin:0;color:#71dcff;letter-spacing:2px}}.sub{{color:var(--muted)}}.grid{{display:grid;grid-template-columns:repeat(3,1fr);gap:16px}}.panel{{padding:18px;border-top:3px solid var(--line)}}.panel.ct{{border-top-color:var(--ct)}}.panel.cu{{border-top-color:var(--cu)}}.panel.cm{{border-top-color:var(--cm)}}
h2{{margin:0 0 12px;font-size:18px}}table{{width:100%;border-collapse:collapse}}th,td{{padding:9px;border-bottom:1px solid #26364f;text-align:left;vertical-align:top}}th{{color:#8ca7d5}}.route-verdict{{font-size:20px;color:#ffe16a;margin-bottom:8px}}.toolbar{{display:flex;gap:10px;margin:12px 0}}button{{background:#173e78;color:white;border:1px solid #3672c8;padding:8px 14px;cursor:pointer}}pre{{white-space:pre-wrap;color:#b8c5db;max-height:260px;overflow:auto}}.heat,.speed{{display:inline-block;min-width:190px;padding:7px 10px;border-radius:7px;color:#07101c;font-weight:700;background:linear-gradient(90deg,var(--heat),color-mix(in srgb,var(--heat) 35%,#101827))}}.heat.na,.speed.na{{color:#aab5c7;background:#273143}}.heat small,.speed small{{display:block;font-weight:500;opacity:.82}}.legend{{display:flex;flex-wrap:wrap;gap:8px;margin:10px 0 16px}}.legend span{{padding:4px 9px;border-radius:999px;color:#07101c;font-weight:700}}.carrier-brand{{display:inline-flex;align-items:center;gap:7px;color:var(--brand);font-weight:800;white-space:nowrap}}.carrier-logo{{display:grid;place-items:center;width:26px;height:26px;border:1px solid color-mix(in srgb,var(--brand) 72%,white);border-radius:8px;background:color-mix(in srgb,var(--brand) 18%,#101827);box-shadow:0 0 15px color-mix(in srgb,var(--brand) 24%,transparent);font-size:16px;line-height:1}}.carrier-brand small{{padding:1px 5px;border:1px solid color-mix(in srgb,var(--brand) 55%,transparent);border-radius:999px;font-size:10px;letter-spacing:.8px}}.section-suffix{{margin-left:8px;color:var(--text);font-weight:650}}@media(max-width:900px){{.grid{{grid-template-columns:1fr}}.heat,.speed{{min-width:150px}}}}
</style></head><body><div class="wrap">
<header><h1>CHINA 3NET ROUTE LAB</h1><div class="sub" id="meta"></div><div class="toolbar"><button id="copy">复制为 NodeSeek 格式</button><button onclick="window.print()">打印／另存 PDF</button><button id="json">下载 JSON</button></div></header>
<section class="panel" id="topology"></section><div class="grid" id="cards"></div><section class="panel" id="heatmap"></section><section class="panel" id="speed"></section><section class="panel" id="improvements"></section><div id="details"></div></div>
<script>const R={embedded};
const E=s=>String(s??'').replace(/[&<>"']/g,c=>({{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}}[c]));
document.getElementById('meta').textContent=R.version+'｜入口 '+R.target.host+':'+R.target.port+'｜出口 '+R.exit.host+'｜'+R.generated;
const carrierMeta={{
  CT:{{name:'中国电信',mark:'CT',glyph:'◈',color:'#00A8E0'}},
  CU:{{name:'中国联通',mark:'CU',glyph:'∞',color:'#E60012'}},
  CM:{{name:'中国移动',mark:'CM',glyph:'▰',color:'#008F3D'}}
}};
const names=Object.fromEntries(Object.entries(carrierMeta).map(([k,v])=>[k,v.name]));
const carrierBrand=c=>{{
  const m=carrierMeta[c]||{{name:c,mark:c,glyph:'◆',color:'#7f8da8'}};
  return `<span class="carrier-brand" style="--brand:${{m.color}}"><b class="carrier-logo">${{E(m.glyph)}}</b><span>${{E(m.name)}}</span><small>${{E(m.mark)}}</small></span>`;
}};
const heatCell=x=>{{
  const v=x.latencyVisual||{{measured:false,reason:'未测'}};
  if(!v.measured)return `<span class="heat na">N/A<small>${{E(v.reason||'未测')}}</small></span>`;
  return `<span class="heat" style="--heat:${{E(v.color)}}">AVG ${{E(v.avgMs)}} ms｜热度 ${{E(v.relativeHeat)}}%<small>P95 ${{E(v.p95Ms)}} ms｜绝对区间 ${{E(v.absoluteBand)}}</small></span>`;
}};
document.getElementById('topology').innerHTML=`<h2>被测网络模型</h2><table><tbody>
<tr><th>拓扑</th><td>${{E(R.dedicatedLine.topology)}}</td><th>外部端口核对</th><td>${{E(R.dedicatedLine.portStatus)}}</td></tr>
<tr><th>被测 VPS</th><td>${{E(R.dedicatedLine.entry)}}｜${{E(R.dedicatedLine.entryAsn)}}</td><th>执行 VPS</th><td>${{E(R.dedicatedLine.exit)}}｜${{E(R.dedicatedLine.exitAsn)}}</td></tr>
<tr><th>矩阵状态</th><td colspan="3">${{E((R.matrixAssessment||{{}}).status||'N/A')}}</td></tr>
<tr><th>模型边界</th><td colspan="3">${{E(R.dedicatedLine.internalVerdict)}}</td></tr></tbody></table>`;
document.getElementById('cards').innerHTML=R.grades.map(g=>`<section class="panel ${{g.carrier.toLowerCase()}}"><h2>${{carrierBrand(g.carrier)}}</h2><div class="route-verdict">${{E(g.routeGrade?.label||'证据不足')}}｜去程 ${{E(g.forwardRoute)}} ↔ 回程 ${{E(g.returnRoute)}}</div><div>${{E(g.routeGrade?.reason||'按可见 ASN／特征跳点判定')}}</div><div>矩阵：${{E(g.matrixStatus)}}｜指定地区去程 ${{E(g.forwardRegional)}}｜回程有效 ${{E(g.returnValid)}}</div><div>测量覆盖 ${{Math.round((g.measurementCoverage||0)*100)}}%｜可判定证据 ${{Math.round((g.scorableCoverage||0)*100)}}%</div><div>全国独立参考 ${{g.forwardReference||0}}｜复用参考 ${{g.forwardSharedReference||0}}｜参考不补足省份矩阵</div></section>`).join('');
const bands=((R.latencyHeatmap||{{}}).absoluteBands||[]).map(b=>`<span style="background:${{E(b.color)}}">${{E(b.range)}}</span>`).join('');
const heatRows=['CT','CU','CM'].map(c=>{{
  const fs=R.forward.filter(x=>x.carrier===c),rs=R.returns.filter(x=>x.carrier===c);
  return fs.map(f=>{{
    const r=rs.find(x=>x.city===f.region)||{{latencyVisual:{{measured:false,reason:'无对应回程'}}}};
    return `<tr><td>${{carrierBrand(c)}}</td><td>${{E(f.region)}}</td><td>${{heatCell(f)}}</td><td>${{heatCell(r)}}</td><td>${{E(f.class)}} ↔ ${{E(r.class||'N/A')}}</td></tr>`;
  }}).join('');
}}).join('');
document.getElementById('heatmap').innerHTML=`<h2>各省实测延迟热图</h2><div class="sub">${{E((R.latencyHeatmap||{{}}).legend||'')}}</div><div class="legend">${{bands}}</div><table><thead><tr><th>运营商</th><th>地区</th><th>去程</th><th>回程</th><th>双程线路</th></tr></thead><tbody>${{heatRows}}</tbody></table>`;
const S=R.singleThreadSpeed||{{rows:[],status:'N/A',reason:'未执行'}};
const speedCell=v=>!v?.measured?`<span class="speed na">N/A<small>${{E(v?.reason||'未测')}}</small></span>`:`<span class="speed" style="--heat:${{E(v.color)}}">${{E(v.mbps)}} Mbps<small>同次百分位 ${{E(v.relativePercentile)}}%｜${{E(v.absoluteBand)}}</small></span>`;
const speedRows=(S.rows||[]).map(x=>`<tr><td>${{E(x.region)}}</td><td>${{carrierBrand(x.carrier)}}<br><span class="sub">${{E(x.label)}}</span></td><td><span class="speed" style="--heat:${{E(x.retransVisual?.color||'#596579')}}">${{E(x.returnRetransmits??'N/A')}}<small>${{E(x.retransVisual?.band||'N/A')}}</small></span></td><td>${{speedCell(x.returnVisual)}}</td><td>${{speedCell(x.forwardVisual)}}</td><td>${{E(x.status)}}</td></tr>`).join('');
document.getElementById('speed').innerHTML=`<h2>三网公网单线程速度</h2><div class="sub">${{E(S.boundary||S.reason||'N/A')}}</div>${{speedRows?`<table><thead><tr><th>地区</th><th>测速节点</th><th>回程重传</th><th>回程速度</th><th>去程速度</th><th>状态</th></tr></thead><tbody>${{speedRows}}</tbody></table>`:`<p>${{E(S.reason||'未执行')}}</p>`}}`;
document.getElementById('improvements').innerHTML=`<h2>最终判定建议改善</h2><ol>${{(R.improvements||['当前未生成额外建议']).map(x=>`<li>${{E(x)}}</li>`).join('')}}</ol>`;
document.getElementById('details').innerHTML=['CT','CU','CM'].map(c=>`<section class="panel ${{c.toLowerCase()}}"><h2>${{carrierBrand(c)}} <span class="section-suffix">${{E(R.matrixLabel||'多地区')}}双程证据</span></h2><table><thead><tr><th>方向／地区</th><th>测点健康／线路</th><th>骨干标签／中文路由注释</th><th>延迟热度</th><th>原始质量数据</th><th>判定证据</th></tr></thead><tbody>${{R.forward.filter(x=>x.carrier===c).map(x=>`<tr><td>去程／${{E(x.region)}}<br>${{E(x.access)}}</td><td>${{E(x.probeHealth||'N/A')}}<br>${{E(x.class)}}</td><td>${{E((x.backboneTags||[]).join(' → '))}}<br>${{E(x.routeNote)}}</td><td>${{heatCell(x)}}</td><td>${{E(JSON.stringify(x.stats))}}</td><td>${{E(x.evidence)}}</td></tr>`).join('')}}${{R.returns.filter(x=>x.carrier===c).map(x=>`<tr><td>回程／${{E(x.probeCapital||x.city)}}</td><td>${{E(x.probeHealth||'N/A')}}<br>${{E(x.class)}}</td><td>${{E((x.backboneTags||[]).join(' → '))}}<br>${{E(x.routeNote)}}</td><td>${{heatCell(x)}}</td><td>${{E(JSON.stringify(x.stats))}}</td><td>${{E(x.evidence)}}</td></tr>`).join('')}}</tbody></table></section>`).join('');
function nodeSeek(){{
  const header=`## 中国三网 VPS 双程质量报告\n\n- 被测 VPS：${{R.target.host}}:${{R.target.port}}\n- 执行 VPS：${{R.exit.host}}\n- 外部端口核对：${{R.dedicatedLine.portStatus}}\n- 网络模型：${{R.dedicatedLine.topology}}\n- 版本：${{R.version}}\n\n`;
  const tabs=':::: tabs\\n'+['CT','CU','CM'].map(c=>{{
    const g=R.grades.find(x=>x.carrier===c);
    const forwards=R.forward.filter(x=>x.carrier===c);
    const returns=R.returns.filter(x=>x.carrier===c);
    const visual=x=>x.latencyVisual?.measured?`AVG ${{x.latencyVisual.avgMs}} ms｜P95 ${{x.latencyVisual.p95Ms}} ms｜相对热度 ${{x.latencyVisual.relativeHeat}}%｜${{x.latencyVisual.absoluteBand}}`:`N/A｜${{x.latencyVisual?.reason||'未测'}}`;
    const forwardRows=forwards.map(x=>`- 去程（${{x.probeCapital||x.region}}→VPS）：测点 ${{x.probeHealth||'N/A'}}｜${{x.class}}｜骨干 ${{(x.backboneTags||[]).join(' → ')||'未识别'}}｜${{visual(x)}}｜注释 ${{x.routeNote||'N/A'}}`).join('\\n');
    const returnRows=returns.map(x=>`- 回程（VPS→${{x.probeCapital||x.city}}）：测点 ${{x.probeHealth||'N/A'}}｜${{x.class}}｜骨干 ${{(x.backboneTags||[]).join(' → ')||'未识别'}}｜${{visual(x)}}｜LOSS ${{x.stats.loss??'N/A'}}%｜注释 ${{x.routeNote||'N/A'}}`).join('\\n');
    return `::: tab-item ${{carrierMeta[c].glyph}} ${{carrierMeta[c].mark}} ${{names[c]}}\n线路等级：${{g.routeGrade?.label||'证据不足'}}｜去程 ${{g.forwardRoute}} ↔ 回程 ${{g.returnRoute}}｜矩阵 ${{g.matrixStatus}}｜测量覆盖 ${{Math.round((g.measurementCoverage||0)*100)}}%｜可判定证据 ${{Math.round((g.scorableCoverage||0)*100)}}%｜指定地区去程 ${{g.forwardRegional}}｜全国独立参考 ${{g.forwardReference||0}}｜复用参考 ${{g.forwardSharedReference||0}}｜回程有效 ${{g.returnValid}}\n判定说明：${{g.routeGrade?.reason||'按可见 ASN／特征跳点判定'}}\n\n${{forwardRows}}\n${{returnRows}}\n:::`;
  }}).join('\\n\\n')+'\\n::::';
  const speedText=(R.singleThreadSpeed?.rows||[]).map(x=>`- ${{x.label}}：回程 ${{x.returnMbps??'N/A'}} Mbps／重传 ${{x.returnRetransmits??'N/A'}}；去程 ${{x.forwardMbps??'N/A'}} Mbps`).join('\\n');
  const advice=(R.improvements||[]).map((x,i)=>`${{i+1}}. ${{x}}`).join('\\n');
  return header+tabs+`\\n\\n### 三网单线程速度\\n${{speedText||'N/A｜未执行 --speed'}}\\n\\n### 改善建议\\n${{advice||'无'}}\\n\\n> traceroute 跳点不回应不等于端到端丢包；去程 LOSS 显示 N/A，只有 TCP connect 才计算业务探测丢包。`;
}}
document.getElementById('copy').onclick=async()=>{{await navigator.clipboard.writeText(nodeSeek());alert('NodeSeek 格式已复制')}};
document.getElementById('json').onclick=()=>{{const a=document.createElement('a');a.download='3net-report.json';a.href=URL.createObjectURL(new Blob([JSON.stringify(R,null,2)],{{type:'application/json'}}));a.click()}};
</script></body></html>""", encoding="utf-8")
    return html_path, json_path


def public_report_payload(report: dict[str, Any]) -> dict[str, Any]:
    """Convert RC4 native data to the public site's established flat schema."""
    carrier_names = {"CT": "中国电信", "CU": "中国联通", "CM": "中国移动"}
    carrier_marks = {"CT": "◈", "CU": "∞", "CM": "▰"}

    def average(values: list[Any]) -> float | None:
        numeric = [float(x) for x in values if isinstance(x, (int, float))]
        return round(statistics.mean(numeric), 1) if numeric else None

    def flatten_forward(item: dict[str, Any]) -> dict[str, Any]:
        s = item["stats"]
        return {
            "region": item.get("region", "中国"),
            "label": f"{item.get('region', '中国')}远端实测 → VPS",
            "access": item["access"], "publicIp": "",
            "verified": item["verified"],
            "requestedCity": item.get("requestedCity", ""),
            "actualProbeCity": item.get("actualProbeCity", ""),
            "selectionScope": item.get("selectionScope", ""),
            "regionalVerified": bool(item.get("regionalVerified")),
            "sourceAsn": item.get("sourceAsn", 0),
            "nationalProbeReused": bool(item.get("nationalProbeReused")),
            "probeFingerprint": item.get("probeFingerprint", ""),
            "route": item["class"], "evidence": item["evidence"],
            "avg": s.get("avg"), "min": s.get("minimum"), "max": s.get("maximum"),
            "p95": s.get("p95"), "jitter": s.get("jitter"), "stddev": None,
            "loss": s.get("loss"),
            "success": f"{s.get('success', 0)}/{s.get('expected', 0)}",
            "routeHops": item.get("routeHops"),
            "timeoutHops": item.get("timeoutHops"),
            "backboneTags": item.get("backboneTags", []),
            "routeNote": item.get("routeNote", ""),
            "probeCapital": item.get("probeCapital", CAPITALS.get(item.get("region", ""), "")),
            "probeHealth": item.get("probeHealth", ""),
            "reachability": item.get("reachability", "INCONCLUSIVE"),
            "latencyVisual": item.get("latencyVisual", {}),
        }

    carriers: list[dict[str, Any]] = []
    for carrier in ("CT", "CU", "CM"):
        forward_items = [x for x in report["forward"] if x["carrier"] == carrier]
        reached_forward_items = [
            x for x in forward_items
            if int(x.get("rank", 0)) > 0 and x.get("verified") and x.get("targetReached")
        ]
        regional_forward_items = [
            x for x in reached_forward_items if not national_reference(x)
        ]
        reference_forward_items = [
            x for x in reached_forward_items
            if national_reference(x) and not x.get("nationalProbeReused")
        ]
        shared_reference_items = [
            x for x in reached_forward_items
            if national_reference(x) and x.get("nationalProbeReused")
        ]
        valid_forward_items = regional_forward_items + reference_forward_items
        forward_probes = [flatten_forward(x) for x in forward_items]
        grade_item = next(x for x in report["grades"] if x["carrier"] == carrier)
        return_items = [x for x in report["returns"] if x["carrier"] == carrier]
        probes: list[dict[str, Any]] = []
        for item in return_items:
            s = item["stats"]
            probes.append({
                "city": item["city"], "host": item["host"], "ip": item["probeIp"],
                "targetPort": item.get("targetPort", 443),
                "nodeSource": item.get("nodeSource", "STATIC+NETQUALITY_FALLBACK"),
                "fallbackUsed": bool(item.get("fallbackUsed")),
                "route": item["class"], "evidence": item["evidence"],
                "observedClasses": item.get("observedClasses", []),
                "avg": s.get("avg"), "min": s.get("minimum"), "max": s.get("maximum"),
                "p95": s.get("p95"), "jitter": s.get("jitter"), "stddev": None,
                "loss": s.get("loss"), "success": f"{s.get('success', 0)}/{s.get('expected', 0)}",
                "routeHops": item.get("routeHops", 0),
                "timeoutHops": 0,
                "backboneTags": item.get("backboneTags", []),
                "routeNote": item.get("routeNote", ""),
                "probeCapital": item.get("probeCapital", CAPITALS.get(item.get("city", ""), "")),
                "probeHealth": item.get("probeHealth", ""),
                "reachability": item.get("reachability", "INCONCLUSIVE"),
                "latencyVisual": item.get("latencyVisual", {}),
            })
        forward_flat = {
            "region": f"{MATRIX_LABEL}汇总",
            "label": f"{MATRIX_LABEL}远端实测 → VPS",
            "access": MATRIX_CITIES,
            "publicIp": "",
            "verified": len(regional_forward_items) == len(forward_items),
            "route": grade_item["forwardRoute"],
            "evidence": f"{MATRIX_LABEL}去程共 {len(forward_items)} 组",
            "avg": average([x["stats"].get("avg") for x in valid_forward_items]),
            "min": average([x["stats"].get("minimum") for x in valid_forward_items]),
            "max": average([x["stats"].get("maximum") for x in valid_forward_items]),
            "p95": average([x["stats"].get("p95") for x in valid_forward_items]),
            "jitter": average([x["stats"].get("jitter") for x in valid_forward_items]),
            "stddev": None, "loss": None,
            "success": f"{len(regional_forward_items)}/{len(forward_items)}",
            "regionalSuccess": f"{len(regional_forward_items)}/{len(forward_items)}",
            "nationalReference": len(reference_forward_items),
            "sharedReference": len(shared_reference_items),
            "routeHops": None, "timeoutHops": None,
            "backboneTags": sorted({
                tag for x in valid_forward_items for tag in x.get("backboneTags", [])
            }),
            "routeNote": (
                "各地区分别列示骨干标签与中文路由注释；"
                "全国同运营商参考不会冒充指定地区证据。"
            ),
            "reachability": (
                f"指定地区 {len(regional_forward_items)}/{len(forward_items)}"
                f"｜全国独立参考 {len(reference_forward_items)}"
                f"｜复用参考 {len(shared_reference_items)}"
            ),
        }
        carriers.append({
            "id": carrier, "name": carrier_names[carrier],
            "brand": {
                "mark": carrier_marks[carrier],
                "short": carrier,
                "color": CARRIER_HEX[carrier],
            },
            "route": grade_item["returnRoute"], "probeCount": len(probes),
            "routeTypes": len({
                x["class"] for x in return_items if int(x.get("rank", 0)) > 0
            }),
            "forward": forward_flat, "forwardRoute": grade_item["forwardRoute"],
            "forwardProbes": forward_probes,
            "evidenceCoverage": grade_item["evidenceCoverage"],
            "measurementCoverage": grade_item["measurementCoverage"],
            "scorableCoverage": grade_item["scorableCoverage"],
            "matrixStatus": grade_item["matrixStatus"],
            "matrixComplete": grade_item["matrixComplete"],
            "forwardMeasured": grade_item["forwardMeasured"],
            "forwardRegional": grade_item["forwardRegional"],
            "forwardReference": grade_item["forwardReference"],
            "forwardSharedReference": grade_item["forwardSharedReference"],
            "forwardReached": grade_item["forwardReached"],
            "forwardFailures": grade_item["forwardFailures"],
            "returnMeasured": grade_item["returnMeasured"],
            "returnValid": grade_item["returnValid"],
            "returnFailures": grade_item["returnFailures"],
            "bidirectional": grade_item["bidirectionalPremium"],
            "routeGrade": grade_item["routeGrade"],
            "probes": probes,
        })
    matrix_complete = all(x["matrixComplete"] for x in report["grades"])
    forward_regional_total = sum(
        int(str(x["forwardRegional"]).split("/", 1)[0])
        for x in report["grades"]
    )
    route_classification = report["routeClassification"]
    final_title = (
        f"{route_classification['overallLabel']}｜"
        + (
            "三网完整矩阵"
            if matrix_complete else
            f"矩阵 PARTIAL｜指定地区去程 {forward_regional_total}/{EXPECTED_PER_DIRECTION}"
        )
    )
    return {
        "version": report["version"], "generated": report["generated"],
        "target": report["target"]["host"], "targetPort": report["target"]["port"],
        "returnSshHost": report["exit"]["host"], "selfTest": report["selfTest"],
        "mode": report["mode"],
        "matrix": (
            f"{MATRIX_CITIES} × 三网去程＋回程（{TOTAL_MATRIX_GROUPS} 组）"
        ),
        "methodology": report["methodology"],
        "speedMethodology": report.get("speedMethodology", ""),
        "bgp": {"asn": report["dedicatedLine"]["exitAsn"],
                "provider": report["exit"]["identity"], "location": ""},
        "final": {
            "matrixComplete": matrix_complete,
            "matrixStatus": "COMPLETE" if matrix_complete else "PARTIAL",
            "title": final_title,
            "elapsed": "N/A",
            "routeGrade": route_classification,
        },
        "carriers": carriers,
        "routeClassification": route_classification,
        "singleThreadSpeed": report.get("singleThreadSpeed", {}),
        "improvements": report.get("improvements", []),
        "latencyHeatmap": report.get("latencyHeatmap", {}),
        "matrixAssessment": report.get("matrixAssessment", {}),
        "dedicatedLine": report["dedicatedLine"],
    }


def publish(report: dict[str, Any]) -> str:
    try:
        result = http_json(PUBLIC_REPORT_API, "POST", public_report_payload(report), 30)
        for key in ("url", "reportUrl", "report_url", "publicUrl"):
            if result.get(key):
                return str(result[key])
        if result.get("id"):
            return f"https://china-3net-route-report.souldance4.chatgpt.site/report/{result['id']}"
        return ""
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:300]
        field("公共报告", f"上传失败｜HTTP {exc.code}｜{detail}", YELLOW)
        return ""
    except Exception as exc:
        field("公共报告", f"上传失败｜{exc}", YELLOW)
        return ""


def main() -> int:
    logo()
    if SELF_TEST:
        exit_ip, exit_identity = "45.207.225.70", "SELF-TEST VPS"
    else:
        exit_ip, exit_identity = public_ip()
    target, port = ask_target(exit_ip)

    banner("TARGET / 双端检测模型", CYAN)
    native_mode = target == exit_ip
    field("被测 VPS", f"{mask_ip(target)}:{port}", CYAN)
    field("执行位置", f"{mask_ip(exit_ip)}｜{exit_identity or '本机原生执行'}", GREEN)
    field("认证方式", "VPS 本机原生执行｜不使用 SSH／密码／私钥", GREEN)
    field("去程核对方式", "中国本地端主动证据优先；缺项才使用 Globalping，不以回程反推", CYAN)
    field("测试矩阵", f"{MATRIX_LABEL}｜{MATRIX_CITIES}", MAGENTA)

    client_forward, client_forward_status = load_client_forward_evidence(
        FORWARD_EVIDENCE_PATH, target, port
    )
    field(
        "真实去程证据",
        client_forward_status,
        GREEN if client_forward else YELLOW,
    )
    forward: list[dict[str, Any]] = []
    forward_total = len(FORWARD_REGIONS) * 3
    forward_index = 0
    for carrier in ("CT", "CU", "CM"):
        for region, probe_city in FORWARD_REGIONS:
            forward_index += 1
            if SELF_TEST:
                item = self_test_forward(carrier, region, probe_city)
            elif (carrier, region) in client_forward:
                item = client_forward[(carrier, region)]
            else:
                field(
                    f"[{forward_index}/{forward_total}] 去程",
                    f"{region} AS{FORWARD_ASN[carrier]} → {mask_ip(target)}:{port}",
                    CARRIER_COLOR[carrier],
                )
                field("探针状态", "本地证据缺项，正在请求 Globalping 同省远端 TCP traceroute……", GRAY)
                item = globalping_trace(target, port, carrier, region, probe_city)
            item = add_route_labels(item)
            forward.append(item)
            show_forward(item, forward_index, forward_total)

    true_forward_count = sum(
        1 for item in forward
        if item.get("evidenceSource") == "CHINA_CLIENT_ACTIVE"
    )
    if not SELF_TEST and true_forward_count < len(forward):
        banner("TRUE FORWARD / 中国本地端补测提示", MAGENTA)
        field(
            "已导入真去程",
            f"{true_forward_count}/{EXPECTED_PER_DIRECTION} 组",
            GREEN if true_forward_count else YELLOW,
        )
        field(
            "Windows 客户端",
            "运行 cn3_client_probe.ps1，按当前网络填写 CT／CU／CM 与所在省份，生成 forward_evidence.json",
            CYAN,
        )
        field(
            "重新合并",
            f"bash 3net-route.sh --target {target} --port {port} --forward-evidence /root/forward_evidence.json",
            GRAY,
        )

    dedicated_line = dedicated_line_assessment(target, port, exit_ip, forward)
    banner(
        "VPS MODEL / 原生公网双向模型"
        if native_mode else
        "FORWARDING MODEL / 入口与 NAT 内段",
        MAGENTA,
    )
    field("网络拓扑", dedicated_line["topology"], CYAN)
    field("外部端口", dedicated_line["portStatus"],
          GREEN if dedicated_line["reachedBy"] else YELLOW)
    field("目标 ASN", dedicated_line["entryAsn"], CYAN)
    field("出口 ASN", dedicated_line["exitAsn"], GREEN)
    field(
        "内段可见性",
        (
            "不适用｜目标与执行 VPS 为同一公网 IP"
            if native_mode else
            "NAT 隐藏｜不强判精品或普通线路"
        ),
        GREEN if native_mode else YELLOW,
    )
    field("判断边界", dedicated_line["internalVerdict"], GRAY)

    return_pool, return_pool_status = load_return_probe_pool()
    return_total = sum(len(items) for items in return_pool.values())
    banner(
        f"RETURN PROBE / 出口 VPS 原生三网"
        f"{EXPECTED_PER_DIRECTION}组回程",
        CYAN,
    )
    field("执行位置", mask_ip(exit_ip), GREEN)
    field("动态测点池", return_pool_status, GREEN if return_pool_status.startswith("ONLINE") else YELLOW)
    field("执行方式", "真实 TCP 端口＋TCP／ICMP／UDP 交叉识别；证据不足再切 oneclickvirt 同省三网 ICMP 备用", GRAY)
    returns: list[dict[str, Any]] = []
    index = 0
    for carrier in ("CT", "CU", "CM"):
        for spec in return_pool[carrier]:
            city, host = str(spec["city"]), str(spec["host"])
            index += 1
            item = self_test_return(carrier, city, host) if SELF_TEST else return_probe(carrier, city, spec)
            item = add_route_labels(item)
            returns.append(item)
            show_return(item, index, return_total)

    if SPEED_TEST:
        banner("NEXT / 开始三网公网单线程测速", YELLOW)
        field(
            "预计耗时",
            "约 4～12 分钟｜北上广三网 9 组｜会消耗实际测速流量",
            YELLOW,
        )
    speed = single_thread_speed()
    latency_heatmap = annotate_latency_visuals(forward, returns)
    grades = [grade(c, forward, returns) for c in ("CT", "CU", "CM")]
    route_classification = overall_route_grade(grades)
    measured_total = sum(
        int(item["forwardMeasured"].split("/", 1)[0])
        + int(item["returnMeasured"].split("/", 1)[0])
        for item in grades
    )
    scorable_total = sum(
        int(item["forwardValid"].split("/", 1)[0])
        + int(item["returnValid"].split("/", 1)[0])
        for item in grades
    )
    matrix_complete = (
        all(item["matrixComplete"] for item in grades)
        and measured_total == TOTAL_MATRIX_GROUPS
    )
    matrix_assessment = {
        "status": "COMPLETE" if matrix_complete else "PARTIAL",
        "completed": f"{measured_total}/{TOTAL_MATRIX_GROUPS}",
        "scorable": f"{scorable_total}/{TOTAL_MATRIX_GROUPS}",
        "measurementCoverage": round(
            measured_total / max(1, TOTAL_MATRIX_GROUPS), 3
        ),
        "scorableCoverage": round(
            scorable_total / max(1, TOTAL_MATRIX_GROUPS), 3
        ),
        "matrixComplete": matrix_complete,
        "coverageNote": (
            "指定省份去程与回程全部完成"
            if matrix_complete else
            "指定省份矩阵未完成；全国参考不会补足省份覆盖"
        ),
    }
    if SELF_TEST:
        self_test_regressions()
        if not all(item["bidirectionalPremium"] for item in grades):
            raise AssertionError("离线精品双程样本未通过严格双程判定")
        if route_classification["overallLevel"] != "BIDIRECTIONAL_PREMIUM":
            raise AssertionError("离线三网最终线路等级未判为双程精品")
    banner("FINAL VERDICT / 三网双程线路判定", CYAN)
    overall_color = (
        GREEN
        if route_classification["overallLevel"] == "BIDIRECTIONAL_PREMIUM"
        else YELLOW
        if route_classification["overallLevel"] == "ONE_WAY_OPTIMIZED_OR_MIXED"
        else RED
        if route_classification["overallLevel"] == "EVIDENCE_INSUFFICIENT"
        else CYAN
    )
    field("最终线路等级", route_classification["overallLabel"], overall_color)
    field("等级判定依据", route_classification["reason"], GRAY)
    field("判定边界", route_classification["policy"], YELLOW)
    for item in grades:
        color = CARRIER_COLOR[item["carrier"]]
        field(
            carrier_label(item["carrier"]),
            f"等级 {item['routeGrade']['label']}｜"
            f"去程 {item['forwardRoute']}〔地区 {item['forwardRegional']}｜"
            f"测量 {item['forwardMeasured']}｜有效 {item['forwardValid']}｜"
            f"全国独立参考 {item['forwardReference']}｜"
            f"复用参考 {item['forwardSharedReference']}｜失败 {item['forwardFailures']}〕｜"
            f"回程 {item['returnRoute']}〔测量 {item['returnMeasured']}｜"
            f"有效 {item['returnValid']}｜失败 {item['returnFailures']}〕｜"
            f"测量覆盖 {round(item['measurementCoverage'] * 100)}%｜"
            f"矩阵 {item['matrixStatus']}",
            color,
        )
        field("判定说明", item["routeGrade"]["reason"], GRAY)
    field(
        "矩阵完整性",
        f"{matrix_assessment['status']}｜完成 {matrix_assessment['completed']}｜"
        f"可判定 {matrix_assessment['scorable']}｜"
        + ("指定省份完整" if matrix_assessment["matrixComplete"] else "指定省份未完整"),
        GREEN if matrix_assessment["matrixComplete"] else YELLOW,
    )
    show_latency_heatmap(forward, returns)
    show_single_thread_speed(speed)
    improvements = build_improvements(grades, forward, returns, speed)
    banner("IMPROVEMENTS / 最终判定建议改善", MAGENTA)
    for index, suggestion in enumerate(improvements, start=1):
        field(f"建议 {index}", suggestion, YELLOW)

    # 评分只保留在运行期供旧分类回归使用；用户报告与公开载荷不输出
    # 这些内部字段，避免无意义的兼容字段占用版面。
    for item in forward + returns:
        item.pop("score", None)
        item.pop("stars", None)
    for item in grades:
        for key in ("forwardScore", "returnScore", "sampleScore", "score", "stars"):
            item.pop(key, None)

    report = {
        "version": VERSION,
        "generated": dt.datetime.now(dt.timezone.utc).astimezone().isoformat(timespec="seconds"),
        "mode": "VPS_NATIVE_DUAL_ENDPOINT",
        "matrixLabel": MATRIX_LABEL,
        "matrix": (
            f"{MATRIX_CITIES} × 三网去程＋回程（{TOTAL_MATRIX_GROUPS} 组）"
        ),
        "selfTest": SELF_TEST,
        "target": {"host": mask_ip(target), "port": port, "role": "被测 VPS 公网"},
        "exit": {"host": mask_ip(exit_ip), "identity": exit_identity, "role": "脚本执行 VPS"},
        "forwardEvidence": {
            "status": client_forward_status,
            "clientActive": true_forward_count,
            "total": len(forward),
        },
        "methodology": "默认使用成熟的北上广三网主矩阵；--extended 才追加合肥、南京、杭州。去程优先读取 cn3-forward-evidence/v1：中国本地 Windows 客户端对目标业务端口执行真实 TCP connect 与 tracert，且证据目标必须与本次 IP／端口完全一致；未覆盖项先由 Globalping 请求同省真实外部探针。省会及同省没有探针时，一次收集中国境内同运营商名称及各省网 ASN 的多探针共享快照；北上广与扩展模式使用相同池规则，按实际城市和地区 ASN 优先分配并避免重复。全国参考只证明该运营商网络到入口的线路与可达性，不冒充指定省份，也不能补足指定省份矩阵。仍无探针时标记 NOT-TESTED，不得写成入口不通。完整矩阵必须由指定省份去程探针与对应省份回程目标实际执行；实际执行但未接通保留为真实失败，NOT-TESTED 与复用参考不冒充失败。最终结论以去回程骨干线路类型、各省实测 AVG／P95、相对热度与单线程吞吐为主，全国参考不进入省份延迟热图。net.sh 的 zstaticcdn 目标、TcpQuality 动态节点池以及 zhanghanyun／oneclickvirt backtrace 均为 VPS→中国回程，只用于回程稳定性，绝不冒充去程。回程先使用 TcpQuality 真实端口主备节点与 NetQuality 域名备用，TCP／ICMP／UDP 交叉取证；三协议仍无骨干证据时，才按 oneclickvirt/backtrace 的设计切换 spiritLHLS/icmp_targets 同省同运营商最多三个 ICMP 地址。若多协议同时观察到精品与普通线路，按动态混合保守降级。CN2 GIA 至少需要两个可见 CN2 跳点，单一 CN2 特征或多个 163 交付跳点只判混合／证据不足。",
        "speedMethodology": (
            "--speed 固定调用已锁定提交的 TcpQuality 北上广三网公共 TOS 单线程测试；"
            "回程定义为当前 VPS→中国测速端，去程定义为中国测速端→当前 VPS。"
            "测速结果作为独立实测指标，不补足省份路由矩阵。"
        ),
        "forward": forward,
        "returns": returns,
        "grades": grades,
        "routeClassification": route_classification,
        "latencyHeatmap": latency_heatmap,
        "singleThreadSpeed": speed,
        "improvements": improvements,
        "matrixAssessment": matrix_assessment,
        "dedicatedLine": dedicated_line,
        "privacy": "报告中的入口与出口 IPv4 均只保留前两段。",
    }
    if SELF_TEST:
        public_payload = public_report_payload(report)
        speed_check = public_payload.get("singleThreadSpeed") or {}
        serialized_payload = json.dumps(public_payload, ensure_ascii=False)
        if (
            not public_payload.get("latencyHeatmap", {}).get("forward")
            or any(
                token in serialized_payload
                for token in ('"score"', '"stars"', '"sampleScore"', '"ratingEnabled"')
            )
        ):
            raise AssertionError("公开报告载荷必须使用延迟热图，且不得包含旧评分字段")
        if (
            len(speed_check.get("rows") or []) != 9
            or int((speed_check.get("summary") or {}).get("complete", 0)) != 9
        ):
            raise AssertionError("单线程速度必须包含北上广三网九组与完整摘要")
        if any(
            item.get("routeHops") == 0
            for carrier in public_payload["carriers"]
            for item in carrier.get("forwardProbes") or []
            if item.get("verified")
        ):
            raise AssertionError("已核对去程不得再硬编码显示 0 hops")
    html_path, json_path = write_report(report)
    banner("REPORT / 报告输出", MAGENTA)
    field("HTML 报告", html_path, GREEN)
    field("JSON 数据", json_path, GREEN)
    field(
        "页面功能",
        "双程线路／延迟热图／单线程吞吐／改善建议／NodeSeek／JSON／PDF",
        CYAN,
    )
    if not SELF_TEST:
        public_url = publish(report)
        if public_url:
            field("公共报告", public_url, GREEN)
    else:
        field(
            "SELF-TEST",
            "PASS｜离线分类、延迟热图、单线程吞吐、跳数与报告生成完成",
            GREEN,
        )
    field("隐私", f"入口 {mask_ip(target)}｜出口 {mask_ip(exit_ip)}；无 SSH 凭据", CYAN)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\n" + YELLOW + "用户已中止。" + RESET)
        raise SystemExit(130)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:500]
        print(RED + f"\n[ERROR] HTTP {exc.code}：{detail}" + RESET)
        raise SystemExit(6)
    except Exception as exc:
        print(RED + f"\n[ERROR] {type(exc).__name__}：{exc}" + RESET)
        raise SystemExit(7)
PY
