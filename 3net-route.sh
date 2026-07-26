#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="v0.9 RC4.2 SIX-REGION FULL"
SCRIPT_NAME="$(basename "$0")"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'EOF'
中国三网 VPS 双程质量检测 v0.9 RC4.2 六地区完整版

用法：
  bash 中国三网VPS双程质量检测_v0.9_RC4.2_六地区完整版.sh
  bash 中国三网VPS双程质量检测_v0.9_RC4.2_六地区完整版.sh --self-test
  bash 中国三网VPS双程质量检测_v0.9_RC4.2_六地区完整版.sh --target 203.55.99.88 --port 443

说明：
  本脚本直接在出口 VPS 上运行，不使用 SSH 密码或私钥。
  目标 IP 示例：203.55.99.88
  业务端口示例：443（Trojan／AnyTLS 等协议实际监听端口，不是 SSH 22）
  去程：中国电信 AS4134／联通 AS4837／移动 AS9808 六地区远端探针 → 国内入口。
  回程：当前出口 VPS → 北京／上海／广东／安徽／江苏／浙江三网十八组目标。
  NAT 专线入口端口由三网外部 TCP traceroute 共同核对，不从出口反连入口。
  traceroute 跳点不回应只计为“路由回覆率”，不会伪装成业务丢包。
EOF
  exit 0
fi

SELF_TEST=0
TARGET=""
TARGET_PORT=""
NO_INSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) SELF_TEST=1; shift ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --port) TARGET_PORT="${2:-}"; shift 2 ;;
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

python3 - <<'PY'
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
import sys
import time
import unicodedata
import urllib.error
import urllib.request
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any

VERSION = os.environ.get("THREE_NET_VERSION", "v0.9 RC4.2 SIX-REGION FULL")
SELF_TEST = os.environ.get("THREE_NET_SELF_TEST") == "1"
TARGET = os.environ.get("THREE_NET_TARGET", "").strip()
PORT_TEXT = os.environ.get("THREE_NET_TARGET_PORT", "").strip()
GLOBALPING_API = "https://api.globalping.io/v1/measurements"
PUBLIC_REPORT_API = "https://china-3net-route-report.souldance4.chatgpt.site/api/reports"
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

PROBES = {
    "CT": [
        ("北京", "v4-bj-ct.oojj.de"),
        ("上海", "v4-sh-ct.oojj.de"),
        ("广东", "v4-gd-ct.oojj.de"),
        ("安徽", "v4-ah-ct.oojj.de"),
        ("江苏", "v4-js-ct.oojj.de"),
        ("浙江", "v4-zj-ct.oojj.de"),
    ],
    "CU": [
        ("北京", "v4-bj-cu.oojj.de"),
        ("上海", "v4-sh-cu.oojj.de"),
        ("广东", "v4-gd-cu.oojj.de"),
        ("安徽", "v4-ah-cu.oojj.de"),
        ("江苏", "v4-js-cu.oojj.de"),
        ("浙江", "v4-zj-cu.oojj.de"),
    ],
    "CM": [
        ("北京", "v4-bj-cm.oojj.de"),
        ("上海", "v4-sh-cm.oojj.de"),
        ("广东", "v4-gd-cm.oojj.de"),
        ("安徽", "v4-ah-cm.oojj.de"),
        ("江苏", "v4-js-cm.oojj.de"),
        ("浙江", "v4-zj-cm.oojj.de"),
    ],
}
FORWARD_REGIONS = [
    ("北京", "Beijing"),
    ("上海", "Shanghai"),
    ("广东", "Guangzhou"),
    ("安徽", "Hefei"),
    ("江苏", "Nanjing"),
    ("浙江", "Hangzhou"),
]
FORWARD_ASN = {"CT": 4134, "CU": 4837, "CM": 9808}


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


