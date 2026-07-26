#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="v0.10 RC1"
ENTRY_IP=""
ENTRY_PORT=""
EXPECTED_EXIT=""
LOCAL_PRIVATE=""
REMOTE_PEER=""
CLIENT_VERIFIED_EXIT=""
FULL=0
SELF_TEST=0
NO_PUBLISH=0

usage() {
  cat <<'EOF'
沪日专线／IX-style 四层质量检测 v0.10 RC1

用途：
  专门检测“中国用户 → 上海公网入口 → NAT／IPLC／IEPL 隐藏内段 → 日本出口”。
  本脚本与 3net-route.sh 完全独立，不共用评分或报告。

推荐：在日本出口 VPS 上执行
  bash <(curl -fsSL https://raw.githubusercontent.com/souldance7-ai/vps-speedtest/main/ix-route.sh)

非交互示例：
  bash ix-route.sh --entry 211.136.162.184 --port 10103 \
    --expected-exit 87.86.87.231 --local-private 172.16.2.101

默认北上广三网双程；完整六地区三网：
  bash ix-route.sh --entry 211.136.162.184 --port 10103 --full

可选参数：
  --entry IP             上海／中国侧公网入口
  --port PORT            协议业务端口，不是 SSH 22 或管理端口
  --expected-exit IP     预期日本公网出口
  --local-private IP     日本端专线内网 IP
  --peer IP              上海端专线内网对端；未知可留空
  --client-verified-exit IP
                        中国客户端连接 Mieru 后实测到的出口；匹配时确认真实握手
  --full                 在固定北上广基础上加入安徽、江苏、浙江 × 三网
  --no-publish           只生成本地 HTML／JSON／Markdown，不上传 Chain 3Net
  --self-test            离线自检，不发起网络探测
  -h, --help             显示帮助

判定边界：
  入口 TCP traceroute 到达，只证明入口端口经映射后的 TCP 路径可达。
  不要求供应商未交付的上海内网对端 IP；入口可达、本机监听、私网地址与路由会形成映射链证据。
  只有确实知道上海内网对端 IP 时，才额外测量专线纯内段 RTT／抖动／丢包。
  自动识别 Mieru mita 服务、版本、运行状态、端口监听与 NTP。
  只有提供中国客户端实测出口且与日本出口一致时，才确认 Mieru 真实握手 PASS。
  DNS、探针或权限失败一律显示 N/A，不会换算成 100% LOSS。
  北京、上海、广州固定列入三网去程与日本出口回程；--full 再加入合肥、南京、杭州。
  报告保存到“Chain 3Net”目录，并生成 HTML／JSON／Markdown；上传成功必须显示公共网址。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --entry) ENTRY_IP="${2:-}"; shift 2 ;;
    --port) ENTRY_PORT="${2:-}"; shift 2 ;;
    --expected-exit) EXPECTED_EXIT="${2:-}"; shift 2 ;;
    --local-private) LOCAL_PRIVATE="${2:-}"; shift 2 ;;
    --peer) REMOTE_PEER="${2:-}"; shift 2 ;;
    --client-verified-exit) CLIENT_VERIFIED_EXIT="${2:-}"; shift 2 ;;
    --full) FULL=1; shift ;;
    --no-publish) NO_PUBLISH=1; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[ERROR] 未知参数：$1"; usage; exit 2 ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "[ERROR] 找不到 python3。Debian/Ubuntu：apt-get update && apt-get install -y python3"
  exit 3
fi

export IX_VERSION="$VERSION"
export IX_ENTRY_IP="$ENTRY_IP"
export IX_ENTRY_PORT="$ENTRY_PORT"
export IX_EXPECTED_EXIT="$EXPECTED_EXIT"
export IX_LOCAL_PRIVATE="$LOCAL_PRIVATE"
export IX_REMOTE_PEER="$REMOTE_PEER"
export IX_CLIENT_VERIFIED_EXIT="$CLIENT_VERIFIED_EXIT"
export IX_FULL="$FULL"
export IX_SELF_TEST="$SELF_TEST"
export IX_NO_PUBLISH="$NO_PUBLISH"

# Python 程序从文件描述符 3 读取，stdin 保留给交互输入。
python3 /dev/fd/3 3<<'PY'
from __future__ import annotations

import datetime as dt
import html
import ipaddress
import json
import math
import os
import re
import shutil
import socket
import statistics
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

VERSION = os.environ.get("IX_VERSION", "v0.10 RC1")
ENTRY_IP = os.environ.get("IX_ENTRY_IP", "").strip()
PORT_TEXT = os.environ.get("IX_ENTRY_PORT", "").strip()
EXPECTED_EXIT = os.environ.get("IX_EXPECTED_EXIT", "").strip()
LOCAL_PRIVATE = os.environ.get("IX_LOCAL_PRIVATE", "").strip()
REMOTE_PEER = os.environ.get("IX_REMOTE_PEER", "").strip()
CLIENT_VERIFIED_EXIT = os.environ.get("IX_CLIENT_VERIFIED_EXIT", "").strip()
FULL = os.environ.get("IX_FULL") == "1"
SELF_TEST = os.environ.get("IX_SELF_TEST") == "1"
NO_PUBLISH = os.environ.get("IX_NO_PUBLISH") == "1"
GLOBALPING_API = "https://api.globalping.io/v1/measurements"
GLOBALPING_PROBES_API = "https://api.globalping.io/v1/probes"
ICMP_TARGETS_API = "https://raw.githubusercontent.com/spiritLHLS/icmp_targets/main/nodes.json"
PUBLIC_REPORT_API = "https://china-3net-route-report.souldance4.chatgpt.site/api/reports"
PUBLIC_REPORT_ROOT = "https://china-3net-route-report.souldance4.chatgpt.site"

RESET = "\033[0m"
GRAY = "\033[38;5;245m"
WHITE = "\033[97m"
BLUE = "\033[38;5;27m"
CYAN = "\033[96m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
RED = "\033[91m"
MAGENTA = "\033[95m"
WIDTH = min(max(shutil.get_terminal_size((108, 30)).columns, 88), 128)

CARRIERS = {
    "CT": ("中国电信", 4134, CYAN),
    "CU": ("中国联通", 4837, RED),
    "CM": ("中国移动", 9808, GREEN),
}
CORE_REGIONS = [
    ("北京", "Beijing"),
    ("上海", "Shanghai"),
    ("广东", "Guangzhou"),
]
FULL_REGIONS = [
    ("北京", "Beijing"),
    ("上海", "Shanghai"),
    ("广东", "Guangzhou"),
    ("安徽", "Hefei"),
    ("江苏", "Nanjing"),
    ("浙江", "Hangzhou"),
]
RETURN_TARGETS = {
    "CT": {
        "北京": "219.141.136.10", "上海": "202.96.209.133",
        "广东": "202.96.128.86", "安徽": "61.132.163.68",
        "江苏": "218.2.2.2", "浙江": "202.101.172.35",
    },
    "CU": {
        "北京": "202.106.50.1", "上海": "210.22.70.3",
        "广东": "210.21.196.6", "安徽": "218.104.78.2",
        "江苏": "58.240.53.78", "浙江": "221.12.1.227",
    },
    "CM": {
        "北京": "221.179.155.161", "上海": "211.136.112.200",
        "广东": "211.139.129.222", "安徽": "211.138.180.2",
        "江苏": "221.131.143.69", "浙江": "112.13.113.199",
    },
}
CAPITALS = {
    "北京": "北京市", "上海": "上海市", "广东": "广州市",
    "安徽": "合肥市", "江苏": "南京市", "浙江": "杭州市",
}
CITY_CANDIDATES = {
    # 省会优先；省会没有目标运营商探针时，逐一尝试同省常见机房城市。
    # 北京、上海为直辖市，没有可合法冒充的“同省其他城市”。
    "北京": ["Beijing"],
    "上海": ["Shanghai"],
    "广东": [
        "Guangzhou", "Shenzhen", "Dongguan", "Foshan", "Zhuhai",
        "Huizhou", "Zhongshan", "Shantou", "Jiangmen", "Zhanjiang",
        "Maoming", "Zhaoqing", "Qingyuan", "Shaoguan", "Heyuan",
        "Meizhou", "Shanwei", "Yangjiang", "Yunfu", "Chaozhou", "Jieyang",
    ],
    "安徽": [
        "Hefei", "Wuhu", "Bengbu", "Maanshan", "Anqing", "Chuzhou",
        "Fuyang", "Huainan", "Huaibei", "Tongling", "Chizhou",
        "Xuancheng", "Huangshan", "Bozhou", "Luan",
    ],
    "江苏": [
        "Nanjing", "Suzhou", "Wuxi", "Changzhou", "Nantong",
        "Xuzhou", "Yangzhou", "Zhenjiang", "Yancheng", "Lianyungang",
        "Huai'an", "Huaian", "Taizhou", "Suqian",
    ],
    "浙江": [
        "Hangzhou", "Ningbo", "Wenzhou", "Jiaxing", "Shaoxing",
        "Jinhua", "Taizhou", "Huzhou", "Quzhou", "Zhoushan", "Lishui",
    ],
}
CARRIER_SELECTORS = {
    "CT": ["China Telecom", "AS4134", "AS4812", "AS4816"],
    "CU": ["China Unicom", "AS4837", "AS4808", "AS17816"],
    "CM": ["China Mobile", "AS9808", "AS24445", "AS56040"],
}
CARRIER_ASNS = {
    # Globalping 探针可能挂在省网、接入网或运营商 IDC ASN，而不是骨干主 ASN。
    # 只收录可明确归属三大运营商的 ASN；第三方机房仍只能记 REFERENCE。
    "CT": {4134, 4809, 4812, 4816, 17638, 17799, 23724, 134768},
    "CU": {
        4837, 4808, 17620, 17621, 17622, 17623, 17773, 17788, 17789,
        17816, 134542,
    },
    "CM": {
        9808, 24400, 24444, 24445, 24547, 56040, 56041, 56042, 56043,
        56044, 56045, 56046, 56047, 56048, 56049, 56050, 56051, 56052,
        56053, 56054, 56055, 56056, 56057, 56058, 58453,
    },
}
CARRIER_NAME_RE = {
    "CT": re.compile(
        r"china\s*telecom|chinanet|ctgnet|cn2|中国电信", re.I
    ),
    "CU": re.compile(
        r"china\s*unicom|china169|cncgroup|unicom|中国联通", re.I
    ),
    "CM": re.compile(
        r"china\s*mobile|cmnet|cmcc|cmi(?:\W|$)|中国移动", re.I
    ),
}
REGION_BOUNDS = {
    # Bounding boxes are only a last-resort hint. They overlap and must never override
    # Globalping's state field or the explicit city→province map.
    "北京": (39.3, 41.2, 115.3, 117.7),
    "上海": (30.6, 31.9, 120.8, 122.2),
    "广东": (20.0, 25.7, 109.4, 117.4),
    "安徽": (29.3, 34.8, 114.7, 119.8),
    "江苏": (30.6, 35.3, 116.2, 122.0),
    "浙江": (27.0, 31.6, 118.0, 123.1),
}
REGION_STATE_ALIASES = {
    "北京": {"beijing", "beijingmunicipality", "cn11", "cnbj", "bj", "北京市"},
    "上海": {"shanghai", "shanghaimunicipality", "cn31", "cnsh", "sh", "上海市"},
    "广东": {"guangdong", "guangdongsheng", "cn44", "cngd", "gd", "广东", "广东省"},
    "安徽": {"anhui", "anhuisheng", "cn34", "cnah", "ah", "安徽", "安徽省"},
    "江苏": {"jiangsu", "jiangsusheng", "cn32", "cnjs", "js", "江苏", "江苏省"},
    "浙江": {"zhejiang", "zhejiangsheng", "cn33", "cnzj", "zj", "浙江", "浙江省"},
}
CROSS_REGION_ORDER = {
    "北京": ["上海", "江苏", "浙江", "安徽", "广东"],
    "上海": ["江苏", "浙江", "安徽", "北京", "广东"],
    "广东": ["浙江", "上海", "江苏", "安徽", "北京"],
    "安徽": ["江苏", "浙江", "上海", "北京", "广东"],
    "江苏": ["上海", "浙江", "安徽", "北京", "广东"],
    "浙江": ["上海", "江苏", "安徽", "广东", "北京"],
}
MAX_PROVINCE_CARRIER_ATTEMPTS = 5
MAX_PROVINCE_REFERENCE_ATTEMPTS = 1
MAX_CROSS_PROVINCE_ATTEMPTS = 2
PROBE_INVENTORY: list[dict[str, Any]] | None = None
PROBE_INVENTORY_ERROR = ""
ICMP_TARGETS_CACHE: list[dict[str, Any]] | None = None
ICMP_TARGETS_ERROR = ""


def line(char: str = "═", color: str = BLUE) -> None:
    print(color + char * WIDTH + RESET)


def section(title: str, color: str = CYAN) -> None:
    print()
    line("═", BLUE)
    print(color + f"  {title}" + RESET)
    line("─", BLUE)


def field(label: str, value: Any, color: str = WHITE) -> None:
    text = str(value)
    if len(text) > WIDTH - 24:
        text = text[: WIDTH - 25] + "…"
    print(f"  {GRAY}{label:<16}{RESET} {color}{text}{RESET}")


def valid_ipv4(value: str, public: bool | None = None) -> bool:
    try:
        ip = ipaddress.ip_address(value)
        if ip.version != 4:
            return False
        if public is True:
            return ip.is_global
        if public is False:
            return ip.is_private
        return True
    except ValueError:
        return False


def mask_ip(value: str) -> str:
    if not valid_ipv4(value):
        return "N/A"
    parts = value.split(".")
    return f"{parts[0]}.{parts[1]}.*.*"


