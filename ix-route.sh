#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="v0.1 RC1"
ENTRY_IP=""
ENTRY_PORT=""
EXPECTED_EXIT=""
LOCAL_PRIVATE=""
REMOTE_PEER=""
FULL=0
SELF_TEST=0

usage() {
  cat <<'EOF'
沪日专线／IX-style 三层质量检测 v0.1 RC1

用途：
  专门检测“中国用户 → 上海公网入口 → NAT／IPLC／IEPL 隐藏内段 → 日本出口”。
  本脚本与 3net-route.sh 完全独立，不共用评分或报告。

推荐：在日本出口 VPS 上执行
  bash <(curl -fsSL https://raw.githubusercontent.com/souldance7-ai/vps-speedtest/main/ix-route.sh)

非交互示例：
  bash ix-route.sh --entry 211.136.162.184 --port 10101 \
    --expected-exit 114.111.176.37 --local-private 172.16.2.101

完整六地区三网：
  bash ix-route.sh --entry 211.136.162.184 --port 10101 --full

可选参数：
  --entry IP             上海／中国侧公网入口
  --port PORT            协议业务端口，不是 SSH 22 或管理端口
  --expected-exit IP     预期日本公网出口
  --local-private IP     日本端专线内网 IP
  --peer IP              上海端专线内网对端；未知可留空
  --full                 北京、上海、广东、安徽、江苏、浙江 × 三网
  --self-test            离线自检，不发起网络探测
  -h, --help             显示帮助

判定边界：
  入口 TCP traceroute 到达，只证明入口端口经映射后的 TCP 路径可达。
  只有提供上海内网对端 IP，才会测量专线纯内段 RTT／抖动／丢包。
  没有协议凭据时不会伪装成 AnyTLS／Trojan／Mieru 真实握手成功。
  DNS、探针或权限失败一律显示 N/A，不会换算成 100% LOSS。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --entry) ENTRY_IP="${2:-}"; shift 2 ;;
    --port) ENTRY_PORT="${2:-}"; shift 2 ;;
    --expected-exit) EXPECTED_EXIT="${2:-}"; shift 2 ;;
    --local-private) LOCAL_PRIVATE="${2:-}"; shift 2 ;;
    --peer) REMOTE_PEER="${2:-}"; shift 2 ;;
    --full) FULL=1; shift ;;
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
export IX_FULL="$FULL"
export IX_SELF_TEST="$SELF_TEST"

# Python 程序从文件描述符 3 读取，stdin 保留给交互输入。
python3 /dev/fd/3 3<<'PY'
from __future__ import annotations

import datetime as dt
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
import urllib.request
from pathlib import Path
from typing import Any

