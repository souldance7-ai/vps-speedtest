#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="v0.5 RC2"
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
沪日专线／IX-style 四层质量检测 v0.5 RC2

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

VERSION = os.environ.get("IX_VERSION", "v0.5 RC2")
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
CARRIER_ASN_FAMILIES = {
    "CT": {4134, 4812, 4816},
    "CU": {4837, 4808, 17621, 17622, 17623, 17816},
    "CM": {
        9808, 24445, 56040, 56041, 56042, 56044, 56046, 56047,
        56048, 56050, 56055, 56056, 56057, 56058,
    },
}
CARRIER_NETWORK_HINTS = {
    "CT": ("chinanet", "china telecom", "telecom"),
    "CU": ("china unicom", "china169", "unicom"),
    "CM": ("china mobile", "mobile communications", "mobile communica"),
}
CARRIER_MAGIC = {
    "CT": "China Telecom", "CU": "China Unicom", "CM": "China Mobile",
}
PROVINCE_CITIES = {
    "北京": ("Beijing",),
    "上海": ("Shanghai",),
    "广东": ("Guangzhou", "Shenzhen", "Foshan", "Dongguan"),
    "安徽": ("Hefei", "Wuhu", "Bengbu"),
    "江苏": ("Nanjing", "Suzhou", "Wuxi", "Changzhou", "Xuzhou"),
    "浙江": ("Hangzhou", "Ningbo", "Wenzhou", "Shaoxing", "Jiaxing"),
}
REGION_ACCESS_ASNS = {
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


ASN_CACHE: dict[str, str] = {}


def origin_asn(ip: str) -> str:
    if ip in ASN_CACHE:
        return ASN_CACHE[ip]
    if not valid_ipv4(ip, public=True) or not shutil.which("dig"):
        return ""
    reversed_ip = ".".join(reversed(ip.split(".")))
    try:
        output = subprocess.check_output(
            ["dig", "+short", "TXT", f"{reversed_ip}.origin.asn.cymru.com"],
            text=True, timeout=4, stderr=subprocess.DEVNULL,
        )
        match = re.search(r'"?\s*(\d+)\s*\|', output)
        result = f"AS{match.group(1)}" if match else ""
    except Exception:
        result = ""
    ASN_CACHE[ip] = result
    return result


def enrich_route(route: str, maximum: int = 24) -> str:
    seen: set[str] = set()
    evidence: list[str] = []
    for ip in re.findall(r"(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)", route):
        if ip in seen or not valid_ipv4(ip, public=True):
            continue
        seen.add(ip)
        asn = origin_asn(ip)
        if asn:
            evidence.append(f"{ip} {asn}")
        if len(seen) >= maximum:
            break
    return route + ("\n@@ASN_EVIDENCE " + " | ".join(evidence) if evidence else "")


def normalize_city(value: str) -> str:
    return re.sub(r"[^a-z]", "", value.lower())


def probe_matches_carrier(probe: dict[str, Any], carrier: str) -> bool:
    try:
        probe_asn = int(probe.get("asn") or 0)
    except (TypeError, ValueError):
        probe_asn = 0
    network = str(probe.get("network") or "").lower()
    return (
        probe_asn in CARRIER_ASN_FAMILIES[carrier]
        or any(hint in network for hint in CARRIER_NETWORK_HINTS[carrier])
    )


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


def globalping_probe(entry: str, port: int, carrier: str, region: str, city: str) -> dict[str, Any]:
    name, asn, _ = CARRIERS[carrier]
    attempts: list[tuple[str, list[str]]] = []
    for city_index, candidate_city in enumerate(PROVINCE_CITIES[region]):
        magic_values = [f"{candidate_city}+{CARRIER_MAGIC[carrier]}"]
        magic_values.extend(
            f"{candidate_city}+AS{candidate_asn}"
            for candidate_asn in REGION_ACCESS_ASNS[carrier][region]
        )
        scope = "省会直测" if city_index == 0 else f"同省备用 {candidate_city}"
        attempts.append((scope, magic_values))
    errors: list[str] = []
    for mode, magic_values in attempts:
        try:
            created = http_json(
                GLOBALPING_API,
                "POST",
                {
                    "limit": min(8, max(1, len(magic_values))),
                    "target": entry,
                    "type": "traceroute",
                    "locations": [{"magic": value} for value in magic_values],
                    "measurementOptions": {"protocol": "TCP", "port": port},
                },
            )
            measurement_id = created.get("id")
            if not measurement_id:
                raise RuntimeError("API 未返回 measurement id")
            result = None
            for _ in range(35):
                time.sleep(0.8)
                result = http_json(f"{GLOBALPING_API}/{measurement_id}")
                if result.get("status") == "finished":
                    break
                if result.get("status") != "in-progress":
                    raise RuntimeError(f"API 状态 {result.get('status')}")
            if not result or result.get("status") != "finished":
                raise TimeoutError("等待远端结果超时")
            candidate_city = magic_values[0].split("+", 1)[0]
            candidates = [
                x for x in result.get("results", [])
                if (
                    x.get("result", {}).get("status") == "finished"
                    and normalize_city(str((x.get("probe") or {}).get("city") or ""))
                    == normalize_city(candidate_city)
                    and probe_matches_carrier(x.get("probe") or {}, carrier)
                )
            ]
            candidates.sort(key=lambda x: (
                int((x.get("probe") or {}).get("asn") or 0) != asn,
                "eyeball-network" not in ((x.get("probe") or {}).get("tags") or []),
            ))
            item = candidates[0] if candidates else None
            if not item:
                visible = "、".join(
                    (
                        f"{(x.get('probe') or {}).get('city', '未知城市')} "
                        f"AS{(x.get('probe') or {}).get('asn', 0)} "
                        f"{(x.get('probe') or {}).get('network', '未知网络')}"
                    )
                    for x in result.get("results", [])
                )
                raise RuntimeError(f"无同城市同运营商探针；返回 {visible or '空'}")
            probe = item.get("probe") or {}
            source_asn = int(probe.get("asn") or 0)
            actual_city = str(probe.get("city") or "")
            city_verified = normalize_city(actual_city) == normalize_city(candidate_city)
            asn_verified = probe_matches_carrier(probe, carrier)
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
            rtts = target_rtts or last_rtts
            latency = summarize(rtts, len(rtts)) if rtts else summarize([], 0)
            latency["loss"] = None
            status = "PASS" if reached and city_verified and asn_verified else "INCONCLUSIVE"
            reasons: list[str] = []
            if not city_verified:
                reasons.append(
                    f"省会核对失败：请求 {CAPITALS[region]}，实际 {actual_city or '未知城市'}"
                )
            if not asn_verified:
                reasons.append(f"运营商核对失败：预期 AS{asn}，实际 AS{source_asn or 'N/A'}")
            if not reached:
                reasons.append("TCP traceroute 未显示终点；不等于真实业务 100% 丢包")
            return {
                "carrier": carrier,
                "carrierName": name,
                "requestedRegion": region,
                "mode": mode,
                "probeCity": actual_city,
                "probeAsn": source_asn,
                "asnVerified": asn_verified,
                "cityVerified": city_verified,
                "selectionScope": "CAPITAL" if mode == "省会直测" else "PROVINCE_FALLBACK",
                "status": status,
                "targetReached": reached,
                "latency": latency,
                "route": "\n".join(route_lines),
                "reason": (
                    (
                        f"省会 {CAPITALS[region]} 无可用探针，"
                        f"退到同省 {actual_city}；未跨省。"
                    )
                    if mode != "省会直测"
                    else f"省会 {CAPITALS[region]} 定向探针命中。"
                ) + "；".join(reasons),
            }
        except Exception as exc:
            errors.append(
                f"{mode}〔{'、'.join(magic_values)}〕: {type(exc).__name__}: {exc}"
            )
    return {
        "carrier": carrier,
        "carrierName": name,
        "requestedRegion": region,
        "mode": "N/A",
        "probeCity": "",
        "probeAsn": 0,
        "asnVerified": False,
        "cityVerified": False,
        "selectionScope": "NO_PROBE",
        "status": "NO_PROBE",
        "targetReached": False,
        "latency": summarize([], 0),
        "route": "",
        "reason": (
            "已先查省会，再查同省城市；未跨省替代。"
            + "；".join(errors)
        ),
    }


def self_test_probe(carrier: str, region: str, city: str, index: int) -> dict[str, Any]:
    name, asn, _ = CARRIERS[carrier]
    reached = index % 7 != 0
    return {
        "carrier": carrier,
        "carrierName": name,
        "requestedRegion": region,
        "mode": f"{region}+AS{asn}",
        "probeCity": city,
        "probeAsn": asn,
        "asnVerified": True,
        "cityVerified": True,
        "selectionScope": "CAPITAL",
        "status": "PASS" if reached else "INCONCLUSIVE",
        "targetReached": reached,
        "latency": {
            "status": "PASS", "avg": round(18.0 + index * 1.7, 1),
            "p95": round(20.0 + index * 1.7, 1), "jitter": 1.2,
            "loss": None, "received": 3, "sent": 3,
        },
        "route": "01 10.0.0.1 1.0ms\n02 211.136.162.184 25.0ms",
        "reason": "" if reached else "SELF-TEST 模拟未显示终点",
    }


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


def matching_hop_count(route: str, patterns: list[str]) -> int:
    return sum(
        1 for row in route.splitlines()
        if re.search(r"^\s*\d+\s+", row)
        and any(re.search(pattern, row, re.I) for pattern in patterns)
    )


def return_route_label(carrier: str, route: str) -> tuple[str, list[str], str, int]:
    patterns = {
        "CT": [
            ("CN2 GIA／CN2", [r"AS4809", r"59\.43\."], "AS4809｜CN2 精品骨干", 5),
            ("ChinaNet 163", [r"AS4134", r"202\.97\."], "AS4134｜ChinaNet 163 普通骨干", 2),
        ],
        "CU": [
            ("CUII AS9929", [r"AS9929", r"218\.105\.", r"210\.(51|52|53|78)\."], "AS9929｜CUII 联通精品骨干", 5),
            ("CUG AS10099", [r"AS10099", r"202\.77\.", r"43\.252\.", r"61\.14\."], "AS10099｜CUG 联通国际网", 3),
            ("China169 AS4837", [r"AS4837", r"219\.158\."], "AS4837｜China169 联通普通骨干", 2),
        ],
        "CM": [
            ("CMIN2", [r"AS58807", r"223\.118\.32\."], "AS58807｜CMIN2 移动精品骨干", 5),
            ("CMI 普通国际", [r"AS58453", r"223\.118\.(?!32\.)", r"223\.119\."], "AS58453｜CMI 移动普通国际网", 2),
            ("CMNET 国内骨干", [r"AS9808", r"221\.183\.", r"111\.24\."], "AS9808｜CMNET 移动国内骨干", 2),
        ],
    }
    matched = [
        (label, tag, rank, expressions)
        for label, expressions, tag, rank in patterns[carrier]
        if any(re.search(expression, route, re.I) for expression in expressions)
    ]
    if not matched:
        return (
            "INCONCLUSIVE｜可见跳点证据不足",
            ["未识别骨干｜不按普通线或精品线强判"],
            "仅确认日本出口到目标运营商公网地址的可见路由；缺少特征跳点时保持证据不足。",
            0,
        )
    labels = [x[0] for x in matched]
    tags = [x[1] for x in matched]
    rank = max(x[2] for x in matched)
    premium = any(x[2] == 5 for x in matched)
    if not premium:
        carrier_hops = max(matching_hop_count(route, x[3]) for x in matched)
        if carrier_hops <= 1:
            return (
                f"INCONCLUSIVE｜仅见{CARRIERS[carrier][0]}目的网",
                tags,
                "单一运营商目的网投递跳点不能证明完整回程骨干；保留标签但不参与线路评分。",
                0,
            )
    return (
        " → ".join(labels),
        tags,
        (
            "精品骨干证据来自可见 ASN／特征 IP；普通目的网投递段不覆盖精品判定。"
            if premium
            else "非精品骨干证据来自至少两个可见运营商跳点；中间节点不回应不作为端到端业务丢包。"
        ),
        rank,
    )


def return_probe(carrier: str, region: str, host: str) -> dict[str, Any]:
    name, _, _ = CARRIERS[carrier]
    if SELF_TEST:
        routes = {
            "CT": "1 87.86.87.1 1.2 ms\n2 59.43.181.1 32.0 ms\n3 219.141.136.10 38.1 ms",
            "CU": "1 87.86.87.1 1.1 ms\n2 218.105.2.205 39.0 ms\n3 219.158.8.1 41.0 ms\n4 202.106.50.1 45.2 ms",
            "CM": "1 87.86.87.1 1.0 ms\n2 223.118.32.1 35.0 ms\n3 221.179.155.161 39.4 ms",
        }
        route = enrich_route(routes[carrier])
        route_class, tags, note, route_rank = return_route_label(carrier, route)
        transport = "SELF-TEST"
    elif shutil.which("traceroute"):
        raw_candidates = [
            ("TCP/443", run(
                ["traceroute", "-n", "-T", "-p", "443", "-q", "1", "-w", "1", "-m", "25", host],
                40,
            )),
            ("ICMP", run(
                ["traceroute", "-n", "-I", "-q", "1", "-w", "1", "-m", "25", host],
                40,
            )),
            ("UDP", run(
                ["traceroute", "-n", "-q", "1", "-w", "1", "-m", "25", host],
                40,
            )),
        ]
        evaluated = []
        for candidate_transport, raw_route in raw_candidates:
            candidate_route = enrich_route(raw_route)
            candidate_class, candidate_tags, candidate_note, candidate_rank = (
                return_route_label(carrier, candidate_route)
            )
            evaluated.append((
                candidate_rank, route_hop_count(raw_route), candidate_transport,
                candidate_route, candidate_class, candidate_tags, candidate_note,
            ))
        (
            route_rank, _, transport, route, route_class, tags, note
        ) = max(evaluated, key=lambda x: (x[0], x[1]))
    elif shutil.which("tracepath"):
        transport = "TRACEPATH"
        route = enrich_route(run(["tracepath", "-n", "-m", "25", host], 40))
        route_class, tags, note, route_rank = return_route_label(carrier, route)
    else:
        return {
            "carrier": carrier, "carrierName": name, "region": region,
            "capital": CAPITALS[region], "host": host, "status": "N/A",
            "route": "", "routeHops": 0, "routeClass": "N/A",
            "routeRank": 0, "routeScore": 0, "transport": "N/A",
            "backboneTags": [], "routeNote": "系统无 traceroute／tracepath",
            "latency": summarize([], 0), "reason": "缺少回程路由工具；不换算为 100% 丢包",
        }
    hops = route_hop_count(route)
    if not hops:
        return {
            "carrier": carrier, "carrierName": name, "region": region,
            "capital": CAPITALS[region], "host": host, "status": "INCONCLUSIVE",
            "route": route, "routeHops": 0, "routeClass": "回程无有效跳点",
            "routeRank": 0, "routeScore": 0, "transport": transport,
            "backboneTags": [], "routeNote": "未取得有效跳点，不等于业务中断",
            "latency": summarize([], 0), "reason": "traceroute 无有效回覆；不换算为 100% 丢包",
        }
    values = traceroute_rtts(route)
    latency = summarize(values[-3:], len(values[-3:])) if values else summarize([], 0)
    latency["loss"] = None
    route_score = {5: 90, 3: 72, 2: 55}.get(route_rank, 0)
    return {
        "carrier": carrier, "carrierName": name, "region": region,
        "capital": CAPITALS[region], "host": host, "status": "PASS",
        "route": route, "routeHops": hops, "routeClass": route_class,
        "routeRank": route_rank, "routeScore": route_score, "transport": transport,
        "backboneTags": tags, "routeNote": note, "latency": latency,
        "reason": (
            f"{transport} 取得 {hops} 个有效回程跳点；"
            "三种协议先按骨干证据等级选择，等级相同才比较回覆跳数；RTT 仅取末段可见样本"
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
    if access.get("pass", 0) > 0 and listener.get("status") == "PASS" and local_status == "PASS":
        return {
            "status": "PASS",
            "reason": "中国探针可达入口业务端口＋日本私网主机同端口监听＋本机私网地址吻合",
        }
    if access.get("pass", 0) > 0 and listener.get("status") == "PASS":
        return {
            "status": "PARTIAL",
            "reason": "入口端口可达且日本端监听，但日本私网地址未核对",
        }
    if access.get("pass", 0) > 0:
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
        f"- 上海入口端到端 TCP：{access['status']}（PASS {access['pass']}/{access['total']}，INCONCLUSIVE {access['inconclusive']}，NO_PROBE {access.get('noProbe', 0)}，N/A {access['na']}）",
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
        "| 地区 | 运营商 | 实际探针 | 城市核对 | ASN核对 | 终点 | RTT | 状态 |",
        "|---|---|---|---:|---:|---:|---:|---|",
    ]
    for item in report["probes"]:
        latency = item.get("latency") or {}
        rtt = f"{latency['avg']} ms" if latency.get("avg") is not None else "N/A"
        lines.append(
            f"| {item['requestedRegion']} | {item['carrierName']} | "
            f"{item.get('probeCity') or 'N/A'} | "
            f"{'是' if item.get('cityVerified') else '否'} | "
            f"{'是' if item.get('asnVerified') else '否'} | "
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
.PASS{{color:var(--green)}}.FAIL{{color:var(--red)}}.N\\/A,.INCONCLUSIVE,.PARTIAL{{color:var(--yellow)}}.panel{{padding:20px;margin:16px 0}}h2{{font-size:16px;color:var(--cyan);margin:0 0 14px}}
.topology{{display:flex;align-items:center;gap:8px;overflow:auto;padding:6px 0}}.node{{min-width:180px;background:#091827;border:1px solid #2e5576;border-radius:10px;padding:13px;text-align:center}}.arrow{{color:var(--yellow);font-size:20px}}
table{{width:100%;border-collapse:collapse}}th,td{{border-bottom:1px solid var(--line);padding:9px;text-align:left;vertical-align:top}}th{{color:var(--muted)}}code{{color:#a9efff}}button{{background:#0e7490;color:white;border:0;border-radius:8px;padding:9px 13px;cursor:pointer;margin-right:8px}}
.note{{color:var(--muted)}}@media(max-width:850px){{.grid{{grid-template-columns:1fr 1fr}}main{{padding:14px}}}}@media print{{body{{background:white;color:#111}}header,.panel{{box-shadow:none;background:white}}}}
</style></head><body><main>
<header><h1>CHAIN 3NET · 沪日专线 MIERU 四层质量报告</h1><div class="sub" id="meta"></div>
<div style="margin-top:14px"><button id="json">下载 JSON</button><button onclick="window.print()">打印／另存 PDF</button></div></header>
<section class="panel"><h2>TOPOLOGY / 实际业务拓扑</h2><div class="topology" id="topology"></div></section>
<div class="grid" id="cards"></div>
<section class="panel"><h2>MIERU / 日本端服务证据</h2><table id="mieru"></table></section>
<section class="panel"><h2>FORWARD / 北上广固定三网去程</h2><div style="overflow:auto"><table><thead><tr><th>地区</th><th>运营商</th><th>实际探针</th><th>城市</th><th>ASN</th><th>终点</th><th>RTT</th><th>状态</th><th>说明</th></tr></thead><tbody id="rows"></tbody></table></div></section>
<section class="panel"><h2>RETURN / 日本出口至北上广固定三网回程</h2><div style="overflow:auto"><table><thead><tr><th>地区</th><th>运营商</th><th>目标</th><th>跳点</th><th>RTT</th><th>路由标签</th><th>骨干证据</th><th>状态</th></tr></thead><tbody id="returnRows"></tbody></table></div></section>
<section class="panel"><h2>BOUNDARY / 判定边界</h2><p class="note" id="method"></p></section>
</main><script>
const R={embedded}; const E=s=>String(s??'N/A').replace(/[&<>"']/g,c=>({{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}}[c]));
const badge=(label,obj)=>`<article class="card"><span>${{E(label)}}</span><strong class="${{E(obj.status)}}">${{E(obj.status)}}</strong><small>${{E(obj.reason||obj.evidence||'')}}</small></article>`;
document.getElementById('meta').textContent=`${{R.generated}} · ${{R.version}} · ${{R.matrix}}`;
document.getElementById('topology').innerHTML=[
`<div class="node">中国 Mieru 客户端</div>`,`<b class="arrow">→</b>`,
`<div class="node">上海入口<br><code>${{E(R.entry.masked)}}:${{R.entry.port}}</code></div>`,`<b class="arrow">→</b>`,
`<div class="node">隐藏专线／映射链</div>`,`<b class="arrow">→</b>`,
`<div class="node">日本 Mita<br><code>${{E(R.localPrivate.masked)}}:${{R.entry.port}}</code></div>`,`<b class="arrow">→</b>`,
`<div class="node">日本出口<br><code>${{E(R.exitIdentity.ipMasked)}}</code></div>`].join('');
document.getElementById('cards').innerHTML=[
badge('上海入口接入',{{status:R.access.status,reason:`PASS ${{R.access.pass}}/${{R.access.total}} · 覆盖 ${{R.access.coverage}}%`}}),
badge('上海→日本映射链',R.mappingChain),badge('Mieru 真实握手',R.protocolHandshake),badge('日本出口一致性',R.exitMatch)].join('');
const M=R.mieruService;
document.getElementById('mieru').innerHTML=`<tr><th>服务识别</th><td class="${{E(M.status)}}">${{E(M.status)}}</td><th>版本</th><td>${{E(M.version)}}</td></tr>
<tr><th>运行状态</th><td>${{E(M.runtime)}}</td><th>systemd</th><td>${{E(M.systemd)}}</td></tr>
<tr><th>NTP</th><td>${{E(M.ntp)}}</td><th>端口监听</th><td class="${{E(R.listener.status)}}">${{E(R.listener.status)}} · ${{E(R.listener.evidence)}}</td></tr>`;
document.getElementById('rows').innerHTML=R.probes.map(p=>`<tr><td>${{E(p.requestedRegion)}}</td><td>${{E(p.carrierName)}}</td><td>${{E(p.probeCity)}}</td><td>${{p.cityVerified?'已核对':'未核对'}}</td><td>${{p.asnVerified?'已核对':'未核对'}}</td><td>${{p.targetReached?'到达':'未确认'}}</td><td>${{E(p.latency?.avg)}} ms</td><td class="${{E(p.status)}}">${{E(p.status)}}</td><td>${{E(p.reason)}}</td></tr>`).join('');
document.getElementById('returnRows').innerHTML=R.returns.map(p=>`<tr><td>${{E(p.capital)}}</td><td>${{E(p.carrierName)}}</td><td><code>${{E(p.host)}}</code></td><td>${{E(p.routeHops)}}</td><td>${{E(p.latency?.avg)}} ms</td><td>${{E(p.routeClass)}}</td><td>${{E((p.backboneTags||[]).join(' → '))}}<br><small>${{E(p.routeNote)}}</small></td><td class="${{E(p.status)}}">${{E(p.status)}}</td></tr>`).join('');
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
        score = round(len(passed) * 100 / len(items)) if items else 0
        flat = []
        for item in items:
            latency = item.get("latency") or {}
            flat.append({
                "region": item["requestedRegion"],
                "label": f"{item['requestedRegion']} {carrier_names[carrier]} → 上海入口",
                "access": item.get("mode") or "N/A",
                "actualProbeCity": item.get("probeCity") or "",
                "selectionScope": item.get("selectionScope") or "",
                "publicIp": "",
                "verified": bool(item.get("asnVerified") and item.get("cityVerified")),
                "route": "Mieru TCP 上海入口接入",
                "evidence": item.get("reason") or "TCP traceroute 终点到达",
                "score": 100 if item["status"] == "PASS" else 0,
                "stars": "★★★★★" if item["status"] == "PASS" else "☆☆☆☆☆",
                "avg": latency.get("avg"), "min": None, "max": None,
                "p95": latency.get("p95"), "jitter": latency.get("jitter"),
                "stddev": None, "loss": None,
                "success": "1/1" if item["status"] == "PASS" else "0/1",
                "routeHops": len(item.get("route", "").splitlines()),
                "timeoutHops": 0, "backboneTags": ["Mieru TCP", "上海映射入口"],
                "reachability": item["status"],
            })
        summary = {
            "region": "入口接入汇总", "label": "中国三网 → 上海 Mieru 入口",
            "access": report["matrix"], "publicIp": "",
            "verified": all(
                x.get("asnVerified") and x.get("cityVerified") for x in items
            ) if items else False,
            "route": "Mieru TCP 上海入口接入",
            "evidence": f"PASS {len(passed)}/{len(items)}；仅为入口接入，不作为普通回程",
            "score": score, "stars": "★★★★★" if score >= 80 else "★★★☆☆",
            "avg": round(statistics.mean(
                x["latency"]["avg"] for x in passed if x.get("latency", {}).get("avg") is not None
            ), 1) if any(x.get("latency", {}).get("avg") is not None for x in passed) else None,
            "min": None, "max": None, "p95": None, "jitter": None,
            "stddev": None, "loss": None,
            "success": f"{len(passed)}/{len(items)}", "routeHops": 0,
            "timeoutHops": 0, "backboneTags": ["Mieru TCP", "专线映射链"],
            "reachability": report["access"]["status"],
        }
        return_items = [x for x in report["returns"] if x["carrier"] == carrier]
        return_passed = [x for x in return_items if x["status"] == "PASS"]
        return_valid = [x for x in return_items if int(x.get("routeRank", 0)) > 0]
        return_score = (
            round(sum(int(x.get("routeScore", 0)) for x in return_items) / len(return_items))
            if return_items else 0
        )
        return_probes = []
        for item in return_items:
            latency = item.get("latency") or {}
            return_probes.append({
                "city": item["capital"], "host": item["host"], "ip": item["host"],
                "route": item["routeClass"], "evidence": item["reason"],
                "score": int(item.get("routeScore", 0)),
                "stars": (
                    "★★★★★" if int(item.get("routeScore", 0)) >= 85
                    else "★★★☆☆" if int(item.get("routeScore", 0)) >= 55
                    else "☆☆☆☆☆"
                ),
                "avg": latency.get("avg"), "min": None, "max": None,
                "p95": latency.get("p95"), "jitter": latency.get("jitter"),
                "stddev": None, "loss": None,
                "success": "1/1" if item["status"] == "PASS" else "0/1",
                "routeHops": item["routeHops"], "timeoutHops": 0,
                "backboneTags": item.get("backboneTags", []),
                "routeNote": item.get("routeNote", ""),
                "probeCapital": item["capital"],
                "routeRank": int(item.get("routeRank", 0)),
                "transport": item.get("transport", ""),
                "reachability": item["status"],
            })
        overall_score = round(score * 0.3 + return_score * 0.7)
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
            "returnValid": f"{len(return_valid)}/{len(return_items)}",
            "returnReachable": f"{len(return_passed)}/{len(return_items)}",
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
            "title": (
                f"Mieru 映射链 {report['mappingChain']['status']}｜"
                "分数含回程骨干证据，不以 traceroute 可达直接计 100"
            ),
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
                "routeClass": x["routeClass"], "routeHops": x["routeHops"],
                "routeRank": x.get("routeRank", 0),
                "routeScore": x.get("routeScore", 0),
                "transport": x.get("transport", ""),
                "backboneTags": x.get("backboneTags", []),
                "routeNote": x.get("routeNote", ""),
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
            result_color = GREEN if item["status"] == "PASS" else YELLOW
            field("结果", f"{item['status']}｜终点 {'到达' if item['targetReached'] else '未确认'}｜RTT {shown_rtt}", result_color)

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
            field("结果", f"{item['status']}｜{item['routeClass']}｜RTT {shown_rtt}", result_color)

    access = {
        "total": total,
        "pass": sum(x["status"] == "PASS" for x in probes),
        "inconclusive": sum(x["status"] == "INCONCLUSIVE" for x in probes),
        "na": sum(x["status"] == "N/A" for x in probes),
        "noProbe": sum(x["status"] == "NO_PROBE" for x in probes),
    }
    access["coverage"] = round(access["pass"] * 100 / total, 1) if total else 0.0
    access["status"] = (
        "PASS" if access["pass"] / total >= 0.8
        else "PARTIAL" if access["pass"] > 0
        else "N/A" if access["na"] + access["noProbe"] == total
        else "INCONCLUSIVE"
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
            "中国侧不再随机扫描整座城市，也不把骨干 ASN 当成唯一探针 ASN；"
            "每组先以省会＋运营商名称／省级接入 ASN 定向查找 Globalping 探针，"
            "省会无探针时才退到同省其他城市，实际城市、ASN 与退选原因完整列示，绝不跨省替代。"
            "北京、上海、广州固定列入，--full 再扩展合肥、南京与杭州。"
            "日本出口对相同地区的三网公网目标同时执行 TCP/443、ICMP、UDP traceroute，"
            "先选择 CN2／AS9929／CMIN2 等骨干证据等级最高的结果，等级相同才比较回覆跳数；"
            "回程分数来自骨干等级与证据覆盖，不再把“有跳点回应”直接计为 100 分。"
            "不把中间跳点沉默当作业务丢包。"
            "日本出口本机核对公网 IP、业务监听、本机内网地址、"
            "默认路由及到上海入口的路由；入口可达且日本端同端口监听、私网地址吻合时，"
            "给出端口映射链证据；自动识别 mita 版本、运行状态、端口与 NTP。"
            "只有中国客户端连接 Mieru 后实测出口与日本端实际／预期出口一致，"
            "才把真实握手判为 PASS。供应商确实提供上海内网对端时，才用 20 次 ICMP 与 "
            "MTR／traceroute 增测专线纯内段。"
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
    field("上海入口接入", f"{access['status']}｜PASS {access['pass']}/{access['total']}｜覆盖 {access['coverage']}%", GREEN if access["status"] == "PASS" else YELLOW)
    return_pass = sum(x["status"] == "PASS" for x in returns)
    return_valid = sum(int(x.get("routeRank", 0)) > 0 for x in returns)
    return_premium = sum(int(x.get("routeRank", 0)) == 5 for x in returns)
    field(
        "北上广／六地回程",
        (
            f"可达 {return_pass}/{len(returns)}｜骨干有效 {return_valid}/{len(returns)}｜"
            f"精品证据 {return_premium}/{len(returns)}｜可达不直接计 100 分"
        ),
        GREEN if return_valid else YELLOW,
    )
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