def ask_inputs() -> tuple[str, int, str, str, str]:
    global ENTRY_IP, PORT_TEXT, EXPECTED_EXIT, LOCAL_PRIVATE, REMOTE_PEER
    if SELF_TEST:
        return "211.136.162.184", 10103, "87.86.87.231", "172.16.2.101", ""

    section("INPUT GUIDE / 沪日专线目标输入", MAGENTA)
    field("本线架构", "中国用户 → 211.136.162.184:10103 → 隐藏专线 → 172.16.2.101 → 87.86.87.231")
    field("入口 IP 示例", "211.136.162.184", CYAN)
    field("协议端口示例", "10103 Mieru TCP（10100 是 SSH 管理端口）", GREEN)
    field("重要提醒", "填写业务端口；不要填 SSH 22，也不要把管理端口 10100 当业务端口", YELLOW)
    field("日本出口示例", "87.86.87.231（114.111.176.37 是供应商外部／NAT 地址）", GREEN)
    field("日本内网示例", "172.16.2.101；上海内网对端未知可直接回车", CYAN)

    while not valid_ipv4(ENTRY_IP, public=True):
        ENTRY_IP = input("请输入上海／中国侧公网入口 IPv4〔例 211.136.162.184〕：").strip()
        if not valid_ipv4(ENTRY_IP, public=True):
            print(RED + "  IPv4 无效，请重新输入。" + RESET)
    while True:
        if not PORT_TEXT:
            PORT_TEXT = input("请输入协议业务端口〔本线 10103；不是 SSH 22／10100〕：").strip()
        try:
            port = int(PORT_TEXT)
            if 1 <= port <= 65535:
                break
        except ValueError:
            pass
        print(RED + "  端口无效，请输入 1～65535。" + RESET)
        PORT_TEXT = ""
    if not EXPECTED_EXIT:
        EXPECTED_EXIT = input("请输入预期日本公网出口 IP〔本线 87.86.87.231；未知可回车〕：").strip()
    if EXPECTED_EXIT and not valid_ipv4(EXPECTED_EXIT, public=True):
        print(YELLOW + "  预期出口格式无效，本项按 N/A 处理。" + RESET)
        EXPECTED_EXIT = ""
    if not LOCAL_PRIVATE:
        LOCAL_PRIVATE = input("请输入日本端专线内网 IP〔例 172.16.2.101；未知可回车〕：").strip()
    if LOCAL_PRIVATE and not valid_ipv4(LOCAL_PRIVATE):
        print(YELLOW + "  日本端内网 IP 格式无效，本项按 N/A 处理。" + RESET)
        LOCAL_PRIVATE = ""
    if REMOTE_PEER and not valid_ipv4(REMOTE_PEER):
        print(YELLOW + "  上海内网对端格式无效，纯内段测试按 N/A 处理。" + RESET)
        REMOTE_PEER = ""
    return ENTRY_IP, port, EXPECTED_EXIT, LOCAL_PRIVATE, REMOTE_PEER


def http_json(url: str, method: str = "GET", payload: Any = None, timeout: int = 25) -> Any:
    body = None
    headers = {"Accept": "application/json", "User-Agent": "ix-route/0.1"}
    if payload is not None:
        body = json.dumps(payload, ensure_ascii=False).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.loads(response.read().decode())


def public_identity() -> dict[str, str]:
    identity = {"ip": "", "asn": "", "org": "", "country": "", "city": ""}
    for url in ("https://ipwho.is/", "https://api.ipify.org?format=json"):
        try:
            data = http_json(url, timeout=10)
            ip = str(data.get("ip", ""))
            if not valid_ipv4(ip, public=True):
                continue
            connection = data.get("connection") or {}
            identity.update({
                "ip": ip,
                "asn": str(connection.get("asn") or data.get("asn") or ""),
                "org": str(connection.get("org") or connection.get("isp") or data.get("isp") or ""),
                "country": str(data.get("country") or ""),
                "city": str(data.get("city") or ""),
            })
            if identity["asn"] and identity["org"]:
                return identity
            break
        except Exception:
            pass
    if not identity["ip"]:
        return identity
    lookup_urls = (
        f"https://ipwho.is/{identity['ip']}",
        f"https://api.ip.sb/geoip/{identity['ip']}",
        f"https://ipapi.co/{identity['ip']}/json/",
    )
    for url in lookup_urls:
        try:
            data = http_json(url, timeout=10)
            connection = data.get("connection") or {}
            raw_asn = (
                connection.get("asn") or data.get("asn") or data.get("asn_number")
                or data.get("autonomous_system_number") or ""
            )
            raw_org = (
                connection.get("org") or connection.get("isp") or data.get("isp")
                or data.get("organization") or data.get("org")
                or data.get("autonomous_system_organization") or ""
            )
            if raw_asn and not identity["asn"]:
                identity["asn"] = str(raw_asn)
            if raw_org and not identity["org"]:
                identity["org"] = str(raw_org)
            identity["country"] = identity["country"] or str(
                data.get("country") or data.get("country_name") or ""
            )
            identity["city"] = identity["city"] or str(data.get("city") or "")
            if identity["asn"] and identity["org"]:
                break
        except Exception:
            pass
    if identity["asn"] and not identity["asn"].upper().startswith("AS"):
        identity["asn"] = "AS" + re.sub(r"\D", "", identity["asn"])
    return identity


def run(command: list[str], timeout: int = 30) -> str:
    try:
        result = subprocess.run(command, text=True, capture_output=True, timeout=timeout)
        return (result.stdout + result.stderr).strip()
    except Exception as exc:
        return f"COMMAND_ERROR {type(exc).__name__}: {exc}"


def local_addresses() -> list[str]:
    output = run(["ip", "-4", "-o", "addr", "show"], 5) if shutil.which("ip") else ""
    return re.findall(r"\binet\s+((?:\d{1,3}\.){3}\d{1,3})/", output)


def network_context(entry: str) -> dict[str, str]:
    if not shutil.which("ip"):
        return {"defaultRoute": "N/A｜系统无 ip", "entryRoute": "N/A｜系统无 ip"}
    default_route = run(["ip", "-4", "route", "show", "default"], 5)
    entry_route = run(["ip", "-4", "route", "get", entry], 5)
    return {
        "defaultRoute": default_route.splitlines()[0] if default_route else "N/A",
        "entryRoute": entry_route.splitlines()[0] if entry_route else "N/A",
    }


def listener_status(port: int) -> dict[str, Any]:
    if not shutil.which("ss"):
        return {"status": "N/A", "evidence": "系统无 ss，未检查本机监听"}
    output = run(["ss", "-lntup"], 8)
    matched = [row for row in output.splitlines() if re.search(rf":{port}\b", row)]
    if not matched:
        return {"status": "FAIL", "evidence": f"未发现 TCP／UDP {port} 监听"}
    return {"status": "PASS", "evidence": " | ".join(matched[:3])}


def mieru_service(port: int) -> dict[str, Any]:
    """Identify the local Mieru server without reading or exposing credentials."""
    if SELF_TEST:
        return {
            "status": "PASS",
            "binary": "mita",
            "version": "mita 3.34.1 SELF-TEST",
            "runtime": "RUNNING",
            "systemd": "active",
            "ntp": "PASS",
            "port": port,
            "evidence": "mita 3.34.1｜RUNNING｜systemd active｜NTP synchronized",
        }
    binary = shutil.which("mita") or ""
    version = run([binary, "version"], 8) if binary else ""
    status_text = run([binary, "status"], 8) if binary else ""
    systemd = run(["systemctl", "is-active", "mita"], 8) if shutil.which("systemctl") else "N/A"
    ntp_value = (
        run(["timedatectl", "show", "-p", "NTPSynchronized", "--value"], 8)
        if shutil.which("timedatectl") else "N/A"
    )
    running = bool(re.search(r"\bRUNNING\b|\brunning\b", status_text, re.I)) or systemd.strip() == "active"
    ntp_status = "PASS" if ntp_value.strip().lower() in {"yes", "true", "1"} else "N/A"
    if not binary:
        result = "N/A"
        evidence = "未找到 mita；本项不影响其他协议的入口与出口检测"
    elif running:
        result = "PASS"
        short_version = next((x.strip() for x in version.splitlines() if x.strip()), "版本未知")
        evidence = f"{short_version}｜RUNNING｜systemd {systemd or 'N/A'}｜NTP {ntp_status}"
    else:
        result = "FAIL"
        evidence = f"已找到 mita，但未确认 RUNNING｜systemd {systemd or 'N/A'}"
    return {
        "status": result,
        "binary": binary or "N/A",
        "version": version or "N/A",
        "runtime": status_text or "N/A",
        "systemd": systemd or "N/A",
        "ntp": ntp_status,
        "port": port,
        "evidence": evidence,
    }


def handshake_verdict(
    client_exit: str,
    expected_exit: str,
    actual_exit: str,
    service: dict[str, Any],
    chain: dict[str, str],
) -> dict[str, str]:
    if client_exit and not valid_ipv4(client_exit, public=True):
        return {"status": "N/A", "reason": "中国客户端实测出口格式无效"}
    if not client_exit:
        return {
            "status": "N/A",
            "reason": "尚未提供中国客户端连接 Mieru 后实测到的公网出口",
        }
    if client_exit != actual_exit or (expected_exit and client_exit != expected_exit):
        return {
            "status": "FAIL",
            "reason": (
                f"客户端实测 {mask_ip(client_exit)}，与日本端实际／预期出口不一致"
            ),
        }
    if service.get("status") != "PASS":
        return {
            "status": "INCONCLUSIVE",
            "reason": "客户端出口一致，但日本端 mita 服务状态未确认",
        }
    if chain.get("status") != "PASS":
        return {
            "status": "INCONCLUSIVE",
            "reason": "客户端出口一致，但入口映射链证据尚不完整",
        }
    return {
        "status": "PASS",
        "reason": "中国客户端经 Mieru 连接后出口与日本端实际／预期出口一致",
    }


def percentile(values: list[float], ratio: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[max(0, math.ceil(ratio * len(ordered)) - 1)], 2)


def summarize(values: list[float], sent: int) -> dict[str, Any]:
    if not values:
        return {
            "status": "N/A", "avg": None, "p95": None, "jitter": None,
            "loss": None, "received": 0, "sent": sent,
        }
    jitter = statistics.mean(
        abs(values[i] - values[i - 1]) for i in range(1, len(values))
    ) if len(values) > 1 else 0.0
    return {
        "status": "PASS",
        "avg": round(statistics.mean(values), 2),
        "p95": percentile(values, 0.95),
        "jitter": round(jitter, 2),
        "loss": round((sent - len(values)) * 100 / sent, 1),
        "received": len(values),
        "sent": sent,
    }


def normalized_city(value: str) -> str:
    return re.sub(r"[^a-z]", "", value.lower())


def normalized_place(value: Any) -> str:
    return re.sub(r"[^a-z0-9\u4e00-\u9fff]", "", str(value or "").lower())


def city_regions(value: str) -> set[str]:
    key = normalized_city(value)
    if not key:
        return set()
    return {
        region
        for region, cities in CITY_CANDIDATES.items()
        if any(normalized_city(city) == key for city in cities)
    }


def coordinate_regions(latitude: Any, longitude: Any) -> list[str]:
    try:
        lat = float(latitude)
        lon = float(longitude)
    except (TypeError, ValueError):
        return []
    return [
        region
        for region, (south, north, west, east) in REGION_BOUNDS.items()
        if south <= lat <= north and west <= lon <= east
    ]


def infer_probe_region(location: dict[str, Any]) -> tuple[str, str]:
    """Resolve a Chinese probe to one target province without overlapping boxes.

    Globalping exposes `state`; use it first. An explicit city map is second.
    Coordinates are accepted only when exactly one of our six regions matches.
    """
    state_key = normalized_place(location.get("state"))
    state_matches = [
        region
        for region, aliases in REGION_STATE_ALIASES.items()
        if state_key and state_key in aliases
    ]
    city_matches = city_regions(str(location.get("city") or ""))
    if len(state_matches) == 1:
        state_region = state_matches[0]
        if city_matches and state_region not in city_matches:
            return "", "STATE_CITY_CONFLICT"
        return state_region, "STATE"
    if len(city_matches) == 1:
        return next(iter(city_matches)), "CITY_MAP"
    coordinate_matches = coordinate_regions(
        location.get("latitude"), location.get("longitude")
    )
    if len(coordinate_matches) == 1:
        return coordinate_matches[0], "UNIQUE_COORDINATE"
    return "", "AMBIGUOUS_OR_UNKNOWN"


def coordinates_match_region(region: str, latitude: Any, longitude: Any) -> bool:
    # Kept for report compatibility; strict inference is used for selection.
    matches = coordinate_regions(latitude, longitude)
    return len(matches) == 1 and matches[0] == region


def probe_tags(item: dict[str, Any]) -> set[str]:
    values: set[str] = set()
    for tag in item.get("tags") or []:
        if isinstance(tag, dict):
            value = tag.get("value")
        else:
            value = tag
        if value:
            values.add(str(value).lower())
    return values


def load_probe_inventory() -> list[dict[str, Any]]:
    """Load Globalping's live probe list once so unavailable cities are not tested blindly."""
    global PROBE_INVENTORY, PROBE_INVENTORY_ERROR
    if PROBE_INVENTORY is not None:
        return PROBE_INVENTORY
    try:
        data = http_json(GLOBALPING_PROBES_API, timeout=35)
        if not isinstance(data, list):
            raise RuntimeError("在线探针接口未返回列表")
        PROBE_INVENTORY = [
            item for item in data
            if isinstance(item, dict)
            and isinstance(item.get("location"), dict)
            and str(item["location"].get("country") or "").upper() == "CN"
        ]
        if not PROBE_INVENTORY:
            raise RuntimeError("在线探针清单中没有中国探针")
    except Exception as exc:
        PROBE_INVENTORY = []
        PROBE_INVENTORY_ERROR = f"{type(exc).__name__}: {exc}"
    return PROBE_INVENTORY


