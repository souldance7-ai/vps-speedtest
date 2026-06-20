#!/usr/bin/env bash
# =====================================================================
# LazyVPS CN3 VPS Net Test Plus
# 中国电信 / 中国联通 / 中国移动 三网 VPS 网络质量测试脚本（非家宽口径）
# License: MIT
# Version: 2.2.0-open
# =====================================================================

set -Eeuo pipefail

VERSION="2.6.0-open"
SCRIPT_NAME="CN3 VPS 三网综合测试（VPS版）"
MODE="standard"          # quick / standard / deep / route
RUN_SPEED=1
INSTALL_DEPS=0
PING_COUNT=10
TCP_COUNT=3
TCP_TIMEOUT=2
MTR_COUNT=20
SPEED_COUNT=2
OUT_BASE=""
NON_INTERACTIVE=0
QUIET=0
SPINNER_PID=""
IP_BRIEF=""

TARGETS_CSV=$(cat <<'CSV'
ISP,Region,Name,Host,Port
CT,广东,电信DNS-广东,202.96.128.86,53
CT,上海,电信DNS-上海,202.96.209.133,53
CT,江苏,电信DNS-江苏,218.2.2.2,53
CT,四川,电信DNS-四川,61.139.2.69,53
CT,全国,中国电信官网,www.189.cn,443
CU,广东,联通DNS-广东,210.21.196.6,53
CU,北京,联通DNS-北京,202.106.0.20,53
CU,河南,联通DNS-河南,202.102.224.68,53
CU,全国,中国联通官网,www.10010.com,443
CM,广东,移动DNS-广东,211.136.192.6,53
CM,上海,移动DNS-上海,211.136.150.66,53
CM,北京,移动DNS-北京,221.130.33.52,53
CM,全国,中国移动官网,www.10086.cn,443
CSV
)

# ---------- 颜色 ----------
NO_COLOR_MODE=0
if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then NO_COLOR_MODE=1; fi
if [[ "$NO_COLOR_MODE" -eq 0 ]]; then
  RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; MAGENTA=$'\033[35m'; CYAN=$'\033[36m'; WHITE=$'\033[37m'
else
  RESET=""; BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; WHITE=""
fi

if locale 2>/dev/null | grep -qi 'UTF-8'; then
  BLOCK_FULL="█"; BLOCK_EMPTY="░"; SPARK="◆"; CHECK="✓"; CROSS="✗"; ARROW="➜"; TROPHY="🏆"; STAR="★"
else
  BLOCK_FULL="#"; BLOCK_EMPTY="-"; SPARK="*"; CHECK="OK"; CROSS="NO"; ARROW="->"; TROPHY="[TOP1]"; STAR="*"
fi

# ---------- 通用 ----------
has_cmd() { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }
SUDO=""; if ! is_root && has_cmd sudo; then SUDO="sudo"; fi

repeat_char() { local ch="$1" n="$2" out=""; local i; for ((i=0;i<n;i++)); do out+="$ch"; done; printf '%s' "$out"; }
hr() { repeat_char '=' "${1:-86}"; }
clear_screen() { [[ "$QUIET" -eq 0 && -t 1 ]] && clear || true; }
safe_name() { local s="$*"; s="${s// /_}"; s="${s//\//_}"; s="${s//:/_}"; s="${s//,/}"; s="${s//(/}"; s="${s//)/}"; printf '%s' "$s" | tr -cd '[:alnum:]_.@%+=\-一-龥'; }
strip_ansi() { sed -E 's/\x1B\[[0-9;]*[mK]//g'; }

log()  { printf '%s[信息]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[注意]%s %s\n' "$YELLOW" "$RESET" "$*"; }
err()  { printf '%s[错误]%s %s\n' "$RED" "$RESET" "$*" >&2; }
info_note() { printf '%s[说明]%s %s\n' "$CYAN" "$RESET" "$*"; }
section_title() {
  local title="$1" width="${2:-86}"
  printf '\n%s%s%s\n' "$CYAN" "$(hr "$width")" "$RESET"
  printf '%s%s%s %s%s%s\n' "$CYAN" "$SPARK" "$RESET" "$BOLD" "$title" "$RESET"
  printf '%s%s%s\n' "$CYAN" "$(repeat_char '-' "$width")" "$RESET"
}

# ---------- Banner / 封面 ----------
horse_art() {
  cat <<'EOF_HORSE'
        /\_/|       /\_/|       /\_/|       /\_/|
   ____/ 0 0\  ____/ 0 0\  ____/ 0 0\  ____/ 0 0\
  /  __    _/ /  __    _/ /  __    _/ /  __    _/
 /__/  \__/  /__/  \__/  /__/  \__/  /__/  \__/
   /_/ \_\     /_/ \_\     /_/ \_\     /_/ \_\      万马奔腾测速版
EOF_HORSE
}

banner() {
  clear_screen
  printf '%s%s%s\n' "$CYAN" "$(hr 86)" "$RESET"
  horse_art
  printf '%s%s%s\n' "$CYAN" "$(hr 86)" "$RESET"
  printf '%s%s%s\n' "$BOLD" "LazyVPS CN3 VPS Net Test Plus" "$RESET"
  printf '中国电信 / 中国联通 / 中国移动 · VPS 中国方向评估\n'
  printf '延迟 · 丢包 · 路由 · 测速 · 回程骨干观察 · 综合参考评分\n'
  printf '%s开源版 v%s · 交互菜单 · CMD仪表盘 · 评级仅供参考%s\n' "$DIM" "$VERSION" "$RESET"
  printf '%s%s%s\n\n' "$CYAN" "$(hr 86)" "$RESET"
}

# ---------- 评分条 / 进度 ----------
color_by_score() {
  local score="${1:-0}"
  awk -v x="$score" 'BEGIN{if(x>=82)print 3; else if(x>=66)print 2; else if(x>=56)print 1; else print 0}' | {
    read -r s
    case "$s" in
      3) printf '%s' "$GREEN" ;;
      2) printf '%s' "$CYAN" ;;
      1) printf '%s' "$YELLOW" ;;
      *) printf '%s' "$RED" ;;
    esac
  }
}

bar_pct() {
  local value="${1:-0}" max="${2:-100}" width="${3:-36}" pct filled i color out=""
  pct=$(awk -v v="$value" -v m="$max" 'BEGIN{if(m<=0)p=0; else p=v/m*100; if(p<0)p=0; if(p>100)p=100; printf "%d", p+0.5}')
  filled=$(( pct * width / 100 ))
  for ((i=1; i<=width; i++)); do
    if (( i <= filled )); then
      if (( i * 100 / width < 45 )); then color="$RED"; elif (( i * 100 / width < 75 )); then color="$YELLOW"; else color="$GREEN"; fi
      out+="${color}${BLOCK_FULL}${RESET}"
    else
      out+="${DIM}${BLOCK_EMPTY}${RESET}"
    fi
  done
  printf '%s %3s%%' "$out" "$pct"
}

progress_bar() {
  local current="$1" total="$2" label="$3" width=40 pct filled i out=""
  (( total <= 0 )) && total=1
  pct=$(( current * 100 / total )); (( pct > 100 )) && pct=100
  filled=$(( pct * width / 100 ))
  for ((i=1; i<=width; i++)); do
    if (( i <= filled )); then out+="${CYAN}${BLOCK_FULL}${RESET}"; else out+="${DIM}${BLOCK_EMPTY}${RESET}"; fi
  done
  printf '\r%s [%s] %3d%%  %s' "$ARROW" "$out" "$pct" "$label"
}

