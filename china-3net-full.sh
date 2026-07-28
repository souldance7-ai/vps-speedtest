#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="v1.0.0"
REPORT_ROOT="https://china-3net-route-report.souldance4.chatgpt.site"
REPORT_API="${REPORT_ROOT}/api/reports"
OUTPUT_ROOT="${HOME:-/root}/China-3Net-Full-Diagnostic"
PROVINCE=""
PORT=""
SELF_TEST=0
NO_PUBLISH=0
ONLY=""

usage() {
  cat <<'EOF'
China 3Net 全能体检 v1.0.0

连续执行：
  1. 3NT 正式含测速版
  2. IP 质量体检
  3. 网络质量体检
  4. Net.Check.Place IPv4
  5. Net.Check.Place 延迟模式
  6. Net.Check.Place 整路由 TCP 大包模式
  7. Net.Check.Place 默认双栈
  8. 硬件质量体检
  9. 流媒体解锁检测（IPv4）

用法：
  bash china-3net-full.sh
  bash china-3net-full.sh --port 8443 --province 安徽
  bash china-3net-full.sh --province Anhui
  bash china-3net-full.sh --only 3nt,ip,network,media
  bash china-3net-full.sh --no-publish
  bash china-3net-full.sh --self-test

参数：
  --port PORT       3NT 使用的 TCP 业务端口；不是 SSH 22
  --province NAME   整路由模式的大陆省级行政区中文名或中／英文简称
  --only LIST       只执行指定模块，逗号分隔
                    3nt,ip,network,ipv4,latency,route,dual,hardware,media
  --no-publish      只保留本地 JSON 与原始日志，不上传公共报告
  --self-test       离线生成模拟报告并检查结构
  -h, --help        显示帮助

说明：
  本工具是独立入口，不修改 3net-route.sh、RC 或 ix-route.sh。
  每个上游脚本在运行时下载并独立执行；单项失败不会阻断后续体检。
  公共报告仅保存遮罩 IP、分项摘要及截断后的脱敏日志，不保存 SSH 凭据。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="${2:-}"; shift 2 ;;
    --province) PROVINCE="${2:-}"; shift 2 ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    --no-publish) NO_PUBLISH=1; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[ERROR] 未知参数：$1"; usage; exit 2 ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "[ERROR] 找不到 python3。Debian/Ubuntu：apt-get update && apt-get install -y python3 curl"
  exit 3
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "[ERROR] 找不到 curl。Debian/Ubuntu：apt-get update && apt-get install -y curl"
  exit 3
fi