def inventory_attempts(
    carrier: str, region: str, capital_city: str
) -> list[tuple[dict[str, Any], str, str, bool, str, str]]:
    """Select every real online probe inside the province, ordered by carrier fidelity."""
    inventory = load_probe_inventory()
    if not inventory:
        return []
    allowed_cities = CITY_CANDIDATES.get(region, [capital_city])
    city_rank = {normalized_city(city): index for index, city in enumerate(allowed_cities)}
    rows: list[dict[str, Any]] = []
    for item in inventory:
        location = item.get("location") or {}
        probe_region, province_method = infer_probe_region(location)
        if probe_region != region:
            continue
        actual_city = str(location.get("city") or "")
        key = normalized_city(actual_city)
        listed_city = key in city_rank
        if not actual_city:
            continue
        try:
            asn = int(location.get("asn") or 0)
        except (TypeError, ValueError):
            asn = 0
        network = str(location.get("network") or "")
        tags = probe_tags(item)
        is_carrier = (
            asn in CARRIER_ASNS[carrier]
            or bool(CARRIER_NAME_RE[carrier].search(network))
        )
        rows.append({
            "city": actual_city,
            "cityRank": city_rank.get(key, len(allowed_cities) + 1),
            "listedCity": listed_city,
            "asn": asn,
            "network": network,
            "tags": tags,
            "province": probe_region,
            "provinceMethod": province_method,
            "state": str(location.get("state") or ""),
            "carrier": is_carrier,
            "eyeball": "eyeball-network" in tags,
            "datacenter": "datacenter-network" in tags,
        })

    carrier_attempts: list[tuple[dict[str, Any], str, str, bool, str, str]] = []
    reference_attempts: list[tuple[dict[str, Any], str, str, bool, str, str]] = []
    seen: set[tuple[str, int, str]] = set()

    def add(row: dict[str, Any], tier: str, tag: str = "") -> None:
        dedupe = (normalized_city(row["city"]), row["asn"], tier)
        if dedupe in seen:
            return
        seen.add(dedupe)
        location: dict[str, Any] = {"country": "CN", "city": row["city"]}
        if row["asn"]:
            location["asn"] = row["asn"]
        elif row["network"]:
            location["network"] = row["network"]
        if tag:
            location["tags"] = [tag]
        label = "+".join(
            [
                row["city"],
                f"AS{row['asn']}" if row["asn"] else row["network"],
                tag or "online",
            ]
        )
        target = reference_attempts if tier.endswith("_REFERENCE") else carrier_attempts
        target.append((
            location,
            label,
            row["city"],
            row["cityRank"] == 0,
            tier,
            row["province"],
        ))

    ordered = sorted(rows, key=lambda x: (x["cityRank"], x["asn"], x["network"]))
    # True three-network residential/access samples: capital first, then any city in province.
    for row in ordered:
        if row["carrier"] and row["eyeball"]:
            add(
                row,
                (
                    "CAPITAL_CARRIER_EYEBALL"
                    if row["cityRank"] == 0
                    else "PROVINCE_CARRIER_EYEBALL"
                ),
                "eyeball-network",
            )
    # Same-carrier datacenter is a valid carrier path sample, explicitly marked non-residential.
    for row in ordered:
        if row["carrier"] and row["datacenter"]:
            add(row, "PROVINCE_CARRIER_DATACENTER", "datacenter-network")
    # Some live probes have a verified carrier ASN/network but no system classification tag.
    for row in ordered:
        if row["carrier"] and not row["eyeball"] and not row["datacenter"]:
            add(row, "PROVINCE_CARRIER_NETWORK", "")
    # Last resort: any online datacenter in the same province.
    for row in ordered:
        if row["datacenter"]:
            add(row, "PROVINCE_DATACENTER_REFERENCE", "datacenter-network")
    return (
        carrier_attempts[:MAX_PROVINCE_CARRIER_ATTEMPTS]
        + reference_attempts[:MAX_PROVINCE_REFERENCE_ATTEMPTS]
    )


def cross_region_carrier_attempts(
    carrier: str, requested_region: str
) -> list[tuple[dict[str, Any], str, str, bool, str, str]]:
    """Last-resort same-carrier probes outside the requested province.

    These samples are always REFERENCE and never count as the requested
    province's carrier PASS.
    """
    inventory = load_probe_inventory()
    order = {
        region: index
        for index, region in enumerate(CROSS_REGION_ORDER[requested_region])
    }
    rows: list[dict[str, Any]] = []
    for item in inventory:
        location = item.get("location") or {}
        probe_region, province_method = infer_probe_region(location)
        if not probe_region or probe_region == requested_region or probe_region not in order:
            continue
        actual_city = str(location.get("city") or "")
        if not actual_city:
            continue
        try:
            asn = int(location.get("asn") or 0)
        except (TypeError, ValueError):
            asn = 0
        network = str(location.get("network") or "")
        if not (
            asn in CARRIER_ASNS[carrier]
            or bool(CARRIER_NAME_RE[carrier].search(network))
        ):
            continue
        tags = probe_tags(item)
        source_cities = CITY_CANDIDATES.get(probe_region, [])
        city_key = normalized_city(actual_city)
        city_rank = next(
            (
                index
                for index, name in enumerate(source_cities)
                if normalized_city(name) == city_key
            ),
            len(source_cities) + 1,
        )
        rows.append({
            "city": actual_city,
            "cityRank": city_rank,
            "asn": asn,
            "network": network,
            "tags": tags,
            "province": probe_region,
            "provinceMethod": province_method,
        })
    rows.sort(key=lambda row: (
        order[row["province"]],
        0 if "eyeball-network" in row["tags"] else 1,
        row["cityRank"],
        row["asn"],
    ))
    attempts: list[tuple[dict[str, Any], str, str, bool, str, str]] = []
    seen: set[tuple[str, int]] = set()
    for row in rows:
        key = (normalized_city(row["city"]), row["asn"])
        if key in seen:
            continue
        seen.add(key)
        tag = (
            "eyeball-network"
            if "eyeball-network" in row["tags"]
            else "datacenter-network"
            if "datacenter-network" in row["tags"]
            else ""
        )
        source_kind = (
            "EYEBALL" if tag == "eyeball-network"
            else "DATACENTER" if tag == "datacenter-network"
            else "NETWORK"
        )
        location: dict[str, Any] = {"country": "CN", "city": row["city"]}
        if row["asn"]:
            location["asn"] = row["asn"]
        elif row["network"]:
            location["network"] = row["network"]
        if tag:
            location["tags"] = [tag]
        label = "+".join([
            row["city"],
            f"AS{row['asn']}" if row["asn"] else row["network"],
            tag or "online",
        ])
        attempts.append((
            location,
            label,
            row["city"],
            False,
            f"CROSS_PROVINCE_CARRIER_{source_kind}",
            row["province"],
        ))
        if len(attempts) >= MAX_CROSS_PROVINCE_ATTEMPTS:
            break
    return attempts


def no_probe_error(detail: str) -> bool:
    """Recognize Globalping's structured no_probes_found error reliably."""
    try:
        payload = json.loads(detail)
        error = payload.get("error") or {}
        if str(error.get("type") or "").lower() == "no_probes_found":
            return True
        detail = f"{error.get('type', '')} {error.get('message', '')}"
    except Exception:
        pass
    return bool(re.search(
        r"no[_\s-]*(?:matching[_\s-]*(?:ipv[46][_\s-]*)?)?probes?"
        r"|no matching ipv[46] probes?|not enough probes"
        r"|could not find.*probe|location.*not found",
        detail,
        re.I,
    ))


def dynamic_return_targets(carrier: str, region: str, primary: str) -> tuple[list[str], str]:
    """Build a province/carrier target pool using oneclickvirt's maintained data source."""
    global ICMP_TARGETS_CACHE, ICMP_TARGETS_ERROR
    if SELF_TEST:
        return [primary], "SELF_TEST_PRIMARY"
    if ICMP_TARGETS_CACHE is None:
        try:
            data = http_json(ICMP_TARGETS_API, timeout=25)
            if not isinstance(data, list):
                raise RuntimeError("省级三网目标接口未返回列表")
            ICMP_TARGETS_CACHE = [x for x in data if isinstance(x, dict)]
        except Exception as exc:
            ICMP_TARGETS_CACHE = []
            ICMP_TARGETS_ERROR = f"{type(exc).__name__}: {exc}"
    province_names = {
        "北京": {"北京", "北京市"},
        "上海": {"上海", "上海市"},
        "广东": {"广东", "广东省"},
        "安徽": {"安徽", "安徽省"},
        "江苏": {"江苏", "江苏省"},
        "浙江": {"浙江", "浙江省"},
    }
    isp_codes = {"CT": "ct", "CU": "cu", "CM": "cm"}
    candidates = [primary]
    for row in ICMP_TARGETS_CACHE:
        if (
            str(row.get("province") or "") not in province_names[region]
            or str(row.get("isp_code") or "").lower() != isp_codes[carrier]
            or str(row.get("ip_version") or "").lower() != "v4"
        ):
            continue
        for value in str(row.get("ips") or "").split(","):
            value = value.strip()
            if valid_ipv4(value, public=True) and value not in candidates:
                candidates.append(value)
                if len(candidates) >= 3:
                    break
        if len(candidates) >= 3:
            break
    source = (
        "STATIC_PRIMARY+DYNAMIC_PROVINCE_BACKUP"
        if len(candidates) > 1
        else f"STATIC_PRIMARY_ONLY{('｜' + ICMP_TARGETS_ERROR) if ICMP_TARGETS_ERROR else ''}"
    )
    return candidates, source


def ping_peer(peer: str, count: int = 20) -> dict[str, Any]:
    if not peer:
        return {
            "status": "N/A",
            "reason": "未提供上海端专线内网对端 IP，无法测量纯内段",
            "stats": summarize([], count),
            "route": "",
        }
    if not shutil.which("ping"):
        return {
            "status": "N/A", "reason": "系统无 ping",
            "stats": summarize([], count), "route": "",
        }
    output = run(["ping", "-n", "-c", str(count), "-W", "2", "-i", "0.2", peer], count * 3)
    values = [float(x) for x in re.findall(r"time[=<]([\d.]+)\s*ms", output)]
    stats = summarize(values, count)
    if not values:
        stats["status"] = "INCONCLUSIVE"
    route = ""
    if shutil.which("mtr"):
        route = run(["mtr", "-n", "-r", "-c", "10", "-w", peer], 35)
    elif shutil.which("traceroute"):
        route = run(["traceroute", "-n", "-q", "1", "-w", "1", "-m", "16", peer], 25)
    return {
        "status": stats["status"],
        "reason": "" if values else "内网对端未响应 ICMP；可能禁 Ping，不能直接判定专线中断",
        "stats": stats,
        "route": route,
    }


def await_globalping(measurement_id: str, polls: int = 35) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for _ in range(polls):
        time.sleep(0.8)
        result = http_json(f"{GLOBALPING_API}/{measurement_id}")
        if result.get("status") == "finished":
            return result
        if result.get("status") != "in-progress":
            raise RuntimeError(f"API 状态 {result.get('status')}")
    raise TimeoutError("等待远端结果超时")


def same_probe_tcp_check(entry: str, port: int, measurement_id: str) -> dict[str, Any]:
    """Confirm the business TCP port from the exact traceroute probe.

    Globalping officially supports reusing a previous measurement ID as the
    location selector. This prevents a silent final traceroute hop from being
    mislabeled as unreachable.
    """
    try:
        created = http_json(
            GLOBALPING_API,
            "POST",
            {
                "target": entry,
                "type": "ping",
                "locations": measurement_id,
                "measurementOptions": {
                    "protocol": "TCP",
                    "port": port,
                    "packets": 3,
                },
            },
        )
        check_id = str(created.get("id") or "")
        if not check_id:
            raise RuntimeError("TCP 复核未返回 measurement id")
        result = await_globalping(check_id, 25)
        rtts: list[float] = []
        for item in result.get("results") or []:
            detail = item.get("result") or {}
            if detail.get("status") != "finished":
                continue
            for timing in detail.get("timings") or []:
                if timing.get("rtt") is not None:
                    rtts.append(float(timing["rtt"]))
        stats = summarize(rtts, 3)
        return {
            "status": "PASS" if rtts else "INCONCLUSIVE",
            "latency": stats,
            "received": len(rtts),
            "measurementId": check_id,
            "reason": (
                f"同一探针 TCP 业务端口复核 {len(rtts)}/3 响应"
                if rtts
                else "同一探针 TCP 业务端口复核未取得响应"
            ),
        }
    except Exception as exc:
        return {
            "status": "N/A",
            "latency": summarize([], 3),
            "received": 0,
            "measurementId": "",
            "reason": f"TCP 业务端口复核异常 {type(exc).__name__}: {exc}",
        }


def forward_sample_status(
    *,
    reached: bool,
    city_verified: bool,
    selection_province_verified: bool,
    province_verified: bool,
    asn_verified: bool,
    is_cross_province: bool,
    is_reference: bool,
) -> tuple[str, bool, str]:
    """Separate endpoint/carrier reachability from requested-region fidelity.

    A same-carrier probe in another province can prove that carrier reaches the
    business endpoint, but it cannot represent the requested province.  Keep
    both facts instead of turning a successful TCP test into a zero-score
    REFERENCE or pretending it was an exact regional sample.
    """
    carrier_reachable = bool(
        reached
        and city_verified
        and selection_province_verified
        and asn_verified
    )
    if (
        carrier_reachable
        and province_verified
        and not is_cross_province
        and not is_reference
    ):
        return "PASS", True, "REGION_EXACT"
    if is_cross_province:
        if carrier_reachable:
            return "PASS_FALLBACK", True, "CROSS_PROVINCE_FALLBACK"
        return "INCONCLUSIVE", False, "CROSS_PROVINCE_UNVERIFIED"
    if reached and city_verified and selection_province_verified and is_reference:
        return "REFERENCE", False, "PROVINCE_GENERIC_REFERENCE"
    return "INCONCLUSIVE", False, "UNVERIFIED"