spinner_start() {
  local msg="$1"
  [[ ! -t 1 || "$QUIET" -eq 1 ]] && return 0
  (
    local frames=("·    " "··   " "···  " " ··· " "  ···" "   ··" "    ·")
    local i=0
    while true; do
      printf '\r%s%s%s %s' "$CYAN" "${frames[$i]}" "$RESET" "$msg"
      i=$(( (i + 1) % ${#frames[@]} ))
      sleep 0.18
    done
  ) &
  SPINNER_PID=$!
}

spinner_stop() {
  local status="${1:-0}" msg="${2:-完成}"
  if [[ -n "$SPINNER_PID" ]]; then
    kill "$SPINNER_PID" >/dev/null 2>&1 || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
  fi
  if [[ -t 1 && "$QUIET" -eq 0 ]]; then
    if [[ "$status" -eq 0 ]]; then printf '\r%s%s%s %s\n' "$GREEN" "$CHECK" "$RESET" "$msg"; else printf '\r%s%s%s %s\n' "$YELLOW" "$CROSS" "$RESET" "$msg"; fi
  fi
}

# ---------- 帮助 / 参数 ----------
usage() {
cat <<USAGE
${SCRIPT_NAME} v${VERSION}

用法：
  bash cn3_vps_net_test_plus.sh [选项]

交互模式：
  bash cn3_vps_net_test_plus.sh

常用命令：
  bash cn3_vps_net_test_plus.sh --install --standard
  bash cn3_vps_net_test_plus.sh --quick
  bash cn3_vps_net_test_plus.sh --deep
  bash cn3_vps_net_test_plus.sh --route-only
  bash cn3_vps_net_test_plus.sh --standard --no-speed

说明：
  - 本脚本用于 VPS 中国方向网络质量评估，不按家宽跑满带宽的标准打分。
  - 综合评分与评级仅供参考，请结合晚高峰复测、业务场景与回程路由综合判断。
USAGE
}

choose_mode_by_arrow() {
  # 交互式菜单：支持 ↑↓ / W/S / J/K / 数字 / Enter
  # 返回选择编号：0-6
  local selected=2
  local key rest

  while true; do
    banner
    cat <<'MENU_HEAD'
请选择测试模式：

提示：
  - 可直接按数字 1/2/3/4/5/6/0
  - 也可用 ↑ ↓ 方向键选择，Enter 确认
  - 本脚本面向 VPS 中国方向质量评估，不按家宽口径打分，评级仅供参考

MENU_HEAD

    local i
    local names=(
      "0|退出脚本|不执行任何测试"
      "1|快速体验测试|Ping + TCP + 每网 1 个测速点，适合先看大概"
      "2|标准综合测试|Ping + TCP + MTR + Traceroute + 每网 2 个测速点，推荐"
      "3|深度三网测试|更多采样 + 每网 3 个测速点，适合晚高峰留档/发报告"
      "4|仅延迟路由测试|不跑 Speedtest，只看三网延迟、丢包、MTR、回程骨干"
      "5|安装/补齐依赖|curl / python3 / mtr / traceroute / speedtest"
      "6|帮助说明|查看参数与使用方式"
    )

    printf '%s+----+----------------+------------------------------------------------------------+%s\n' "$CYAN" "$RESET"
    printf '%s| %-2s | %-14s | %-58s |%s\n' "$CYAN" "序" "模式" "说明" "$RESET"
    printf '%s+----+----------------+------------------------------------------------------------+%s\n' "$CYAN" "$RESET"

    for item in "${names[@]}"; do
      IFS='|' read -r num title desc <<< "$item"
      if [[ "$num" -eq "$selected" ]]; then
        if [[ "$NO_COLOR_MODE" -eq 0 ]]; then
          printf '%s| %s%-2s%s | %s%-14s%s | %s%-58s%s |%s\n' "$CYAN" "$YELLOW" "▶$num" "$CYAN" "$YELLOW" "$title" "$CYAN" "$YELLOW" "$desc" "$CYAN" "$RESET"
        else
          printf '| >%-1s | %-14s | %-58s |\n' "$num" "$title" "$desc"
        fi
      else
        printf '%s| %-2s | %-14s | %-58s |%s\n' "$CYAN" "$num" "$title" "$desc" "$RESET"
      fi
    done

    printf '%s+----+----------------+------------------------------------------------------------+%s\n' "$CYAN" "$RESET"
    printf '\n当前选择：%s%s%s  （↑↓切换 / Enter确认 / 数字直选）' "$BOLD" "$selected" "$RESET"

    IFS= read -rsn1 key || key=""
    case "$key" in
      "")
        printf '\n'
        echo "$selected"
        return 0
        ;;
      $'\x1b')
        IFS= read -rsn2 -t 0.05 rest || rest=""
        case "$rest" in
          "[A") selected=$((selected-1)); [[ "$selected" -lt 0 ]] && selected=6 ;;
          "[B") selected=$((selected+1)); [[ "$selected" -gt 6 ]] && selected=0 ;;
        esac
        ;;
      [0-6])
        printf '\n'
        echo "$key"
        return 0
        ;;
      w|W|k|K)
        selected=$((selected-1)); [[ "$selected" -lt 0 ]] && selected=6
        ;;
      s|S|j|J)
        selected=$((selected+1)); [[ "$selected" -gt 6 ]] && selected=0
        ;;
      q|Q)
        printf '\n'
        echo "0"
        return 0
        ;;
    esac
  done
}

set_mode_from_option() {
  local opt="$1"
  case "$opt" in
    1)
      MODE="quick"; PING_COUNT=5; TCP_COUNT=2; MTR_COUNT=0; SPEED_COUNT=1; RUN_SPEED=1
      ;;
    2)
      MODE="standard"; PING_COUNT=10; TCP_COUNT=3; MTR_COUNT=20; SPEED_COUNT=2; RUN_SPEED=1
      ;;
    3)
      MODE="deep"; PING_COUNT=20; TCP_COUNT=5; MTR_COUNT=50; SPEED_COUNT=3; RUN_SPEED=1
      ;;
    4)
      MODE="route"; PING_COUNT=15; TCP_COUNT=4; MTR_COUNT=30; SPEED_COUNT=0; RUN_SPEED=0
      ;;
    *)
      return 1
      ;;
  esac
}

interactive_menu() {
  local opt
  while true; do
    if [[ -t 0 && "$QUIET" -eq 0 ]]; then
      opt="$(choose_mode_by_arrow)"
    else
      banner
      cat <<MENU
请选择测试模式：

  1) 快速体验测试
  2) 标准综合测试（推荐）
  3) 深度三网测试
  4) 仅延迟路由测试
  5) 安装/补齐依赖
  6) 帮助说明
  0) 退出

MENU
      printf '请输入选项 [默认 2]：'
      read -r opt || opt="2"
      opt="${opt:-2}"
    fi

    case "$opt" in
      1|2|3|4)
        set_mode_from_option "$opt"
        break
        ;;
      5)
        install_deps
        printf '\n按 Enter 返回菜单...'
        read -r _ || true
        ;;
      6)
        clear_screen
        usage
        printf '\n按 Enter 返回菜单...'
        read -r _ || true
        ;;
      0)
        exit 0
        ;;
      *)
        warn "选项无效。"
        sleep 1
        ;;
    esac
  done

  banner
  printf '%s已选择模式：%s%s%s\n' "$BOLD" "$CYAN" "$MODE" "$RESET"
  printf '%s采样参数：Ping=%s 次 / TCP=%s 次 / MTR=%s 包 / Speedtest每网=%s 个%s\n' "$DIM" "$PING_COUNT" "$TCP_COUNT" "$MTR_COUNT" "$SPEED_COUNT" "$RESET"
  printf '\n输出目录留空则自动生成，直接回车即可：'
  read -r custom_out || custom_out=""
  [[ -n "$custom_out" ]] && OUT_BASE="$custom_out"

  printf '\n是否开始测试？[Y/n]：'
  read -r yesno || yesno="Y"
  yesno="${yesno:-Y}"
  case "$yesno" in
    n|N|no|NO) exit 0 ;;
  esac
}


parse_args() {
  if [[ "$#" -eq 0 && -t 0 ]]; then NON_INTERACTIVE=0; return 0; fi
  NON_INTERACTIVE=1
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --install) INSTALL_DEPS=1; shift ;;
      --quick) MODE="quick"; PING_COUNT=5; TCP_COUNT=2; MTR_COUNT=0; SPEED_COUNT=1; RUN_SPEED=1; shift ;;
      --standard|--full) MODE="standard"; PING_COUNT=10; TCP_COUNT=3; MTR_COUNT=20; SPEED_COUNT=2; RUN_SPEED=1; shift ;;
      --deep) MODE="deep"; PING_COUNT=20; TCP_COUNT=5; MTR_COUNT=50; SPEED_COUNT=3; RUN_SPEED=1; shift ;;
      --route-only) MODE="route"; PING_COUNT=15; TCP_COUNT=4; MTR_COUNT=30; SPEED_COUNT=0; RUN_SPEED=0; shift ;;
      --no-speed) RUN_SPEED=0; SPEED_COUNT=0; shift ;;
      --speed-count) SPEED_COUNT="${2:-2}"; shift 2 ;;
      --ping-count) PING_COUNT="${2:-10}"; shift 2 ;;
      --tcp-count) TCP_COUNT="${2:-3}"; shift 2 ;;
      --tcp-timeout) TCP_TIMEOUT="${2:-2}"; shift 2 ;;
      --mtr-count) MTR_COUNT="${2:-20}"; shift 2 ;;
      --out) OUT_BASE="${2:-}"; shift 2 ;;
      --no-color) NO_COLOR_MODE=1; RESET=""; BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; WHITE=""; shift ;;
      --quiet) QUIET=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) err "未知参数：$1"; usage; exit 1 ;;
    esac
  done
}