if [[ "$SELF_TEST" -eq 0 ]]; then
  if [[ -z "$PORT" ]]; then
    read -r -p "请输入 3NT 检测使用的 TCP 业务端口（不是 SSH 22）：" PORT
  fi
  if ! [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || (( PORT < 1 || PORT > 65535 )); then
    echo "[ERROR] TCP 业务端口无效：$PORT"
    exit 2
  fi
  if [[ -z "$PROVINCE" ]]; then
    read -r -p "请输入整路由模式省份（例如 安徽／Anhui；直接 Enter 跳过整路由）：" PROVINCE
  fi
fi

RUN_ID="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${OUTPUT_ROOT}/${RUN_ID}"
LOG_DIR="${RUN_DIR}/logs"
META_FILE="${RUN_DIR}/modules.tsv"
REPORT_FILE="${RUN_DIR}/China3Net_全能体检_${RUN_ID}.json"
mkdir -p "$LOG_DIR"
printf 'id\ttitle\tgroup\tstatus\texitCode\tstarted\telapsed\tcommand\tlog\n' > "$META_FILE"

TMP_DIR="$(mktemp -d /tmp/china3net-full.XXXXXX)"
cleanup() {
  rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT INT TERM

module_enabled() {
  local id="$1"
  [[ -z "$ONLY" ]] && return 0
  [[ ",${ONLY// /}," == *",$id,"* ]]
}

safe_field() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

record_skipped() {
  local id="$1" title="$2" group="$3" command="$4" reason="$5"
  local log="${LOG_DIR}/${id}.log"
  printf '%s\n' "$reason" > "$log"
  printf '%s\t%s\t%s\tSKIPPED\t0\t%s\t0\t%s\t%s\n' \
    "$id" "$(safe_field "$title")" "$group" "$(date -Is)" \
    "$(safe_field "$command")" "$log" >> "$META_FILE"
}

run_module() {
  local id="$1" title="$2" group="$3" url="$4"
  shift 4
  local args=("$@")
  local command="bash <(curl -Ls ${url})"
  local arg
  for arg in "${args[@]}"; do command+=" $(printf '%q' "$arg")"; done

  if ! module_enabled "$id"; then
    record_skipped "$id" "$title" "$group" "$command" "按 --only 设置跳过。"
    return 0
  fi

  local script="${TMP_DIR}/${id}.sh"
  local log="${LOG_DIR}/${id}.log"
  local started epoch_start epoch_end rc status
  started="$(date -Is)"
  epoch_start="$(date +%s)"

  printf '\n\033[96m[%s/9] %s\033[0m\n' "$((MODULE_INDEX += 1))" "$title"
  printf '\033[38;5;245m%s\033[0m\n' "$command"

  if ! curl -fsSL --retry 3 --connect-timeout 15 --max-time 90 "$url" -o "$script"; then
    printf '[ERROR] 上游脚本下载失败：%s\n' "$url" | tee "$log"
    rc=90
  elif [[ ! -s "$script" ]]; then
    printf '[ERROR] 上游脚本为空：%s\n' "$url" | tee "$log"
    rc=91
  else
    set +e
    TERM=xterm-256color bash "$script" "${args[@]}" 2>&1 | tee "$log"
    rc="${PIPESTATUS[0]}"
    set -e
  fi

  epoch_end="$(date +%s)"
  status="PASS"
  if (( rc != 0 )); then status="WARNING"; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$(safe_field "$title")" "$group" "$status" "$rc" "$started" \
    "$((epoch_end - epoch_start))" "$(safe_field "$command")" "$log" >> "$META_FILE"
  printf '\033[92m[%s] %s｜%ss\033[0m\n' "$status" "$title" "$((epoch_end - epoch_start))"
}

make_self_test_logs() {
  local id title group status rc started elapsed command log
  local rows=(
    "3nt|3NT 正式含测速版|route|PASS|0|中国电信 CN2 GIA  回程 312.5 Mbps\n中国联通 AS9929  回程 286.8 Mbps\n中国移动 CMIN2  回程 341.2 Mbps"
    "ip|IP 质量体检|identity|PASS|0|IP 类型：数据中心\n风险数据库：低风险\n端口：正常"
    "network|网络质量体检|network|PASS|0|TCP 拥塞控制：BBR\n国际互联：良好\n丢包：0.0%"
    "ipv4|Net.Check.Place IPv4|route|PASS|0|IPv4 路由检测完成\n中国三网回程均有结果"
    "latency|Net.Check.Place 延迟模式|latency|PASS|0|中国大陆平均延迟 42.8 ms\n亚洲平均延迟 31.5 ms"
    "route|Net.Check.Place 整路由 TCP 大包|route|PASS|0|安徽电信／联通／移动 TCP 大包路由完成"
    "dual|Net.Check.Place 默认双栈|network|WARNING|1|IPv4：PASS\nIPv6：未配置"
    "hardware|硬件质量体检|hardware|PASS|0|CPU：4 Core\n内存：8 GB\n磁盘：NVMe"
    "media|流媒体解锁检测 IPv4|media|PASS|0|Netflix：YES\nDisney+：YES\nYouTube Premium：YES"
  )
  for row in "${rows[@]}"; do
    IFS='|' read -r id title group status rc command <<< "$row"
    started="$(date -Is)"
    elapsed=1
    log="${LOG_DIR}/${id}.log"
    printf '%b\n' "$command" > "$log"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "$title" "$group" "$status" "$rc" "$started" "$elapsed" \
      "SELF-TEST ${id}" "$log" >> "$META_FILE"
  done
}

STARTED_AT="$(date -Is)"
START_EPOCH="$(date +%s)"
MODULE_INDEX=0

if [[ "$SELF_TEST" -eq 1 ]]; then
  PROVINCE="${PROVINCE:-安徽}"
  PORT="${PORT:-8443}"
  make_self_test_logs
else
  run_module \
    "3nt" "3NT 正式含测速版" "route" \
    "https://raw.githubusercontent.com/souldance7-ai/vps-speedtest/main/3net-route-speed.sh" \
    --port "$PORT"
  run_module "ip" "IP 质量体检" "identity" "https://Check.Place" -I
  run_module "network" "网络质量体检" "network" "https://Check.Place" -N
  run_module "ipv4" "Net.Check.Place IPv4" "route" "https://Net.Check.Place" -4
  run_module "latency" "Net.Check.Place 延迟模式" "latency" "https://Net.Check.Place" -P
  if [[ -n "$PROVINCE" ]]; then
    run_module "route" "Net.Check.Place 整路由 TCP 大包" "route" "https://Net.Check.Place" -R "$PROVINCE"
  else
    record_skipped \
      "route" "Net.Check.Place 整路由 TCP 大包" "route" \
      "bash <(curl -Ls https://Net.Check.Place) -R 省份" \
      "未填写省份，已安全跳过整路由模式。"
  fi
  run_module "dual" "Net.Check.Place 默认双栈" "network" "https://Net.Check.Place"
  run_module "hardware" "硬件质量体检" "hardware" "https://Hardware.Check.Place"
  run_module "media" "流媒体解锁检测 IPv4" "media" "https://Media.Check.Place" -M 4
fi

FINISHED_AT="$(date -Is)"
END_EPOCH="$(date +%s)"

export FULL_DIAG_VERSION="$VERSION"
export FULL_DIAG_META="$META_FILE"
export FULL_DIAG_REPORT="$REPORT_FILE"
export FULL_DIAG_STARTED="$STARTED_AT"
export FULL_DIAG_FINISHED="$FINISHED_AT"
export FULL_DIAG_ELAPSED="$((END_EPOCH - START_EPOCH))"
export FULL_DIAG_PROVINCE="$PROVINCE"
export FULL_DIAG_PORT="$PORT"
export FULL_DIAG_SELF_TEST="$SELF_TEST"

python3 /dev/fd/3 3<<'PY'
from __future__ import annotations

import csv
import datetime as dt
import ipaddress
import json
import os
import re
import urllib.request
from pathlib import Path

ANSI_RE = re.compile(
    r"(?:\x1B\][^\x07]*(?:\x07|\x1B\\))|(?:\x1B[@-_][0-?]*[ -/]*[@-~])"
)
IPV4_RE = re.compile(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])")
PORT_RE = re.compile(r"(?<!\d):(\d{2,5})(?!\d)")


def public_ipv4() -> str:
    if os.environ["FULL_DIAG_SELF_TEST"] == "1":
        return "203.55.99.88"
    for url in ("https://api.ipify.org", "https://ipv4.icanhazip.com"):
        try:
            with urllib.request.urlopen(url, timeout=8) as response:
                value = response.read().decode("utf-8", "replace").strip()
            if ipaddress.ip_address(value).version == 4:
                return value
        except Exception:
            pass
    return "0.0.0.0"


def mask_ipv4(value: str) -> str:
    try:
        address = ipaddress.ip_address(value)
        if address.version != 4:
            return value
        parts = value.split(".")
        return f"{parts[0]}.{parts[1]}.*.*"
    except ValueError:
        return value


def sanitize(text: str) -> str:
    text = ANSI_RE.sub("", text).replace("\r", "")
    text = "".join(ch for ch in text if ch == "\n" or ch == "\t" or ord(ch) >= 32)
    text = IPV4_RE.sub(lambda match: mask_ipv4(match.group(0)), text)
    text = PORT_RE.sub(lambda match: ":***" if match.group(1) != "443" else ":443", text)
    lines = [re.sub(r"[ \t]+", " ", line).strip() for line in text.splitlines()]
    lines = [line for line in lines if line and not re.fullmatch(r"[-=━─┄┅┈┉━░▒▓█ ]+", line)]
    return "\n".join(lines)


def summarize(text: str) -> list[str]:
    keywords = re.compile(
        r"(PASS|FAIL|WARNING|YES|NO|支持|解锁|风险|延迟|丢包|抖动|"
        r"CN2|AS9929|CMIN2|CMI2|Mbps|Gbps|CPU|内存|磁盘|IPv4|IPv6|"
        r"Netflix|Disney|YouTube|ChatGPT|OpenAI)",
        re.I,
    )
    lines = [line for line in text.splitlines() if 3 <= len(line) <= 180]
    selected: list[str] = []
    for line in lines:
        if keywords.search(line) and line not in selected:
            selected.append(line)
        if len(selected) >= 8:
            break
    if not selected:
        selected = lines[:6]
    return selected


meta_path = Path(os.environ["FULL_DIAG_META"])
modules = []
with meta_path.open(encoding="utf-8", newline="") as handle:
    for row in csv.DictReader(handle, delimiter="\t"):
        raw = Path(row["log"]).read_text(encoding="utf-8", errors="replace")
        clean = sanitize(raw)
        if len(clean) > 12000:
            clean = clean[:11800].rstrip() + "\n\n[公开报告日志已截断；完整原始日志保留在被测 VPS]"
        modules.append(
            {
                "id": row["id"],
                "title": row["title"],
                "group": row["group"],
                "status": row["status"],
                "exitCode": int(row["exitCode"]),
                "started": row["started"],
                "elapsedSeconds": int(row["elapsed"]),
                "command": row["command"],
                "summary": summarize(clean),
                "log": clean,
            }
        )

counts = {
    key: sum(1 for module in modules if module["status"] == key)
    for key in ("PASS", "WARNING", "SKIPPED")
}
masked_ip = mask_ipv4(public_ipv4())
report = {
    "reportKind": "FULL_DIAGNOSTIC",
    "version": os.environ["FULL_DIAG_VERSION"],
    "generated": dt.datetime.now(dt.timezone.utc).astimezone().isoformat(timespec="seconds"),
    "target": masked_ip,
    "selfTest": os.environ["FULL_DIAG_SELF_TEST"] == "1",
    "mode": "ALL_IN_ONE_CONTINUOUS",
    "matrix": "3NT＋IP质量＋网络质量＋IPv4＋延迟＋整路由＋双栈＋硬件＋流媒体",
    "bgp": {"asn": "由分项原始结果核对", "provider": "N/A", "location": "N/A"},
    "final": {
        "title": f"全能体检完成｜{counts['PASS']} 项正常／{counts['WARNING']} 项需复核／{counts['SKIPPED']} 项跳过",
        "elapsed": f"{int(os.environ['FULL_DIAG_ELAPSED'])}s",
        "matrixComplete": counts["WARNING"] == 0 and counts["SKIPPED"] == 0,
        "presentationPolicy": "FULL_DIAGNOSTIC_SVG",
    },
    "carriers": [],
    "diagnostics": {
        "province": os.environ["FULL_DIAG_PROVINCE"] or "未指定",
        "businessPort": "***",
        "startedAt": os.environ["FULL_DIAG_STARTED"],
        "finishedAt": os.environ["FULL_DIAG_FINISHED"],
        "elapsedSeconds": int(os.environ["FULL_DIAG_ELAPSED"]),
        "counts": counts,
        "modules": modules,
        "privacy": "IPv4 仅保留前两段；非 443 端口统一显示为 ***；不上传 SSH 凭据。",
    },
}

encoded = json.dumps(report, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
if len(encoded) > 192 * 1024:
    raise SystemExit(f"公开报告超过 192 KB：{len(encoded)} bytes")

report_path = Path(os.environ["FULL_DIAG_REPORT"])
report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"[REPORT] JSON：{report_path}")
print(f"[REPORT] 大小：{len(encoded)} bytes")
PY

if [[ "$SELF_TEST" -eq 1 ]]; then
  python3 - "$REPORT_FILE" <<'PY'
import json, sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
assert report["reportKind"] == "FULL_DIAGNOSTIC"
assert len(report["diagnostics"]["modules"]) == 9
assert report["target"].endswith("*.*")
assert all("summary" in item and "log" in item for item in report["diagnostics"]["modules"])
print("[SELF-TEST] PASS｜九分项、脱敏、摘要、日志与 JSON 结构完成")
PY
  exit 0
fi

if [[ "$NO_PUBLISH" -eq 1 ]]; then
  echo "[REPORT] 已按 --no-publish 保留本地报告：$REPORT_FILE"
  exit 0
fi

UPLOAD_RESPONSE="${RUN_DIR}/upload-response.json"
set +e
curl -fsS --retry 2 --connect-timeout 15 --max-time 60 \
  -H "Content-Type: application/json" \
  --data-binary "@${REPORT_FILE}" \
  "$REPORT_API" > "$UPLOAD_RESPONSE"
UPLOAD_RC=$?
set -e

if (( UPLOAD_RC != 0 )); then
  echo "[WARNING] 公共报告上传失败；本地 JSON 与日志已保留。"
  echo "[RETRY] 稍后可在报告站使用“选择 JSON 并上传”重传本地 JSON。"
  exit 8
fi

python3 - "$UPLOAD_RESPONSE" "$REPORT_FILE" <<'PY'
import json, sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
if not result.get("ok") or not result.get("url"):
    raise SystemExit("[ERROR] 报告站未返回有效网址：" + json.dumps(result, ensure_ascii=False))
print("")
print("============================================================")
print("  China 3Net 全能体检已完成")
print("============================================================")
print("☀️ 浅色报告：" + (result.get("readableUrl") or result["url"] + "/readable"))
print("🌙 深色报告：" + (result.get("darkUrl") or result["url"]))
print("📄 本地 JSON：" + sys.argv[2])
print("网页功能：分项浏览／SVG／PNG／NodeSeek 浅色高清／NodeSeek 深色高清")
PY