def globalping_probe(entry: str, port: int, carrier: str, region: str, city: str) -> dict[str, Any]:
    name, asn, _ = CARRIERS[carrier]
    # v0.9 uses Globalping state → explicit city map → unique coordinates. Overlapping
    # bounding boxes can no longer mislabel Xuzhou/Nanjing as Anhui.
    inventory_available = bool(load_probe_inventory())
    attempts = inventory_attempts(carrier, region, city)
    inventory_used = inventory_available
    if inventory_available:
        # Cross-province same-carrier probes are appended only as a clearly labeled
        # last resort. They can never count as the requested province's PASS.
        attempts += cross_region_carrier_attempts(carrier, region)
    elif not attempts:
        # Inventory failure fallback: preserve the old magic path without claiming it was prechecked.
        carrier_attempts: list[tuple[dict[str, Any], str, str, bool, str, str]] = []
        reference_attempts: list[tuple[dict[str, Any], str, str, bool, str, str]] = []
        for candidate_city in CITY_CANDIDATES.get(region, [city]):
            is_capital = candidate_city == city
            for selector in CARRIER_SELECTORS[carrier]:
                carrier_attempts.append((
                    {"magic": f"{candidate_city}+{selector}+eyeball"},
                    f"{candidate_city}+{selector}+eyeball",
                    candidate_city,
                    is_capital,
                    (
                        "CAPITAL_CARRIER_EYEBALL"
                        if is_capital
                        else "PROVINCE_CARRIER_EYEBALL"
                    ),
                    region,
                ))
            reference_attempts.append((
                {"magic": f"{candidate_city}+datacenter"},
                f"{candidate_city}+datacenter",
                candidate_city,
                is_capital,
                "PROVINCE_DATACENTER_REFERENCE",
                region,
            ))
        cross_attempts: list[tuple[dict[str, Any], str, str, bool, str, str]] = []
        as_selector = f"AS{asn}"
        for fallback_region in CROSS_REGION_ORDER[region][:MAX_CROSS_PROVINCE_ATTEMPTS]:
            fallback_city = CITY_CANDIDATES[fallback_region][0]
            cross_attempts.append((
                {"magic": f"{fallback_city}+{as_selector}+eyeball"},
                f"{fallback_city}+{as_selector}+eyeball",
                fallback_city,
                False,
                "CROSS_PROVINCE_CARRIER_EYEBALL",
                fallback_region,
            ))
        attempts = (
            carrier_attempts
            + reference_attempts[:MAX_PROVINCE_REFERENCE_ATTEMPTS]
            + cross_attempts
        )
    errors: list[str] = []
    no_probe_count = 0
    api_error_count = 0
    best_result: dict[str, Any] | None = None
    same_province_reference: dict[str, Any] | None = None
    for (
        location,
        mode,
        requested_city,
        is_capital,
        selection_tier,
        selection_region,
    ) in attempts:
        try:
            created = http_json(
                GLOBALPING_API,
                "POST",
                {
                    "target": entry,
                    "type": "traceroute",
                    "limit": 1,
                    "locations": [location],
                    "measurementOptions": {"protocol": "TCP", "port": port},
                },
            )
            measurement_id = created.get("id")
            if not measurement_id:
                raise RuntimeError("API 未返回 measurement id")
            result = await_globalping(str(measurement_id))
            item = next(
                (x for x in result.get("results", []) if x.get("result", {}).get("status") == "finished"),
                None,
            )
            if not item:
                raise RuntimeError("无有效探针结果")
            probe = item.get("probe") or {}
            source_asn = int(probe.get("asn") or 0)
            actual_city = str(probe.get("city") or "")
            actual_state = str(probe.get("state") or "")
            actual_network = str(
                probe.get("network")
                or probe.get("networkName")
                or probe.get("isp")
                or ""
            )
            actual_probe_region, province_match_method = infer_probe_region({
                "state": actual_state,
                "city": actual_city,
                "latitude": probe.get("latitude"),
                "longitude": probe.get("longitude"),
            })
            selection_province_verified = actual_probe_region == selection_region
            province_verified = actual_probe_region == region
            city_verified = re.sub(r"[^a-z]", "", actual_city.lower()) == re.sub(
                r"[^a-z]", "", requested_city.lower()
            )
            asn_verified = (
                source_asn in CARRIER_ASNS[carrier]
                or bool(CARRIER_NAME_RE[carrier].search(actual_network))
            )
            route_lines: list[str] = []
            target_rtts: list[float] = []
            last_rtts: list[float] = []
            reached = False
            for index, hop in enumerate((item.get("result") or {}).get("hops") or [], 1):
                address = str(hop.get("resolvedAddress") or "")
                rtts = [
                    float(t["rtt"]) for t in (hop.get("timings") or [])
                    if t.get("rtt") is not None
                ]
                if rtts:
                    last_rtts = rtts
                if address == entry:
                    reached = True
                    target_rtts = rtts
                shown = " ".join(f"{x:.1f}ms" for x in rtts) if rtts else "* * *"
                route_lines.append(f"{index:02d} {address or '*':<16} {shown}")
            trace_reached = reached
            tcp_check = {
                "status": "NOT_NEEDED",
                "latency": summarize([], 3),
                "received": 0,
                "measurementId": "",
                "reason": "TCP traceroute 已显示终点",
            }
            if not reached:
                tcp_check = same_probe_tcp_check(
                    entry, port, str(measurement_id)
                )
                reached = tcp_check["status"] == "PASS"
            rtts = target_rtts or last_rtts
            if reached and not trace_reached:
                checked_latency = tcp_check.get("latency") or {}
                if checked_latency.get("avg") is not None:
                    rtts = [float(checked_latency["avg"])]
            latency = summarize(rtts, len(rtts)) if rtts else summarize([], 0)
            latency["loss"] = None
            is_cross_province = selection_tier.startswith("CROSS_PROVINCE_")
            is_reference = (
                selection_tier.endswith("_REFERENCE") or is_cross_province
            )
            carrier_representative = bool(
                asn_verified and province_verified and not is_reference
            )
            source_class = (
                "CROSS_PROVINCE_CARRIER_FALLBACK"
                if is_cross_province
                else
                "GENERIC_DATACENTER_REFERENCE"
                if is_reference
                else "CARRIER_DATACENTER"
                if selection_tier.endswith("_DATACENTER")
                else "CARRIER_EYEBALL"
                if selection_tier.endswith("_EYEBALL")
                else "CARRIER_NETWORK"
            )
            status, carrier_reachability_verified, region_fidelity = forward_sample_status(
                reached=reached,
                city_verified=city_verified,
                selection_province_verified=selection_province_verified,
                province_verified=province_verified,
                asn_verified=asn_verified,
                is_cross_province=is_cross_province,
                is_reference=is_reference,
            )
            reasons: list[str] = []
            if not city_verified:
                reasons.append(
                    f"城市核对失败：请求 {requested_city}，实际 {actual_city or '未知城市'}"
                )
            if not selection_province_verified:
                reasons.append(
                    f"省份核对失败：选点期望 {selection_region}，实际 "
                    f"{actual_probe_region or '无法确认'}（{province_match_method}）"
                )
            if not asn_verified and (not is_reference or is_cross_province):
                reasons.append(
                    f"运营商核对失败：预期 {name}，实际 AS{source_asn or 'N/A'}"
                    f" {actual_network or '未知网络'}"
                )
            if is_cross_province:
                reasons.append(
                    f"{region}本省未取得{name}有效探针；最后降级到"
                    f"{selection_region} {requested_city} 的同运营商测点；"
                    f"业务端口到达计入{name}可达，但不计入{region}地区精准覆盖"
                )
            elif is_reference:
                reasons.append(
                    f"{region}省级数据中心参考点；只证明该省到入口可达，不冒充{name}家宽"
                )
            elif source_class == "CARRIER_DATACENTER":
                reasons.append(
                    f"{region}省内{name}运营商机房测点；ASN／网络归属已核对，非家宽探针"
                )
            elif source_class == "CARRIER_NETWORK":
                reasons.append(
                    f"{region}省内{name}运营商网络测点；探针未标家宽／机房类型"
                )
            if not reached:
                reasons.append(
                    "TCP traceroute 未显示终点；"
                    f"{tcp_check['reason']}；不等于真实业务 100% 丢包"
                )
            elif not trace_reached:
                reasons.append(
                    f"TCP traceroute 末跳未显示，但{tcp_check['reason']}，判定业务端口可达"
                )
            if not is_capital and not is_cross_province:
                reasons.append(
                    f"省会 {city} 无可用探针，已退到{region}省内 {requested_city}"
                )
            candidate_result = {
                "carrier": carrier,
                "carrierName": name,
                "requestedRegion": region,
                "displayRegion": region,
                "mode": mode,
                "probeCity": actual_city,
                "probeState": actual_state,
                "probeRegion": actual_probe_region,
                "probeAsn": source_asn,
                "probeNetwork": actual_network,
                "capitalPreferred": is_capital,
                "selectorCity": requested_city,
                "selectionRegion": selection_region,
                "selectionTier": selection_tier,
                "sourceClass": source_class,
                "inventoryPrechecked": inventory_used,
                "carrierRepresentative": carrier_representative,
                "carrierReachabilityVerified": carrier_reachability_verified,
                "regionFidelity": region_fidelity,
                "carrierIdentityVerified": asn_verified,
                "asnVerified": asn_verified,
                "cityVerified": city_verified,
                "provinceVerified": province_verified,
                "selectionProvinceVerified": selection_province_verified,
                "provinceMatchMethod": province_match_method,
                "status": status,
                "targetReached": reached,
                "traceTargetReached": trace_reached,
                "tcpPortCheck": tcp_check,
                "latency": latency,
                "route": "\n".join(route_lines),
                "reason": "；".join(reasons),
            }
            if status == "PASS":
                return candidate_result
            if status == "REFERENCE" and not is_cross_province:
                same_province_reference = candidate_result
            candidate_rank = (
                30 if status == "PASS_FALLBACK"
                else 20 if status == "REFERENCE"
                else 10 if asn_verified and selection_province_verified
                else 0
            )
            best_rank = int((best_result or {}).get("_selectionRank", -1))
            candidate_result["_selectionRank"] = candidate_rank
            if best_result is None or candidate_rank > best_rank:
                best_result = candidate_result
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:1000]
            if exc.code == 422:
                if no_probe_error(detail):
                    no_probe_count += 1
                    errors.append(f"{mode}: 无在线匹配探针")
                else:
                    api_error_count += 1
                    errors.append(f"{mode}: API 422 {detail}")
            else:
                api_error_count += 1
                errors.append(f"{mode}: HTTP {exc.code} {detail}")
        except Exception as exc:
            api_error_count += 1
            errors.append(f"{mode}: {type(exc).__name__}: {exc}")
    if best_result is not None:
        best_result.pop("_selectionRank", None)
        if (
            best_result.get("sourceClass") == "CROSS_PROVINCE_CARRIER_FALLBACK"
            and same_province_reference is not None
        ):
            best_result["sameProvinceReference"] = {
                "city": same_province_reference.get("probeCity") or "",
                "asn": same_province_reference.get("probeAsn") or 0,
                "network": same_province_reference.get("probeNetwork") or "",
                "targetReached": same_province_reference.get("targetReached", False),
            }
            best_result["reason"] += (
                f"；同时已确认{region}省内第三方机房 "
                f"{same_province_reference.get('probeCity') or '未知城市'} 到入口可达"
            )
        return best_result
    all_unavailable = no_probe_count == len(attempts) and api_error_count == 0
    return {
        "carrier": carrier,
        "carrierName": name,
        "requestedRegion": region,
        "displayRegion": region,
        "mode": "NO_PROBE" if all_unavailable else "N/A",
        "probeCity": "",
        "probeState": "",
        "probeRegion": "",
        "probeAsn": 0,
        "probeNetwork": "",
        "capitalPreferred": True,
        "selectorCity": city,
        "selectionRegion": region,
        "selectionTier": "NONE",
        "sourceClass": "NONE",
        "inventoryPrechecked": inventory_used,
        "carrierRepresentative": False,
        "carrierReachabilityVerified": False,
        "regionFidelity": "UNAVAILABLE",
        "carrierIdentityVerified": False,
        "asnVerified": False,
        "cityVerified": False,
        "provinceVerified": False,
        "selectionProvinceVerified": False,
        "provinceMatchMethod": "NONE",
        "status": "NO_PROBE" if all_unavailable else "N/A",
        "targetReached": False,
        "traceTargetReached": False,
        "tcpPortCheck": {
            "status": "N/A",
            "received": 0,
            "reason": "未取得可复核探针",
        },
        "latency": summarize([], 0),
        "route": "",
        "reason": (
            f"已按在线清单执行省会→全省行政区扫描→运营商网络→省内数据中心"
            f"→跨省同运营商最后备援，筛选 {len(attempts)} 组候选；"
            f"{region}当前没有在线可用探针"
            if all_unavailable
            else (
                f"在线探针清单读取失败 {PROBE_INVENTORY_ERROR}；"
                f"已降级使用 magic 选点｜{'；'.join(errors[-4:])}"
                if PROBE_INVENTORY_ERROR
                else f"探针 API／测量异常，不得误报为全省无探针｜{'；'.join(errors[-4:])}"
            )
        ),
    }