# ---------- 依赖 ----------
install_deps() {
  banner
  log "开始安装/补齐依赖：curl、python3、ping、mtr、traceroute、jq、bc、Ookla speedtest。"
  if has_cmd apt-get; then
    $SUDO apt-get update -y
    $SUDO apt-get install -y curl ca-certificates python3 iputils-ping mtr-tiny traceroute bc dnsutils jq coreutils procps || true
    if ! has_cmd speedtest; then
      curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | $SUDO bash || true
      $SUDO apt-get update -y || true
      $SUDO apt-get install -y speedtest || warn "speedtest 安装失败，将跳过测速。"
    fi
  elif has_cmd dnf; then
    $SUDO dnf install -y curl ca-certificates python3 iputils mtr traceroute bc bind-utils jq coreutils procps-ng || true
    if ! has_cmd speedtest; then curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | $SUDO bash || true; $SUDO dnf install -y speedtest || true; fi
  elif has_cmd yum; then
    $SUDO yum install -y curl ca-certificates python3 iputils mtr traceroute bc bind-utils jq coreutils procps-ng || true
    if ! has_cmd speedtest; then curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | $SUDO bash || true; $SUDO yum install -y speedtest || true; fi
  elif has_cmd apk; then
    $SUDO apk add --no-cache curl ca-certificates python3 iputils mtr traceroute bc bind-tools jq coreutils procps || true
    warn "Alpine 暂不自动安装 Ookla speedtest，请按需手动安装。"
  else
    warn "未识别包管理器，请手动安装基础依赖。"
  fi
  log "依赖处理完成。"
}

check_deps() {
  local missing=0 c
  for c in curl python3 ping awk sed grep; do if ! has_cmd "$c"; then warn "缺少必要命令：$c"; missing=1; fi; done
  has_cmd mtr || warn "未检测到 mtr，完整路由测试会跳过 MTR。"
  has_cmd traceroute || warn "未检测到 traceroute，完整路由测试会跳过 Traceroute。"
  if [[ "$RUN_SPEED" -eq 1 && ! $(command -v speedtest 2>/dev/null || true) ]]; then warn "未检测到 Ookla speedtest，测速阶段会自动跳过。可使用 --install 安装。"; fi
  if [[ "$missing" -eq 1 ]]; then err "必要依赖缺失，请先执行：bash $0 --install"; exit 1; fi
}

# ---------- 准备输出 ----------
prepare_outdir() {
  if [[ -z "$OUT_BASE" ]]; then OUT_BASE="cn3_test_$(date '+%Y%m%d_%H%M%S')"; fi
  OUT_DIR="$OUT_BASE"
  mkdir -p "$OUT_DIR" "$OUT_DIR/mtr" "$OUT_DIR/traceroute" "$OUT_DIR/speedtest_json"
  BASEINFO_MD="$OUT_DIR/base_info.md"
  LATENCY_CSV="$OUT_DIR/latency_summary.csv"
  SPEED_CSV="$OUT_DIR/speedtest_summary.csv"
  OVERVIEW_CSV="$OUT_DIR/cn3_overview.csv"
  ROUTE_CSV="$OUT_DIR/route_backbone_summary.csv"
  REPORT_MD="$OUT_DIR/report.md"
  OOKLA_SERVERS_CSV="$OUT_DIR/ookla_cn_servers.csv"

  echo 'ISP,运营商,区域,目标名称,Host,Port,Ping丢包%,Ping最小ms,Ping平均ms,Ping最大ms,Ping抖动ms,TCP成功数,TCP失败率%,TCP最小ms,TCP平均ms,TCP最大ms,目标评分' > "$LATENCY_CSV"
  echo 'ISP,运营商,ServerID,测速点名称,赞助商,城市,SpeedtestPingms,下载Mbps,上传Mbps,结果URL,状态' > "$SPEED_CSV"
  echo '排名,ISP,运营商,目标数,平均Pingms,平均Ping丢包%,平均TCPms,TCP成功率%,测速点数,平均下载Mbps,平均上传Mbps,综合评分,评级,建议,报告评语' > "$OVERVIEW_CSV"
  echo 'ISP,运营商,回程骨干识别,关键特征,备注' > "$ROUTE_CSV"
}

# ---------- 基础信息 ----------
public_ip_info() {
  local outfile="$1"
  spinner_start "正在读取 VPS 基础信息、出口 IP 与来源地"
  python3 - "$outfile" <<'PYCODE'
import json, urllib.request, subprocess, sys, re
out=sys.argv[1]

def fetch(url, timeout=4):
    try:
        req=urllib.request.Request(url, headers={"User-Agent":"LazyVPS-CN3-Test"})
        return urllib.request.urlopen(req, timeout=timeout).read().decode('utf-8', 'ignore')
    except Exception:
        return ""

def jget(s):
    try:
        return json.loads(s)
    except Exception:
        return {}

def sh(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return 'N/A'

ip4 = fetch('https://api.ipify.org') or fetch('https://ip.sb') or 'N/A'
ip6 = fetch('https://api64.ipify.org') or 'N/A'
ipinfo = jget(fetch('https://ipinfo.io/json'))
ipwho = jget(fetch('https://ipwho.is/'))
country = ipinfo.get('country') or ipwho.get('country_code') or 'N/A'
region = ipinfo.get('region') or ipwho.get('region') or 'N/A'
city = ipinfo.get('city') or ipwho.get('city') or 'N/A'
org = ipinfo.get('org') or (ipwho.get('connection') or {}).get('isp') or 'N/A'
asn = (ipwho.get('connection') or {}).get('asn')
if asn:
    asn = 'AS' + str(asn)
else:
    m = re.search(r'AS(\d+)', str(org), re.I)
    asn = 'AS' + m.group(1) if m else 'N/A'

os_name = 'N/A'
try:
    with open('/etc/os-release', encoding='utf-8', errors='ignore') as f:
        for line in f:
            if line.startswith('PRETTY_NAME='):
                os_name = line.split('=', 1)[1].strip().strip('"')
                break
except Exception:
    pass

lines = [
    '# VPS 基础信息',
    '',
    '- 脚本版本：2.6.0-open',
    '- 测试时间：' + sh("date '+%F %T %Z'"),
    '- Hostname：' + sh('hostname'),
    '- Kernel：' + sh('uname -a'),
    '- OS：' + os_name,
    '- CPU：' + sh("awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | sed 's/^ *//'"),
    '- Memory：' + sh("free -h | awk '/Mem:/{print $2}'"),
    '- TCP Congestion：' + sh('sysctl -n net.ipv4.tcp_congestion_control'),
    "- BBR 状态：" + sh("lsmod | grep -q '^tcp_bbr' && echo 已加载/可能可用 || echo 未确认"),
    '',
    '## 出口 IP 与来源地',
    '',
    '- IPv4：' + ip4,
    '- IPv6：' + ip6,
    '- 归属地：' + ' / '.join([country, region, city]),
    '- ASN：' + asn,
    '- 组织/运营商：' + str(org),
    '- 默认网关：' + sh("ip route | awk '/default/ {print $3; exit}'"),
    '- 默认路由观察：' + sh('ip route get 1.1.1.1 | head -n1'),
    '',
    '## IPInfo 原始信息',
    '',
    '```json',
    json.dumps(ipinfo, ensure_ascii=False, indent=2) if ipinfo else '{}',
    '```',
    ''
]
with open(out, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines))
PYCODE
  IP_BRIEF="$(grep -E '^- 归属地：|^- ASN：|^- 组织/运营商：' "$outfile" | sed 's/^- //g' | paste -sd ' | ' - || true)"
  spinner_stop 0 "VPS 基础信息读取完成（含 IP 来源地）"
}

# ---------- 单项测试 ----------
ping_one() {
  local host="$1" count="$2" out loss avg min max mdev limit
  limit=$(( count + 5 ))
  if has_cmd timeout; then out=$(timeout "${limit}s" ping -c "$count" -W 1 "$host" 2>&1 || true); else out=$(ping -c "$count" -W 1 "$host" 2>&1 || true); fi
  loss=$(echo "$out" | awk -F',' '/packet loss/{for(i=1;i<=NF;i++){if($i~/% packet loss/ || $i~/packet loss/){gsub(/[^0-9.]/,"",$i); print $i; exit}}}')
  avg=$(echo "$out" | awk -F'=' '/min\/avg\/max|round-trip/{split($2,a,"/"); gsub(/ /,"",a[2]); print a[2]; exit}')
  min=$(echo "$out" | awk -F'=' '/min\/avg\/max|round-trip/{split($2,a,"/"); gsub(/ /,"",a[1]); print a[1]; exit}')
  max=$(echo "$out" | awk -F'=' '/min\/avg\/max|round-trip/{split($2,a,"/"); gsub(/ /,"",a[3]); print a[3]; exit}')
  mdev=$(echo "$out" | awk -F'=' '/min\/avg\/max|round-trip/{split($2,a,"/"); gsub(/ ms| /,"",a[4]); print a[4]; exit}')
  echo "${loss:-100},${min:-NA},${avg:-NA},${max:-NA},${mdev:-NA}"
}