def ask_target() -> tuple[str, int]:
    global TARGET, PORT_TEXT
    if SELF_TEST:
        return "45.207.225.70", 10100
    banner("INPUT GUIDE / 目标输入说明", MAGENTA)
    field("目标 IP 示例", "203.55.99.88", CYAN)
    field("协议端口示例", "443", GREEN)
    field("重要提醒", "这里填写 Trojan／AnyTLS／Hysteria 等协议实际监听端口，不是 SSH 登录端口 22", YELLOW)
    field("完整输入示例", "上方输入 203.55.99.88；下方输入 443", WHITE)
    while not valid_public_ipv4(TARGET):
        TARGET = input("请输入国内入口／被测 VPS 的 IPv4〔例 203.55.99.88〕：").strip()
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
    headers = {"User-Agent": "3net-route-detector/0.9-RC4.2", "Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


ASN_CACHE: dict[str, str] = {}


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


def pattern_count(text: str, patterns: list[str]) -> int:
    return len({(m.start(), m.group(0)) for p in patterns for m in re.finditer(p, text, re.I)})


def classify(carrier: str, route: str, direction: str) -> tuple[str, int, str]:
    plain = route.replace("\r", "")
    if carrier == "CT":
        cn2 = [r"AS4809", r"59\.43\."]
        normal = [r"AS4134", r"202\.97\."]
        ci, ni = first_index(plain, cn2), first_index(plain, normal)
        ccount, ncount = pattern_count(plain, cn2), pattern_count(plain, normal)
        if ci >= 0:
            if direction == "Forward":
                if ni < 0 or (ni < ci and ncount <= 2 and ccount >= 2):
                    return "CN2 GIA", 5, "去程连续进入 AS4809／59.43，普通 163 仅为接入段或未出现"
                if ni < ci:
                    return "CN2 GT", 3, "去程先经过 AS4134／202.97 普通骨干，出口才切入 CN2"
                return "CN2／163 混合", 3, "去程进入 CN2 后又出现普通 163，骨干不纯"
            if ni < 0 or ci < ni:
                return "CN2 GIA", 5, "回程优先进入 AS4809／59.43，普通 163 仅作目的网交付"
            return "CN2 GT／混合", 3, "回程先走普通 163，随后才进入 CN2"
        if first_index(plain, [r"AS23764", r"CTGNet", r"69\.194\."]) >= 0:
            return "CTG GIA", 4, "检测到 AS23764／CTGNet 特征"
        if ni >= 0:
            return "电信 163", 2, "仅检测到 AS4134／202.97 普通骨干"
        return "国际 BGP／未见电信骨干", 1, "ASN 已补查，未命中 AS4809、AS4134 或 AS23764，不伪判 CN2"

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
            return "AS4837 普通联通", 2, "仅检测到 AS4837／219.158 普通骨干"
        return "国际 BGP／未见联通骨干", 1, "ASN 已补查，未命中 AS9929、AS10099 或 AS4837"

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
    return "国际 BGP／未见移动骨干", 1, "ASN 已补查，未命中 AS58807、AS58453 或 AS9808"


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
    route_score = {5: 60, 4: 54, 3: 42, 2: 28}.get(rank, 12)
    latency = 0
    if s.avg is not None:
        latency = 30 if s.avg <= 100 else 25 if s.avg <= 150 else 18 if s.avg <= 200 else 10 if s.avg <= 250 else 4
    stability = 5 if s.loss is None else 10 if s.loss == 0 else 6 if s.loss <= 20 else 0
    return min(100, route_score + latency + stability)


def stars(value: int) -> str:
    count = 5 if value >= 90 else 4 if value >= 75 else 3 if value >= 60 else 2 if value >= 40 else 1
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


def globalping_trace(target: str, port: int, carrier: str,
                     region: str, probe_city: str) -> dict[str, Any]:
    asn = FORWARD_ASN[carrier]
    errors: list[str] = []
    location_modes = [
        (
            f"{region}+ASN+家宽",
            {"country": "CN", "city": probe_city, "asn": asn,
             "tags": ["eyeball-network"], "limit": 1},
        ),
        (
            f"{region}+ASN",
            {"country": "CN", "city": probe_city, "asn": asn, "limit": 1},
        ),
        (
            "中国+ASN 备用",
            {"country": "CN", "asn": asn, "tags": ["eyeball-network"], "limit": 1},
        ),
    ]
    for mode, location in location_modes:
        payload = {
            "target": target,
            "type": "traceroute",
            "locations": [location],
            "measurementOptions": {"protocol": "TCP", "port": port},
        }
        try:
            created = http_json(GLOBALPING_API, "POST", payload)
            measurement_id = created.get("id")
            if not measurement_id:
                raise RuntimeError("未返回 measurement id")
            measurement = None
            for _ in range(30):
                time.sleep(0.8)
                measurement = http_json(f"{GLOBALPING_API}/{measurement_id}")
                if measurement.get("status") == "finished":
                    break
                if measurement.get("status") != "in-progress":
                    raise RuntimeError(f"状态 {measurement.get('status')}")
            if not measurement or measurement.get("status") != "finished":
                raise TimeoutError("等待远端结果超时")
            entry = next((x for x in measurement.get("results", []) if x.get("result", {}).get("status") == "finished"), None)
            if not entry:
                raise RuntimeError("探针无有效 traceroute 结果")
            probe = entry.get("probe", {})
            route_lines: list[str] = []
            last_timings: list[float] = []
            target_timings: list[float] = []
            target_reached = False
            for index, hop in enumerate(entry.get("result", {}).get("hops", []), 1):
                ip = str(hop.get("resolvedAddress") or "")
                hostname = str(hop.get("resolvedHostname") or "")
                timings = [float(x["rtt"]) for x in hop.get("timings", []) if x.get("rtt") is not None]
                if timings:
                    last_timings = timings
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
            access = f"{probe.get('city', '')}, {probe.get('country', '')}｜{probe.get('network', '')}｜AS{source_asn}"
            route_timings = target_timings or last_timings
            result_stats = stats(
                route_timings, len(route_timings), loss_valid=False,
                metric="TCP traceroute RTT（不作为业务丢包）"
            )
            value = score(rank, result_stats)
            verified = source_asn == asn
            if not verified:
                value = max(0, value - 15)
            return {
                "carrier": carrier, "region": region,
                "requestedCity": probe_city, "access": access,
                "verified": verified, "route": route,
                "class": route_class, "rank": rank, "evidence": evidence,
                "targetReached": target_reached,
                "reachability": "PASS｜外部 TCP traceroute 到达入口" if target_reached
                                else "INCONCLUSIVE｜未显示终点，不等于端口关闭",
                "stats": asdict(result_stats), "score": value, "stars": stars(value),
            }
        except Exception as exc:
            errors.append(f"{mode}: {exc}")
    empty = stats([], 0, loss_valid=False, metric="TCP traceroute RTT（探针不可用）")
    return {
        "carrier": carrier, "region": region, "requestedCity": probe_city,
        "access": f"{region}远端 AS{asn}", "verified": False, "route": "",
        "class": "远端探针不可用", "rank": 0, "evidence": "；".join(errors),
        "targetReached": False, "reachability": "INCONCLUSIVE｜远端探针不可用",
        "stats": asdict(empty), "score": 0, "stars": "☆☆☆☆☆",
    }


def return_probe(carrier: str, city: str, host: str) -> dict[str, Any]:
    ip = resolve_ipv4(host)
    if shutil.which("traceroute"):
        route = run(["traceroute", "-n", "-T", "-p", "80", "-q", "1", "-w", "1", "-m", "25", host], 35)
    elif shutil.which("tracepath"):
        route = run(["tracepath", "-n", "-m", "25", host], 35)
    else:
        route = "TRACEROUTE_UNAVAILABLE"
    route = enrich_route(route)
    route_class, rank, evidence = classify(carrier, route, "Return")
    result_stats = stats(tcp_samples(host), 5, metric="TCP connect")
    value = score(rank, result_stats)
    return {
        "carrier": carrier, "city": city, "host": host, "probeIp": ip, "route": route,
        "class": route_class, "rank": rank, "evidence": evidence,
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
        "route": routes[carrier], "class": route_class, "rank": rank, "evidence": evidence,
        "stats": asdict(result_stats), "score": value, "stars": stars(value),
    }


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


def dedicated_line_assessment(target: str, port: int, exit_ip: str,
                              forward: list[dict[str, Any]]) -> dict[str, Any]:
    reached_samples = [
        f"{x['carrier']}-{x.get('region', '中国')}"
        for x in forward if x.get("targetReached")
    ]
    reached = sorted({x["carrier"] for x in forward if x.get("targetReached")})
    entry_asn = origin_asn(target)
    exit_asn = origin_asn(exit_ip) if valid_public_ipv4(exit_ip) else ""
    if reached_samples:
        port_status = (
            f"PASS｜{len(reached_samples)}/{len(forward)} 组六地区外部 TCP traceroute 到达入口"
        )
    else:
        port_status = "INCONCLUSIVE｜探针未显示终点；不能据此判定端口关闭"
    return {
        "topology": "中国入口端口映射／NAT → 出口 VPS",
        "entry": f"{mask_ip(target)}:{port}",
        "entryAsn": entry_asn or "ASN 未取得",
        "exit": mask_ip(exit_ip),
        "exitAsn": exit_asn or "ASN 未取得",
        "portStatus": port_status,
        "reachedBy": reached,
        "reachedSamples": reached_samples,
        "internalVisibility": "HIDDEN_BY_NAT",
        "internalVerdict": (
            "入口到出口为端口映射／专线内部段，公共 traceroute 通常只看到中国入口，"
            "不能把隐藏段强判为 CN2、AS9929、CMIN2 或普通国际线路。"
        ),
    }


def representative_route(items: list[dict[str, Any]], direction: str) -> str:
    if not items:
        return f"{direction}未测"
    unique = sorted({str(x["class"]) for x in items})
    if len(unique) == 1:
        return unique[0]
    return f"六地区混合（{len(unique)} 类）"


def grade(carrier: str, forwards: list[dict[str, Any]],
          returns: list[dict[str, Any]]) -> dict[str, Any]:
    forward_items = [x for x in forwards if x["carrier"] == carrier]
    items = [x for x in returns if x["carrier"] == carrier]
    forward_score = (
        round(statistics.mean(x["score"] for x in forward_items))
        if forward_items else 0
    )
    return_score = round(statistics.mean(x["score"] for x in items)) if items else 0
    overall = round(forward_score * 0.4 + return_score * 0.6)
    return {
        "carrier": carrier,
        "forwardRoute": representative_route(forward_items, "去程"),
        "returnRoute": representative_route(items, "回程"),
        "forwardScore": forward_score, "returnScore": return_score,
        "score": overall, "stars": stars(overall),
    }


def show_forward(item: dict[str, Any], index: int, total: int) -> None:
    carrier = item["carrier"]
    color = CARRIER_COLOR[carrier]
    banner(
        f"FORWARD [{index}/{total}] {carrier} / {CARRIER_NAME[carrier]} · {item.get('region', '中国')}去程",
        color,
    )
    field("请求地区", item.get("region", "中国"), color)
    field("来源核对", ("PASS｜" if item["verified"] else "WARN｜") + item["access"], GREEN if item["verified"] else YELLOW)
    field("入口可达性", item.get("reachability", "INCONCLUSIVE"), GREEN if item.get("targetReached") else YELLOW)
    field("去程线路", item["class"], color)
    field("去程质量", f"{format_stats(item['stats'])}｜{item['score']} 分", GREEN if item["score"] >= 75 else YELLOW if item["score"] >= 50 else RED)
    field("判定证据", item["evidence"], GRAY)


def show_return(item: dict[str, Any], index: int, total: int) -> None:
    carrier = item["carrier"]
    color = CARRIER_COLOR[carrier]
    field(f"[{index}/{total}] {carrier} {item['city']}", f"{item['class']}｜{format_stats(item['stats'])}｜{item['score']} 分", color)


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
h2{{margin:0 0 12px;font-size:18px}}table{{width:100%;border-collapse:collapse}}th,td{{padding:9px;border-bottom:1px solid #26364f;text-align:left;vertical-align:top}}th{{color:#8ca7d5}}.score{{font-size:28px;color:#ffe16a}}.toolbar{{display:flex;gap:10px;margin:12px 0}}button{{background:#173e78;color:white;border:1px solid #3672c8;padding:8px 14px;cursor:pointer}}pre{{white-space:pre-wrap;color:#b8c5db;max-height:260px;overflow:auto}}@media(max-width:900px){{.grid{{grid-template-columns:1fr}}}}
</style></head><body><div class="wrap">
<header><h1>CHINA 3NET ROUTE LAB</h1><div class="sub" id="meta"></div><div class="toolbar"><button id="copy">复制为 NodeSeek 格式</button><button onclick="window.print()">打印／另存 PDF</button><button id="json">下载 JSON</button></div></header>
<section class="panel" id="topology"></section><div class="grid" id="cards"></div><div id="details"></div></div>
<script>const R={embedded};
const E=s=>String(s??'').replace(/[&<>"']/g,c=>({{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}}[c]));
document.getElementById('meta').textContent=R.version+'｜入口 '+R.target.host+':'+R.target.port+'｜出口 '+R.exit.host+'｜'+R.generated;
const names={{CT:'中国电信',CU:'中国联通',CM:'中国移动'}};
document.getElementById('topology').innerHTML=`<h2>专线／NAT 双端模型</h2><table><tbody>
<tr><th>拓扑</th><td>${{E(R.dedicatedLine.topology)}}</td><th>外部入口核对</th><td>${{E(R.dedicatedLine.portStatus)}}</td></tr>
<tr><th>中国入口</th><td>${{E(R.dedicatedLine.entry)}}｜${{E(R.dedicatedLine.entryAsn)}}</td><th>出口 VPS</th><td>${{E(R.dedicatedLine.exit)}}｜${{E(R.dedicatedLine.exitAsn)}}</td></tr>
<tr><th>专线内段</th><td colspan="3">${{E(R.dedicatedLine.internalVerdict)}}</td></tr></tbody></table>`;
document.getElementById('cards').innerHTML=R.grades.map(g=>`<section class="panel ${{g.carrier.toLowerCase()}}"><h2>${{names[g.carrier]}}</h2><div class="score">${{g.score}} 分 ${{g.stars}}</div><div>去程：${{E(g.forwardRoute)}}（${{g.forwardScore}}）</div><div>回程：${{E(g.returnRoute)}}（${{g.returnScore}}）</div></section>`).join('');
document.getElementById('details').innerHTML=['CT','CU','CM'].map(c=>`<section class="panel ${{c.toLowerCase()}}"><h2>${{names[c]}} 六地区双程证据</h2><table><thead><tr><th>方向／地区</th><th>线路</th><th>评分</th><th>质量</th><th>判定证据</th></tr></thead><tbody>${{R.forward.filter(x=>x.carrier===c).map(x=>`<tr><td>去程／${{E(x.region)}}<br>${{E(x.access)}}</td><td>${{E(x.class)}}</td><td>${{x.score}}</td><td>${{E(JSON.stringify(x.stats))}}</td><td>${{E(x.evidence)}}</td></tr>`).join('')}}${{R.returns.filter(x=>x.carrier===c).map(x=>`<tr><td>回程／${{x.city}}</td><td>${{E(x.class)}}</td><td>${{x.score}}</td><td>${{E(JSON.stringify(x.stats))}}</td><td>${{E(x.evidence)}}</td></tr>`).join('')}}</tbody></table></section>`).join('');
function nodeSeek(){{
  const header=`## 中国三网 VPS 双程质量报告\n\n- 入口：${{R.target.host}}:${{R.target.port}}\n- 出口：${{R.exit.host}}\n- 入口核对：${{R.dedicatedLine.portStatus}}\n- 专线内段：NAT 隐藏，不强判线路等级\n- 版本：${{R.version}}\n\n`;
  const tabs=':::: tabs\\n'+['CT','CU','CM'].map(c=>{{
    const g=R.grades.find(x=>x.carrier===c);
    const forwards=R.forward.filter(x=>x.carrier===c);
    const returns=R.returns.filter(x=>x.carrier===c);
    const forwardRows=forwards.map(x=>`- 去程（${{x.region}}→VPS）：${{x.class}}｜AVG ${{x.stats.avg??'N/A'}} ms｜P95 ${{x.stats.p95??'N/A'}} ms｜JITTER ${{x.stats.jitter??'N/A'}} ms｜LOSS N/A｜${{x.score}} 分`).join('\\n');
    const returnRows=returns.map(x=>`- 回程（VPS→${{x.city}}）：${{x.class}}｜AVG ${{x.stats.avg??'N/A'}} ms｜P95 ${{x.stats.p95??'N/A'}} ms｜JITTER ${{x.stats.jitter??'N/A'}} ms｜LOSS ${{x.stats.loss??'N/A'}}%｜${{x.score}} 分`).join('\\n');
    return `::: tab-item ${{names[c]}}\n双程：${{g.score}} 分 ${{g.stars}}\n\n${{forwardRows}}\n${{returnRows}}\n:::`;
  }}).join('\\n\\n')+'\\n::::';
  return header+tabs+'\\n\\n> traceroute 跳点不回应不等于端到端丢包；去程 LOSS 显示 N/A，只有 TCP connect 才计算业务探测丢包。';
}}
document.getElementById('copy').onclick=async()=>{{await navigator.clipboard.writeText(nodeSeek());alert('NodeSeek 格式已复制')}};
document.getElementById('json').onclick=()=>{{const a=document.createElement('a');a.download='3net-report.json';a.href=URL.createObjectURL(new Blob([JSON.stringify(R,null,2)],{{type:'application/json'}}));a.click()}};
</script></body></html>""", encoding="utf-8")
    return html_path, json_path


def public_report_payload(report: dict[str, Any]) -> dict[str, Any]:
    """Convert RC4 native data to the public site's established flat schema."""
    carrier_names = {"CT": "中国电信", "CU": "中国联通", "CM": "中国移动"}

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
            "route": item["class"], "evidence": item["evidence"],
            "score": item["score"], "stars": item["stars"],
            "avg": s.get("avg"), "min": s.get("minimum"), "max": s.get("maximum"),
            "p95": s.get("p95"), "jitter": s.get("jitter"), "stddev": None,
            "loss": s.get("loss"),
            "success": f"{s.get('success', 0)}/{s.get('expected', 0)}",
            "routeHops": 0, "timeoutHops": 0, "backboneTags": [],
            "reachability": item.get("reachability", "INCONCLUSIVE"),
        }

    carriers: list[dict[str, Any]] = []
    for carrier in ("CT", "CU", "CM"):
        forward_items = [x for x in report["forward"] if x["carrier"] == carrier]
        forward_probes = [flatten_forward(x) for x in forward_items]
        grade_item = next(x for x in report["grades"] if x["carrier"] == carrier)
        probes: list[dict[str, Any]] = []
        for item in (x for x in report["returns"] if x["carrier"] == carrier):
            s = item["stats"]
            probes.append({
                "city": item["city"], "host": item["host"], "ip": item["probeIp"],
                "route": item["class"], "evidence": item["evidence"],
                "score": item["score"], "stars": item["stars"],
                "avg": s.get("avg"), "min": s.get("minimum"), "max": s.get("maximum"),
                "p95": s.get("p95"), "jitter": s.get("jitter"), "stddev": None,
                "loss": s.get("loss"), "success": f"{s.get('success', 0)}/{s.get('expected', 0)}",
                "routeHops": 0, "timeoutHops": 0, "backboneTags": [],
            })
        forward_flat = {
            "region": "六地区汇总", "label": "六地区远端实测 → VPS",
            "access": "北京／上海／广东／安徽／江苏／浙江",
            "publicIp": "", "verified": all(x["verified"] for x in forward_items),
            "route": grade_item["forwardRoute"],
            "evidence": f"六地区去程共 {len(forward_items)} 组",
            "score": grade_item["forwardScore"],
            "stars": stars(grade_item["forwardScore"]),
            "avg": average([x["stats"].get("avg") for x in forward_items]),
            "min": average([x["stats"].get("minimum") for x in forward_items]),
            "max": average([x["stats"].get("maximum") for x in forward_items]),
            "p95": average([x["stats"].get("p95") for x in forward_items]),
            "jitter": average([x["stats"].get("jitter") for x in forward_items]),
            "stddev": None, "loss": None,
            "success": f"{sum(1 for x in forward_items if x.get('targetReached'))}/{len(forward_items)}",
            "routeHops": 0, "timeoutHops": 0, "backboneTags": [],
            "reachability": report["dedicatedLine"]["portStatus"],
        }
        carriers.append({
            "id": carrier, "name": carrier_names[carrier],
            "route": grade_item["returnRoute"], "score": grade_item["score"],
            "stars": grade_item["stars"], "probeCount": len(probes),
            "routeTypes": len({x["route"] for x in probes}),
            "forward": forward_flat, "forwardRoute": grade_item["forwardRoute"],
            "forwardProbes": forward_probes,
            "forwardScore": grade_item["forwardScore"],
            "returnScore": grade_item["returnScore"],
            "bidirectional": True, "probes": probes,
        })
    final_score = round(statistics.mean(x["score"] for x in report["grades"]))
    return {
        "version": report["version"], "generated": report["generated"],
        "target": report["target"]["host"], "targetPort": report["target"]["port"],
        "returnSshHost": report["exit"]["host"], "selfTest": report["selfTest"],
        "mode": report["mode"],
        "matrix": "北京／上海／广东／安徽／江苏／浙江 × 三网去程＋回程（36 组）",
        "methodology": report["methodology"],
        "bgp": {"asn": report["dedicatedLine"]["exitAsn"],
                "provider": report["exit"]["identity"], "location": ""},
        "final": {"score": final_score, "stars": stars(final_score),
                  "title": "三网双程综合判定", "elapsed": "N/A"},
        "carriers": carriers,
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
    target, port = ask_target()
    if SELF_TEST:
        exit_ip, exit_identity = "45.207.225.70", "SELF-TEST VPS"
    else:
        exit_ip, exit_identity = public_ip()

    banner("TARGET / 双端检测模型", CYAN)
    field("国内入口目标", f"{mask_ip(target)}:{port}", CYAN)
    field("当前出口 VPS", f"{mask_ip(exit_ip)}｜{exit_identity or '本机原生执行'}", GREEN)
    field("认证方式", "VPS 本机原生执行｜不使用 SSH／密码／私钥", GREEN)
    field("入口核对方式", "由中国三网外部 TCP traceroute 核对；不从出口反连 NAT 入口", CYAN)
    field("测试地区", "北京／上海／广东／安徽／江苏／浙江", MAGENTA)

    forward: list[dict[str, Any]] = []
    forward_total = len(FORWARD_REGIONS) * 3
    forward_index = 0
    for carrier in ("CT", "CU", "CM"):
        for region, probe_city in FORWARD_REGIONS:
            forward_index += 1
            if SELF_TEST:
                item = self_test_forward(carrier, region, probe_city)
            else:
                field(
                    f"[{forward_index}/{forward_total}] 去程",
                    f"{region} AS{FORWARD_ASN[carrier]} → {mask_ip(target)}:{port}",
                    CARRIER_COLOR[carrier],
                )
                field("探针状态", "正在请求 Globalping 六地区远端 TCP traceroute……", GRAY)
                item = globalping_trace(target, port, carrier, region, probe_city)
            forward.append(item)
            show_forward(item, forward_index, forward_total)

    dedicated_line = dedicated_line_assessment(target, port, exit_ip, forward)
    banner("DEDICATED LINE / 专线与 NAT 内段", MAGENTA)
    field("网络拓扑", dedicated_line["topology"], CYAN)
    field("外部端口", dedicated_line["portStatus"],
          GREEN if dedicated_line["reachedBy"] else YELLOW)
    field("入口 ASN", dedicated_line["entryAsn"], CYAN)
    field("出口 ASN", dedicated_line["exitAsn"], GREEN)
    field("内段可见性", "NAT 隐藏｜不强判精品或普通线路", YELLOW)
    field("判断边界", dedicated_line["internalVerdict"], GRAY)

    return_total = sum(len(items) for items in PROBES.values())
    banner("RETURN PROBE / 出口 VPS 原生三网十八组回程", CYAN)
    field("执行位置", mask_ip(exit_ip), GREEN)
    field("执行方式", "traceroute TCP/80＋五次 TCP connect；本机直接执行", GRAY)
    returns: list[dict[str, Any]] = []
    index = 0
    for carrier in ("CT", "CU", "CM"):
        for city, host in PROBES[carrier]:
            index += 1
            item = self_test_return(carrier, city, host) if SELF_TEST else return_probe(carrier, city, host)
            returns.append(item)
            show_return(item, index, return_total)

    grades = [grade(c, forward, returns) for c in ("CT", "CU", "CM")]
    banner("FINAL VERDICT / 三网双程综合判定", CYAN)
    for item in grades:
        color = CARRIER_COLOR[item["carrier"]]
        field(CARRIER_NAME[item["carrier"]], f"去程 {item['forwardRoute']}｜回程 {item['returnRoute']}｜双程 {item['score']} 分｜{item['stars']}", color)

    report = {
        "version": VERSION,
        "generated": dt.datetime.now(dt.timezone.utc).astimezone().isoformat(timespec="seconds"),
        "mode": "VPS_NATIVE_DUAL_ENDPOINT",
        "selfTest": SELF_TEST,
        "target": {"host": mask_ip(target), "port": port, "role": "国内入口"},
        "exit": {"host": mask_ip(exit_ip), "identity": exit_identity, "role": "出口 VPS 本机"},
        "methodology": "Globalping 在北京／上海／广东／安徽／江苏／浙江调用中国电信 AS4134／联通 AS4837／移动 AS9808 远端探针，对国内入口协议业务端口执行十八组 TCP traceroute；无法取得地区探针时明确降级为同 ASN 中国探针，不把降级样本伪装成指定地区。出口 VPS 本机对相同六地区三网十八组目标执行原生 traceroute 与五次 TCP connect；traceroute 跳点不回应不计算为业务丢包，Cymru DNS 补查可见 IP Origin ASN。NAT／端口映射隐藏的入口至出口专线内段单列为不可见，不强判线路等级。",
        "forward": forward,
        "returns": returns,
        "grades": grades,
        "dedicatedLine": dedicated_line,
        "privacy": "报告中的入口与出口 IPv4 均只保留前两段。",
    }
    html_path, json_path = write_report(report)
    banner("REPORT / 报告输出", MAGENTA)
    field("HTML 报告", html_path, GREEN)
    field("JSON 数据", json_path, GREEN)
    field("页面功能", "双程证据／NodeSeek 复制／JSON 下载／打印 PDF", CYAN)
    if not SELF_TEST:
        public_url = publish(report)
        if public_url:
            field("公共报告", public_url, GREEN)
    else:
        field("SELF-TEST", "PASS｜离线分类、评分、排版与报告生成完成", GREEN)
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