def self_test_probe(carrier: str, region: str, city: str, index: int) -> dict[str, Any]:
    name, asn, _ = CARRIERS[carrier]
    reached = index % 7 != 0
    return {
        "carrier": carrier,
        "carrierName": name,
        "requestedRegion": region,
        "displayRegion": region,
        "mode": f"{region}+AS{asn}",
        "probeCity": city,
        "probeState": region,
        "probeRegion": region,
        "probeAsn": asn,
        "probeNetwork": name,
        "capitalPreferred": index % 5 != 0,
        "selectorCity": city,
        "selectionRegion": region,
        "selectionTier": (
            "CAPITAL_CARRIER_EYEBALL"
            if index % 5
            else "PROVINCE_CARRIER_EYEBALL"
        ),
        "sourceClass": "CARRIER_EYEBALL",
        "carrierRepresentative": True,
        "carrierReachabilityVerified": reached,
        "regionFidelity": "REGION_EXACT" if reached else "UNVERIFIED",
        "carrierIdentityVerified": True,
        "asnVerified": True,
        "cityVerified": True,
        "provinceVerified": True,
        "selectionProvinceVerified": True,
        "provinceMatchMethod": "SELF_TEST",
        "status": "PASS" if reached else "INCONCLUSIVE",
        "targetReached": reached,
        "traceTargetReached": reached,
        "tcpPortCheck": {
            "status": "NOT_NEEDED" if reached else "INCONCLUSIVE",
            "received": 0,
            "reason": "SELF-TEST",
        },
        "latency": {
            "status": "PASS", "avg": round(18.0 + index * 1.7, 1),
            "p95": round(20.0 + index * 1.7, 1), "jitter": 1.2,
            "loss": None, "received": 3, "sent": 3,
        },
        "route": "01 10.0.0.1 1.0ms\n02 211.136.162.184 25.0ms",
        "reason": "" if reached else "SELF-TEST 模拟未显示终点",
    }


def selection_self_test() -> None:
    """Regression: state wins; overlapping boxes can never cross-label provinces."""
    global PROBE_INVENTORY, PROBE_INVENTORY_ERROR
    saved_inventory = PROBE_INVENTORY
    saved_error = PROBE_INVENTORY_ERROR
    try:
        PROBE_INVENTORY_ERROR = ""
        PROBE_INVENTORY = [
            {
                "location": {
                    "country": "CN",
                    "city": "Tongcheng",
                    "state": "Anhui",
                    "latitude": 31.05,
                    "longitude": 116.95,
                    "asn": 4134,
                    "network": "China Telecom",
                },
                "tags": ["datacenter-network"],
            },
            {
                "location": {
                    "country": "CN",
                    "city": "Hefei",
                    "state": "Anhui",
                    "latitude": 31.82,
                    "longitude": 117.23,
                    "asn": 37963,
                    "network": "Third-party IDC",
                },
                "tags": ["datacenter-network"],
            },
            {
                "location": {
                    "country": "CN",
                    "city": "Xuzhou",
                    "state": "Jiangsu",
                    "latitude": 34.26,
                    "longitude": 117.18,
                    "asn": 4134,
                    "network": "China Telecom",
                },
                "tags": ["eyeball-network"],
            },
            {
                "location": {
                    "country": "CN",
                    "city": "Nanjing",
                    "state": "Jiangsu",
                    "latitude": 32.06,
                    "longitude": 118.79,
                    "asn": 4837,
                    "network": "China Unicom",
                },
                "tags": ["eyeball-network"],
            },
        ]
        attempts = inventory_attempts("CT", "安徽", "Hefei")
        if not attempts:
            raise AssertionError("省级坐标扫描未返回候选")
        if attempts[0][2] != "Tongcheng":
            raise AssertionError("未优先选择同省运营商探针")
        if attempts[0][4] != "PROVINCE_CARRIER_DATACENTER":
            raise AssertionError("同省运营商机房分类错误")
        if not any(x[4] == "PROVINCE_DATACENTER_REFERENCE" for x in attempts):
            raise AssertionError("第三方省级参考回退缺失")
        if any(x[2] in {"Xuzhou", "Nanjing"} for x in attempts):
            raise AssertionError("江苏城市被错误纳入安徽省内候选")
        cross_attempts = cross_region_carrier_attempts("CT", "安徽")
        if not any(x[2] == "Xuzhou" and x[5] == "江苏" for x in cross_attempts):
            raise AssertionError("跨省同运营商最后备援缺失")
        if infer_probe_region({
            "city": "Nanjing",
            "state": "Jiangsu",
            "latitude": 32.06,
            "longitude": 118.79,
        })[0] != "江苏":
            raise AssertionError("南京行政区判定错误")
        if 4816 not in CARRIER_ASNS["CT"]:
            raise AssertionError("电信省网 ASN 家族缺少 AS4816")
        if not {24445, *range(56049, 56059)}.issubset(CARRIER_ASNS["CM"]):
            raise AssertionError("移动省网 ASN 家族不完整")
        fallback_status = forward_sample_status(
            reached=True,
            city_verified=True,
            selection_province_verified=True,
            province_verified=False,
            asn_verified=True,
            is_cross_province=True,
            is_reference=True,
        )
        if fallback_status != (
            "PASS_FALLBACK", True, "CROSS_PROVINCE_FALLBACK"
        ):
            raise AssertionError("跨省同运营商到达未与地区精准度分离")
    finally:
        PROBE_INVENTORY = saved_inventory
        PROBE_INVENTORY_ERROR = saved_error


def route_hop_count(route: str) -> int:
    return sum(
        1 for row in route.splitlines()
        if re.search(r"^\s*\d+\s+(?:\d{1,3}\.){3}\d{1,3}(?:\s|$)", row)
    )


def traceroute_rtts(route: str) -> list[float]:
    values: list[float] = []
    for row in route.splitlines():
        if re.search(r"^\s*\d+\s+", row):
            values.extend(float(x) for x in re.findall(r"(\d+(?:\.\d+)?)\s*ms", row))
    return values


def return_route_label(carrier: str, route: str) -> tuple[str, list[str], str]:
    patterns = {
        "CT": [
            ("CN2 GIA／CN2", [r"59\.43\."], "AS4809｜CN2 精品骨干"),
            ("ChinaNet 163", [r"202\.97\."], "AS4134｜ChinaNet 163 普通骨干"),
        ],
        "CU": [
            ("CUII AS9929", [r"218\.105\.", r"210\.(51|52|53|78)\."], "AS9929｜CUII 联通精品骨干"),
            ("China169 AS4837", [r"219\.158\."], "AS4837｜China169 联通普通骨干"),
        ],
        "CM": [
            ("CMIN2", [r"223\.118\.32\."], "AS58807｜CMIN2 移动精品骨干"),
            ("CMI／CMNET", [r"223\.(118|119)\.", r"221\.183\.", r"111\.24\."], "AS58453／AS9808｜移动普通骨干"),
        ],
    }
    matched = [
        (label, tag) for label, expressions, tag in patterns[carrier]
        if any(re.search(expression, route, re.I) for expression in expressions)
    ]
    if not matched:
        return (
            "INCONCLUSIVE｜可见跳点证据不足",
            ["未识别骨干｜不按普通线或精品线强判"],
            "仅确认日本出口到目标运营商公网地址的可见路由；缺少特征跳点时保持证据不足。",
        )
    labels = [x[0] for x in matched]
    tags = [x[1] for x in matched]
    return (
        " → ".join(labels),
        tags,
        "线路标签来自可见特征 IP；中间节点不回应不作为端到端业务丢包。",
    )


def return_probe(carrier: str, region: str, host: str) -> dict[str, Any]:
    """Trace VPS→China return paths with protocol fallback and province target fallback.

    Inspired by oneclickvirt/backtrace: use repeated hop probes and alternate ICMP
    targets. Unlike backtrace, targets remain return-path evidence only.
    """
    name, _, _ = CARRIERS[carrier]
    candidates, target_source = dynamic_return_targets(carrier, region, host)
    selected_host = host
    selected_protocol = "SELF_TEST"
    protocol_attempts: list[dict[str, Any]] = []
    if SELF_TEST:
        routes = {
            "CT": "1 87.86.87.1 1.2 ms\n2 59.43.181.1 32.0 ms\n3 219.141.136.10 38.1 ms",
            "CU": "1 87.86.87.1 1.1 ms\n2 219.158.8.1 41.0 ms\n3 202.106.50.1 45.2 ms",
            "CM": "1 87.86.87.1 1.0 ms\n2 223.118.32.1 35.0 ms\n3 221.179.155.161 39.4 ms",
        }
        route = routes[carrier]
        protocol_attempts.append({"host": host, "protocol": "SELF_TEST", "hops": 3, "identified": True})
    elif shutil.which("traceroute") or shutil.which("tracepath"):
        best: tuple[int, int, int, str, str, str] | None = None
        for candidate in candidates:
            methods: list[tuple[str, list[str]]] = []
            if shutil.which("traceroute"):
                # -q 3 follows backtrace's multi-sample idea without spawning three
                # full traces for every one of the 36 matrix entries.
                base = ["traceroute", "-n", "-q", "3", "-w", "2", "-m", "30"]
                methods = [
                    ("TCP", base + ["-T", "-p", "80", candidate]),
                    ("ICMP", base + ["-I", candidate]),
                    ("UDP", base + ["-U", "-p", "33434", candidate]),
                ]
            else:
                methods = [("TRACEPATH", ["tracepath", "-n", "-m", "30", candidate])]
            for protocol, command in methods:
                candidate_route = run(command, 70)
                candidate_hops = route_hop_count(candidate_route)
                candidate_class, _, _ = return_route_label(carrier, candidate_route)
                identified = not candidate_class.startswith("INCONCLUSIVE")
                values = traceroute_rtts(candidate_route)
                rtt_samples = len(values)
                protocol_attempts.append({
                    "host": candidate,
                    "protocol": protocol,
                    "hops": candidate_hops,
                    "identified": identified,
                    "routeClass": candidate_class,
                    "rttSamples": rtt_samples,
                })
                rank = (
                    1 if identified else 0,
                    candidate_hops,
                    rtt_samples,
                    candidate,
                    protocol,
                    candidate_route,
                )
                if best is None or rank[:3] > best[:3]:
                    best = rank
                # TCP is closest to the Mieru business path. Only fall back when
                # TCP does not expose a known backbone or enough valid hops.
                if protocol == "TCP" and identified and candidate_hops >= 3:
                    break
                if protocol != "TCP" and identified and candidate_hops >= 3:
                    break
            if best is not None and best[0] and best[1] >= 3:
                break
        if best is None:
            route = ""
        else:
            selected_host = best[3]
            selected_protocol = best[4]
            route = best[5]
    else:
        return {
            "carrier": carrier, "carrierName": name, "region": region,
            "capital": CAPITALS[region], "host": host, "primaryHost": host,
            "targetSource": target_source, "targetCandidates": candidates,
            "selectedProtocol": "N/A", "protocolAttempts": [],
            "status": "N/A",
            "route": "", "routeHops": 0, "routeClass": "N/A",
            "backboneTags": [], "routeNote": "系统无 traceroute／tracepath",
            "latency": summarize([], 0), "reason": "缺少回程路由工具；不换算为 100% 丢包",
        }
    hops = route_hop_count(route)
    if not hops:
        return {
            "carrier": carrier, "carrierName": name, "region": region,
            "capital": CAPITALS[region], "host": selected_host, "primaryHost": host,
            "targetSource": target_source, "targetCandidates": candidates,
            "selectedProtocol": selected_protocol,
            "protocolAttempts": protocol_attempts,
            "status": "INCONCLUSIVE",
            "route": route, "routeHops": 0, "routeClass": "回程无有效跳点",
            "backboneTags": [], "routeNote": "TCP／ICMP／UDP均未取得有效跳点；不等于业务中断",
            "latency": summarize([], 0), "reason": "多协议 traceroute 无有效回覆；不换算为 100% 丢包",
        }
    values = traceroute_rtts(route)
    latency = summarize(values[-9:], len(values[-9:])) if values else summarize([], 0)
    latency["loss"] = None
    route_class, tags, note = return_route_label(carrier, route)
    identified_runs = sum(bool(x.get("identified")) for x in protocol_attempts)
    return {
        "carrier": carrier, "carrierName": name, "region": region,
        "capital": CAPITALS[region], "host": selected_host, "primaryHost": host,
        "targetSource": target_source, "targetCandidates": candidates,
        "selectedProtocol": selected_protocol,
        "protocolAttempts": protocol_attempts,
        "identifiedAttempts": identified_runs,
        "status": "PASS",
        "route": route, "routeHops": hops, "routeClass": route_class,
        "backboneTags": tags,
        "routeNote": note + f" 实际采用 {selected_protocol}；协议冲突时以可见跳点证据为准。",
        "latency": latency,
        "reason": (
            f"取得 {hops} 个有效回程跳点；采用 {selected_protocol}，"
            f"{identified_runs}/{len(protocol_attempts)} 次协议／目标尝试识别到骨干；"
            f"使用 {'固定主测点' if selected_host == host else '省级三网动态备援点'}"
        ),
    }


def quality_label(internal: dict[str, Any]) -> str:
    stats = internal.get("stats") or {}
    if internal.get("status") != "PASS" or stats.get("avg") is None:
        return "N/A｜缺少可验证的专线纯内段数据"
    avg = float(stats["avg"])
    loss = float(stats.get("loss") or 0)
    jitter = float(stats.get("jitter") or 0)
    if avg <= 45 and loss == 0 and jitter <= 5:
        return "优秀｜符合沪日低时延专线特征"
    if avg <= 70 and loss <= 1 and jitter <= 10:
        return "良好｜可作为稳定中转"
    if avg <= 100 and loss <= 3:
        return "一般｜建议晚高峰复测"
    return "较差｜需检查内段拥塞、限速或路由"