tcp_connect_one() {
  local host="$1" port="$2" count="$3" tcp_timeout="$4"
  local i start end elapsed ok success=0 sum=0 min=0 max=0 loss avg
  for ((i=0;i<count;i++)); do
    start=$(date +%s%3N 2>/dev/null || date +%s000)
    ok=1
    if has_cmd timeout; then timeout "${tcp_timeout}s" bash -c ': >/dev/tcp/$1/$2' _ "$host" "$port" >/dev/null 2>&1 || ok=0; else bash -c ': >/dev/tcp/$1/$2' _ "$host" "$port" >/dev/null 2>&1 || ok=0; fi
    end=$(date +%s%3N 2>/dev/null || date +%s000)
    elapsed=$(( end - start ))
    if [[ "$ok" -eq 1 ]]; then
      success=$(( success + 1 )); sum=$(( sum + elapsed ))
      if [[ "$min" -eq 0 || "$elapsed" -lt "$min" ]]; then min="$elapsed"; fi
      if [[ "$elapsed" -gt "$max" ]]; then max="$elapsed"; fi
    fi
  done
  loss=$(awk -v c="$count" -v s="$success" 'BEGIN{if(c<=0)print "100.00"; else printf "%.2f", (c-s)/c*100}')
  if [[ "$success" -gt 0 ]]; then avg=$(awk -v sum="$sum" -v s="$success" 'BEGIN{printf "%.2f", sum/s}'); printf '%s,%s,%s,%s,%s\n' "$success" "$loss" "$min" "$avg" "$max"; else printf '0,100,NA,NA,NA\n'; fi
}

calc_target_score() {
  local ping_loss="$1" ping_avg="$2" tcp_loss="$3" tcp_avg="$4"
  awk -v pl="$ping_loss" -v pa="$ping_avg" -v tl="$tcp_loss" -v ta="$tcp_avg" '
    function num(x){ return (x=="NA" || x=="" ? -1 : x+0) }
    function clamp(x){ return x<0?0:(x>100?100:x) }
    BEGIN{
      pln=num(pl); pan=num(pa); tln=num(tl); tan=num(ta);
      if(pln<0) pln=100; if(tln<0) tln=100;
      ps=(pan<0?0:100 - ((pan>45)?(pan-45)*0.12:0) - ((pan>160)?(pan-160)*0.10:0) - ((pln*1.4>45)?45:pln*1.4));
      ts=(tan<0?0:100 - ((tan>50)?(tan-50)*0.10:0) - ((tan>180)?(tan-180)*0.08:0) - ((tln*0.75>40)?40:tln*0.75));
      score=clamp(ps*0.56+ts*0.44); printf "%.1f", score;
    }'
}

run_route_tools() {
  local isp="$1" region="$2" name="$3" host="$4" port="$5" filebase mtr_limit
  filebase="$(safe_name "${isp}_${region}_${name}_${host}")"
  if [[ "$MODE" == "quick" || "$MTR_COUNT" -le 0 ]]; then return 0; fi
  mtr_limit=$(( MTR_COUNT + 30 ))
  if has_cmd mtr; then
    if has_cmd timeout; then timeout "${mtr_limit}s" mtr -rwzc "$MTR_COUNT" "$host" > "$OUT_DIR/mtr/${filebase}.txt" 2>&1 || true; else mtr -rwzc "$MTR_COUNT" "$host" > "$OUT_DIR/mtr/${filebase}.txt" 2>&1 || true; fi
  fi
  if has_cmd traceroute; then
    if has_cmd timeout; then
      timeout 70s traceroute -A -T -p "$port" "$host" > "$OUT_DIR/traceroute/${filebase}_tcp.txt" 2>&1 || timeout 70s traceroute -T -p "$port" "$host" > "$OUT_DIR/traceroute/${filebase}_tcp.txt" 2>&1 || timeout 70s traceroute "$host" > "$OUT_DIR/traceroute/${filebase}.txt" 2>&1 || true
    else
      traceroute -A -T -p "$port" "$host" > "$OUT_DIR/traceroute/${filebase}_tcp.txt" 2>&1 || traceroute -T -p "$port" "$host" > "$OUT_DIR/traceroute/${filebase}_tcp.txt" 2>&1 || traceroute "$host" > "$OUT_DIR/traceroute/${filebase}.txt" 2>&1 || true
    fi
  fi
}

run_latency_tests() {
  local total current isp region name host port pingres tcpres score isp_cn
  local ping_loss ping_min ping_avg ping_max ping_mdev tcp_success tcp_loss tcp_min tcp_avg tcp_max
  total=$(echo "$TARGETS_CSV" | awk 'NR>1{c++}END{print c+0}')
  current=0
  section_title "基础连通测试：Ping / TCP / MTR / Traceroute"
  while IFS=, read -r isp region name host port; do
    [[ "$isp" == "ISP" || -z "$isp" ]] && continue
    current=$((current+1))
    isp_cn=$(isp_name "$isp")
    progress_bar "$current" "$total" "${isp_cn} · ${region} · ${name}"
    pingres=$(ping_one "$host" "$PING_COUNT")
    tcpres=$(tcp_connect_one "$host" "$port" "$TCP_COUNT" "$TCP_TIMEOUT")
    IFS=, read -r ping_loss ping_min ping_avg ping_max ping_mdev <<< "$pingres"
    IFS=, read -r tcp_success tcp_loss tcp_min tcp_avg tcp_max <<< "$tcpres"
    score=$(calc_target_score "$ping_loss" "$ping_avg" "$tcp_loss" "$tcp_avg")
    echo "${isp},${isp_cn},${region},${name},${host},${port},${ping_loss},${ping_min},${ping_avg},${ping_max},${ping_mdev},${tcp_success},${tcp_loss},${tcp_min},${tcp_avg},${tcp_max},${score}" >> "$LATENCY_CSV"
    run_route_tools "$isp" "$region" "$name" "$host" "$port"
  done <<< "$TARGETS_CSV"
  printf '\n'
  log "基础连通测试完成。"
}

# ---------- Ookla ----------
fetch_ookla_servers() {
  local outfile="$1"
  echo 'ISP,ServerID,Name,Sponsor,City,Country,Latitude,Longitude' > "$outfile"
  python3 - "$outfile" <<'PYCODE'
import sys, urllib.request, xml.etree.ElementTree as ET
out=sys.argv[1]
urls=["https://www.speedtest.net/speedtest-servers-static.php","https://www.speedtest.net/speedtest-servers.php"]

def classify(text):
    t=text.lower()
    if any(x in text for x in ["电信", "中國電信", "中国电信"]): return "CT"
    if any(x in text for x in ["联通", "聯通", "中国联通"]): return "CU"
    if any(x in text for x in ["移动", "移動", "中国移动"]): return "CM"
    if "unicom" in t or "cucc" in t: return "CU"
    if "telecom" in t or "chinanet" in t or "ctcc" in t: return "CT"
    if "mobile" in t or "cmcc" in t: return "CM"
    return ""
rows=[]
for url in urls:
    try:
        req=urllib.request.Request(url, headers={"User-Agent":"Mozilla/5.0 LazyVPS-CN3-Test"})
        data=urllib.request.urlopen(req, timeout=20).read()
        root=ET.fromstring(data)
        for server in root.iter('server'):
            a=server.attrib
            country=(a.get('country','') or '').replace(',',' ').strip()
            cc=(a.get('cc','') or '').strip()
            name=(a.get('name','') or '').replace(',',' ').strip()
            sponsor=(a.get('sponsor','') or '').replace(',',' ').strip()
            sid=(a.get('id','') or '').strip()
            lat=(a.get('lat','') or '').strip(); lon=(a.get('lon','') or '').strip()
            text=' '.join([country,cc,name,sponsor])
            is_china=(cc.upper()=='CN' or country.lower()=='china' or '中国' in text or 'china' in text.lower())
            isp=classify(text)
            if sid and is_china and isp:
                rows.append((isp,sid,name,sponsor,name,country,lat,lon))
        if rows: break
    except Exception:
        continue
seen=set(); final=[]
order={"CT":0, "CU":1, "CM":2}
for r in rows:
    if r[1] in seen: continue
    seen.add(r[1]); final.append(r)
final.sort(key=lambda r:(order.get(r[0],9), r[4], r[3], r[1]))
with open(out,'a',encoding='utf-8') as f:
    for r in final:
        f.write(','.join(r)+'\n')
print(len(final))
PYCODE
}

