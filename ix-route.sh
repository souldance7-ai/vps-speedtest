#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="v1.2.0"
ENTRY_IP=""
ENTRY_PORT=""
EXPECTED_EXIT=""
LOCAL_PRIVATE=""
REMOTE_PEER=""
CLIENT_VERIFIED_EXIT=""
FULL=0
SELF_TEST=0
NO_PUBLISH=0
SPEED_TEST=0

usage() {
  cat <<'EOF'
中国三网入口去程／TCP应答与专线映射核对 v1.2.0

用途：
  独立检测“中国用户 → 中国侧公网入口 → NAT／IPLC／IEPL／中转隐藏内段 → 出口 VPS”。
  本脚本与 3net-route.sh 完全独立，不共用评分或报告。

推荐：在出口 VPS 上执行完整六地区 × 三网测试
  bash <(curl -fsSL https://raw.githubusercontent.com/souldance7-ai/vps-speedtest/refs/heads/agent/fix-ix-forward-probes/ix-route.sh) --full

非交互示例：
  bash ix-route.sh --entry 你的中国侧入口IPv4 --port 业务端口 \
    --expected-exit 预期出口IPv4 --local-private 出口端内网IPv4 --full

默认北上广三网TCP去程＋应答确认；完整六地区三网：
  bash ix-route.sh --entry 你的中国侧入口IPv4 --port 业务端口 --full

可选参数：
  --entry IP             中国侧公网入口
  --port PORT            协议业务端口，不是 SSH 22 或管理端口
  --expected-exit IP     预期公网出口
  --local-private IP     出口端专线内网 IP
  --peer IP              入口端专线内网对端；未知可留空
  --client-verified-exit IP
                        中国客户端连接协议后实测到的出口；Mieru 可进一步核对握手
  --full                 在固定北上广基础上加入安徽、江苏、浙江 × 三网
  --speed                追加北上广三网公网单线程速度辅助测试
  --no-publish           只生成本地 HTML／JSON／Markdown，不上传 Chain 3Net
  --self-test            离线自检，不发起网络探测
  -h, --help             显示帮助

判定边界：
  入口 TCP traceroute 到达，只证明入口端口经映射后的 TCP 路径可达。
  不要求供应商未交付的入口内网对端 IP；入口可达、本机监听、私网地址与路由会形成映射链证据。
  只有确实知道入口内网对端 IP 时，才额外测量专线纯内段 RTT／抖动／丢包。
  自动识别 Mieru mita 服务、版本、运行状态、端口监听与 NTP。
  只有提供中国客户端实测出口且与出口 VPS 一致时，才确认 Mieru 真实握手 PASS。
  DNS、探针或权限失败一律显示 N/A，不会换算成 100% LOSS。
  北京、上海、广州固定列入三网 TCP 去程与对应 TCP 应答确认；--full 再加入合肥、南京、杭州。
  TCP 应答确认只证明原探针收到入口端应答，不等于独立反向逐跳路由。
  --speed 使用第三方开源 TcpQuality 的三网公网单线程测量；它不经过用户填写的
  中国侧业务入口，不代表隐藏专线或实际协议端到端吞吐，不参与映射链 PASS。
  本地与公共报告会把用户相关 IPv4 脱敏为前两段，业务端口末三位脱敏为 ***。
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
    --speed) SPEED_TEST=1; shift ;;
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
export IX_SPEED_TEST="$SPEED_TEST"

# Python 程序从文件描述符 3 读取，stdin 保留给交互输入。
python3 /dev/fd/3 3<<'PY'
from __future__ import annotations

import datetime as dt
import csv
import html
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
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

VERSION = os.environ.get("IX_VERSION", "v1.2.0")
ENTRY_IP = os.environ.get("IX_ENTRY_IP", "").strip()
PORT_TEXT = os.environ.get("IX_ENTRY_PORT", "").strip()
EXPECTED_EXIT = os.environ.get("IX_EXPECTED_EXIT", "").strip()
LOCAL_PRIVATE = os.environ.get("IX_LOCAL_PRIVATE", "").strip()
REMOTE_PEER = os.environ.get("IX_REMOTE_PEER", "").strip()
CLIENT_VERIFIED_EXIT = os.environ.get("IX_CLIENT_VERIFIED_EXIT", "").strip()
FULL = os.environ.get("IX_FULL") == "1"
SELF_TEST = os.environ.get("IX_SELF_TEST") == "1"
NO_PUBLISH = os.environ.get("IX_NO_PUBLISH") == "1"
SPEED_TEST = os.environ.get("IX_SPEED_TEST") == "1"
GLOBALPING_API = "https://api.globalping.io/v1/measurements"
GLOBALPING_PROBES_API = "https://api.globalping.io/v1/probes"
PUBLIC_REPORT_API = "https://china-3net-route-report.souldance4.chatgpt.site/api/reports"
PUBLIC_REPORT_ROOT = "https://china-3net-route-report.souldance4.chatgpt.site"
TCPQUALITY_COMMIT = "5852b9af8a94afe6299f355673f9e2090a55d8c4"
TCPQUALITY_RAW_BASE = (
    "https://raw.githubusercontent.com/ibsgss/TcpQuality/"
    f"{TCPQUALITY_COMMIT}"
)

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


def mask_port(value: Any) -> str:
    text = str(value).strip()
    if not text.isdigit():
        return "N/A"
    return f"{text[:-3]}***" if len(text) > 3 else "***"


def mask_port_in_text(value: str, sensitive_ports: list[int]) -> str:
    for port in sensitive_ports:
        raw = str(port)
        masked = mask_port(raw)
        value = re.sub(rf":{re.escape(raw)}(?!\d)", f":{masked}", value)
        value = re.sub(
            rf"(?i)\b(TCP|UDP|PORT)\s*[:=]?\s*{re.escape(raw)}(?!\d)",
            lambda match: match.group(0).replace(raw, masked),
            value,
        )
        value = re.sub(
            rf"(端口\s*){re.escape(raw)}(?!\d)",
            lambda match: f"{match.group(1)}{masked}",
            value,
        )
    return value


def privacy_scrub(
    value: Any,
    sensitive_ips: list[str],
    sensitive_ports: list[int] | None = None,
) -> Any:
    """Mask user-specific IPv4 and business ports before report output/upload."""
    sensitive_ports = sensitive_ports or []
    replacements = {
        ip: mask_ip(ip)
        for ip in sensitive_ips
        if valid_ipv4(ip) and mask_ip(ip) != "N/A"
    }
    sensitive_prefixes = {
        ".".join(ip.split(".")[:2])
        for ip in replacements
    }
    if isinstance(value, dict):
        scrubbed: dict[str, Any] = {}
        port_keys = {
            "port", "targetPort", "entryPort", "businessPort", "primaryPort",
        }
        for key, item in value.items():
            if key in port_keys and str(item).isdigit():
                scrubbed[key] = mask_port(item)
            else:
                scrubbed[key] = privacy_scrub(item, sensitive_ips, sensitive_ports)
        return scrubbed
    if isinstance(value, list):
        return [privacy_scrub(item, sensitive_ips, sensitive_ports) for item in value]
    if isinstance(value, tuple):
        return tuple(privacy_scrub(item, sensitive_ips, sensitive_ports) for item in value)
    if isinstance(value, str):
        for raw, masked in sorted(replacements.items(), key=lambda item: len(item[0]), reverse=True):
            value = value.replace(raw, masked)
        def mask_related(match: re.Match[str]) -> str:
            ip = match.group(0)
            try:
                parsed = ipaddress.ip_address(ip)
            except ValueError:
                return ip
            prefix = ".".join(ip.split(".")[:2])
            if prefix in sensitive_prefixes or parsed.is_private:
                return mask_ip(ip)
            return ip
        value = re.sub(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])", mask_related, value)
        return mask_port_in_text(value, sensitive_ports)
    return value