def mapping_chain(access: dict[str, Any], listener: dict[str, Any], local_status: str) -> dict[str, str]:
    reachable = access.get(
        "endpointReachable", access.get("reachable", access.get("pass", 0))
    )
    if reachable > 0 and listener.get("status") == "PASS" and local_status == "PASS":
        return {
            "status": "PASS",
            "reason": "中国省级在线探针可达入口业务端口＋日本私网主机同端口监听＋本机私网地址吻合",
        }
    if reachable > 0 and listener.get("status") == "PASS":
        return {
            "status": "PARTIAL",
            "reason": "入口端口可达且日本端监听，但日本私网地址未核对",
        }
    if reachable > 0:
        return {
            "status": "INCONCLUSIVE",
            "reason": "入口端口可达，但日本端未确认同端口监听",
        }
    return {
        "status": "N/A",
        "reason": "缺少足够的入口与日本端关联证据",
    }


def markdown_report(report: dict[str, Any]) -> str:
    access = report["access"]
    internal = report["internal"]
    identity = report["exitIdentity"]
    listener = report["listener"]
    lines = [
        f"# 沪日专线／IX-style Mieru 四层质量检测报告",
        "",
        f"- 版本：{report['version']}",
        f"- 时间：{report['generated']}",
        f"- 上海入口：`{report['entry']['masked']}:{report['entry']['port']}`",
        f"- 日本出口：`{mask_ip(identity.get('ip', ''))}` / {identity.get('asn') or 'N/A'} / {identity.get('org') or 'N/A'}",
        f"- 测试矩阵：{report['matrix']}",
        "",
        "## 结论",
        "",
        (
            f"- 上海入口端到端 TCP：{access['status']}（运营商可达 "
            f"{access.get('carrierReachable', access['pass'])}/{access['total']}，"
            f"原省精确 {access['pass']}/{access['total']}，省级可达 "
            f"{access.get('reachable', access['pass'])}/{access['total']}，"
            f"省内第三方机房参考 {access.get('provinceReference', 0)}，"
            f"跨省同运营商降级 {access.get('crossProvinceFallback', 0)}，"
            f"INCONCLUSIVE {access['inconclusive']}，"
            f"NO_PROBE {access.get('noProbe', 0)}，N/A {access['na']}）"
        ),
        f"- 日本端业务监听：{listener['status']} — {listener['evidence']}",
        f"- Mieru／Mita 服务：{report['mieruService']['status']} — {report['mieruService']['evidence']}",
        f"- Mieru 真实握手：{report['protocolHandshake']['status']} — {report['protocolHandshake']['reason']}",
        f"- 上海→日本端口映射链：{report['mappingChain']['status']} — {report['mappingChain']['reason']}",
        f"- 专线纯内段（可选）：{internal['status']} — {quality_label(internal)}",
        f"- 日本出口一致性：{report['exitMatch']['status']} — {report['exitMatch']['reason']}",
        "",
        "## 四层判定边界",
        "",
        "1. 中国探针到入口业务端口的 TCP traceroute 到达，表示入口映射后的 TCP 路径可达。",
        "2. 入口端口可达、日本端同端口监听及私网地址吻合，作为端口映射链证据，但不冒充协议认证成功。",
        "3. 只有供应商确实提供上海内网对端时，才额外统计纯内段 Ping RTT／P95／抖动／丢包。",
        "4. 自动识别 mita 服务；只有中国客户端连接后实测出口一致，真实握手才为 PASS。",
        "5. traceroute 中间跳点不回应、DNS 或探针失败不记作 100% 业务丢包。",
        "6. “IX-style”是工具名称，不等于已证明经过某个 IXP。",
        "",
        "## 中国侧入口探针",
        "",
        "| 省级任务 | 运营商 | 实际省／城市 | 来源类型 | 选点层级 | 代表性 | 终点 | RTT | 状态 |",
        "|---|---|---|---|---|---|---:|---:|---|",
    ]
    for item in report["probes"]:
        latency = item.get("latency") or {}
        rtt = f"{latency['avg']} ms" if latency.get("avg") is not None else "N/A"
        lines.append(
            f"| {item['requestedRegion']} | {item['carrierName']} | "
            f"{item.get('probeRegion') or 'N/A'}／{item.get('probeCity') or 'N/A'} | "
            f"{item.get('sourceClass') or 'N/A'} | "
            f"{item.get('selectionTier') or 'N/A'} | "
            f"{'本省运营商有效' if item.get('carrierRepresentative') else '跨省同运营商可达／非原省代表' if item.get('sourceClass') == 'CROSS_PROVINCE_CARRIER_FALLBACK' else '省内第三方参考'} | "
            f"{'到达' if item.get('targetReached') else '未确认'} | {rtt} | {item['status']} |"
        )
    lines.extend([
        "",
        "## 日本出口至北上广／六地三网回程",
        "",
        "| 地区 | 运营商 | 公网目标 | 可见跳点 | RTT | 路由标签 | 状态 |",
        "|---|---|---|---:|---:|---|---|",
    ])
    for item in report["returns"]:
        latency = item.get("latency") or {}
        rtt = f"{latency['avg']} ms" if latency.get("avg") is not None else "N/A"
        lines.append(
            f"| {item['capital']} | {item['carrierName']} | `{item['host']}` | "
            f"{item['routeHops']} | {rtt} | {item['routeClass']} | {item['status']} |"
        )
    stats = internal.get("stats") or {}
    lines.extend([
        "",
        "## 映射链与专线纯内段",
        "",
        f"- 日本端内网：`{report['localPrivate']['masked']}`；本机存在：{report['localPrivate']['status']}",
        f"- 上海端内网对端：`{report['remotePeer']['masked']}`",
        f"- 映射链证据：{report['mappingChain']['status']} — {report['mappingChain']['reason']}",
        f"- 默认路由：`{report['networkContext']['defaultRoute']}`",
        f"- 到上海入口路由：`{report['networkContext']['entryRoute']}`",
        f"- 平均 RTT：{stats.get('avg') if stats.get('avg') is not None else 'N/A'} ms",
        f"- P95：{stats.get('p95') if stats.get('p95') is not None else 'N/A'} ms",
        f"- 抖动：{stats.get('jitter') if stats.get('jitter') is not None else 'N/A'} ms",
        f"- ICMP 丢包：{stats.get('loss') if stats.get('loss') is not None else 'N/A'}%",
        "",
        "## 方法说明",
        "",
        report["methodology"],
        "",
    ])
    return "\n".join(lines)


def write_html(report: dict[str, Any], path: Path) -> None:
    embedded = json.dumps(report, ensure_ascii=False).replace("</", "<\\/")
    path.write_text(f"""<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Chain 3Net｜沪日专线 Mieru 四层质量报告</title>
<style>
:root{{--bg:#07111f;--panel:#0d1b2d;--line:#1e3a56;--text:#e6f2ff;--muted:#8da8c4;--cyan:#35d9ff;--green:#42e39a;--yellow:#ffd166;--red:#ff657a}}
*{{box-sizing:border-box}}body{{margin:0;background:radial-gradient(circle at top,#102a46 0,#07111f 45%);color:var(--text);font:14px/1.55 Inter,"Microsoft YaHei",sans-serif}}
main{{max-width:1280px;margin:auto;padding:28px}}header,.panel{{background:rgba(13,27,45,.94);border:1px solid var(--line);border-radius:14px;box-shadow:0 14px 40px #0006}}
header{{padding:25px;margin-bottom:18px}}h1{{margin:0;color:var(--cyan);letter-spacing:.06em}}.sub{{color:var(--muted);margin-top:7px}}.grid{{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin:18px 0}}
.card{{padding:15px;border-radius:10px;background:#091827;border:1px solid var(--line)}}.card span{{display:block;color:var(--muted)}}.card strong{{display:block;margin-top:8px;font-size:18px}}
.PASS,.PASS_FALLBACK{{color:var(--green)}}.FAIL{{color:var(--red)}}.N\\/A,.NO_PROBE,.INCONCLUSIVE,.PARTIAL,.REFERENCE{{color:var(--yellow)}}.panel{{padding:20px;margin:16px 0}}h2{{font-size:16px;color:var(--cyan);margin:0 0 14px}}
.topology{{display:flex;align-items:center;gap:8px;overflow:auto;padding:6px 0}}.node{{min-width:180px;background:#091827;border:1px solid #2e5576;border-radius:10px;padding:13px;text-align:center}}.arrow{{color:var(--yellow);font-size:20px}}
table{{width:100%;border-collapse:collapse}}th,td{{border-bottom:1px solid var(--line);padding:9px;text-align:left;vertical-align:top}}th{{color:var(--muted)}}code{{color:#a9efff}}button{{background:#0e7490;color:white;border:0;border-radius:8px;padding:9px 13px;cursor:pointer;margin-right:8px}}
.note{{color:var(--muted)}}@media(max-width:850px){{.grid{{grid-template-columns:1fr 1fr}}main{{padding:14px}}}}@media print{{body{{background:white;color:#111}}header,.panel{{box-shadow:none;background:white}}}}
</style></head><body><main>
<header><h1>CHAIN 3NET · 沪日专线 MIERU 四层质量报告</h1><div class="sub" id="meta"></div>
<div style="margin-top:14px"><button id="json">下载 JSON</button><button onclick="window.print()">打印／另存 PDF</button></div></header>
<section class="panel"><h2>TOPOLOGY / 实际业务拓扑</h2><div class="topology" id="topology"></div></section>
<div class="grid" id="cards"></div>
<section class="panel"><h2>MIERU / 日本端服务证据</h2><table id="mieru"></table></section>
<section class="panel"><h2>FORWARD / 省级任务三网去程</h2><div style="overflow:auto"><table><thead><tr><th>省级任务</th><th>运营商</th><th>实际省／城市</th><th>来源类型</th><th>选点层级</th><th>实际网络／ASN</th><th>代表性</th><th>终点</th><th>RTT</th><th>状态</th><th>说明</th></tr></thead><tbody id="rows"></tbody></table></div><p class="note">省会无探针时先扫描同省全部在线城市；同省运营商机房／未分类运营商网络可作为运营商去程证据并明确标注非家宽。全省仍无指定运营商时，才使用跨省同运营商测点；终点到达标为 PASS_FALLBACK 并计入运营商可达，但不计入原省精准覆盖。NO_PROBE 不代表线路中断或 100% 丢包。</p></section>
<section class="panel"><h2>RETURN / 日本出口至北上广固定三网回程</h2><div style="overflow:auto"><table><thead><tr><th>地区</th><th>运营商</th><th>目标</th><th>跳点</th><th>RTT</th><th>路由标签</th><th>骨干证据</th><th>状态</th></tr></thead><tbody id="returnRows"></tbody></table></div></section>
<section class="panel"><h2>BOUNDARY / 判定边界</h2><p class="note" id="method"></p></section>
</main><script>
const R={embedded}; const E=s=>String(s??'N/A').replace(/[&<>"']/g,c=>({{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}}[c]));
const metric=(v,suffix='')=>v===null||v===undefined||v===''?'N/A':`${{E(v)}}${{suffix}}`;
const badge=(label,obj)=>`<article class="card"><span>${{E(label)}}</span><strong class="${{E(obj.status)}}">${{E(obj.status)}}</strong><small>${{E(obj.reason||obj.evidence||'')}}</small></article>`;
document.getElementById('meta').textContent=`${{R.generated}} · ${{R.version}} · ${{R.matrix}}`;
document.getElementById('topology').innerHTML=[
`<div class="node">中国 Mieru 客户端</div>`,`<b class="arrow">→</b>`,
`<div class="node">上海入口<br><code>${{E(R.entry.masked)}}:${{R.entry.port}}</code></div>`,`<b class="arrow">→</b>`,
`<div class="node">隐藏专线／映射链</div>`,`<b class="arrow">→</b>`,
`<div class="node">日本 Mita<br><code>${{E(R.localPrivate.masked)}}:${{R.entry.port}}</code></div>`,`<b class="arrow">→</b>`,
`<div class="node">日本出口<br><code>${{E(R.exitIdentity.ipMasked)}}</code></div>`].join('');
document.getElementById('cards').innerHTML=[
badge('上海入口接入',{{status:R.access.status,reason:`运营商可达 ${{R.access.carrierReachable??R.access.pass}}/${{R.access.total}} · 原省精确 ${{R.access.pass}}/${{R.access.total}} · 跨省同运营商降级 ${{R.access.crossProvinceFallback??0}}`}}),
badge('上海→日本映射链',R.mappingChain),badge('Mieru 真实握手',R.protocolHandshake),badge('日本出口一致性',R.exitMatch)].join('');
const M=R.mieruService;
document.getElementById('mieru').innerHTML=`<tr><th>服务识别</th><td class="${{E(M.status)}}">${{E(M.status)}}</td><th>版本</th><td>${{E(M.version)}}</td></tr>
<tr><th>运行状态</th><td>${{E(M.runtime)}}</td><th>systemd</th><td>${{E(M.systemd)}}</td></tr>
<tr><th>NTP</th><td>${{E(M.ntp)}}</td><th>端口监听</th><td class="${{E(R.listener.status)}}">${{E(R.listener.status)}} · ${{E(R.listener.evidence)}}</td></tr>`;
document.getElementById('rows').innerHTML=R.probes.map(p=>`<tr><td>${{E(p.displayRegion||p.requestedRegion)}}</td><td>${{E(p.carrierName)}}</td><td>${{E(p.probeRegion||'N/A')}}／${{E(p.probeCity||'N/A')}}${{p.sourceClass==='CROSS_PROVINCE_CARRIER_FALLBACK'?'<br><small>跨省最后备援</small>':p.capitalPreferred===false?'<br><small>同省备选</small>':''}}</td><td>${{E(p.sourceClass||'N/A')}}</td><td>${{E(p.selectionTier||'N/A')}}</td><td>${{E(p.probeNetwork||'N/A')}}<br><small>AS${{E(p.probeAsn||'N/A')}}</small></td><td>${{p.carrierRepresentative?'本省运营商有效':p.sourceClass==='CROSS_PROVINCE_CARRIER_FALLBACK'?'同运营商可达／非原省代表':'省内第三方参考'}}</td><td>${{p.targetReached?'到达':'未确认'}}${{p.traceTargetReached===false&&p.targetReached?'<br><small>同探针 TCP 复核</small>':''}}</td><td>${{metric(p.latency?.avg,' ms')}}</td><td class="${{E(p.status)}}">${{E(p.status)}}</td><td>${{E(p.reason)}}</td></tr>`).join('');
document.getElementById('returnRows').innerHTML=R.returns.map(p=>`<tr><td>${{E(p.capital)}}</td><td>${{E(p.carrierName)}}</td><td><code>${{E(p.host)}}</code><br><small>${{p.primaryHost&&p.host!==p.primaryHost?'省级动态备援':'固定主测点'}}</small></td><td>${{p.routeHops?E(p.routeHops):'N/A'}}</td><td>${{metric(p.latency?.avg,' ms')}}</td><td>${{E(p.routeClass)}}</td><td>${{E((p.backboneTags||[]).join(' → '))}}<br><small>${{E(p.routeNote)}}</small></td><td class="${{E(p.status)}}">${{E(p.status)}}</td></tr>`).join('');
document.getElementById('method').textContent=R.methodology;
document.getElementById('json').onclick=()=>{{const a=document.createElement('a');a.download='ix-route-report.json';a.href=URL.createObjectURL(new Blob([JSON.stringify(R,null,2)],{{type:'application/json'}}));a.click()}};
</script></body></html>""", encoding="utf-8")