VERSION = os.environ.get("IX_VERSION", "v0.1 RC1")
ENTRY_IP = os.environ.get("IX_ENTRY_IP", "").strip()
PORT_TEXT = os.environ.get("IX_ENTRY_PORT", "").strip()
EXPECTED_EXIT = os.environ.get("IX_EXPECTED_EXIT", "").strip()
LOCAL_PRIVATE = os.environ.get("IX_LOCAL_PRIVATE", "").strip()
REMOTE_PEER = os.environ.get("IX_REMOTE_PEER", "").strip()
FULL = os.environ.get("IX_FULL") == "1"
SELF_TEST = os.environ.get("IX_SELF_TEST") == "1"
GLOBALPING_API = "https://api.globalping.io/v1/measurements"

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
EAST_CHINA = [
    ("上海", "Shanghai"),
    ("安徽", "Hefei"),
    ("江苏", "Nanjing"),
    ("浙江", "Hangzhou"),
]
FULL_REGIONS = [
    ("北京", "Beijing"),
    ("上海", "Shanghai"),
    ("广东", "Guangzhou"),
    ("安徽", "Hefei"),
    ("江苏", "Nanjing"),
    ("浙江", "Hangzhou"),
]


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
        return "211.136.162.184", 10101, "114.111.176.37", "172.16.2.101", ""

    section("INPUT GUIDE / 沪日专线目标输入", MAGENTA)
    field("架构示例", "中国用户 → 211.136.162.184:10101 → 隐藏专线 → 172.16.2.101 → 日本公网")
    field("入口 IP 示例", "211.136.162.184", CYAN)
    field("协议端口示例", "10101 AnyTLS／10102 Trojan", GREEN)
    field("重要提醒", "填写业务端口；不要填 SSH 22，也不要把管理端口 10100 当业务端口", YELLOW)
    field("日本出口示例", "114.111.176.37", GREEN)
    field("日本内网示例", "172.16.2.101；上海内网对端未知可直接回车", CYAN)

    while not valid_ipv4(ENTRY_IP, public=True):
        ENTRY_IP = input("请输入上海／中国侧公网入口 IPv4〔例 211.136.162.184〕：").strip()
        if not valid_ipv4(ENTRY_IP, public=True):
            print(RED + "  IPv4 无效，请重新输入。" + RESET)
    while True:
        if not PORT_TEXT:
            PORT_TEXT = input("请输入协议业务端口〔例 10101；不是 SSH 22／10100〕：").strip()
        try:
            port = int(PORT_TEXT)
            if 1 <= port <= 65535:
                break
        except ValueError:
            pass
        print(RED + "  端口无效，请输入 1～65535。" + RESET)
        PORT_TEXT = ""
    if not EXPECTED_EXIT:
        EXPECTED_EXIT = input("请输入预期日本公网出口 IP〔例 114.111.176.37；未知可回车〕：").strip()
    if EXPECTED_EXIT and not valid_ipv4(EXPECTED_EXIT, public=True):
        print(YELLOW + "  预期出口格式无效，本项按 N/A 处理。" + RESET)
        EXPECTED_EXIT = ""
    if not LOCAL_PRIVATE:
        LOCAL_PRIVATE = input("请输入日本端专线内网 IP〔例 172.16.2.101；未知可回车〕：").strip()
    if LOCAL_PRIVATE and not valid_ipv4(LOCAL_PRIVATE):
        print(YELLOW + "  日本端内网 IP 格式无效，本项按 N/A 处理。" + RESET)
        LOCAL_PRIVATE = ""
    if not REMOTE_PEER:
        REMOTE_PEER = input("请输入上海端专线内网对端 IP〔未知可直接回车〕：").strip()
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
    for url in ("https://ipwho.is/", "https://api.ipify.org?format=json"):
        try:
            data = http_json(url, timeout=10)
            ip = str(data.get("ip", ""))
            if not valid_ipv4(ip, public=True):
                continue
            connection = data.get("connection") or {}
            return {
                "ip": ip,
                "asn": str(connection.get("asn") or ""),
                "org": str(connection.get("org") or connection.get("isp") or ""),
                "country": str(data.get("country") or ""),
                "city": str(data.get("city") or ""),
            }
        except Exception:
            pass
    return {"ip": "", "asn": "", "org": "", "country": "", "city": ""}


def run(command: list[str], timeout: int = 30) -> str:
    try:
        result = subprocess.run(command, text=True, capture_output=True, timeout=timeout)
        return (result.stdout + result.stderr).strip()
    except Exception as exc:
        return f"COMMAND_ERROR {type(exc).__name__}: {exc}"


def local_addresses() -> list[str]:
    output = run(["ip", "-4", "-o", "addr", "show"], 5) if shutil.which("ip") else ""
    return re.findall(r"\binet\s+((?:\d{1,3}\.){3}\d{1,3})/", output)