speedtest_parse_json() {
  local json_file="$1" fallback_isp="$2" fallback_sid="$3" fallback_name="$4" fallback_sponsor="$5" fallback_city="$6"
  python3 - "$json_file" "$fallback_isp" "$fallback_sid" "$fallback_name" "$fallback_sponsor" "$fallback_city" <<'PYCODE'
import sys, json
path, isp, sid, name, sponsor, city = sys.argv[1:7]
try:
    with open(path, 'r', encoding='utf-8') as f:
        data=json.load(f)
    ping=data.get('ping',{}).get('latency')
    down=data.get('download',{}).get('bandwidth')
    up=data.get('upload',{}).get('bandwidth')
    server=data.get('server',{})
    sid=str(server.get('id') or sid)
    name=str(server.get('name') or name).replace(',', ' ')
    sponsor=str(server.get('sponsor') or sponsor).replace(',', ' ')
    city=str(server.get('location') or city).replace(',', ' ')
    url=str(data.get('result',{}).get('url') or '')
    down_mbps=(float(down)*8/1_000_000) if down is not None else None
    up_mbps=(float(up)*8/1_000_000) if up is not None else None
    def fmt(x): return 'NA' if x is None else f'{float(x):.2f}'
    print(f"{isp},{sid},{name},{sponsor},{city},{fmt(ping)},{fmt(down_mbps)},{fmt(up_mbps)},{url},OK")
except Exception:
    print(f"{isp},{sid},{name},{sponsor},{city},NA,NA,NA,,FAIL")
PYCODE
}

run_speedtests() {
  if [[ "$RUN_SPEED" -ne 1 || "$SPEED_COUNT" -le 0 ]]; then warn "已选择不执行 Speedtest。"; return 0; fi
  if ! has_cmd speedtest; then warn "未安装 Ookla speedtest，跳过测速。可执行 --install 后重跑。"; return 0; fi

  section_title "Ookla Speedtest 三网测速"
  spinner_start "正在抓取中国区 Ookla 测速点并按三网分类"
  local server_count
  server_count=$(fetch_ookla_servers "$OOKLA_SERVERS_CSV" 2>/dev/null || echo 0)
  server_count="${server_count##*$'\n'}"
  if [[ "${server_count:-0}" -eq 0 ]]; then spinner_stop 1 "未抓到中国区三网测速点，跳过 Speedtest。"; return 0; fi
  spinner_stop 0 "已抓到中国区测速点：${server_count} 个"

  speedtest --accept-license --accept-gdpr --version >/dev/null 2>&1 || true

  local selected="$OUT_DIR/ookla_selected_servers.csv"
  echo 'ISP,ServerID,Name,Sponsor,City,Country,Latitude,Longitude' > "$selected"
  local isp
  for isp in CT CU CM; do awk -F, -v isp="$isp" -v n="$SPEED_COUNT" 'NR>1 && $1==isp {print; c++; if(c>=n) exit}' "$OOKLA_SERVERS_CSV" >> "$selected"; done

  local total current sid name sponsor city country lat lon isp_cn json_file parsed
  local p_isp p_sid p_name p_sponsor p_city p_ping p_down p_up p_url p_status
  total=$(awk 'NR>1{c++}END{print c+0}' "$selected")
  if [[ "$total" -eq 0 ]]; then warn "没有可用的三网测速点，跳过 Speedtest。"; return 0; fi

  current=0
  while IFS=, read -r isp sid name sponsor city country lat lon; do
    [[ "$isp" == "ISP" || -z "$isp" ]] && continue
    current=$((current+1))
    isp_cn=$(isp_name "$isp")
    json_file="$OUT_DIR/speedtest_json/$(safe_name "${isp}_${sid}_${sponsor}_${city}").json"
    spinner_start "测速中 ${current}/${total}：${isp_cn} · ${sponsor} · ${city}"
    if speedtest --accept-license --accept-gdpr -s "$sid" --format=json > "$json_file" 2>"${json_file}.err"; then
      spinner_stop 0 "测速完成 ${isp_cn} · ${sponsor} · ${city}"
    else
      spinner_stop 1 "测速失败 ${isp_cn} · ${sponsor} · ${city}"
    fi
    parsed=$(speedtest_parse_json "$json_file" "$isp" "$sid" "$name" "$sponsor" "$city")
    IFS=, read -r p_isp p_sid p_name p_sponsor p_city p_ping p_down p_up p_url p_status <<< "$parsed"
    echo "${p_isp},${isp_cn},${p_sid},${p_name},${p_sponsor},${p_city},${p_ping},${p_down},${p_up},${p_url},${p_status}" >> "$SPEED_CSV"
    progress_bar "$current" "$total" "Speedtest 进度"
    printf '\n'
  done < "$selected"
  log "Speedtest 测速完成。"
}