def ask_inputs() -> tuple[str, int, str, str, str]:
    global ENTRY_IP, PORT_TEXT, EXPECTED_EXIT, LOCAL_PRIVATE, REMOTE_PEER
    if SELF_TEST:
        return "203.0.113.10", 443, "198.51.100.20", "10.0.0.10", ""

    section("INPUT GUIDE / 公用专项目标输入", MAGENTA)
    field("检测架构", "中国用户 → 中国侧公网入口:业务端口 → 隐藏内段 → 出口 VPS")
    field("入口 IP", "填写你要验证的中国侧公网入口 IPv4", CYAN)
    field("协议端口", "填写实际业务端口；不是 SSH 22 或管理端口", GREEN)
    field("预期出口", "填写本机应呈现的公网出口 IPv4；未知可留空", GREEN)
    field("出口端内网", "有专线／NAT 内网时填写；没有或未知可留空", CYAN)

    while not valid_ipv4(ENTRY_IP, public=True):
        ENTRY_IP = input("请输入中国侧公网入口 IPv4：").strip()
        if not valid_ipv4(ENTRY_IP, public=True):
            print(RED + "  IPv4 无效，请重新输入。" + RESET)
    while True:
        if not PORT_TEXT:
            PORT_TEXT = input("请输入协议业务端口〔不是 SSH 22／管理端口〕：").strip()
        try:
            port = int(PORT_TEXT)
            if 1 <= port <= 65535:
                break
        except ValueError:
            pass
        print(RED + "  端口无效，请输入 1～65535。" + RESET)
        PORT_TEXT = ""
    if not EXPECTED_EXIT:
        EXPECTED_EXIT = input("请输入预期公网出口 IPv4〔未知可回车〕：").strip()
    if EXPECTED_EXIT and not valid_ipv4(EXPECTED_EXIT, public=True):
        print(YELLOW + "  预期出口格式无效，本项按 N/A 处理。" + RESET)
        EXPECTED_EXIT = ""
    if not LOCAL_PRIVATE:
        LOCAL_PRIVATE = input("请输入出口端专线内网 IPv4〔未知可回车〕：").strip()
    if LOCAL_PRIVATE and not valid_ipv4(LOCAL_PRIVATE):
        print(YELLOW + "  出口端内网 IP 格式无效，本项按 N/A 处理。" + RESET)
        LOCAL_PRIVATE = ""
    if not REMOTE_PEER:
        REMOTE_PEER = input(
            "请输入入口端专线内网对端 IPv4〔未知可回车；脚本会尝试从活动连接识别〕："
        ).strip()
    if REMOTE_PEER and not valid_ipv4(REMOTE_PEER):
        print(YELLOW + "  入口内网对端格式无效，纯内段测试按 N/A 处理。" + RESET)
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