def public_report_payload(report: dict[str, Any]) -> dict[str, Any]:
    """Map IX access samples onto Chain 3Net's established storage schema."""
    carrier_names = {"CT": "中国电信", "CU": "中国联通", "CM": "中国移动"}
    carriers: list[dict[str, Any]] = []
    for carrier in ("CT", "CU", "CM"):
        items = [x for x in report["probes"] if x["carrier"] == carrier]
        passed = [x for x in items if x["status"] == "PASS"]
        fallback_passed = [x for x in items if x["status"] == "PASS_FALLBACK"]
        carrier_reached = passed + fallback_passed
        score = round(
            (len(passed) * 100 + len(fallback_passed) * 70) / len(items)
        ) if items else 0
        flat = []
        for item in items:
            latency = item.get("latency") or {}
            flat.append({
                "region": item["requestedRegion"],
                "label": f"{item['requestedRegion']} {carrier_names[carrier]} → 上海入口",
                "access": item.get("mode") or "N/A",
                "publicIp": "",
                "verified": bool(
                    item.get("carrierRepresentative")
                    and item.get("cityVerified")
                    and item.get("provinceVerified")
                    and item.get("targetReached")
                ),
                "route": "Mieru TCP 上海入口接入",
                "evidence": (
                    f"实际省市 {item.get('probeRegion') or 'N/A'}／"
                    f"{item.get('probeCity') or 'N/A'}；"
                    f"行政区核对 {item.get('provinceMatchMethod') or 'N/A'}；"
                    f"选点 {item.get('selectionTier') or 'N/A'}；"
                    f"TCP路由终点 {'到达' if item.get('traceTargetReached') else '未显示'}；"
                    f"{item.get('reason') or 'TCP traceroute 终点到达'}"
                ),
                "score": (
                    100 if item["status"] == "PASS"
                    else 70 if item["status"] == "PASS_FALLBACK"
                    else 0
                ),
                "stars": (
                    "★★★★★" if item["status"] == "PASS"
                    else "★★★★☆" if item["status"] == "PASS_FALLBACK"
                    else "☆☆☆☆☆"
                ),
                "avg": latency.get("avg"), "min": None, "max": None,
                "p95": latency.get("p95"), "jitter": latency.get("jitter"),
                "stddev": None, "loss": None,
                "success": "1/1" if item.get("targetReached") else "0/1",
                "routeHops": len(item.get("route", "").splitlines()),
                "timeoutHops": 0,
                "backboneTags": (
                    ["Mieru TCP", "上海映射入口"]
                    + (
                        ["同探针 TCP 业务端口复核"]
                        if item.get("targetReached")
                        and not item.get("traceTargetReached")
                        else []
                    )
                ),
                "reachability": (
                    "PASS｜原省运营商探针到达"
                    if item["status"] == "PASS"
                    else "PASS_FALLBACK｜跨省同运营商探针到达，非原省代表"
                    if item["status"] == "PASS_FALLBACK"
                    else item["status"]
                ),
            })
        summary = {
            "region": "入口接入汇总", "label": "中国三网 → 上海 Mieru 入口",
            "access": report["matrix"], "publicIp": "",
            "verified": all(
                x.get("carrierRepresentative")
                and x.get("cityVerified")
                and x.get("provinceVerified")
                for x in items
            ) if items else False,
            "route": "Mieru TCP 上海入口接入",
            "evidence": (
                f"运营商可达 {len(carrier_reached)}/{len(items)}；"
                f"原省精确 {len(passed)}/{len(items)}；"
                f"跨省同运营商降级 {len(fallback_passed)}；"
                "仅为入口接入，不作为普通回程"
            ),
            "score": score, "stars": "★★★★★" if score >= 80 else "★★★☆☆",
            "avg": round(statistics.mean(
                x["latency"]["avg"] for x in carrier_reached
                if x.get("latency", {}).get("avg") is not None
            ), 1) if any(
                x.get("latency", {}).get("avg") is not None
                for x in carrier_reached
            ) else None,
            "min": None, "max": None, "p95": None, "jitter": None,
            "stddev": None, "loss": None,
            "success": f"{len(carrier_reached)}/{len(items)}", "routeHops": 0,
            "timeoutHops": 0, "backboneTags": ["Mieru TCP", "专线映射链"],
            "reachability": report["access"]["status"],
        }
        return_items = [x for x in report["returns"] if x["carrier"] == carrier]
        return_passed = [x for x in return_items if x["status"] == "PASS"]
        return_score = round(len(return_passed) * 100 / len(return_items)) if return_items else 0
        return_probes = []
        for item in return_items:
            latency = item.get("latency") or {}
            return_probes.append({
                "city": item["capital"], "host": item["host"], "ip": item["host"],
                "route": item["routeClass"], "evidence": item["reason"],
                "score": 100 if item["status"] == "PASS" else 0,
                "stars": "★★★★★" if item["status"] == "PASS" else "☆☆☆☆☆",
                "avg": latency.get("avg"), "min": None, "max": None,
                "p95": latency.get("p95"), "jitter": latency.get("jitter"),
                "stddev": None, "loss": None,
                "success": "1/1" if item["status"] == "PASS" else "0/1",
                "routeHops": item["routeHops"], "timeoutHops": 0,
                "backboneTags": item.get("backboneTags", []),
                "routeNote": item.get("routeNote", ""),
                "probeCapital": item["capital"],
                "targetSource": item.get("targetSource", "STATIC_PRIMARY"),
                "primaryHost": item.get("primaryHost", item["host"]),
                "reachability": item["status"],
            })
        overall_score = round(score * 0.5 + return_score * 0.5)
        carriers.append({
            "id": carrier, "name": carrier_names[carrier],
            "route": "日本出口 → 北上广／六地运营商公网目标",
            "score": overall_score,
            "stars": "★★★★★" if overall_score >= 80 else "★★★☆☆",
            "probeCount": len(return_probes),
            "routeTypes": len({x["routeClass"] for x in return_items}),
            "forward": summary,
            "forwardRoute": "Mieru TCP 上海入口接入",
            "forwardProbes": flat, "forwardScore": score,
            "returnScore": return_score,
            "bidirectional": False,
            "probes": return_probes,
        })
    final_score = round(statistics.mean(x["score"] for x in carriers))
    return {
        "version": report["version"], "generated": report["generated"],
        "target": report["entry"]["masked"], "targetPort": report["entry"]["port"],
        "returnSshHost": report["exitIdentity"]["ipMasked"],
        "selfTest": False, "mode": "沪日专线 Mieru 四层验证",
        "matrix": report["matrix"] + "（北上广固定三网去程＋日本出口回程）",
        "methodology": report["methodology"],
        "bgp": {
            "asn": report["exitIdentity"].get("asn") or "N/A",
            "provider": report["exitIdentity"].get("org") or "N/A",
            "location": " ".join(filter(None, [
                report["exitIdentity"].get("country"), report["exitIdentity"].get("city")
            ])),
        },
        "final": {
            "score": final_score,
            "stars": "★★★★★" if final_score >= 80 else "★★★☆☆",
            "title": f"Mieru 映射链 {report['mappingChain']['status']}",
            "elapsed": "N/A",
        },
        "carriers": carriers,
        "dedicatedLine": {
            "topology": "中国客户端→上海公网入口→隐藏专线→日本 Mita→日本公网出口",
            "entry": f"{report['entry']['masked']}:{report['entry']['port']}",
            "entryAsn": "中国移动映射入口",
            "exit": report["exitIdentity"]["ipMasked"],
            "exitAsn": report["exitIdentity"].get("asn") or "N/A",
            "portStatus": report["mappingChain"]["status"],
            "internalVerdict": (
                f"Mita {report['mieruService']['status']}；"
                f"真实握手 {report['protocolHandshake']['status']}；"
                "未知私网对端不误算丢包"
            ),
        },
        "ixData": {
            "version": report["version"],
            "entry": report["entry"],
            "exit": report["exitIdentity"]["ipMasked"],
            "localPrivate": report["localPrivate"]["masked"],
            "access": report["access"],
            "mappingChain": report["mappingChain"],
            "mieruService": {
                "status": report["mieruService"]["status"],
                "ntp": report["mieruService"]["ntp"],
            },
            "protocolHandshake": report["protocolHandshake"],
            "returns": [{
                "carrier": x["carrier"], "capital": x["capital"],
                "host": x["host"], "status": x["status"],
                "primaryHost": x.get("primaryHost", x["host"]),
                "targetSource": x.get("targetSource", "STATIC_PRIMARY"),
                "routeClass": x["routeClass"], "routeHops": x["routeHops"],
                "selectedProtocol": x.get("selectedProtocol", "N/A"),
                "latency": x["latency"],
            } for x in report["returns"]],
            "internal": {
                "status": report["internal"]["status"],
                "reason": report["internal"].get("reason") or "",
            },
        },
    }


def publish(report: dict[str, Any]) -> str:
    payload = public_report_payload(report)
    for carrier in payload["carriers"]:
        forward_count = len(carrier.get("forwardProbes") or [])
        return_count = len(carrier.get("probes") or [])
        if forward_count not in {3, 6} or return_count not in {3, 6}:
            field(
                "Chain 3Net",
                f"上传前校验失败｜{carrier['id']} 去程 {forward_count}／回程 {return_count}，必须为 3 或 6",
                RED,
            )
            return ""
    try:
        result = http_json(PUBLIC_REPORT_API, "POST", payload, 30)
        candidates = [result]
        if isinstance(result, dict):
            candidates.extend(
                value for value in result.values() if isinstance(value, dict)
            )
        for candidate in candidates:
            for key in ("url", "reportUrl", "report_url", "publicUrl", "public_url"):
                if candidate.get(key):
                    value = str(candidate[key])
                    return value if value.startswith("http") else PUBLIC_REPORT_ROOT + value
            if candidate.get("id"):
                return f"{PUBLIC_REPORT_ROOT}/report/{candidate['id']}"
        field("Chain 3Net", f"上传响应缺少公共网址｜{str(result)[:220]}", YELLOW)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:360]
        field("Chain 3Net", f"上传失败｜HTTP {exc.code}｜{detail}", YELLOW)
    except Exception as exc:
        field("Chain 3Net", f"上传失败｜{type(exc).__name__}: {exc}", YELLOW)
    return ""