# ---------- 路由骨干 ----------
build_route_summary() {
  python3 - "$OUT_DIR/mtr" "$OUT_DIR/traceroute" "$ROUTE_CSV" "$MODE" <<'PYCODE'
import sys, os, glob, csv, re, ipaddress
from collections import Counter, OrderedDict
mtr_dir, tr_dir, out, mode = sys.argv[1:5]
isp_map={'CT':'中国电信','CU':'中国联通','CM':'中国移动'}

RANGES = {
    'CT': [
        ('59.43.0.0/16', 'CN2 精品网', '59.43.*'),
        ('202.97.0.0/16', '电信 163 骨干', '202.97.*'),
        ('203.22.0.0/16', '电信国际 CTG', '203.22.*'),
    ],
    'CU': [
        ('219.158.0.0/16', '联通 169 / AS4837', '219.158.*'),
        ('218.105.0.0/16', '联通 CUII / 9929 疑似', '218.105.*'),
        ('210.51.0.0/16', '联通 CUII / 9929 疑似', '210.51.*'),
        ('210.52.0.0/16', '联通 CUII / 9929 疑似', '210.52.*'),
    ],
    'CM': [
        ('221.183.0.0/16', '移动 CMNET / AS9808', '221.183.*'),
        ('221.176.0.0/16', '移动 CMNET / AS9808', '221.176.*'),
        ('223.120.0.0/15', '移动国际 CMI', '223.120/121.*'),
        ('223.118.0.0/16', '移动国际 CMI', '223.118.*'),
    ],
}

nets = {isp: [(ipaddress.ip_network(cidr), label, feat) for cidr,label,feat in items] for isp,items in RANGES.items()}

def all_ips(text):
    seen=[]
    for m in re.finditer(r'(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])', text):
        ip=m.group(0)
        try:
            ipaddress.ip_address(ip)
        except Exception:
            continue
        if ip not in seen:
            seen.append(ip)
    return seen

def add_label(labels, label):
    if label not in labels:
        labels.append(label)

def detect(isp, text):
    text_l=text.lower()
    labels=[]
    feat_counter=Counter()
    examples=OrderedDict()
    if not text.strip():
        if mode == 'quick':
            return '快速模式未采路由', '请用 --standard / --deep / --route-only 复测', '快速模式不跑 MTR/Traceroute，无法判断骨干。'
        return '无路由样本', '缺 mtr/traceroute 或目标禁止探测', '建议先安装 mtr-tiny traceroute 后重跑。'

    def hit(label, feat, sample=''):
        add_label(labels, label)
        feat_counter[feat]+=1
        if feat not in examples and sample:
            examples[feat]=sample

    # 关键字识别
    if isp=='CT':
        if '59.43.' in text: hit('CN2 精品网', '59.43.*')
        if '202.97.' in text: hit('电信 163 骨干', '202.97.*')
        if 'ctgnet' in text_l or 'chinatelecomglobal' in text_l or 'as4134' in text_l: hit('电信国际/CTG 或 163', 'AS4134/CTG')
    elif isp=='CU':
        if '219.158.' in text or 'as4837' in text_l or 'china169' in text_l: hit('联通 169 / AS4837', '219.158/AS4837')
        if 'as9929' in text_l or 'cuii' in text_l or '218.105.' in text or '210.51.' in text or '210.52.' in text: hit('联通 CUII / 9929 疑似', '9929/CUII')
        if 'as10099' in text_l: hit('联通国际精品 / AS10099', 'AS10099')
    elif isp=='CM':
        if '221.183.' in text or '221.176.' in text or 'as9808' in text_l or 'cmnet' in text_l: hit('移动 CMNET / AS9808', '221.183/221.176')
        if '223.120.' in text or '223.121.' in text or '223.118.' in text or 'chinamobileltd' in text_l or 'cmi' in text_l: hit('移动国际 CMI', '223.120/CMI')

    # IP 前缀识别，统计数量但不把每个 IP 全塞到 CMD
    for ip in all_ips(text):
        obj=ipaddress.ip_address(ip)
        for net,label,feat in nets.get(isp, []):
            if obj in net:
                hit(label, feat, ip)

    if not labels:
        ips=all_ips(text)
        if len(ips)<=2 or text.count('*')>8:
            return '路由隐藏较多', '多跳 * / 信息不足', '建议 deep 模式或人工查看原始路由。'
        return '未命中典型骨干', '未命中 CN2/163/169/9929/CMI 前缀', '可能为普通国际/中转/隐藏路由，需看原始路由。'

    # 压缩关键特征：最多 4 个，不展开长 IP 列表
    parts=[]
    for feat,count in feat_counter.most_common(4):
        sample=examples.get(feat,'')
        if sample:
            parts.append(f'{feat}×{count} 例:{sample}')
        else:
            parts.append(f'{feat}×{count}')
    label_text=' / '.join(labels[:3])
    feat_text='；'.join(parts)
    note='已压缩显示；完整 MTR/Traceroute 请看输出目录。'
    return label_text, feat_text, note

rows=[]
for isp,name in isp_map.items():
    txt=''
    for path in glob.glob(os.path.join(mtr_dir, isp+'_*')) + glob.glob(os.path.join(tr_dir, isp+'_*')):
        try:
            txt += '\n' + open(path, encoding='utf-8', errors='ignore').read()
        except Exception:
            pass
    label, feat, note = detect(isp, txt)
    rows.append([isp, name, label, feat, note])
with open(out,'w',encoding='utf-8',newline='') as f:
    w=csv.writer(f)
    w.writerow(['ISP','运营商','回程骨干识别','关键特征','备注'])
    w.writerows(rows)
PYCODE
}
# ---------- 聚合评分 ----------
aggregate_results() {
  python3 - "$LATENCY_CSV" "$SPEED_CSV" "$OVERVIEW_CSV" <<'PYCODE'
import sys, csv
lat_file, speed_file, out_file = sys.argv[1:4]
isps=[('CT','中国电信'),('CU','中国联通'),('CM','中国移动')]

def num(x):
    try:
        if x is None or str(x).upper()=='NA' or str(x).strip()=='' or str(x).lower()=='nan': return None
        return float(x)
    except Exception:
        return None

def avg(vals):
    vals=[v for v in vals if v is not None]
    return None if not vals else sum(vals)/len(vals)

def clamp(x): return max(0,min(100,x))

def latency_score(avg_ping, loss):
    if avg_ping is None: return 0
    loss = 100 if loss is None else loss
    return clamp(100 - max(0,avg_ping-45)*0.12 - max(0,avg_ping-160)*0.10 - min(45,loss*1.5))

def tcp_score(avg_tcp, success_rate):
    if avg_tcp is None: return 0
    if success_rate is None: success_rate=0
    return clamp(100 - max(0,avg_tcp-50)*0.10 - max(0,avg_tcp-180)*0.08 - max(0,100-success_rate)*0.75)

def speed_score(down, up):
    if down is None and up is None: return None
    down = 0 if down is None else down
    up = 0 if up is None else up
    return clamp(min(down,500)/500*65 + min(up,150)/150*35)

def grade(score):
    if score>=90: return 'A+'
    if score>=82: return 'A'
    if score>=74: return 'B+'
    if score>=66: return 'B'
    if score>=56: return 'C'
    return 'D'

def advice(score):
    if score>=90: return '主力优选，可长期承担中国方向核心流量'
    if score>=82: return '综合优秀，可作为主力使用，晚高峰建议复测'
    if score>=74: return '整体良好，可兼顾主力与备用场景'
    if score>=66: return '中等偏上，可用性尚可，建议结合业务再判断'
    if score>=56: return '基础可用，更适合作为备用或轻量线路'
    return '波动或样本偏弱，建议结合路由与高峰复测再判断'

def report_comment(score, ping, loss, tcp, tcp_ok, down, up):
    parts=[]
    if score>=82:
        parts.append('本轮样本中该网络方向表现突出')
    elif score>=66:
        parts.append('本轮样本中该网络方向整体可用')
    else:
        parts.append('本轮样本中该网络方向表现相对偏弱')
    if ping is not None:
        if ping<=70: parts.append('时延控制较好')
        elif ping<=120: parts.append('时延处于可接受区间')
        else: parts.append('时延偏高，远程交互体验需关注')
    if loss is not None:
        if loss<=2: parts.append('丢包表现稳定')
        elif loss<=8: parts.append('存在轻微丢包波动')
        else: parts.append('丢包偏明显，稳定性需重点复核')
    if tcp_ok is not None:
        if tcp_ok>=90: parts.append('TCP 连通性较强')
        elif tcp_ok>=70: parts.append('TCP 连通性尚可')
        else: parts.append('TCP 连通成功率偏低')
    if down is not None:
        if down>=250: parts.append('跨境下载能力较强')
        elif down>=80: parts.append('跨境速率处于中等水平')
        else: parts.append('跨境速率偏保守')
    return '，'.join(parts) + '。'

lat_rows=[]
with open(lat_file,encoding='utf-8') as f:
    for r in csv.DictReader(f): lat_rows.append(r)
speed_rows=[]
try:
    with open(speed_file,encoding='utf-8') as f:
        for r in csv.DictReader(f): speed_rows.append(r)
except FileNotFoundError:
    pass

rows=[]
for isp, name in isps:
    l=[r for r in lat_rows if r.get('ISP')==isp]
    pings=[num(r.get('Ping平均ms')) for r in l]
    losses=[num(r.get('Ping丢包%')) for r in l]
    tcps=[num(r.get('TCP平均ms')) for r in l]
    tcp_losses=[num(r.get('TCP失败率%')) for r in l]
    scores=[num(r.get('目标评分')) for r in l]
    avg_ping=avg(pings); avg_loss=avg(losses); avg_tcp=avg(tcps)
    tcp_ok = None if not tcp_losses else 100 - avg([x for x in tcp_losses if x is not None])
    s=[r for r in speed_rows if r.get('ISP')==isp and r.get('状态')=='OK']
    downs=[num(r.get('下载Mbps')) for r in s]
    ups=[num(r.get('上传Mbps')) for r in s]
    avg_down=avg(downs); avg_up=avg(ups)
    ls=avg(scores)
    if ls is None:
        ls=latency_score(avg_ping, avg_loss)*0.56 + tcp_score(avg_tcp, tcp_ok)*0.44
    ss=speed_score(avg_down, avg_up)
    total=clamp(ls) if ss is None else clamp(ls*0.72 + ss*0.28)
    fmt=lambda x: 'NA' if x is None else f'{x:.2f}'
    rows.append({
      'ISP':isp,'运营商':name,'目标数':len(l),'平均Pingms':fmt(avg_ping),'平均Ping丢包%':fmt(avg_loss),'平均TCPms':fmt(avg_tcp),
      'TCP成功率%':fmt(tcp_ok),'测速点数':len(s),'平均下载Mbps':fmt(avg_down),'平均上传Mbps':fmt(avg_up),
      '综合评分':f'{total:.1f}','评级':grade(total),'建议':advice(total),'报告评语':report_comment(total,avg_ping,avg_loss,avg_tcp,tcp_ok,avg_down,avg_up)
    })
rows.sort(key=lambda r: float(r['综合评分']), reverse=True)
for i,row in enumerate(rows, start=1): row['排名']=str(i)
with open(out_file,'w',encoding='utf-8',newline='') as f:
    fields=['排名','ISP','运营商','目标数','平均Pingms','平均Ping丢包%','平均TCPms','TCP成功率%','测速点数','平均下载Mbps','平均上传Mbps','综合评分','评级','建议','报告评语']
    w=csv.DictWriter(f, fieldnames=fields)
    w.writeheader(); w.writerows(rows)
PYCODE
}