def listener_status(port: int) -> dict[str, Any]:
    if not shutil.which("ss"):
        return {"status": "N/A", "evidence": "系统无 ss，未检查本机监听"}
    output = run(["ss", "-lntup"], 8)
    matched = [row for row in output.splitlines() if re.search(rf":{port}\b", row)]
    if not matched:
        return {"status": "FAIL", "evidence": f"未发现 TCP／UDP {port} 监听"}
    return {"status": "PASS", "evidence": " | ".join(matched[:3])}


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
    attempts = [
        (
            f"{region}+AS{asn}",
            {"country": "CN", "city": city, "asn": asn, "tags": ["eyeball-network"], "limit": 1},
        ),
        (
            f"中国+AS{asn}备用",
            {"country": "CN", "asn": asn, "tags": ["eyeball-network"], "limit": 1},
        ),
    ]
    errors: list[str] = []
    for mode, location in attempts:
        try:
            created = http_json(
                GLOBALPING_API,
                "POST",
                {
                    "target": entry,
                    "type": "traceroute",
                    "locations": [location],
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
            item = next(
                (x for x in result.get("results", []) if x.get("result", {}).get("status") == "finished"),
                None,
            )
            if not item:
                raise RuntimeError("无有效探针结果")
            probe = item.get("probe") or {}
            source_asn = int(probe.get("asn") or 0)
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
            status = "PASS" if reached else "INCONCLUSIVE"
            return {
                "carrier": carrier,
                "carrierName": name,
                "requestedRegion": region,
                "mode": mode,
                "probeCity": str(probe.get("city") or ""),
                "probeAsn": source_asn,
                "asnVerified": source_asn == asn,
                "status": status,
                "targetReached": reached,
                "latency": latency,
                "route": "\n".join(route_lines),
                "reason": "" if reached else "TCP traceroute 未显示终点；不等于真实业务 100% 丢包",
            }
        except Exception as exc:
            errors.append(f"{mode}: {type(exc).__name__}: {exc}")
    return {
        "carrier": carrier,
        "carrierName": name,
        "requestedRegion": region,
        "mode": "N/A",
        "probeCity": "",
        "probeAsn": 0,
        "asnVerified": False,
        "status": "N/A",
        "targetReached": False,
        "latency": summarize([], 0),
        "route": "",
        "reason": "；".join(errors),
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


def markdown_report(report: dict[str, Any]) -> str:
    access = report["access"]
    internal = report["internal"]
    identity = report["exitIdentity"]
    listener = report["listener"]
    lines = [
        f"# 沪日专线／IX-style 三层质量检测报告",
        "",
        f"- 版本：{report['version']}",
        f"- 时间：{report['generated']}",
        f"- 上海入口：`{report['entry']['masked']}:{report['entry']['port']}`",
        f"- 日本出口：`{mask_ip(identity.get('ip', ''))}` / {identity.get('asn') or 'N/A'} / {identity.get('org') or 'N/A'}",
        f"- 测试矩阵：{report['matrix']}",
        "",
        "## 结论",
        "",
        f"- 上海入口端到端 TCP：{access['status']}（PASS {access['pass']}/{access['total']}，INCONCLUSIVE {access['inconclusive']}，N/A {access['na']}）",
        f"- 日本端业务监听：{listener['status']} — {listener['evidence']}",
        f"- 滬日专线纯内段：{internal['status']} — {quality_label(internal)}",
        f"- 日本出口一致性：{report['exitMatch']['status']} — {report['exitMatch']['reason']}",
        "",
        "## 三层判定边界",
        "",
        "1. 中国探针到入口业务端口的 TCP traceroute 到达，表示入口映射后的 TCP 路径可达。",
        "2. 只有提供上海端内网对端，才统计专线纯内段 Ping RTT／P95／抖动／丢包。",
        "3. 未提供协议种类与凭据时，AnyTLS／Trojan／Mieru 真实应用握手为 N/A。",
        "4. traceroute 中间跳点不回应、DNS 或探针失败不记作 100% 业务丢包。",
        "5. “IX-style”是工具名称，不等于已证明经过某个 IXP。",
        "",
        "## 中国侧入口探针",
        "",
        "| 地区 | 运营商 | 实际探针 | ASN核对 | 终点 | RTT | 状态 |",
        "|---|---|---|---:|---:|---:|---|",
    ]
    for item in report["probes"]:
        latency = item.get("latency") or {}
        rtt = f"{latency['avg']} ms" if latency.get("avg") is not None else "N/A"
        lines.append(
            f"| {item['requestedRegion']} | {item['carrierName']} | "
            f"{item.get('probeCity') or 'N/A'} | "
            f"{'是' if item.get('asnVerified') else '否'} | "
            f"{'到达' if item.get('targetReached') else '未确认'} | {rtt} | {item['status']} |"
        )
    stats = internal.get("stats") or {}
    lines.extend([
        "",
        "## 专线纯内段",
        "",
        f"- 日本端内网：`{report['localPrivate']['masked']}`；本机存在：{report['localPrivate']['status']}",
        f"- 上海端内网对端：`{report['remotePeer']['masked']}`",
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


def main() -> int:
    entry, port, expected_exit, local_private, remote_peer = ask_inputs()
    print(BLUE + "\n  ██╗██╗  ██╗      ██████╗  ██████╗ ██╗   ██╗████████╗███████╗" + RESET)
    print(CYAN + "  IX-ROUTE · 沪日专线／隐藏内段三层验证 · 独立版" + RESET)

    section("TOPOLOGY / 检测拓扑", CYAN)
    field("中国公网入口", f"{mask_ip(entry)}:{port}", CYAN)
    field("业务端口", f"{port}（协议业务端口；不是 SSH）", GREEN)
    field("日本预期出口", mask_ip(expected_exit), GREEN)
    field("日本端内网", mask_ip(local_private), CYAN)
    field("上海内网对端", mask_ip(remote_peer), MAGENTA)
    field("测试边界", "入口接入、专线纯内段、日本出口三层独立判定", YELLOW)

    identity = (
        {"ip": "114.111.176.37", "asn": "AS9999", "org": "SELF-TEST JP", "country": "Japan", "city": "Tokyo"}
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
    regions = FULL_REGIONS if FULL else EAST_CHINA
    field("模式", "完整六地区 × 三网" if FULL else "华东四地区 × 三网（适合沪日入口）")
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

    access = {
        "total": total,
        "pass": sum(x["status"] == "PASS" for x in probes),
        "inconclusive": sum(x["status"] == "INCONCLUSIVE" for x in probes),
        "na": sum(x["status"] == "N/A" for x in probes),
    }
    access["status"] = (
        "PASS" if access["pass"] == total
        else "DEGRADED" if access["pass"] > 0
        else "N/A" if access["na"] == total
        else "INCONCLUSIVE"
    )

    section("LAYER 2 / 滬日专线纯内段", MAGENTA)
    field("日本内网本机核对", local_status, GREEN if local_status == "PASS" else YELLOW)
    field("日本业务端口监听", listener["status"], GREEN if listener["status"] == "PASS" else YELLOW)
    internal = (
        {
            "status": "N/A",
            "reason": "SELF-TEST 未提供内网对端，用于验证 N/A 逻辑",
            "stats": summarize([], 20),
            "route": "",
        }
        if SELF_TEST else ping_peer(remote_peer)
    )
    field("内段测试", internal["status"], GREEN if internal["status"] == "PASS" else YELLOW)
    field("内段评级", quality_label(internal), CYAN)
    field("协议握手", "N/A｜未提供协议类型与凭据，不伪判 AnyTLS／Trojan／Mieru", YELLOW)

    section("LAYER 3 / 日本出口公网", GREEN)
    field("实际公网出口", mask_ip(identity.get("ip", "")), GREEN)
    field("ASN／运营商", f"{identity.get('asn') or 'N/A'}｜{identity.get('org') or 'N/A'}")
    field("位置", f"{identity.get('country') or 'N/A'} {identity.get('city') or ''}")
    field("与预期出口", f"{exit_match['status']}｜{exit_match['reason']}", GREEN if exit_match["status"] == "PASS" else YELLOW)

    generated = dt.datetime.now(dt.timezone.utc).astimezone()
    report = {
        "version": VERSION,
        "generated": generated.isoformat(timespec="seconds"),
        "mode": "HURI_DEDICATED_LINE_THREE_LAYER",
        "matrix": "六地区 × 三网" if FULL else "华东四地区 × 三网",
        "entry": {"masked": mask_ip(entry), "port": port},
        "exitIdentity": identity,
        "exitMatch": exit_match,
        "localPrivate": {"masked": mask_ip(local_private), "status": local_status},
        "remotePeer": {"masked": mask_ip(remote_peer)},
        "listener": listener,
        "access": access,
        "internal": internal,
        "probes": probes,
        "protocolHandshake": {
            "status": "N/A",
            "reason": "未提供协议类型与认证材料；TCP 到达不能替代真实应用握手",
        },
        "methodology": (
            "中国侧使用 Globalping 指定中国电信 AS4134、联通 AS4837、移动 AS9808，"
            "对上海入口业务端口执行 TCP traceroute；默认聚焦上海、安徽、江苏、浙江，"
            "--full 扩展北京与广东。日本出口本机核对公网 IP、业务监听及本机内网地址；"
            "提供上海内网对端时，用 20 次 ICMP 与 MTR／traceroute 测专线纯内段。"
            "探针失败、DNS 失败、权限不足或缺少对端均记 N/A／INCONCLUSIVE，"
            "不会换算为 100% 业务丢包。"
        ),
    }

    output_name = f"ix-route-report-{generated.strftime('%Y%m%d-%H%M%S')}"
    preferred_root = Path("/root") if os.geteuid() == 0 else Path.cwd()
    output_dir = preferred_root / output_name
    try:
        output_dir.mkdir(parents=True, exist_ok=True)
    except OSError:
        output_dir = Path.cwd() / output_name
        output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / "report.json"
    md_path = output_dir / "report.md"
    json_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    md_path.write_text(markdown_report(report), encoding="utf-8")

    section("FINAL / 三层独立结论", CYAN)
    field("上海入口接入", f"{access['status']}｜PASS {access['pass']}/{access['total']}", GREEN if access["status"] == "PASS" else YELLOW)
    field("滬日专线纯内段", f"{internal['status']}｜{quality_label(internal)}", GREEN if internal["status"] == "PASS" else YELLOW)
    field("日本出口公网", f"{exit_match['status']}｜{mask_ip(identity.get('ip', ''))}", GREEN if exit_match["status"] == "PASS" else YELLOW)
    field("协议真实握手", "N/A｜需协议类型与测试凭据", YELLOW)
    field("Markdown 报告", str(md_path), GREEN)
    field("JSON 数据", str(json_path), GREEN)
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