def main() -> int:
    entry, port, expected_exit, local_private, remote_peer = ask_inputs()
    if SELF_TEST:
        selection_self_test()
    client_verified_exit = CLIENT_VERIFIED_EXIT
    if SELF_TEST and not client_verified_exit:
        client_verified_exit = "87.86.87.231"
    print(BLUE + "\n  ═══════════════════════════════════════════════════════════════" + RESET)
    print(CYAN + f"  IX-ROUTE {VERSION} · 沪日专线／Mieru 双程四层验证" + RESET)
    print(BLUE + "  ═══════════════════════════════════════════════════════════════" + RESET)

    section("TOPOLOGY / 检测拓扑", CYAN)
    field("中国公网入口", f"{mask_ip(entry)}:{port}", CYAN)
    field("业务端口", f"{port}（协议业务端口；不是 SSH）", GREEN)
    field("日本预期出口", mask_ip(expected_exit), GREEN)
    field("日本端内网", mask_ip(local_private), CYAN)
    field("上海内网对端", mask_ip(remote_peer), MAGENTA)
    field("测试边界", "入口接入、映射链、Mieru 服务／握手、日本出口；纯内段为附加项", YELLOW)

    identity = (
        {"ip": "87.86.87.231", "asn": "AS9999", "org": "SELF-TEST JP", "country": "Japan", "city": "Tokyo"}
        if SELF_TEST else public_identity()
    )
    addresses = ["172.16.2.101", "127.0.0.1"] if SELF_TEST else local_addresses()
    local_status = (
        "PASS" if local_private and local_private in addresses
        else "N/A" if not local_private
        else "FAIL"
    )
    listener = (
        {"status": "PASS", "evidence": f"SELF-TEST TCP {port} LISTEN"}
        if SELF_TEST else listener_status(port)
    )
    mieru = mieru_service(port)
    net_context = (
        {"defaultRoute": "default via 172.16.2.1 dev eth0", "entryRoute": "211.136.162.184 via 172.16.2.1 dev eth0"}
        if SELF_TEST else network_context(entry)
    )
    if not expected_exit:
        exit_match = {"status": "N/A", "reason": "未提供预期日本出口"}
    elif identity.get("ip") == expected_exit:
        exit_match = {"status": "PASS", "reason": "本机公网出口与预期日本出口一致"}
    elif not identity.get("ip"):
        exit_match = {"status": "N/A", "reason": "公网出口识别失败"}
    else:
        exit_match = {
            "status": "FAIL",
            "reason": f"本机实际 {mask_ip(identity['ip'])}，与预期 {mask_ip(expected_exit)} 不一致",
        }

    section("LAYER 1 / 中国三网到上海入口", CYAN)
    regions = FULL_REGIONS if FULL else CORE_REGIONS
    field("模式", "完整六地区 × 三网双程" if FULL else "北上广固定三地区 × 三网双程")
    field("业务丢包口径", "TCP traceroute 只判到达／未确认；中间跳点不回不算 LOSS", YELLOW)
    probes: list[dict[str, Any]] = []
    total = len(regions) * len(CARRIERS)
    index = 0
    for region, city in regions:
        for carrier, (carrier_name, asn, color) in CARRIERS.items():
            index += 1
            field(f"[{index}/{total}]", f"{region} {carrier_name} AS{asn} → {mask_ip(entry)}:{port}", color)
            item = (
                self_test_probe(carrier, region, city, index)
                if SELF_TEST else globalping_probe(entry, port, carrier, region, city)
            )
            probes.append(item)
            latency = item.get("latency") or {}
            shown_rtt = f"{latency['avg']} ms" if latency.get("avg") is not None else "N/A"
            result_color = GREEN if item["status"] in {"PASS", "PASS_FALLBACK"} else YELLOW
            field(
                "结果",
                (
                    f"{item['status']}｜{item.get('sourceClass', 'N/A')}｜"
                    f"终点 {'到达' if item['targetReached'] else '未确认'}｜RTT {shown_rtt}"
                ),
                result_color,
            )

    section("LAYER 1B / 日本出口到北上广三网回程", CYAN)
    field("回程口径", "日本出口 → 各省会运营商公网目标；TCP traceroute 可见路由，不把跳点沉默算丢包", YELLOW)
    returns: list[dict[str, Any]] = []
    return_index = 0
    for region, _ in regions:
        for carrier, (carrier_name, _, color) in CARRIERS.items():
            return_index += 1
            host = RETURN_TARGETS[carrier][region]
            field(f"[{return_index}/{total}]", f"日本出口 → {CAPITALS[region]} {carrier_name} {host}", color)
            item = return_probe(carrier, region, host)
            returns.append(item)
            latency = item.get("latency") or {}
            shown_rtt = f"{latency['avg']} ms" if latency.get("avg") is not None else "N/A"
            result_color = GREEN if item["status"] == "PASS" else YELLOW
            field("结果", f"{item['status']}｜{item.get('selectedProtocol', 'N/A')}｜{item['routeClass']}｜RTT {shown_rtt}", result_color)

    access = {
        "total": total,
        "pass": sum(x["status"] == "PASS" for x in probes),
        "fallbackPass": sum(x["status"] == "PASS_FALLBACK" for x in probes),
        "inconclusive": sum(x["status"] == "INCONCLUSIVE" for x in probes),
        "reference": sum(x["status"] == "REFERENCE" for x in probes),
        "provinceReference": sum(
            x["status"] == "REFERENCE"
            for x in probes
        ),
        "crossProvinceReference": sum(
            x["status"] == "PASS_FALLBACK"
            and x.get("sourceClass") == "CROSS_PROVINCE_CARRIER_FALLBACK"
            for x in probes
        ),
        "na": sum(x["status"] == "N/A" for x in probes),
        "noProbe": sum(x["status"] == "NO_PROBE" for x in probes),
    }
    access["crossProvinceFallback"] = access["fallbackPass"]
    access["carrierReachable"] = access["pass"] + access["fallbackPass"]
    access["endpointReachable"] = sum(
        bool(x.get("targetReached")) for x in probes
    )
    access["reachable"] = access["pass"] + access["provinceReference"]
    access["coverage"] = round(access["pass"] * 100 / total, 1) if total else 0.0
    access["carrierCoverage"] = (
        round(access["carrierReachable"] * 100 / total, 1) if total else 0.0
    )
    access["endpointCoverage"] = (
        round(access["endpointReachable"] * 100 / total, 1) if total else 0.0
    )
    access["provinceCoverage"] = (
        round(access["reachable"] * 100 / total, 1) if total else 0.0
    )
    access["status"] = (
        "PASS" if access["carrierReachable"] / total >= 0.8
        else "PARTIAL" if access["carrierReachable"] > 0
        else "N/A" if access["na"] + access["noProbe"] == total
        else "INCONCLUSIVE"
    )
    access["regionStatus"] = (
        "PASS" if access["pass"] / total >= 0.8
        else "PARTIAL" if access["pass"] > 0
        else "N/A"
    )

    section("LAYER 2 / 上海→日本映射链与可选纯内段", MAGENTA)
    field("日本内网本机核对", local_status, GREEN if local_status == "PASS" else YELLOW)
    field("日本业务端口监听", listener["status"], GREEN if listener["status"] == "PASS" else YELLOW)
    chain = mapping_chain(access, listener, local_status)
    field("端口映射链证据", f"{chain['status']}｜{chain['reason']}", GREEN if chain["status"] == "PASS" else YELLOW)
    field("本机默认路由", net_context["defaultRoute"], CYAN)
    field("到上海入口路由", net_context["entryRoute"], CYAN)
    internal = (
        {
            "status": "N/A",
            "reason": "SELF-TEST 未提供内网对端，用于验证 N/A 逻辑",
            "stats": summarize([], 20),
            "route": "",
        }
        if SELF_TEST else ping_peer(remote_peer)
    )
    field("纯内段附加测试", internal["status"], GREEN if internal["status"] == "PASS" else YELLOW)
    field("纯内段附加评级", quality_label(internal), CYAN)

    section("LAYER 3 / Mieru 服务与真实握手", MAGENTA)
    field("Mieru／Mita 识别", f"{mieru['status']}｜{mieru['evidence']}", GREEN if mieru["status"] == "PASS" else YELLOW)
    field("TCP 业务监听", f"{listener['status']}｜{listener['evidence']}", GREEN if listener["status"] == "PASS" else YELLOW)
    field("NTP 时间同步", mieru["ntp"], GREEN if mieru["ntp"] == "PASS" else YELLOW)
    handshake = handshake_verdict(
        client_verified_exit,
        expected_exit,
        identity.get("ip", ""),
        mieru,
        chain,
    )
    field("Mieru 真实握手", f"{handshake['status']}｜{handshake['reason']}", GREEN if handshake["status"] == "PASS" else YELLOW)

    section("LAYER 4 / 日本出口公网", GREEN)
    field("实际公网出口", mask_ip(identity.get("ip", "")), GREEN)
    field("ASN／运营商", f"{identity.get('asn') or 'N/A'}｜{identity.get('org') or 'N/A'}")
    field("位置", f"{identity.get('country') or 'N/A'} {identity.get('city') or ''}")
    field("与预期出口", f"{exit_match['status']}｜{exit_match['reason']}", GREEN if exit_match["status"] == "PASS" else YELLOW)

    generated = dt.datetime.now(dt.timezone.utc).astimezone()
    report = {
        "version": VERSION,
        "generated": generated.isoformat(timespec="seconds"),
        "mode": "HURI_MIERU_DEDICATED_LINE_FOUR_LAYER",
        "matrix": "六地区 × 三网双程（36组）" if FULL else "北上广 × 三网双程（18组）",
        "entry": {"masked": mask_ip(entry), "port": port},
        "exitIdentity": {**identity, "ipMasked": mask_ip(identity.get("ip", ""))},
        "exitMatch": exit_match,
        "localPrivate": {"masked": mask_ip(local_private), "status": local_status},
        "remotePeer": {"masked": mask_ip(remote_peer)},
        "networkContext": net_context,
        "listener": listener,
        "mieruService": mieru,
        "access": access,
        "mappingChain": chain,
        "internal": internal,
        "probes": probes,
        "returns": returns,
        "protocolHandshake": handshake,
        "clientVerifiedExit": mask_ip(client_verified_exit),
        "methodology": (
            "中国侧使用 Globalping 指定中国电信、联通、移动完整运营商 ASN 家族，"
            "对上海入口业务端口执行 TCP traceroute；北京、上海、广州固定列入，"
            "--full 再扩展合肥、南京与杭州。日本出口同时对相同城市的三网公网目标执行"
            "TCP traceroute，作为真实可见的回程证据；不把中间跳点沉默当作业务丢包。"
            "日本出口本机核对公网 IP、业务监听、本机内网地址、"
            "默认路由及到上海入口的路由；入口可达且日本端同端口监听、私网地址吻合时，"
            "给出端口映射链证据；自动识别 mita 版本、运行状态、端口与 NTP。"
            "只有中国客户端连接 Mieru 后实测出口与日本端实际／预期出口一致，"
            "才把真实握手判为 PASS。供应商确实提供上海内网对端时，才用 20 次 ICMP 与 "
            "MTR／traceroute 增测专线纯内段。"
            "去程先读取 Globalping 在线探针清单，再按省会运营商家宽、省内任意城市运营商家宽、"
            "省内运营商数据中心、省内运营商未分类网络、省内其他数据中心五级筛选；"
            "行政区核对严格按 Globalping state、省市映射、唯一坐标范围依次判定；"
            "重叠经纬度矩形不得把徐州／南京等江苏城市误标为安徽。"
            "运营商数据中心／未分类网络必须通过 ASN 或网络名称核对，并明确标注非家宽；"
            "第三方省内数据中心只标 REFERENCE，不冒充三网。全省没有指定运营商探针时，"
            "才按相邻优先顺序改用其他省份的同运营商探针；终点到达标为 PASS_FALLBACK，"
            "计入运营商端口可达，但不计入原省精准覆盖。TCP traceroute 末跳沉默时，使用原 measurement ID "
            "锁定同一探针，对业务端口追加三次 TCP ping；端口有响应可确认去程可达，"
            "同时保留“完整末跳未显示”的事实。Globalping magic 请求的 limit 位于请求最外层；"
            "测量使用严格 country+city+ASN+tag 参数；只有确认所有合法候选均无在线探针才记 NO_PROBE，"
            "结构化 no_probes_found 与其他 API 422 分开处理。"
            "回程参考 oneclickvirt/backtrace 的备援策略：每省每运营商保留固定主测点，"
            "主测点骨干证据不足时，从每日更新的省级三网 ICMP 目标池选择最多两个备援地址；"
            "每个目标先以 TCP 三探测追踪，证据不足时依次回退 ICMP 与 UDP，最大 30 跳、单跳等待 2 秒；"
            "备援仅改变日本出口的回程目标，不会冒充中国侧去程来源。"
            "探针失败、DNS 失败、权限不足或缺少对端均记 N/A／INCONCLUSIVE，"
            "不会换算为 100% 业务丢包。"
        ),
    }

    output_name = f"ix-route-report-{generated.strftime('%Y%m%d-%H%M%S')}"
    preferred_root = Path("/root") if os.geteuid() == 0 else Path.cwd()
    chain_root = preferred_root / "Chain 3Net"
    output_dir = chain_root / output_name
    try:
        output_dir.mkdir(parents=True, exist_ok=True)
    except OSError:
        output_dir = Path.cwd() / "Chain 3Net" / output_name
        output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / "report.json"
    md_path = output_dir / "report.md"
    html_path = output_dir / "report.html"
    json_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    md_path.write_text(markdown_report(report), encoding="utf-8")
    write_html(report, html_path)
    public_url = "" if SELF_TEST or NO_PUBLISH else publish(report)

    section("FINAL / 四层独立结论", CYAN)
    field(
        "上海入口接入",
        (
            f"{access['status']}｜运营商可达 {access['carrierReachable']}/{access['total']} "
            f"({access['carrierCoverage']}%)｜原省精确 {access['pass']}/{access['total']} "
            f"({access['coverage']}%)｜省内第三方参考 {access['provinceReference']}｜"
            f"跨省同运营商降级 {access['crossProvinceFallback']}｜"
            f"NO_PROBE {access['noProbe']}"
        ),
        GREEN if access["status"] == "PASS" else YELLOW,
    )
    return_pass = sum(x["status"] == "PASS" for x in returns)
    field("北上广／六地回程", f"PASS {return_pass}/{len(returns)}｜N/A/未确认不计 100% LOSS", GREEN if return_pass else YELLOW)
    field("上海→日本映射链", f"{chain['status']}｜{chain['reason']}", GREEN if chain["status"] == "PASS" else YELLOW)
    field("专线纯内段附加项", quality_label(internal), GREEN if internal["status"] == "PASS" else YELLOW)
    field("Mieru／Mita 服务", f"{mieru['status']}｜{mieru['evidence']}", GREEN if mieru["status"] == "PASS" else YELLOW)
    field("Mieru 真实握手", f"{handshake['status']}｜{handshake['reason']}", GREEN if handshake["status"] == "PASS" else YELLOW)
    field("日本出口公网", f"{exit_match['status']}｜{mask_ip(identity.get('ip', ''))}", GREEN if exit_match["status"] == "PASS" else YELLOW)
    field("HTML 网页", str(html_path), GREEN)
    field("Markdown 报告", str(md_path), GREEN)
    field("JSON 数据", str(json_path), GREEN)
    field("Chain 3Net 公共页", public_url or ("已禁用" if NO_PUBLISH else "N/A｜本地报告已保留"), GREEN if public_url else YELLOW)
    field("重要说明", "IX-style 不等于证明经过某个 IXP；本工具用于专线／隐藏内段分层验证", MAGENTA)
    if SELF_TEST:
        field("SELF-TEST", "PASS｜交互隔离、N/A 逻辑、报告生成均正常", GREEN)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\n" + YELLOW + "用户已中止。" + RESET)
        raise SystemExit(130)
    except Exception as exc:
        print(RED + f"\n[ERROR] {type(exc).__name__}: {exc}" + RESET)
        raise SystemExit(7)
PY