# ---------- 报告 ----------
make_markdown_report() {
  python3 - "$BASEINFO_MD" "$LATENCY_CSV" "$SPEED_CSV" "$OVERVIEW_CSV" "$ROUTE_CSV" "$REPORT_MD" "$MODE" <<'PYCODE'
import sys, csv, os
base, lat, speed, overview, route_csv, report, mode = sys.argv[1:8]

def read_file(p):
    try: return open(p,encoding='utf-8').read()
    except Exception: return ''

def md_table(csv_path, max_rows=None):
    try:
        with open(csv_path,encoding='utf-8') as f: rows=list(csv.reader(f))
    except Exception:
        return '_无数据_\n'
    if not rows: return '_无数据_\n'
    header=rows[0]
    body=rows[1:] if max_rows is None else rows[1:1+max_rows]
    out=[]
    out.append('| ' + ' | '.join(header) + ' |')
    out.append('| ' + ' | '.join(['---']*len(header)) + ' |')
    for r in body:
        r=(r+['']*len(header))[:len(header)]
        out.append('| ' + ' | '.join(x.replace('|','/') for x in r) + ' |')
    if max_rows is not None and len(rows)-1>max_rows:
        out.append(f'\n> 仅展示前 {max_rows} 行，完整数据见 CSV。')
    return '\n'.join(out)+'\n'

with open(report,'w',encoding='utf-8') as f:
    f.write('# 中国三网 VPS 综合测试报告\n\n')
    f.write(f'- 测试模式：{mode}\n')
    f.write(f'- 输出目录：`{os.path.basename(os.path.dirname(report))}`\n')
    f.write('- 口径说明：本测试面向 VPS 中国方向网络质量评估，**非家宽评分口径**。\n')
    f.write('- 注意：综合评分与评级仅供参考，请结合高峰复测、业务类型、回程路由与稳定性综合判断。\n\n')
    f.write('## 1. 三网综合评分总表\n\n'); f.write(md_table(overview))
    f.write('\n## 2. 路由骨干观察摘要\n\n'); f.write(md_table(route_csv))
    f.write('\n## 3. VPS 基础信息与出口来源地\n\n'); f.write(read_file(base))
    f.write('\n## 4. Ping / TCP 连通明细\n\n'); f.write(md_table(lat, max_rows=80))
    f.write('\n## 5. Ookla Speedtest 明细\n\n'); f.write(md_table(speed, max_rows=30))
    f.write('\n## 6. 结果解读说明\n\n')
    f.write('- 本脚本优先看的是 VPS 对中国三网方向的网络质量，不是家用宽带跑满带宽的考核模型。\n')
    f.write('- DNS/官网目标可能存在禁 Ping、CDN 调度或 ICMP 限制，不能单项定结论。\n')
    f.write('- 路由骨干识别基于 MTR / Traceroute 关键字自动判断，仅适合粗判回程特征。\n')
    f.write('- 建议至少对比 **普通时段** 与 **晚高峰** 两轮结果，再决定是否作为主力线路。\n')
PYCODE
}

score_band_name() {
  local s="${1:-0}"
  awk -v x="$s" 'BEGIN{
    if(x>=90) print "优秀主力";
    else if(x>=82) print "主力观察";
    else if(x>=74) print "良好可用";
    else if(x>=66) print "可用观察";
    else if(x>=56) print "备用轻量";
    else print "谨慎使用";
  }'
}

score_ladder_compact() {
  local score="${1:-0}" isp="${2:-}"
  local c
  c=$(color_by_score "$score")
  printf '│ %-8s │ %s%-54s%s │ %-8s │\n' "$isp" "$c" "$(bar_pct "$score" 100 28)" "$RESET" "$(score_band_name "$score")"
}

short_text() {
  local txt="$1" max="${2:-28}"
  python3 - "$txt" "$max" <<'PYCODE'
import sys
s=sys.argv[1]
max_len=int(sys.argv[2])
print(s if len(s)<=max_len else s[:max_len-1]+'…')
PYCODE
}
# ---------- 结果面板 ----------
isp_name() {
  case "$1" in
    CT) printf '中国电信' ;;
    CU) printf '中国联通' ;;
    CM) printf '中国移动' ;;
    *) printf '%s' "$1" ;;
  esac
}

isp_emoji() {
  case "$1" in
    CT) printf '🟦' ;;
    CU) printf '🟨' ;;
    CM) printf '🟩' ;;
    *) printf '⬜' ;;
  esac
}