def detect_private_peer(port: int, local_addresses_seen: list[str]) -> tuple[str, str]:
    """Find a private peer on an active socket using the tested business port."""
    if SELF_TEST:
        return "10.0.0.1", "SELF_TEST_ACTIVE_SOCKET"
    if not shutil.which("ss"):
        return "", "N/A｜系统无 ss，无法从活动连接识别私网对端"
    output = run(["ss", "-Hnt"], 8)
    candidates: list[str] = []
    for row in output.splitlines():
        if "ESTAB" not in row:
            continue
        endpoints = re.findall(
            r"(?<![\d.])((?:\d{1,3}\.){3}\d{1,3}):(\d+)(?!\d)",
            row,
        )
        if len(endpoints) < 2:
            continue
        local_ip, local_port = endpoints[-2]
        peer_ip, peer_port = endpoints[-1]
        if int(local_port) != port and int(peer_port) != port:
            continue
        for candidate in (peer_ip, local_ip):
            if (
                valid_ipv4(candidate, public=False)
                and candidate not in local_addresses_seen
                and not candidate.startswith("127.")
                and candidate not in candidates
            ):
                candidates.append(candidate)
    if not candidates:
        return "", "N/A｜业务端口当前无可识别的私网 ESTABLISHED 对端"
    return candidates[0], f"AUTO_ESTABLISHED｜业务端口 {port} 活动私网对端"


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
    if client_exit and not SELF_TEST and not valid_ipv4(client_exit, public=True):
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
                f"客户端实测 {mask_ip(client_exit)}，与出口 VPS 实际／预期出口不一致"
            ),
        }
    if service.get("status") != "PASS":
        return {
            "status": "INCONCLUSIVE",
            "reason": "客户端出口一致，但出口 VPS 的 mita 服务状态未确认",
        }
    if chain.get("status") not in {"PASS", "PARTIAL"}:
        return {
            "status": "INCONCLUSIVE",
            "reason": "客户端出口一致，但入口映射链证据尚不完整",
        }
    return {
        "status": "PASS",
        "reason": "中国客户端经 Mieru 连接后出口与出口 VPS 实际／预期出口一致",
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


def speed_row(
    region: str,
    carrier: str,
    city: str,
    return_mbps: float | None,
    forward_mbps: float | None,
    return_retransmits: int | None,
) -> dict[str, Any]:
    carrier_codes = {"电信": "CT", "联通": "CU", "移动": "CM"}
    valid = return_mbps is not None or forward_mbps is not None
    return {
        "region": region,
        "carrier": carrier_codes.get(carrier, ""),
        "carrierName": f"中国{carrier}",
        "nodeCity": city or region,
        "label": f"{city or region}{carrier}",
        "returnRetransmits": return_retransmits,
        "returnMbps": return_mbps,
        "forwardMbps": forward_mbps,
        "status": "PASS" if valid else "N/A",
        "measurement": "PUBLIC_TOS_SINGLE_STREAM",
        "pathIncludesBusinessEntry": False,
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
            status = values[6].strip().upper()
            return_mbps = speed_value(values[7])
            return_retransmits = retrans_value(values[8])
            forward_mbps = speed_value(values[9])
            row = speed_row(
                region,
                carrier,
                city,
                return_mbps,
                forward_mbps,
                return_retransmits,
            )
            if status != "OK" and return_mbps is None and forward_mbps is None:
                row["status"] = "N/A"
            rows.append(row)
    order = {"北京": 0, "上海": 1, "广东": 2}
    carrier_order = {"CT": 0, "CU": 1, "CM": 2}
    return sorted(
        rows,
        key=lambda row: (
            order.get(str(row["region"]), 99),
            carrier_order.get(str(row["carrier"]), 99),
        ),
    )


def single_thread_speed() -> dict[str, Any]:
    boundary = (
        "辅助项：出口VPS与中国三网公共TOS测速端的单数据流能力；"
        "不经过用户填写的中国侧业务入口，不代表隐藏专线或实际协议端到端吞吐，"
        "不参与映射链与真实握手判定。"
    )
    if not SPEED_TEST:
        return {
            "enabled": False,
            "status": "N/A",
            "reason": "未使用 --speed；本项未执行",
            "source": "TcpQuality pinned upstream",
            "upstreamCommit": TCPQUALITY_COMMIT,
            "rows": [],
            "boundary": boundary,
            "pathIncludesBusinessEntry": False,
        }
    if SELF_TEST:
        rows = self_test_speed_rows()
        return {
            "enabled": True,
            "status": "PASS",
            "reason": "SELF-TEST 九组结构完整",
            "source": "TcpQuality-compatible self-test fixture",
            "upstreamCommit": TCPQUALITY_COMMIT,
            "rows": rows,
            "boundary": boundary,
            "pathIncludesBusinessEntry": False,
        }
    if os.name != "posix" or not hasattr(os, "geteuid") or os.geteuid() != 0:
        return {
            "enabled": True,
            "status": "N/A",
            "reason": "三网单线程速度需要 Linux root 环境",
            "source": "TcpQuality pinned upstream",
            "upstreamCommit": TCPQUALITY_COMMIT,
            "rows": [],
            "boundary": boundary,
            "pathIncludesBusinessEntry": False,
        }

    workdir = Path(tempfile.mkdtemp(prefix="ix-speed-"))
    entry_script = workdir / "runTcpQuality.sh"
    before = set(Path("/tmp").glob("zstatic_nping_*.csv"))
    started = time.time()
    try:
        req = urllib.request.Request(
            f"{TCPQUALITY_RAW_BASE}/runTcpQuality.sh",
            headers={"User-Agent": f"ix-route/{VERSION}"},
        )
        with urllib.request.urlopen(req, timeout=40) as response:
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
                "bash",
                str(entry_script),
                "--no-rootfs",
                "--only-speedtest",
                "--no-rank-upload",
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
                output, _ = process.communicate(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                output, _ = process.communicate()
            return {
                "enabled": True,
                "status": "N/A",
                "reason": "三网单线程速度超过12分钟，已终止；建议稍后单独复测",
                "source": "TcpQuality pinned upstream",
                "upstreamCommit": TCPQUALITY_COMMIT,
                "rows": [],
                "boundary": boundary,
                "pathIncludesBusinessEntry": False,
            }
        csv_path = newest_speed_csv(started, before)
        rows = parse_tcpquality_speed_csv(csv_path) if csv_path else []
        valid = sum(row["status"] == "PASS" for row in rows)
        status = "PASS" if valid == 9 else "PARTIAL" if valid else "N/A"
        reason = (
            f"北上广三网公网单线程有效 {valid}/9"
            if valid
            else "未取得可解析的三网单线程速度结果"
        )
        if process.returncode and not valid:
            tail = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", output or "")
            tail = " ".join(tail.splitlines()[-3:])[:220]
            reason += f"；上游退出码 {process.returncode}" + (f"：{tail}" if tail else "")
        return {
            "enabled": True,
            "status": status,
            "reason": reason,
            "source": "ibsgss/TcpQuality --only-speedtest --no-rank-upload",
            "upstreamCommit": TCPQUALITY_COMMIT,
            "rows": rows,
            "boundary": boundary,
            "pathIncludesBusinessEntry": False,
        }
    except Exception as exc:
        return {
            "enabled": True,
            "status": "N/A",
            "reason": f"测速辅助项异常 {type(exc).__name__}: {exc}",
            "source": "TcpQuality pinned upstream",
            "upstreamCommit": TCPQUALITY_COMMIT,
            "rows": [],
            "boundary": boundary,
            "pathIncludesBusinessEntry": False,
        }
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def speed_recommendations(speed: dict[str, Any]) -> list[str]:
    if not speed.get("enabled"):
        return ["如需三网公网单线程辅助数据，下次加 --speed；真实专线速度仍应由中国客户端直连业务协议测试。"]
    rows = speed.get("rows") or []
    valid = [row for row in rows if row.get("status") == "PASS"]
    notes: list[str] = []
    if len(valid) < 9:
        notes.append(f"三网公网单线程仅取得 {len(valid)}/9，失败项应换时段复测，不能按0 Mbps计入质量。")
    slow = [
        row for row in valid
        if min(
            value for value in (row.get("returnMbps"), row.get("forwardMbps"))
            if value is not None
        ) < 50
    ]
    if slow:
        labels = "、".join(str(row["label"]) for row in slow[:4])
        notes.append(f"{labels}至少一个方向低于50 Mbps，建议晚高峰／闲时各复测一次并与中国客户端真实协议测速对照。")
    high_retrans = [
        row for row in valid
        if row.get("returnRetransmits") is not None
        and int(row["returnRetransmits"]) >= 1000
    ]
    if high_retrans:
        labels = "、".join(str(row["label"]) for row in high_retrans[:4])
        notes.append(f"{labels}回程重传偏高，优先检查晚高峰拥塞、出口限速与跨境路径波动。")
    if valid and not slow and not high_retrans and len(valid) == 9:
        notes.append("公网辅助测速九组完整，未见明显低速或高重传；仍需中国客户端真实协议测速确认隐藏专线端到端吞吐。")
    return notes


def show_single_thread_speed(speed: dict[str, Any]) -> None:
    section("AUX / 三网公网单线程速度（辅助项）", CYAN)
    field("测量边界", speed.get("boundary") or "N/A", YELLOW)
    field(
        "状态",
        f"{speed.get('status', 'N/A')}｜{speed.get('reason', 'N/A')}",
        GREEN if speed.get("status") == "PASS" else YELLOW,
    )
    rows = speed.get("rows") or []
    if not rows:
        return
    carrier_color = {"CT": CYAN, "CU": RED, "CM": GREEN}
    current_region = ""
    for row in rows:
        region = str(row.get("region") or "N/A")
        if region != current_region:
            print()
            print(MAGENTA + f"  {region}" + RESET)
            print(
                GRAY
                + f"  {'地区':<14}{'回程重传':>10}{'回程速度':>14}{'去程速度':>14}"
                + RESET
            )
            current_region = region
        retrans = row.get("returnRetransmits")
        return_mbps = row.get("returnMbps")
        forward_mbps = row.get("forwardMbps")
        retrans_text = "N/A" if retrans is None else str(retrans)
        return_text = "N/A" if return_mbps is None else f"{return_mbps:.1f}Mbps"
        forward_text = "N/A" if forward_mbps is None else f"{forward_mbps:.1f}Mbps"
        print(
            carrier_color.get(str(row.get("carrier")), WHITE)
            + f"  {str(row.get('label') or 'N/A'):<14}"
            + f"{retrans_text:>10}{return_text:>14}{forward_text:>14}"
            + RESET
        )


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



def ping_peer(peer: str, count: int = 20) -> dict[str, Any]:
    if not peer:
        return {
            "status": "N/A",
            "reason": "未提供且未自动识别入口端专线内网对端 IP，无法测量同路径内段回程",
            "stats": summarize([], count),
            "route": "",
            "routeLookup": "",
            "pathModel": "PRIVATE_PEER_SAME_PATH",
        }
    if not shutil.which("ping"):
        return {
            "status": "N/A", "reason": "系统无 ping",
            "stats": summarize([], count), "route": "",
            "routeLookup": "", "pathModel": "PRIVATE_PEER_SAME_PATH",
        }
    route_lookup = (
        run(["ip", "-4", "route", "get", peer], 8)
        if shutil.which("ip") else ""
    )
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
        "routeLookup": route_lookup,
        "pathModel": "PRIVATE_PEER_SAME_PATH",
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


def tcp_response_confirmation_from_probe(
    probe: dict[str, Any],
    entry: str,
    port: int,
) -> dict[str, Any]:
    """Confirm an endpoint response at the exact forward probe.

    This is not an independent reverse-path measurement.  It only records that
    the original China probe received a TCP response from the same entry and
    business port.  Reverse hop-by-hop routing is not observable from this API.
    """
    check = probe.get("tcpPortCheck") or {}
    measurement_id = str(probe.get("forwardMeasurementId") or "")
    if measurement_id and check.get("status") == "NOT_NEEDED" and not SELF_TEST:
        check = same_probe_tcp_check(entry, port, measurement_id)
        probe["tcpPortCheck"] = check
    trace_reply = bool(probe.get("traceTargetReached"))
    tcp_reply = check.get("status") == "PASS"
    status = "PASS" if trace_reply or tcp_reply else (
        "N/A" if probe.get("status") in {"N/A", "NO_PROBE"} else "INCONCLUSIVE"
    )
    if tcp_reply:
        reason = (
            f"原探针对同一入口、同一业务端口收到 TCP 应答 "
            f"{check.get('received', 0)}/3；仅确认端口应答，不代表反向逐跳路由"
        )
    elif trace_reply:
        reason = (
            "原探针的 TCP traceroute 已收到入口终点应答；"
            "仅确认端口应答，反向逐跳路由不可见"
        )
    else:
        reason = (
            f"{check.get('reason') or probe.get('reason') or '未取得 TCP 应答证据'}；"
            "不改用出口 VPS 的默认公网路由冒充反向路由"
        )
    return {
        "carrier": probe.get("carrier") or "",
        "carrierName": probe.get("carrierName") or "",
        "requestedRegion": probe.get("requestedRegion") or "",
        "probeRegion": probe.get("probeRegion") or "",
        "probeCity": probe.get("probeCity") or "",
        "probeAsn": probe.get("probeAsn") or 0,
        "probeNetwork": probe.get("probeNetwork") or "",
        "sourceClass": probe.get("sourceClass") or "NONE",
        "regionFidelity": probe.get("regionFidelity") or "UNVERIFIED",
        "entry": mask_ip(entry),
        "port": port,
        "status": status,
        "tcpResponses": int(check.get("received") or (1 if trace_reply else 0)),
        "forwardMeasurementId": measurement_id,
        "responseMeasurementId": str(check.get("measurementId") or ""),
        "pathModel": "SAME_PROBE_TCP_RESPONSE_CONFIRMATION",
        "isReverseRoute": False,
        "reverseRouteVisible": False,
        "reason": reason,
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
                "forwardMeasurementId": str(measurement_id),
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
        "forwardMeasurementId": "",
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
        "forwardMeasurementId": f"self-test-forward-{index}",
        "tcpPortCheck": {
            "status": "PASS" if reached else "INCONCLUSIVE",
            "received": 3 if reached else 0,
            "measurementId": f"self-test-return-{index}",
            "latency": {
                "status": "PASS" if reached else "N/A",
                "avg": round(18.5 + index * 1.7, 1) if reached else None,
                "p95": round(20.5 + index * 1.7, 1) if reached else None,
                "jitter": 1.1 if reached else None,
                "loss": None, "received": 3 if reached else 0, "sent": 3,
            },
            "reason": "SELF-TEST 原探针收到 TCP 应答" if reached else "SELF-TEST 未取得 TCP 应答",
        },
        "latency": {
            "status": "PASS", "avg": round(18.0 + index * 1.7, 1),
            "p95": round(20.0 + index * 1.7, 1), "jitter": 1.2,
            "loss": None, "received": 3, "sent": 3,
        },
        "route": f"01 10.0.0.1 1.0ms\n02 {ENTRY_IP or '203.0.113.10'} 25.0ms",
        "reason": "" if reached else "SELF-TEST 模拟未显示终点",
    }


def selection_self_test() -> None:
    """Regression: state wins; overlapping boxes can never cross-label provinces."""
    global PROBE_INVENTORY, PROBE_INVENTORY_ERROR
    saved_inventory = PROBE_INVENTORY
    saved_error = PROBE_INVENTORY_ERROR
    try:
        if mask_port(23456) != "23***" or mask_port(443) != "***":
            raise AssertionError("业务端口末三位脱敏规则错误")
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



def quality_label(internal: dict[str, Any]) -> str:
    stats = internal.get("stats") or {}
    if internal.get("status") != "PASS" or stats.get("avg") is None:
        return "N/A｜缺少可验证的专线纯内段数据"
    avg = float(stats["avg"])
    loss = float(stats.get("loss") or 0)
    jitter = float(stats.get("jitter") or 0)
    if avg <= 45 and loss == 0 and jitter <= 5:
        return "优秀｜符合低时延专线特征"
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
            "status": "PARTIAL",
            "reason": (
                "入口业务端口可达＋出口同端口监听＋本机私网地址吻合；"
                "尚缺中国客户端真实协议握手，不能判整条隐藏映射链PASS"
            ),
        }
    if reachable > 0 and listener.get("status") == "PASS":
        return {
            "status": "PARTIAL",
            "reason": "入口端口可达且出口端监听，但出口端私网地址未核对",
        }
    if reachable > 0:
        return {
            "status": "INCONCLUSIVE",
            "reason": "入口端口可达，但出口端未确认同端口监听",
        }
    return {
        "status": "N/A",
        "reason": "缺少足够的入口与出口端关联证据",
    }


def markdown_report(report: dict[str, Any]) -> str:
    access = report["access"]
    internal = report["internal"]
    identity = report["exitIdentity"]
    listener = report["listener"]
    response_summary = report["tcpResponseSummary"]
    lines = [
        f"# 中国三网入口去程／TCP应答与专线映射核对报告",
        "",
        f"- 版本：{report['version']}",
        f"- 时间：{report['generated']}",
        f"- 中国侧入口：`{report['entry']['masked']}:{report['entry']['port']}`",
        f"- 出口 VPS：`{identity.get('ipMasked') or mask_ip(identity.get('ip', ''))}` / {identity.get('asn') or 'N/A'} / {identity.get('org') or 'N/A'}",
        f"- 测试矩阵：{report['matrix']}",
        "",
        "## 结论",
        "",
        (
            f"- 中国侧入口端到端 TCP：{access['status']}（运营商可达 "
            f"{access.get('carrierReachable', access['pass'])}/{access['total']}，"
            f"原省精确 {access['pass']}/{access['total']}，省级可达 "
            f"{access.get('reachable', access['pass'])}/{access['total']}，"
            f"省内第三方机房参考 {access.get('provinceReference', 0)}，"
            f"跨省同运营商降级 {access.get('crossProvinceFallback', 0)}，"
            f"INCONCLUSIVE {access['inconclusive']}，"
            f"NO_PROBE {access.get('noProbe', 0)}，N/A {access['na']}）"
        ),
        (
            f"- 原探针 TCP 应答确认：{response_summary['status']} "
            f"{response_summary['confirmed']}/{response_summary['total']}；"
            "仅确认入口端口应答，非独立反向逐跳路由，不计算回程分数"
        ),
        (
            f"- 三网公网单线程速度：{report['singleThreadSpeed']['status']} — "
            f"{report['singleThreadSpeed']['reason']}；不经过中国侧业务入口，"
            "不参与专线映射链判定"
        ),
        f"- 出口端业务监听：{listener['status']} — {listener['evidence']}",
        f"- Mieru／Mita 服务：{report['mieruService']['status']} — {report['mieruService']['evidence']}",
        f"- Mieru 真实握手：{report['protocolHandshake']['status']} — {report['protocolHandshake']['reason']}",
        f"- 入口→出口端口映射链：{report['mappingChain']['status']} — {report['mappingChain']['reason']}",
        f"- 专线纯内段（可选）：{internal['status']} — {quality_label(internal)}",
        f"- 出口公网一致性：{report['exitMatch']['status']} — {report['exitMatch']['reason']}",
        "",
        "## 最终改善建议",
        "",
        *[f"- {item}" for item in report.get("improvements") or []],
        "",
        "## 四层判定边界",
        "",
        "1. 中国探针到入口业务端口的 TCP traceroute 到达，表示入口映射后的 TCP 路径可达。",
        "2. 入口端口可达、出口端同端口监听及私网地址吻合，作为端口映射链证据，但不冒充协议认证成功。",
        "3. 只有供应商确实提供入口内网对端时，才额外统计纯内段 Ping RTT／P95／抖动／丢包。",
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
        "## 原探针 TCP 应答确认（非反向路由）",
        "",
        "| 省级任务 | 运营商 | 实际探针 | 入口 | TCP 应答 | 判定边界 | 状态 |",
        "|---|---|---|---|---:|---|---|",
    ])
    for item in report["tcpResponseConfirmations"]:
        lines.append(
            f"| {item['requestedRegion']} | {item['carrierName']} | "
            f"{item.get('probeRegion') or 'N/A'}／{item.get('probeCity') or 'N/A'} | "
            f"`{item['entry']}:{item['port']}` | {item.get('tcpResponses', 0)} | "
            f"原探针收到入口 TCP 应答；非反向逐跳路由 | {item['status']} |"
        )
    lines.extend([
        "",
        "## 三网公网单线程速度（辅助项）",
        "",
        report["singleThreadSpeed"]["boundary"],
        "",
        "| 区域 | 测速节点 | 回程重传 | 回程速度 | 去程速度 | 状态 |",
        "|---|---|---:|---:|---:|---|",
    ])
    for item in report["singleThreadSpeed"].get("rows") or []:
        retrans = (
            str(item["returnRetransmits"])
            if item.get("returnRetransmits") is not None else "N/A"
        )
        return_speed = (
            f"{item['returnMbps']:.1f} Mbps"
            if item.get("returnMbps") is not None else "N/A"
        )
        forward_speed = (
            f"{item['forwardMbps']:.1f} Mbps"
            if item.get("forwardMbps") is not None else "N/A"
        )
        lines.append(
            f"| {item['region']} | {item['label']} | {retrans} | "
            f"{return_speed} | {forward_speed} | {item['status']} |"
        )
    stats = internal.get("stats") or {}
    lines.extend([
        "",
        "## 映射链与专线纯内段",
        "",
        f"- 出口端内网：`{report['localPrivate']['masked']}`；本机存在：{report['localPrivate']['status']}",
        f"- 入口端内网对端：`{report['remotePeer']['masked']}`",
        f"- 私网对端来源：{report['remotePeer'].get('source') or 'N/A'}",
        f"- 映射链证据：{report['mappingChain']['status']} — {report['mappingChain']['reason']}",
        f"- 默认路由：`{report['networkContext']['defaultRoute']}`",
        f"- 到中国侧入口路由：`{report['networkContext']['entryRoute']}`",
        f"- 到私网对端路由：`{internal.get('routeLookup') or 'N/A'}`",
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
<title>Chain 3Net｜中国三网入口去程／TCP应答与专线映射核对</title>
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
<header><h1>CHAIN 3NET · 中国三网入口去程／TCP应答与专线映射核对</h1><div class="sub" id="meta"></div>
<div style="margin-top:14px"><button id="json">下载 JSON</button><button onclick="window.print()">打印／另存 PDF</button></div></header>
<section class="panel"><h2>TOPOLOGY / 实际业务拓扑</h2><div class="topology" id="topology"></div></section>
<div class="grid" id="cards"></div>
<section class="panel"><h2>MIERU / 出口端可选服务证据</h2><table id="mieru"></table></section>
<section class="panel"><h2>FORWARD / 省级任务三网去程</h2><div style="overflow:auto"><table><thead><tr><th>省级任务</th><th>运营商</th><th>实际省／城市</th><th>来源类型</th><th>选点层级</th><th>实际网络／ASN</th><th>代表性</th><th>终点</th><th>RTT</th><th>状态</th><th>说明</th></tr></thead><tbody id="rows"></tbody></table></div><p class="note">省会无探针时先扫描同省全部在线城市；同省运营商机房／未分类运营商网络可作为运营商去程证据并明确标注非家宽。全省仍无指定运营商时，才使用跨省同运营商测点；终点到达标为 PASS_FALLBACK 并计入运营商可达，但不计入原省精准覆盖。NO_PROBE 不代表线路中断或 100% 丢包。</p></section>
<section class="panel"><h2>TCP RESPONSE / 原探针TCP应答确认（非反向路由）</h2><div style="overflow:auto"><table><thead><tr><th>省级任务</th><th>运营商</th><th>实际探针</th><th>入口</th><th>应答证据</th><th>反向逐跳</th><th>状态</th><th>说明</th></tr></thead><tbody id="responseRows"></tbody></table></div><p class="note">本区只确认原中国探针收到同一入口、同一业务端口的 TCP 应答。去程表中的延迟是入口 TCP 往返 RTT，不是单向去程；此区不重复包装成“回程延迟”。</p></section>
<section class="panel"><h2>SPEED / 三网公网单线程速度（辅助项）</h2><div style="overflow:auto"><table><thead><tr><th>区域</th><th>测速节点</th><th>回程重传</th><th>回程速度</th><th>去程速度</th><th>状态</th></tr></thead><tbody id="speedRows"></tbody></table></div><p class="note" id="speedBoundary"></p></section>
<section class="panel"><h2>IMPROVEMENTS / 最终改善建议</h2><ul id="improvements"></ul></section>
<section class="panel"><h2>BOUNDARY / 判定边界</h2><p class="note" id="method"></p></section>
</main><script>
const R={embedded}; const E=s=>String(s??'N/A').replace(/[&<>"']/g,c=>({{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}}[c]));
const metric=(v,suffix='')=>v===null||v===undefined||v===''?'N/A':`${{E(v)}}${{suffix}}`;
const badge=(label,obj)=>`<article class="card"><span>${{E(label)}}</span><strong class="${{E(obj.status)}}">${{E(obj.status)}}</strong><small>${{E(obj.reason||obj.evidence||'')}}</small></article>`;
document.getElementById('meta').textContent=`${{R.generated}} · ${{R.version}} · ${{R.matrix}}`;
document.getElementById('topology').innerHTML=[
`<div class="node">中国客户端／探针</div>`,`<b class="arrow">→</b>`,
`<div class="node">中国侧入口<br><code>${{E(R.entry.masked)}}:${{E(R.entry.port)}}</code></div>`,`<b class="arrow">→</b>`,
`<div class="node">隐藏专线／映射链</div>`,`<b class="arrow">→</b>`,
`<div class="node">出口端服务<br><code>${{E(R.localPrivate.masked)}}:${{E(R.entry.port)}}</code></div>`,`<b class="arrow">→</b>`,
`<div class="node">出口 VPS<br><code>${{E(R.exitIdentity.ipMasked)}}</code></div>`].join('');
document.getElementById('cards').innerHTML=[
badge('中国侧入口接入',{{status:R.access.status,reason:`运营商可达 ${{R.access.carrierReachable??R.access.pass}}/${{R.access.total}} · 原省精确 ${{R.access.pass}}/${{R.access.total}} · 跨省同运营商降级 ${{R.access.crossProvinceFallback??0}}`}}),
badge('原探针TCP应答',R.tcpResponseSummary),badge('入口→出口映射链',R.mappingChain),badge('出口公网一致性',R.exitMatch)].join('');
const M=R.mieruService;
document.getElementById('mieru').innerHTML=`<tr><th>服务识别</th><td class="${{E(M.status)}}">${{E(M.status)}}</td><th>版本</th><td>${{E(M.version)}}</td></tr>
<tr><th>运行状态</th><td>${{E(M.runtime)}}</td><th>systemd</th><td>${{E(M.systemd)}}</td></tr>
<tr><th>NTP</th><td>${{E(M.ntp)}}</td><th>端口监听</th><td class="${{E(R.listener.status)}}">${{E(R.listener.status)}} · ${{E(R.listener.evidence)}}</td></tr>`;
document.getElementById('rows').innerHTML=R.probes.map(p=>`<tr><td>${{E(p.displayRegion||p.requestedRegion)}}</td><td>${{E(p.carrierName)}}</td><td>${{E(p.probeRegion||'N/A')}}／${{E(p.probeCity||'N/A')}}${{p.sourceClass==='CROSS_PROVINCE_CARRIER_FALLBACK'?'<br><small>跨省最后备援</small>':p.capitalPreferred===false?'<br><small>同省备选</small>':''}}</td><td>${{E(p.sourceClass||'N/A')}}</td><td>${{E(p.selectionTier||'N/A')}}</td><td>${{E(p.probeNetwork||'N/A')}}<br><small>AS${{E(p.probeAsn||'N/A')}}</small></td><td>${{p.carrierRepresentative?'本省运营商有效':p.sourceClass==='CROSS_PROVINCE_CARRIER_FALLBACK'?'同运营商可达／非原省代表':'省内第三方参考'}}</td><td>${{p.targetReached?'到达':'未确认'}}${{p.traceTargetReached===false&&p.targetReached?'<br><small>同探针 TCP 复核</small>':''}}</td><td>${{metric(p.latency?.avg,' ms')}}</td><td class="${{E(p.status)}}">${{E(p.status)}}</td><td>${{E(p.reason)}}</td></tr>`).join('');
document.getElementById('responseRows').innerHTML=R.tcpResponseConfirmations.map(p=>`<tr><td>${{E(p.requestedRegion)}}</td><td>${{E(p.carrierName)}}</td><td>${{E(p.probeRegion||'N/A')}}／${{E(p.probeCity||'N/A')}}<br><small>AS${{E(p.probeAsn||'N/A')}}</small></td><td><code>${{E(p.entry)}}:${{E(p.port)}}</code></td><td>${{E(p.tcpResponses||0)}} 次 TCP 应答</td><td>不可见<br><small>非反向路由</small></td><td class="${{E(p.status)}}">${{E(p.status)}}</td><td>${{E(p.reason)}}</td></tr>`).join('');
const S=R.singleThreadSpeed||{{rows:[],status:'N/A',reason:'未执行',boundary:'N/A'}};
document.getElementById('speedRows').innerHTML=(S.rows?.length?S.rows:[{{region:'N/A',label:S.reason,returnRetransmits:null,returnMbps:null,forwardMbps:null,status:S.status}}]).map(p=>`<tr><td>${{E(p.region)}}</td><td>${{E(p.label)}}</td><td>${{metric(p.returnRetransmits)}}</td><td>${{metric(p.returnMbps,' Mbps')}}</td><td>${{metric(p.forwardMbps,' Mbps')}}</td><td class="${{E(p.status)}}">${{E(p.status)}}</td></tr>`).join('');
document.getElementById('speedBoundary').textContent=S.boundary||S.reason||'N/A';
document.getElementById('improvements').innerHTML=(R.improvements||[]).map(p=>`<li>${{E(p)}}</li>`).join('');
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
        flat = []
        for item in items:
            latency = item.get("latency") or {}
            flat.append({
                "region": item["requestedRegion"],
                "label": f"{item['requestedRegion']} {carrier_names[carrier]} → 中国侧入口",
                "access": item.get("mode") or "N/A",
                "publicIp": "",
                "verified": bool(
                    item.get("carrierRepresentative")
                    and item.get("cityVerified")
                    and item.get("provinceVerified")
                    and item.get("targetReached")
                ),
                "route": "中国三网探针 → 中国侧入口（TCP去程）",
                "evidence": (
                    f"实际省市 {item.get('probeRegion') or 'N/A'}／"
                    f"{item.get('probeCity') or 'N/A'}；"
                    f"行政区核对 {item.get('provinceMatchMethod') or 'N/A'}；"
                    f"选点 {item.get('selectionTier') or 'N/A'}；"
                    f"TCP路由终点 {'到达' if item.get('traceTargetReached') else '未显示'}；"
                    f"{item.get('reason') or 'TCP traceroute 终点到达'}"
                ),
                "score": None,
                "stars": "",
                "avg": latency.get("avg"), "min": None, "max": None,
                "p95": latency.get("p95"), "jitter": latency.get("jitter"),
                "stddev": None, "loss": None,
                "success": "1/1" if item.get("targetReached") else "0/1",
                "routeHops": len(item.get("route", "").splitlines()),
                "timeoutHops": 0,
                "backboneTags": (
                    ["TCP 业务端口", "中国侧映射入口"]
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
            "region": "入口接入汇总", "label": "中国三网 → 中国侧业务入口",
            "access": report["matrix"], "publicIp": "",
            "verified": all(
                x.get("carrierRepresentative")
                and x.get("cityVerified")
                and x.get("provinceVerified")
                for x in items
            ) if items else False,
            "route": "中国三网探针 → 中国侧入口（TCP去程）",
            "evidence": (
                f"运营商可达 {len(carrier_reached)}/{len(items)}；"
                f"原省精确 {len(passed)}/{len(items)}；"
                f"跨省同运营商降级 {len(fallback_passed)}；"
                "仅为入口TCP去程，不代表出口VPS普通公网回程"
            ),
            "score": None, "stars": "",
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
            "timeoutHops": 0, "backboneTags": ["TCP 业务端口", "专线映射链"],
            "reachability": report["access"]["status"],
        }
        response_items = [
            x for x in report["tcpResponseConfirmations"]
            if x["carrier"] == carrier
        ]
        response_passed = [x for x in response_items if x["status"] == "PASS"]
        response_rate = (
            round(len(response_passed) * 100 / len(response_items))
            if response_items else 0
        )
        response_probes = []
        for item in response_items:
            response_probes.append({
                "requestedRegion": item["requestedRegion"],
                "probeRegion": item.get("probeRegion") or "",
                "probeCity": item.get("probeCity") or "",
                "probeAsn": item.get("probeAsn") or 0,
                "carrierName": item.get("carrierName") or "",
                "entry": item["entry"],
                "port": item["port"],
                "route": "入口TCP应答已返回原探针（非反向路由）",
                "evidence": item["reason"],
                "status": item["status"],
                "tcpResponses": item.get("tcpResponses") or 0,
                "reverseRouteVisible": False,
                "routeNote": "只确认原探针收到入口TCP应答；不计算回程分数",
                "targetSource": "FORWARD_MEASUREMENT_REUSE",
            })
        carriers.append({
            "id": carrier, "name": carrier_names[carrier],
            "route": "原探针TCP应答确认（非反向路由）",
            "score": None,
            "stars": "",
            "probeCount": len(response_probes),
            "routeTypes": 1 if response_items else 0,
            "forward": summary,
            "forwardRoute": "中国三网探针 → 中国侧入口（TCP去程）",
            "forwardProbes": flat, "forwardScore": None,
            "returnScore": None,
            "tcpResponseRate": response_rate,
            "bidirectional": False,
            "tcpResponseConfirmations": response_probes,
        })
    return {
        "version": report["version"], "generated": report["generated"],
        "reportKind": "IX_ENTRY_AUDIT",
        "target": report["exitIdentity"]["ipMasked"],
        "targetPort": report["entry"]["port"],
        "returnSshHost": report["exitIdentity"]["ipMasked"],
        "selfTest": False, "mode": "中国三网入口去程＋TCP应答确认＋专线映射核对",
        "matrix": report["matrix"],
        "methodology": report["methodology"],
        "bgp": {
            "asn": report["exitIdentity"].get("asn") or "N/A",
            "provider": report["exitIdentity"].get("org") or "N/A",
            "location": " ".join(filter(None, [
                report["exitIdentity"].get("country"), report["exitIdentity"].get("city")
            ])),
        },
        "final": {
            "score": None,
            "stars": "",
            "title": (
                f"入口TCP {report['access']['status']}｜"
                f"原探针应答 {report['tcpResponseSummary']['confirmed']}/"
                f"{report['tcpResponseSummary']['total']}（非反向路由）"
            ),
            "elapsed": "N/A",
            "presentationPolicy": "EVIDENCE_ONLY_NO_SCORE_NO_STARS",
        },
        "carriers": carriers,
        "singleThreadSpeed": report["singleThreadSpeed"],
        "improvements": report["improvements"],
        "dedicatedLine": {
            "topology": "中国客户端→中国侧公网入口→隐藏内段→出口 VPS→公网出口",
            "entry": f"{report['entry']['masked']}:{report['entry']['port']}",
            "entryAsn": "中国侧映射入口｜以各探针实际 ASN 证据为准",
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
            "singleThreadSpeed": report["singleThreadSpeed"],
            "improvements": report["improvements"],
            "tcpResponseConfirmations": [{
                "carrier": x["carrier"], "requestedRegion": x["requestedRegion"],
                "probeRegion": x.get("probeRegion") or "",
                "probeCity": x.get("probeCity") or "",
                "entry": x["entry"], "port": x["port"], "status": x["status"],
                "targetSource": "FORWARD_MEASUREMENT_REUSE",
                "pathModel": x["pathModel"],
                "isReverseRoute": False,
                "reverseRouteVisible": False,
                "tcpResponses": x["tcpResponses"],
            } for x in report["tcpResponseConfirmations"]],
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
        response_count = len(carrier.get("tcpResponseConfirmations") or [])
        if forward_count not in {3, 6} or response_count not in {3, 6}:
            field(
                "Chain 3Net",
                f"上传前校验失败｜{carrier['id']} 去程 {forward_count}／"
                f"TCP应答确认 {response_count}，必须为 3 或 6",
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
        client_verified_exit = "198.51.100.20"
    print(BLUE + "\n  ═══════════════════════════════════════════════════════════════" + RESET)
    print(CYAN + f"  IX-ROUTE {VERSION} · 中国三网入口去程／TCP应答与专线映射核对" + RESET)
    print(BLUE + "  ═══════════════════════════════════════════════════════════════" + RESET)

    section("TOPOLOGY / 检测拓扑", CYAN)
    field("中国公网入口", f"{mask_ip(entry)}:{mask_port(port)}", CYAN)
    field("业务端口", f"{mask_port(port)}（末三位已脱敏；不是 SSH）", GREEN)
    field("预期公网出口", mask_ip(expected_exit), GREEN)
    field("出口端内网", mask_ip(local_private), CYAN)
    field("入口内网对端", mask_ip(remote_peer), MAGENTA)
    field(
        "测试边界",
        "TCP去程、原探针TCP应答、映射链、可选Mieru握手；"
        "TCP应答不是反向逐跳路由",
        YELLOW,
    )

    identity = (
        {"ip": "198.51.100.20", "asn": "AS9999", "org": "SELF-TEST", "country": "Test", "city": "Lab"}
        if SELF_TEST else public_identity()
    )
    addresses = ["10.0.0.10", "127.0.0.1"] if SELF_TEST else local_addresses()
    peer_source = "USER_PROVIDED" if remote_peer else ""
    if not remote_peer:
        remote_peer, peer_source = detect_private_peer(port, addresses)
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
        {"defaultRoute": "default via 10.0.0.254 dev eth0", "entryRoute": "203.0.113.10 via 10.0.0.254 dev eth0"}
        if SELF_TEST else network_context(entry)
    )
    if not expected_exit:
        exit_match = {"status": "N/A", "reason": "未提供预期公网出口"}
    elif identity.get("ip") == expected_exit:
        exit_match = {"status": "PASS", "reason": "本机公网出口与预期出口一致"}
    elif not identity.get("ip"):
        exit_match = {"status": "N/A", "reason": "公网出口识别失败"}
    else:
        exit_match = {
            "status": "FAIL",
            "reason": f"本机实际 {mask_ip(identity['ip'])}，与预期 {mask_ip(expected_exit)} 不一致",
        }

    section("LAYER 1 / 中国三网到中国侧入口", CYAN)
    regions = FULL_REGIONS if FULL else CORE_REGIONS
    field(
        "模式",
        "完整六地区 × 三网TCP去程＋应答确认"
        if FULL else "北上广三地区 × 三网TCP去程＋应答确认",
    )
    field("业务丢包口径", "TCP traceroute 只判到达／未确认；中间跳点不回不算 LOSS", YELLOW)
    probes: list[dict[str, Any]] = []
    total = len(regions) * len(CARRIERS)
    index = 0
    for region, city in regions:
        for carrier, (carrier_name, asn, color) in CARRIERS.items():
            index += 1
            field(
                f"[{index}/{total}]",
                f"{region} {carrier_name} AS{asn} → "
                f"{mask_ip(entry)}:{mask_port(port)}",
                color,
            )
            item = (
                self_test_probe(carrier, region, city, index)
                if SELF_TEST else globalping_probe(entry, port, carrier, region, city)
            )
            tcp_response = tcp_response_confirmation_from_probe(item, entry, port)
            item["tcpResponseConfirmation"] = tcp_response
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
            response_color = GREEN if tcp_response["status"] == "PASS" else YELLOW
            field(
                "TCP应答确认",
                f"{tcp_response['status']}｜原探针收到 "
                f"{tcp_response['tcpResponses']} 次应答｜非反向逐跳路由",
                response_color,
            )

    section("LAYER 1B / 原探针 TCP 应答确认（非反向路由）", CYAN)
    field(
        "判定口径",
        "只确认原中国探针收到同一入口、同一业务端口的TCP应答；"
        "不代表独立反向traceroute，不计算回程分数",
        YELLOW,
    )
    tcp_responses: list[dict[str, Any]] = [
        item["tcpResponseConfirmation"] for item in probes
    ]
    response_pass = sum(item["status"] == "PASS" for item in tcp_responses)
    response_summary = {
        "status": (
            "PASS" if response_pass == len(tcp_responses)
            else "PARTIAL" if response_pass
            else "INCONCLUSIVE"
        ),
        "confirmed": response_pass,
        "total": len(tcp_responses),
        "reason": (
            f"原探针收到入口TCP应答 {response_pass}/{len(tcp_responses)}；"
            "非反向逐跳路由，不计算回程分数"
        ),
        "reverseRouteVisible": False,
    }
    field(
        "TCP应答汇总",
        f"PASS {response_pass}/{len(tcp_responses)}｜"
        "反向逐跳路由不可见，不评回程分",
        GREEN if response_pass else YELLOW,
    )

    if SPEED_TEST:
        field(
            "下一项",
            "开始北上广三网公网单线程辅助测速，约需4～8分钟；"
            "该流量不经过中国侧业务入口",
            YELLOW,
        )
    speed = single_thread_speed()
    show_single_thread_speed(speed)

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

    section("LAYER 2 / 入口→出口映射链与同路径内段回程", MAGENTA)
    field("出口内网本机核对", local_status, GREEN if local_status == "PASS" else YELLOW)
    field("出口业务端口监听", listener["status"], GREEN if listener["status"] == "PASS" else YELLOW)
    chain = mapping_chain(access, listener, local_status)
    field("端口映射链证据", f"{chain['status']}｜{chain['reason']}", GREEN if chain["status"] == "PASS" else YELLOW)
    runtime_sensitive_ips = [
        entry,
        expected_exit,
        identity.get("ip", ""),
        local_private,
        remote_peer,
        client_verified_exit,
    ]
    field(
        "本机默认路由",
        privacy_scrub(net_context["defaultRoute"], runtime_sensitive_ips, [port]),
        CYAN,
    )
    field(
        "到中国侧入口路由",
        privacy_scrub(net_context["entryRoute"], runtime_sensitive_ips, [port]),
        CYAN,
    )
    field("私网对端来源", peer_source or "N/A", MAGENTA)
    field("入口私网对端", mask_ip(remote_peer), MAGENTA)
    internal = (
        {
            "status": "N/A",
            "reason": "SELF-TEST 同路径私网对端未执行真实 ICMP",
            "stats": summarize([], 20),
            "route": "",
            "routeLookup": "10.0.0.1 dev eth0 src 10.0.0.10",
            "pathModel": "PRIVATE_PEER_SAME_PATH",
        }
        if SELF_TEST else ping_peer(remote_peer)
    )
    field("同路径内段回程", internal["status"], GREEN if internal["status"] == "PASS" else YELLOW)
    field(
        "私网路由核对",
        privacy_scrub(
            internal.get("routeLookup") or "N/A",
            runtime_sensitive_ips + [remote_peer],
            [port],
        ),
        CYAN,
    )
    field("内段附加评级", quality_label(internal), CYAN)

    section("LAYER 3 / Mieru 服务与真实握手", MAGENTA)
    field(
        "Mieru／Mita 识别",
        privacy_scrub(
            f"{mieru['status']}｜{mieru['evidence']}",
            runtime_sensitive_ips,
            [port],
        ),
        GREEN if mieru["status"] == "PASS" else YELLOW,
    )
    field(
        "TCP 业务监听",
        privacy_scrub(
            f"{listener['status']}｜{listener['evidence']}",
            runtime_sensitive_ips,
            [port],
        ),
        GREEN if listener["status"] == "PASS" else YELLOW,
    )
    field("NTP 时间同步", mieru["ntp"], GREEN if mieru["ntp"] == "PASS" else YELLOW)
    handshake = handshake_verdict(
        client_verified_exit,
        expected_exit,
        identity.get("ip", ""),
        mieru,
        chain,
    )
    if handshake["status"] == "PASS" and chain["status"] == "PARTIAL":
        chain = {
            "status": "PASS",
            "reason": (
                "入口可达、出口监听、本机私网核对及中国客户端真实协议出口"
                "已形成端到端闭环证据"
            ),
        }
    field("Mieru 真实握手", f"{handshake['status']}｜{handshake['reason']}", GREEN if handshake["status"] == "PASS" else YELLOW)

    section("LAYER 4 / 出口公网", GREEN)
    field("实际公网出口", mask_ip(identity.get("ip", "")), GREEN)
    field("ASN／运营商", f"{identity.get('asn') or 'N/A'}｜{identity.get('org') or 'N/A'}")
    field("位置", f"{identity.get('country') or 'N/A'} {identity.get('city') or ''}")
    field("与预期出口", f"{exit_match['status']}｜{exit_match['reason']}", GREEN if exit_match["status"] == "PASS" else YELLOW)

    improvements: list[str] = []
    if access["pass"] < access["total"]:
        improvements.append(
            f"原省指定运营商精确探针仅 {access['pass']}/{access['total']}；"
            "跨省同运营商结果只证明可达，建议补充目标省真实客户端复测。"
        )
    if internal["status"] != "PASS":
        improvements.append(
            "尚未取得入口私网对端，无法观察同路径内段回程；"
            "可向供应商索取私网对端，或在真实连接建立后重新执行。"
        )
    if handshake["status"] != "PASS":
        improvements.append(
            "尚未完成中国客户端真实协议握手；连接节点后核对客户端公网出口，"
            "再用 --client-verified-exit 提交实测出口。"
        )
    improvements.extend(speed_recommendations(speed))
    if not improvements:
        improvements.append("当前证据闭环完整；建议保留闲时与晚高峰两份报告用于对比。")

    generated = dt.datetime.now(dt.timezone.utc).astimezone()
    report = {
        "version": VERSION,
        "generated": generated.isoformat(timespec="seconds"),
        "mode": "CN3_ENTRY_FORWARD_TCP_RESPONSE_MAPPING_AUDIT",
        "matrix": (
            "六地区 × 三网（18组TCP去程＋18组TCP应答确认；非反向路由）"
            if FULL else "北上广 × 三网（9组TCP去程＋9组TCP应答确认；非反向路由）"
        ),
        "entry": {"masked": mask_ip(entry), "port": port},
        "exitIdentity": {**identity, "ipMasked": mask_ip(identity.get("ip", ""))},
        "exitMatch": exit_match,
        "localPrivate": {"masked": mask_ip(local_private), "status": local_status},
        "remotePeer": {"masked": mask_ip(remote_peer), "source": peer_source or "N/A"},
        "networkContext": net_context,
        "listener": listener,
        "mieruService": mieru,
        "access": access,
        "mappingChain": chain,
        "internal": internal,
        "probes": probes,
        "tcpResponseConfirmations": tcp_responses,
        "tcpResponseSummary": response_summary,
        "singleThreadSpeed": speed,
        "protocolHandshake": handshake,
        "improvements": improvements,
        "clientVerifiedExit": mask_ip(client_verified_exit),
        "privacy": (
            "入口、出口、内网对端及客户端实测IPv4仅保留前两段；"
            "业务端口末三位统一显示为***；报告不保存原值。"
        ),
        "methodology": (
            "中国侧使用 Globalping 指定中国电信、联通、移动完整运营商 ASN 家族，"
            "对中国侧入口业务端口执行 TCP traceroute；北京、上海、广州固定列入，"
            "--full 再扩展合肥、南京与杭州。每组TCP应答确认复用同一Globalping探针、"
            "同一入口与同一业务端口，只记录原探针是否收到入口TCP应答；"
            "这不是独立反向traceroute，不提供反向逐跳路由，也不计算回程分数。"
            "脚本不使用出口VPS默认公网路由探测其他中国公共目标来冒充本专线回程。"
            "出口 VPS 本机核对公网 IP、业务监听、本机内网地址、"
            "默认路由及到中国侧入口的路由；入口可达且出口端同端口监听、私网地址吻合时，"
            "给出端口映射链证据；自动识别 mita 版本、运行状态、端口与 NTP。"
            "只有中国客户端连接 Mieru 后实测出口与出口端实际／预期出口一致，"
            "才把真实握手判为 PASS。供应商提供入口内网对端，或业务端口存在可识别的"
            "私网 ESTABLISHED 对端时，才用 20 次 ICMP、路由查找与 MTR／traceroute"
            "增测出口→入口私网对端的同路径内段回程。"
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
            "探针失败、DNS 失败、权限不足或缺少对端均记 N/A／INCONCLUSIVE，"
            "不会换算为 100% 业务丢包。"
        ),
    }

    report = privacy_scrub(
        report,
        [
            entry,
            expected_exit,
            identity.get("ip", ""),
            local_private,
            remote_peer,
            client_verified_exit,
        ],
        [port],
    )
    if SELF_TEST:
        payload_check = public_report_payload(report)
        if len(payload_check.get("carriers") or []) != 3:
            raise AssertionError("公共报告三网结构不完整")
        for carrier_payload in payload_check["carriers"]:
            if len(carrier_payload.get("forwardProbes") or []) != 6:
                raise AssertionError("公共报告去程必须为每网六组")
            if len(carrier_payload.get("tcpResponseConfirmations") or []) != 6:
                raise AssertionError("公共报告TCP应答确认必须为每网六组")
            if carrier_payload.get("route") != "原探针TCP应答确认（非反向路由）":
                raise AssertionError("公共报告TCP应答判定名称错误")
            if carrier_payload.get("score") is not None:
                raise AssertionError("公共报告不得保留三网评分")
            if carrier_payload.get("stars"):
                raise AssertionError("公共报告不得保留星级")
            if carrier_payload.get("forwardScore") is not None:
                raise AssertionError("公共报告不得计算去程分数")
            if carrier_payload.get("returnScore") is not None:
                raise AssertionError("公共报告不得计算回程分数")
            if carrier_payload.get("bidirectional") is not False:
                raise AssertionError("TCP应答确认不得标成独立双程路由")
            if any(
                "latency" in item
                for item in carrier_payload.get("tcpResponseConfirmations") or []
            ):
                raise AssertionError("TCP应答确认不得重复包装去程RTT")
        if report["entry"]["port"] != mask_port(port):
            raise AssertionError("业务端口末三位未脱敏")
        if payload_check.get("targetPort") != mask_port(port):
            raise AssertionError("公共报告业务端口未脱敏")
        if payload_check.get("target") != report["exitIdentity"]["ipMasked"]:
            raise AssertionError("公共页目标VPS与出口ASN身份未对齐")
        if "returns" in payload_check.get("ixData", {}):
            raise AssertionError("公共报告仍残留误导性的returns字段")
        if any(
            "latency" in item
            for item in payload_check.get("ixData", {}).get(
                "tcpResponseConfirmations", []
            )
        ):
            raise AssertionError("公共报告ixData不得在TCP应答中重复RTT")
        if payload_check.get("final", {}).get("score") is not None:
            raise AssertionError("公共报告最终结论不得保留评分")
        if payload_check.get("final", {}).get("stars"):
            raise AssertionError("公共报告最终结论不得保留星级")
        speed_check = payload_check.get("singleThreadSpeed") or {}
        if len(speed_check.get("rows") or []) != 9:
            raise AssertionError("三网单线程速度必须包含三地区×三运营商九组")
        if speed_check.get("pathIncludesBusinessEntry") is not False:
            raise AssertionError("公网单线程速度不得冒充中国侧业务入口链路")

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
        "中国侧入口接入",
        (
            f"{access['status']}｜运营商可达 {access['carrierReachable']}/{access['total']} "
            f"({access['carrierCoverage']}%)｜原省精确 {access['pass']}/{access['total']} "
            f"({access['coverage']}%)｜省内第三方参考 {access['provinceReference']}｜"
            f"跨省同运营商降级 {access['crossProvinceFallback']}｜"
            f"NO_PROBE {access['noProbe']}"
        ),
        GREEN if access["status"] == "PASS" else YELLOW,
    )
    field(
        "原探针TCP应答",
        f"PASS {response_pass}/{len(tcp_responses)}｜非反向逐跳路由；不评回程分",
        GREEN if response_pass else YELLOW,
    )
    field("入口→出口映射链", f"{chain['status']}｜{chain['reason']}", GREEN if chain["status"] == "PASS" else YELLOW)
    field("同路径私网回程", quality_label(internal), GREEN if internal["status"] == "PASS" else YELLOW)
    field("Mieru／Mita 服务", f"{mieru['status']}｜{mieru['evidence']}", GREEN if mieru["status"] == "PASS" else YELLOW)
    field("Mieru 真实握手", f"{handshake['status']}｜{handshake['reason']}", GREEN if handshake["status"] == "PASS" else YELLOW)
    field("出口公网", f"{exit_match['status']}｜{mask_ip(identity.get('ip', ''))}", GREEN if exit_match["status"] == "PASS" else YELLOW)
    field(
        "三网单线程辅助",
        f"{speed['status']}｜{speed['reason']}｜不经过中国侧业务入口",
        GREEN if speed["status"] == "PASS" else YELLOW,
    )
    section("IMPROVEMENTS / 最终判定建议改善", MAGENTA)
    for index, suggestion in enumerate(improvements, start=1):
        field(f"建议 {index}", suggestion, YELLOW)
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