render_summary_screen() {
  clear_screen
  banner
  section_title "测试完成：CMD 对齐表格 + 组合柱状图"
  info_note "VPS 中国方向评估；CMD 只展示整理后的可视化结果，完整长路由已放到 mtr/ 与 traceroute/。"
  if [[ -n "${IP_BRIEF:-}" ]]; then info_note "出口来源地：${IP_BRIEF}"; fi
  printf '\n'

  if [[ ! -s "$OVERVIEW_CSV" ]]; then warn "没有生成总表。"; return 0; fi

  python3 - "$OVERVIEW_CSV" "$ROUTE_CSV" "$REPORT_MD" "$LATENCY_CSV" "$SPEED_CSV" "$OUT_DIR" <<'PYCODE'
import sys, csv, re, math, unicodedata

overview, route_csv, report_md, latency_csv, speed_csv, out_dir = sys.argv[1:7]
RESET="\033[0m"; BOLD="\033[1m"; DIM="\033[2m"
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; MAGENTA="\033[35m"; CYAN="\033[36m"; WHITE="\033[37m"

ansi_re=re.compile(r'\x1b\[[0-9;]*m')

def strip_ansi(s):
    return ansi_re.sub('', str(s))

def dw(s):
    s=strip_ansi(str(s))
    total=0
    for ch in s:
        if unicodedata.combining(ch):
            continue
        if unicodedata.east_asian_width(ch) in ('F','W'):
            total += 2
        else:
            total += 1
    return total

def fit(s, width):
    s=str(s)
    raw=strip_ansi(s)
    if dw(raw) <= width:
        return s + ' ' * (width - dw(raw))
    out=''
    cur=0
    for ch in raw:
        w=2 if unicodedata.east_asian_width(ch) in ('F','W') else 1
        if cur + w > max(0,width-1):
            break
        out += ch
        cur += w
    return out + '…' + ' ' * max(0, width - cur - 1)

def right(s, width):
    s=str(s)
    return ' ' * max(0, width-dw(s)) + s

def center(s, width):
    s=str(s); pad=max(0, width-dw(s)); l=pad//2; r=pad-l
    return ' '*l + s + ' '*r

def score_color(x):
    try: x=float(x)
    except: x=0
    if x>=82: return GREEN
    if x>=66: return CYAN
    if x>=56: return YELLOW
    return RED

def risk_color_good_pct(x):
    try: x=float(x)
    except: x=0
    if x>=90: return GREEN
    if x>=70: return CYAN
    if x>=50: return YELLOW
    return RED

def loss_color(x):
    try: x=float(x)
    except: x=100
    if x<=2: return GREEN
    if x<=8: return CYAN
    if x<=20: return YELLOW
    return RED

def grade_pos(score):
    try: s=float(score)
    except: s=0
    if s>=90: return 'A+主力'
    if s>=82: return 'A主力'
    if s>=74: return 'B+良好'
    if s>=66: return 'B可用'
    if s>=56: return 'C备用'
    return 'D谨慎'

def usage_label(score):
    try: s=float(score)
    except: s=0
    if s>=82: return '主力'
    if s>=66: return '观察'
    if s>=56: return '备用'
    return '轻量'

def bar(value, width=18, invert=False):
    try: v=float(value)
    except: v=0
    v=max(0,min(100,v))
    n=round(v/100*width)
    col=score_color(v) if not invert else loss_color(v)
    return col + '█'*n + DIM + '░'*(width-n) + RESET

def metric_bar(value, maxv, width=12, lower_is_better=False):
    try: v=float(value)
    except: return DIM + '░'*width + RESET
    pct=max(0,min(100, v/maxv*100 if maxv else 0))
    if lower_is_better:
        if v<=70: col=GREEN
        elif v<=120: col=CYAN
        elif v<=180: col=YELLOW
        else: col=RED
    else:
        if pct>=80: col=GREEN
        elif pct>=50: col=CYAN
        elif pct>=25: col=YELLOW
        else: col=RED
    n=round(pct/100*width)
    return col+'█'*n+DIM+'░'*(width-n)+RESET

def read_csv(p):
    try:
        with open(p, encoding='utf-8') as f:
            return list(csv.DictReader(f))
    except Exception:
        return []

rows=read_csv(overview)
routes=read_csv(route_csv)
route_map={r.get('ISP',''):{'backbone':r.get('回程骨干识别',''), 'feature':r.get('关键特征','')} for r in routes}

# Ensure numeric sort
def sc(r):
    try: return float(r.get('综合评分') or 0)
    except: return 0
rows.sort(key=sc, reverse=True)

def route_short(isp):
    r=route_map.get(isp,{})
    bb=r.get('backbone') or '未识别'
    # simplify readable labels
    reps=[
        ('电信国际/CTG 或 163 出口','电信CTG/163'),
        ('电信 163 骨干','电信163'),
        ('CN2 精品网','CN2'),
        ('联通 169 骨干 / AS4837','联通169/4837'),
        ('联通 A 网 / CUII / 9929 疑似','联通9929/CUII'),
        ('联通国际精品 / AS10099','联通AS10099'),
        ('移动 CMNET 骨干 / AS9808','移动CMNET'),
        ('移动国际 CMI','移动CMI'),
        ('快速模式未执行路由采样','未采样'),
        ('未识别到典型骨干标记','需人工核对'),
        ('路由隐藏较多，暂无法自动识别','隐藏较多'),
    ]
    for a,b in reps:
        bb=bb.replace(a,b)
    bb=bb.replace(' / ','+')
    return bb

def feature_short(isp):
    ft=(route_map.get(isp,{}) or {}).get('feature','') or '无'
    # keep only first meaningful tokens, avoid long IP flood
    tokens=[]
    for key in ['59.43','202.97','219.158','218.105','210.51','210.52','221.183','221.176','223.120','223.121','223.118','AS4837','AS9929','AS9808','CTG','CMI']:
        if key.lower() in ft.lower() and key not in tokens:
            tokens.append(key)
    if tokens:
        return '/'.join(tokens[:6])
    if '快速模式' in ft:
        return '需标准/深度'
    if '人工查看' in ft:
        return '看原始路由'
    return '样本不足'

def line(w=118):
    print(CYAN + '+' + '-'*(w-2) + '+' + RESET)

print(CYAN + '+' + '-'*116 + '+' + RESET)
print(CYAN + '|' + center('中国三网 VPS 可视化仪表盘（CMD 对齐版）',116) + '|' + RESET)
print(CYAN + '+' + '-'*116 + '+' + RESET)

# Table 1
cols=[('排',4),('运营商',10),('评分',7),('级别',6),('定位',8),('Ping',10),('丢包',8),('TCP',8),('下载/上传',16),('回程骨干',20)]
width=sum(w for _,w in cols)+len(cols)+1
print('\n'+CYAN+'+'+'+'.join('-'*w for _,w in cols)+'+'+RESET)
print(CYAN+'|'+'|'.join(center(h,w) for h,w in cols)+'|'+RESET)
print(CYAN+'+'+'+'.join('-'*w for _,w in cols)+'+'+RESET)
for idx,r in enumerate(rows, start=1):
    score=r.get('综合评分','0')
    col=score_color(score)
    rank='🏆1' if idx==1 else str(idx)
    ping=(r.get('平均Pingms') or 'NA')+'ms'
    loss=(r.get('平均Ping丢包%') or 'NA')+'%'
    tcp=(r.get('TCP成功率%') or 'NA')+'%'
    sp=(r.get('平均下载Mbps') or 'NA')+'/'+(r.get('平均上传Mbps') or 'NA')
    cells=[
        rank,
        r.get('运营商',''),
        col+right(score,5)+RESET,
        col+fit(r.get('评级',''),4)+RESET,
        usage_label(score),
        ping,
        loss_color(r.get('平均Ping丢包%'))+fit(loss,7)+RESET,
        risk_color_good_pct(r.get('TCP成功率%'))+fit(tcp,7)+RESET,
        sp,
        route_short(r.get('ISP','')),
    ]
    print(CYAN+'|'+ '|'.join(fit(c,w) for c,(_,w) in zip(cells,cols)) + '|' + RESET)
print(CYAN+'+'+'+'.join('-'*w for _,w in cols)+'+'+RESET)

# Combined bar chart
print('\n'+CYAN+'+'+'-'*116+'+'+RESET)
print(CYAN+'|'+center('柱状组合图：综合评分 + 延迟/丢包/TCP/下载',116)+'|'+RESET)
print(CYAN+'+'+'-'*116+'+'+RESET)
for r in rows:
    isp=fit(r.get('运营商',''),8)
    score=r.get('综合评分','0')
    ping=r.get('平均Pingms','NA')
    loss=r.get('平均Ping丢包%','NA')
    tcp=r.get('TCP成功率%','NA')
    down=r.get('平均下载Mbps','NA')
    print(
        f"{CYAN}|{RESET} {isp} "
        f"总分 {bar(score,22)} {right(score,5)}  "
        f"Ping {metric_bar(ping,180,10,True)} {right(ping,6)}ms  "
        f"丢包 {metric_bar(loss,50,10,False)} {right(loss,6)}%  "
        f"TCP {metric_bar(tcp,100,10,False)} {right(tcp,6)}%  "
        f"下载 {metric_bar(down,500,10,False)} {right(down,7)}Mbps"
    )
print(CYAN+'+'+'-'*116+'+'+RESET)
print(DIM+'  评分区间：D≤55 | C 56-65 | B 66-73 | B+ 74-81 | A 82-89 | A+ ≥90；测速为 VPS 中国方向口径。'+RESET)

# Backbone compact table
cols2=[('运营商',10),('骨干判断',28),('关键命中',28),('阅读建议',36)]
print('\n'+CYAN+'+'+'+'.join('-'*w for _,w in cols2)+'+'+RESET)
print(CYAN+'|'+'|'.join(center(h,w) for h,w in cols2)+'|'+RESET)
print(CYAN+'+'+'+'.join('-'*w for _,w in cols2)+'+'+RESET)
for r in rows:
    isp=r.get('ISP','')
    bb=route_short(isp)
    ft=feature_short(isp)
    if bb in ['未采样','隐藏较多','需人工核对','未识别']:
        tip='建议 --deep 后人工看 traceroute'
    elif 'CN2' in bb or '9929' in bb or 'CMI' in bb:
        tip='疑似优质/国际骨干，建议高峰复核'
    elif '163' in bb or '169' in bb or 'CMNET' in bb:
        tip='普通骨干，重点看晚高峰拥塞'
    else:
        tip='结合 MTR 原始结果判断'
    cells=[r.get('运营商',''),bb,ft,tip]
    print(CYAN+'|'+ '|'.join(fit(c,w) for c,(_,w) in zip(cells,cols2)) + '|' + RESET)
print(CYAN+'+'+'+'.join('-'*w for _,w in cols2)+'+'+RESET)

# Report conclusion compact
print('\n'+CYAN+'+'+'-'*116+'+'+RESET)
print(CYAN+'|'+center('报告式结论（CMD 精简版）',116)+'|'+RESET)
print(CYAN+'+'+'-'*116+'+'+RESET)
for r in rows:
    msg=f"{r.get('运营商')}：{r.get('综合评分')}分 / {r.get('评级')} / {grade_pos(r.get('综合评分'))}；Ping {r.get('平均Pingms')}ms，丢包 {r.get('平均Ping丢包%')}%，TCP {r.get('TCP成功率%')}%；{r.get('建议')}"
    print(f"- {msg}")
if rows:
    top=rows[0]
    print(f"\n一句话：本轮优先看 {top.get('运营商')}，综合 {top.get('综合评分')} 分；是否做主力仍建议晚高峰 + 业务实测确认。")
print()

print(CYAN+'+'+'-'*116+'+'+RESET)
print(CYAN+'|'+center('输出文件',116)+'|'+RESET)
print(CYAN+'+'+'-'*116+'+'+RESET)
print(f"  - Markdown 报告：{report_md}")
print(f"  - 总表 CSV：{overview}")
print(f"  - 路由摘要：{route_csv}")
print(f"  - 延迟明细：{latency_csv}")
print(f"  - 测速明细：{speed_csv}")
print(f"  - MTR/Traceroute 原始路由：{out_dir}/{{mtr,traceroute}}")
print()
PYCODE
}

# ---------- 主流程 ----------
run_all() {
  if [[ "$INSTALL_DEPS" -eq 1 ]]; then install_deps; fi
  check_deps
  prepare_outdir
  banner
  printf '%s测试模式：%s%s%s\n' "$BOLD" "$CYAN" "$MODE" "$RESET"
  printf '%s输出目录：%s%s%s\n' "$BOLD" "$CYAN" "$OUT_DIR" "$RESET"
  printf '%s采样参数：Ping=%s 次 / TCP=%s 次 / MTR=%s 包 / Speedtest每网=%s 个%s\n' "$DIM" "$PING_COUNT" "$TCP_COUNT" "$MTR_COUNT" "$SPEED_COUNT" "$RESET"
  info_note '本脚本评估的是 VPS 对中国三网方向的综合网络质量，并非家用宽带测速模型。'
  info_note '综合评分与评级仅供参考，建议结合晚高峰复测、业务类型与回程骨干观察综合判断。'
  printf '\n'

  public_ip_info "$BASEINFO_MD"
  run_latency_tests
  run_speedtests
  build_route_summary
  aggregate_results
  make_markdown_report
  render_summary_screen
}

main() {
  parse_args "$@"
  if [[ "$NON_INTERACTIVE" -eq 0 ]]; then interactive_menu; fi
  run_all
}

main "$@"
