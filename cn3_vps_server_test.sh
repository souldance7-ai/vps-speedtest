#!/usr/bin/env bash
# =====================================================================
# LazyVPS CN3 VPS SpeedTest Official
# 中国电信 / 中国联通 / 中国移动 三网 VPS 网络质量测试脚本（非家宽口径）
# License: MIT
# Version: 2.1.0
# =====================================================================

set -Eeuo pipefail

VERSION="2.1.0"
RELEASE_NAME="全量容量压测 · SVG Pro"
REPO_SLUG="souldance7-ai/vps-speedtest"
SCRIPT_NAME="CN3 VPS 三网综合测试（VPS版）"
MODE="standard"          # quick / standard / deep / capacity / route
RUN_SPEED=1
RUN_CAPACITY=1
CAPACITY_ONLY=0
INSTALL_DEPS=0
PING_COUNT=10
TCP_COUNT=3
TCP_TIMEOUT=2
MTR_COUNT=20
SPEED_COUNT=2
CAP_THREADS=8
CAP_SINGLE_SECONDS=6
CAP_MULTI_SECONDS=8
CAP_HTTP_SAMPLES=20
CAP_ENDPOINT="https://speed.cloudflare.com"
CAP_PING_HOST="1.1.1.1"
CAP_UPLOAD_CHUNK_MB=8
OUT_BASE=""
NON_INTERACTIVE=0
QUIET=0
SPINNER_PID=""
IP_BRIEF=""
BANNER_SEEN=0
ANIMATE=1
[[ -n "${NO_ANIMATION:-}" || ! -t 1 ]] && ANIMATE=0

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
  BG_DARK=$'\033[48;5;234m'; BG_PANEL=$'\033[48;5;236m'; BG_BLUE=$'\033[48;5;24m'; BG_SELECT=$'\033[48;5;58m'; BG_RED=$'\033[48;5;52m'; BG_GREEN=$'\033[48;5;22m'
else
  RESET=""; BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; WHITE=""
  BG_DARK=""; BG_PANEL=""; BG_BLUE=""; BG_SELECT=""; BG_RED=""; BG_GREEN=""
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
terminal_width() {
  local cols=92
  if has_cmd tput && [[ -t 1 ]]; then cols="$(tput cols 2>/dev/null || printf '92')"; fi
  (( cols > 100 )) && cols=100
  (( cols < 72 )) && cols=72
  printf '%s' "$cols"
}
hr() { repeat_char '=' "${1:-$(terminal_width)}"; }
clear_screen() { [[ "$QUIET" -eq 0 && -t 1 ]] && clear || true; }
safe_name() { local s="$*"; s="${s// /_}"; s="${s//\//_}"; s="${s//:/_}"; s="${s//,/}"; s="${s//(/}"; s="${s//)/}"; printf '%s' "$s" | tr -cd '[:alnum:]_.@%+=\-一-龥'; }
strip_ansi() { sed -E 's/\x1B\[[0-9;]*[mK]//g'; }
pad_display() {
  local text="$1" width="$2"
  if has_cmd python3; then
    python3 - "$text" "$width" <<'PYCODE'
import sys, unicodedata
s=sys.argv[1]
target=int(sys.argv[2])
def cw(ch): return 2 if unicodedata.east_asian_width(ch) in ('W','F') else 1
out=[]; used=0
for ch in s:
    w=cw(ch)
    if used+w>target: break
    out.append(ch); used+=w
sys.stdout.write(''.join(out)+' '*(target-used))
PYCODE
  else
    printf "%-${width}s" "$text"
  fi
}

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

# ---------- ANSI / ASCII 封面 ----------
logo_art() {
  cat <<'EOF_LOGO'
██╗      █████╗ ███████╗██╗   ██╗██╗   ██╗██████╗ ███████╗
██║     ██╔══██╗╚══███╔╝╚██╗ ██╔╝██║   ██║██╔══██╗██╔════╝
██║     ███████║  ███╔╝  ╚████╔╝ ██║   ██║██████╔╝███████╗
██║     ██╔══██║ ███╔╝    ╚██╔╝  ╚██╗ ██╔╝██╔═══╝ ╚════██║
███████╗██║  ██║███████╗   ██║    ╚████╔╝ ██║     ███████║
╚══════╝╚═╝  ╚═╝╚══════╝   ╚═╝     ╚═══╝  ╚═╝     ╚══════╝
EOF_LOGO
}

horse_art() {
  cat <<'EOF_HORSE'
       /\_/|        /\_/|        /\_/|        /\_/|
  ____/ o o\   ____/ o o\   ____/ o o\   ____/ o o\
 / __      /  / __      /  / __      /  / __      /
/_/  \_/\_/  /_/  \_/\_/  /_/  \_/\_/  /_/  \_/\_/   万马奔腾
  /_/  /_/     /_/  /_/     /_/  /_/     /_/  /_/
EOF_HORSE
}

ansi_rule() {
  local width="${1:-$(terminal_width)}" ch="${2:--}"
  printf '%s' "$CYAN"
  repeat_char "$ch" "$width"
  printf '%s\n' "$RESET"
}

banner() {
  clear_screen
  local width line idx=0
  width="$(terminal_width)"
  ansi_rule "$width" "═"
  while IFS= read -r line; do
    case "$idx" in
      0|1) printf '%s%s%s\n' "$CYAN" "$line" "$RESET" ;;
      2|3) printf '%s%s%s\n' "$BLUE" "$line" "$RESET" ;;
      *)   printf '%s%s%s\n' "$MAGENTA" "$line" "$RESET" ;;
    esac
    if [[ "$ANIMATE" -eq 1 && "$BANNER_SEEN" -eq 0 ]]; then sleep 0.035; fi
    idx=$((idx + 1))
  done < <(logo_art)
  printf '%s' "$DIM"
  horse_art
  printf '%s' "$RESET"
  ansi_rule "$width" "─"
  printf '%s%sLazyVPS CN3 SpeedTest%s  %sv%s · %s%s\n' "$BOLD" "$WHITE" "$RESET" "$CYAN" "$VERSION" "$RELEASE_NAME" "$RESET"
  printf '%s中国电信 CT  /  中国联通 CU  /  中国移动 CM%s\n' "$CYAN" "$RESET"
  printf '%s单线/多线/峰值上下行 · HTTP P50/P95 · 丢包抖动 · 三网回程 · SVG%s\n' "$DIM" "$RESET"
  ansi_rule "$width" "═"
  printf '\n'
  BANNER_SEEN=1
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
${SCRIPT_NAME} v${VERSION} · ${RELEASE_NAME}

用法：
  bash cn3_vps_server_test.sh [选项]

交互模式：
  bash cn3_vps_server_test.sh

常用命令：
  bash cn3_vps_server_test.sh --install --standard
  bash cn3_vps_server_test.sh --quick
  bash cn3_vps_server_test.sh --deep
  bash cn3_vps_server_test.sh --capacity-only
  bash cn3_vps_server_test.sh --route-only
  bash cn3_vps_server_test.sh --standard --no-speed

容量压测参数：
  --capacity-threads N          多线程数（默认随模式：4 / 8 / 12）
  --capacity-single-seconds N   单线持续秒数
  --capacity-multi-seconds N    多线持续秒数
  --http-samples N              HTTP 延迟采样数
  --capacity-endpoint URL       容量测试端点（默认 Cloudflare Speed）
  --capacity-ping-host HOST     ICMP 对照目标（默认 1.1.1.1）
  --no-capacity                 跳过容量压测，仅执行原三网测试

说明：
  - 本脚本用于 VPS 中国方向网络质量评估，不按家宽跑满带宽的标准打分。
  - 容量压测会产生实际上下行流量；流量受线程数、时长与线路能力影响。
  - 自定义端点需兼容 /__down、/__up 与 /cdn-cgi/trace 路径。
  - 每次测试自动输出终端仪表板、CSV、JSON、Markdown 与 report.svg。
  - 综合评分与评级仅供参考，请结合晚高峰复测、业务场景与回程路由综合判断。
USAGE
}

choose_mode_by_arrow() {
  # BBS信息板 菜单：只高亮当前选项，不再每行铺满底色，避免 CMD 视觉混乱
  local selected=2
  local key rest
  MENU_CHOICE=""

  while true; do
    banner
    printf '%s%s 选择测试任务%s\n' "$BOLD" "$WHITE" "$RESET"
    printf '%s数字直选 · ↑↓ / W/S 移动 · Enter 确认 · Q 退出%s\n\n' "$DIM" "$RESET"

    local items=(
      "1|快速体验|容量轻测 + 每网 1 点 · 快速筛选"
      "2|标准综合|8 线程容量 + 三网完整测试 · 日常推荐"
      "3|深度三网|12 线程容量 + 加强采样 · 高峰留档"
      "4|容量压测|只测单线/多线/峰值上下行、HTTP/ICMP 品质"
      "5|路由延迟|不跑容量与 Speedtest · MTR / 骨干识别"
      "6|安装依赖|补齐 curl / Python / MTR / Ookla Speedtest"
      "7|帮助说明|参数、输出文件与评分口径"
      "0|安全退出|不执行测试，也不改动系统"
    )

    printf '%s┌%s┐%s\n' "$CYAN" "$(repeat_char '─' 90)" "$RESET"
    local item num title desc prefix line_color title_pad desc_pad
    for item in "${items[@]}"; do
      IFS='|' read -r num title desc <<< "$item"
      if [[ "$num" -eq "$selected" ]]; then
        prefix="▶"
        line_color="$YELLOW$BOLD"
      else
        prefix="·"
        line_color="$WHITE"
      fi
      title_pad="$(pad_display "$title" 10)"
      desc_pad="$(pad_display "$desc" 68)"
      printf '%s│ %s  [%s] %s │ %s │%s\n' "$line_color" "$prefix" "$num" "$title_pad" "$desc_pad" "$RESET"
    done
    printf '%s└%s┘%s\n' "$CYAN" "$(repeat_char '─' 90)" "$RESET"

    printf '\n%sREADY%s  当前 [%s]  %s↑↓ / W/S · Enter · Q%s ' "$GREEN" "$RESET" "$selected" "$DIM" "$RESET"

    IFS= read -rsn1 key || key=""
    case "$key" in
      "")
        printf '\n'
        MENU_CHOICE="$selected"
        return 0
        ;;
      $'\x1b')
        IFS= read -rsn2 -t 0.05 rest || rest=""
        case "$rest" in
          "[A") selected=$((selected-1)); [[ "$selected" -lt 0 ]] && selected=7 ;;
          "[B") selected=$((selected+1)); [[ "$selected" -gt 7 ]] && selected=0 ;;
        esac
        ;;
      [0-7])
        printf '\n'
        MENU_CHOICE="$key"
        return 0
        ;;
      w|W|k|K)
        selected=$((selected-1)); [[ "$selected" -lt 0 ]] && selected=7 ;;
      s|S|j|J)
        selected=$((selected+1)); [[ "$selected" -gt 7 ]] && selected=0 ;;
      q|Q)
        printf '\n'
        MENU_CHOICE="0"
        return 0 ;;
    esac
  done
}


set_mode_from_option() {
  local opt="$1"
  case "$opt" in
    1)
      MODE="quick"; PING_COUNT=5; TCP_COUNT=2; MTR_COUNT=0; SPEED_COUNT=1; RUN_SPEED=1
      RUN_CAPACITY=1; CAPACITY_ONLY=0; CAP_THREADS=4; CAP_SINGLE_SECONDS=4; CAP_MULTI_SECONDS=5; CAP_HTTP_SAMPLES=12
      ;;
    2)
      MODE="standard"; PING_COUNT=10; TCP_COUNT=3; MTR_COUNT=20; SPEED_COUNT=2; RUN_SPEED=1
      RUN_CAPACITY=1; CAPACITY_ONLY=0; CAP_THREADS=8; CAP_SINGLE_SECONDS=6; CAP_MULTI_SECONDS=8; CAP_HTTP_SAMPLES=20
      ;;
    3)
      MODE="deep"; PING_COUNT=20; TCP_COUNT=5; MTR_COUNT=50; SPEED_COUNT=3; RUN_SPEED=1
      RUN_CAPACITY=1; CAPACITY_ONLY=0; CAP_THREADS=12; CAP_SINGLE_SECONDS=10; CAP_MULTI_SECONDS=14; CAP_HTTP_SAMPLES=40
      ;;
    4)
      MODE="capacity"; PING_COUNT=0; TCP_COUNT=0; MTR_COUNT=0; SPEED_COUNT=0; RUN_SPEED=0
      RUN_CAPACITY=1; CAPACITY_ONLY=1; CAP_THREADS=12; CAP_SINGLE_SECONDS=8; CAP_MULTI_SECONDS=12; CAP_HTTP_SAMPLES=30
      ;;
    5)
      MODE="route"; PING_COUNT=15; TCP_COUNT=4; MTR_COUNT=30; SPEED_COUNT=0; RUN_SPEED=0
      RUN_CAPACITY=0; CAPACITY_ONLY=0
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
      choose_mode_by_arrow
      opt="${MENU_CHOICE:-2}"
    else
      banner
      cat <<MENU
请选择测试模式：

  1) 快速体验测试
  2) 标准综合测试（推荐）
  3) 深度三网测试
  4) 仅容量压力测试
  5) 仅延迟路由测试
  6) 安装/补齐依赖
  7) 帮助说明
  0) 退出

MENU
      printf '请输入选项 [默认 2]：'
      read -r opt || opt="2"
      opt="${opt:-2}"
    fi

    case "$opt" in
      1|2|3|4|5)
        set_mode_from_option "$opt"
        break
        ;;
      6)
        install_deps
        printf '\n按 Enter 返回菜单...'
        read -r _ || true
        ;;
      7)
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
  if [[ "$RUN_CAPACITY" -eq 1 ]]; then
    printf '%s容量参数：单线=%ss / 多线=%ss / 线程=%s / HTTP样本=%s%s\n' "$DIM" "$CAP_SINGLE_SECONDS" "$CAP_MULTI_SECONDS" "$CAP_THREADS" "$CAP_HTTP_SAMPLES" "$RESET"
  fi
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
      --quick) set_mode_from_option 1; shift ;;
      --standard|--full) set_mode_from_option 2; shift ;;
      --deep) set_mode_from_option 3; shift ;;
      --capacity-only) set_mode_from_option 4; shift ;;
      --route-only) set_mode_from_option 5; shift ;;
      --no-speed) RUN_SPEED=0; SPEED_COUNT=0; shift ;;
      --no-capacity) RUN_CAPACITY=0; shift ;;
      --capacity-threads) CAP_THREADS="${2:-8}"; shift 2 ;;
      --capacity-single-seconds) CAP_SINGLE_SECONDS="${2:-6}"; shift 2 ;;
      --capacity-multi-seconds) CAP_MULTI_SECONDS="${2:-8}"; shift 2 ;;
      --http-samples) CAP_HTTP_SAMPLES="${2:-20}"; shift 2 ;;
      --capacity-endpoint) CAP_ENDPOINT="${2:-https://speed.cloudflare.com}"; shift 2 ;;
      --capacity-ping-host) CAP_PING_HOST="${2:-1.1.1.1}"; shift 2 ;;
      --speed-count) SPEED_COUNT="${2:-2}"; shift 2 ;;
      --ping-count) PING_COUNT="${2:-10}"; shift 2 ;;
      --tcp-count) TCP_COUNT="${2:-3}"; shift 2 ;;
      --tcp-timeout) TCP_TIMEOUT="${2:-2}"; shift 2 ;;
      --mtr-count) MTR_COUNT="${2:-20}"; shift 2 ;;
      --out) OUT_BASE="${2:-}"; shift 2 ;;
      --no-color) NO_COLOR_MODE=1; RESET=""; BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; WHITE=""; ANIMATE=0; shift ;;
      --no-animation) ANIMATE=0; shift ;;
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
  if [[ "$RUN_SPEED" -eq 1 ]] && ! has_cmd speedtest; then warn "未检测到 Ookla speedtest，测速阶段会自动跳过。可使用 --install 安装。"; fi
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
  REPORT_SVG="$OUT_DIR/report.svg"
  CAPACITY_CSV="$OUT_DIR/capacity_summary.csv"
  CAPACITY_JSON="$OUT_DIR/capacity_raw.json"
  CAPACITY_SAMPLES_CSV="$OUT_DIR/capacity_timeseries.csv"
  OOKLA_SERVERS_CSV="$OUT_DIR/ookla_cn_servers.csv"

  echo 'ISP,运营商,区域,目标名称,Host,Port,Ping丢包%,Ping最小ms,Ping平均ms,Ping最大ms,Ping抖动ms,TCP成功数,TCP失败率%,TCP最小ms,TCP平均ms,TCP最大ms,目标评分' > "$LATENCY_CSV"
  echo 'ISP,运营商,ServerID,测速点名称,赞助商,城市,SpeedtestPingms,下载Mbps,上传Mbps,结果URL,状态' > "$SPEED_CSV"
  echo '排名,ISP,运营商,目标数,平均Pingms,平均Ping丢包%,平均TCPms,TCP成功率%,测速点数,平均下载Mbps,平均上传Mbps,综合评分,评级,建议,报告评语' > "$OVERVIEW_CSV"
  echo 'ISP,运营商,回程骨干识别,关键特征,备注' > "$ROUTE_CSV"
  echo '测试模式,测试端点,网络接口,单线下行Mbps,多线下行Mbps,最大下行Mbps,下行并发增益x,下行持续利用率%,下行多线程数,单线下行持续秒,多线下行持续秒,单线上行Mbps,多线上行Mbps,最大上行Mbps,上行并发增益x,上行持续利用率%,上行多线程数,单线上行持续秒,多线上行持续秒,HTTP平均延迟ms,HTTP_P50ms,HTTP_P95ms,HTTP抖动ms,HTTP层丢包率%,HTTP样本数,ICMP平均延迟ms,ICMP抖动ms,ICMP丢包率%,估算下行流量MB,估算上行流量MB,状态,备注' > "$CAPACITY_CSV"
  echo '方向,阶段,样本序号,相对时间秒,瞬时Mbps' > "$CAPACITY_SAMPLES_CSV"
  printf '{}\n' > "$CAPACITY_JSON"
}

# ---------- 基础信息 ----------
public_ip_info() {
  local outfile="$1"
  spinner_start "正在读取 VPS 基础信息、出口 IP 与来源地"
  python3 - "$outfile" "$VERSION" <<'PYCODE'
import json, urllib.request, subprocess, sys, re
out=sys.argv[1]
version=sys.argv[2]

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
    '- 脚本版本：v' + version,
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

# ---------- 上下行容量压力测试 ----------
run_capacity_stress() {
  if [[ "$RUN_CAPACITY" -ne 1 ]]; then
    warn "已跳过容量压测（--no-capacity 或路由模式）。"
    return 0
  fi

  section_title "全量容量压测：单线 / 多线 / 最大上下行 + HTTP / ICMP"
  info_note "端点：$CAP_ENDPOINT · 线程：$CAP_THREADS · 单线：${CAP_SINGLE_SECONDS}s · 多线：${CAP_MULTI_SECONDS}s"
  warn "本阶段会产生实际上下行流量；最大值采用网卡计数器的约 1 秒滚动峰值。"

  python3 -u - "$CAPACITY_CSV" "$CAPACITY_JSON" "$CAPACITY_SAMPLES_CSV" "$MODE" "$CAP_ENDPOINT" "$CAP_PING_HOST" "$CAP_THREADS" "$CAP_SINGLE_SECONDS" "$CAP_MULTI_SECONDS" "$CAP_HTTP_SAMPLES" "$CAP_UPLOAD_CHUNK_MB" <<'PYCODE'
import concurrent.futures
import csv
import json
import math
import os
import random
import re
import statistics
import subprocess
import sys
import tempfile
import threading
import time

(
    out_csv, out_json, samples_csv, mode, endpoint, ping_host,
    threads_s, single_seconds_s, multi_seconds_s, http_samples_s,
    upload_chunk_mb_s,
) = sys.argv[1:12]

def clamp_int(value, low, high, default):
    try:
        return max(low, min(high, int(float(value))))
    except Exception:
        return default

threads = clamp_int(threads_s, 2, 32, 8)
single_seconds = clamp_int(single_seconds_s, 2, 60, 6)
multi_seconds = clamp_int(multi_seconds_s, 3, 90, 8)
http_sample_count = clamp_int(http_samples_s, 5, 200, 20)
upload_chunk_mb = clamp_int(upload_chunk_mb_s, 1, 64, 8)
if os.environ.get('LAZYVPS_TEST_FAST') == '1':
    single_seconds = 0.6
    multi_seconds = 0.9
    http_sample_count = 5
endpoint = endpoint.rstrip('/')
download_url = endpoint + '/__down?bytes=1000000000'
upload_url = endpoint + '/__up'
latency_url = endpoint + '/cdn-cgi/trace'

def emit(text):
    print(text, flush=True)

def default_interface():
    try:
        with open('/proc/net/route', encoding='ascii', errors='ignore') as f:
            next(f, None)
            for line in f:
                parts = line.split()
                if len(parts) >= 4 and parts[1] == '00000000' and int(parts[3], 16) & 2:
                    return parts[0]
    except Exception:
        pass
    try:
        for name in os.listdir('/sys/class/net'):
            if name != 'lo' and os.path.exists(f'/sys/class/net/{name}/statistics/rx_bytes'):
                return name
    except Exception:
        pass
    return ''

interface = default_interface()

def read_counter(direction):
    if not interface:
        return None
    key = 'rx_bytes' if direction == 'down' else 'tx_bytes'
    try:
        with open(f'/sys/class/net/{interface}/statistics/{key}', encoding='ascii') as f:
            return int(f.read().strip())
    except Exception:
        return None

class NetSampler:
    def __init__(self, direction, stage, interval=0.25):
        self.direction = direction
        self.stage = stage
        self.interval = interval
        self.records = []
        self._stop = threading.Event()
        self._thread = None
        self._start = None

    def start(self):
        self._start = time.monotonic()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self):
        last_t = time.monotonic()
        last_b = read_counter(self.direction)
        while not self._stop.wait(self.interval):
            now_t = time.monotonic()
            now_b = read_counter(self.direction)
            if last_b is not None and now_b is not None and now_t > last_t:
                mbps = max(0.0, (now_b - last_b) * 8 / (now_t - last_t) / 1_000_000)
                self.records.append({
                    '方向': '下行' if self.direction == 'down' else '上行',
                    '阶段': self.stage,
                    '相对时间秒': round(now_t - self._start, 3),
                    '瞬时Mbps': round(mbps, 3),
                })
            last_t, last_b = now_t, now_b

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2)

    def peak_1s(self, fallback):
        values = [float(r['瞬时Mbps']) for r in self.records if float(r['瞬时Mbps']) > 0.01]
        if not values:
            return fallback
        window = max(1, round(1.0 / self.interval))
        if len(values) < window:
            return max(values)
        rolling = [sum(values[i:i+window]) / window for i in range(len(values) - window + 1)]
        return max(rolling)

def parse_curl_metrics(text):
    # size_download|size_upload|time_total|http_code
    line = (text or '').strip().splitlines()[-1:] or ['']
    parts = line[0].split('|')
    if len(parts) != 4:
        return 0, 0, 0.0, 0
    try: down = int(float(parts[0] or 0))
    except Exception: down = 0
    try: up = int(float(parts[1] or 0))
    except Exception: up = 0
    try: elapsed = float(parts[2] or 0)
    except Exception: elapsed = 0.0
    try: code = int(parts[3] or 0)
    except Exception: code = 0
    return down, up, elapsed, code

def curl_transfer(direction, timeout_s, payload_path=''):
    token = f'{time.time_ns()}-{random.randint(1000,9999)}'
    common = [
        'curl', '-sS', '-L', '--http1.1', '--connect-timeout', '3',
        '--max-time', f'{max(1.0, timeout_s):.2f}', '-o', '/dev/null',
        '-w', '%{size_download}|%{size_upload}|%{time_total}|%{http_code}',
        '-H', 'Cache-Control: no-cache', '-A', 'LazyVPS-Capacity/2.1',
    ]
    if direction == 'down':
        cmd = common + [download_url + '&r=' + token]
    else:
        cmd = common + [
            '-X', 'POST', '-H', 'Content-Type: application/octet-stream',
            '--data-binary', '@' + payload_path, upload_url + '?r=' + token,
        ]
    try:
        proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=max(3, timeout_s + 2))
        return parse_curl_metrics(proc.stdout)
    except Exception:
        return 0, 0, 0.0, 0

def run_phase(direction, stage, worker_count, seconds, payload_path=''):
    sampler = NetSampler(direction, stage)
    start = time.monotonic()
    end = start + seconds
    request_rates = []
    lock = threading.Lock()

    def worker():
        total = 0
        attempts = 0
        useful = 0
        while True:
            remaining = end - time.monotonic()
            if remaining < 0.35:
                break
            down_b, up_b, elapsed, code = curl_transfer(direction, remaining, payload_path)
            transferred = down_b if direction == 'down' else up_b
            attempts += 1
            if transferred > 0:
                total += transferred
                useful += 1
                if elapsed > 0:
                    with lock:
                        request_rates.append(transferred * 8 / elapsed / 1_000_000)
            if transferred <= 0 and not (200 <= code < 400):
                time.sleep(0.08)
        return total, attempts, useful

    sampler.start()
    with concurrent.futures.ThreadPoolExecutor(max_workers=worker_count) as pool:
        results = list(pool.map(lambda _: worker(), range(worker_count)))
    sampler.stop()
    elapsed = max(0.001, time.monotonic() - start)
    total_bytes = sum(item[0] for item in results)
    average_mbps = total_bytes * 8 / elapsed / 1_000_000
    request_peak = max(request_rates, default=average_mbps)
    peak_mbps = max(average_mbps, sampler.peak_1s(max(average_mbps, request_peak)))
    return {
        'direction': direction,
        'stage': stage,
        'threads': worker_count,
        'target_seconds': seconds,
        'elapsed_seconds': round(elapsed, 3),
        'bytes': total_bytes,
        'average_mbps': round(average_mbps, 3),
        'peak_mbps': round(peak_mbps, 3),
        'attempts': sum(item[1] for item in results),
        'useful_attempts': sum(item[2] for item in results),
        'samples': sampler.records,
    }

def percentile(values, p):
    if not values:
        return None
    values = sorted(values)
    if len(values) == 1:
        return values[0]
    pos = (len(values) - 1) * p
    lo = math.floor(pos)
    hi = math.ceil(pos)
    if lo == hi:
        return values[lo]
    return values[lo] * (hi - pos) + values[hi] * (pos - lo)

def http_quality(count):
    samples = []
    failures = 0
    raw = []
    for index in range(count):
        token = f'{time.time_ns()}-{index}'
        cmd = [
            'curl', '-sS', '-L', '--http1.1', '--connect-timeout', '2', '--max-time', '4',
            '-o', '/dev/null', '-w', '%{time_total}|%{http_code}',
            '-H', 'Cache-Control: no-cache', '-A', 'LazyVPS-Latency/2.1', latency_url + '?r=' + token,
        ]
        try:
            proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=6)
            parts = proc.stdout.strip().split('|')
            elapsed = float(parts[0]) * 1000 if len(parts) == 2 else 0.0
            code = int(parts[1]) if len(parts) == 2 else 0
        except Exception:
            elapsed, code = 0.0, 0
        ok = 200 <= code < 400 and elapsed > 0
        raw.append({'index': index + 1, 'latency_ms': round(elapsed, 3), 'http_code': code, 'ok': ok})
        if ok:
            samples.append(elapsed)
        else:
            failures += 1
    return {
        'average_ms': statistics.mean(samples) if samples else None,
        'p50_ms': percentile(samples, 0.50),
        'p95_ms': percentile(samples, 0.95),
        'jitter_ms': statistics.pstdev(samples) if len(samples) > 1 else (0.0 if samples else None),
        'loss_percent': failures / count * 100 if count else 100.0,
        'sample_count': count,
        'success_count': len(samples),
        'samples': raw,
    }

def icmp_quality(host, count):
    if not host:
        return {'average_ms': None, 'jitter_ms': None, 'loss_percent': None, 'raw': ''}
    try:
        proc = subprocess.run(['ping', '-c', str(count), '-W', '1', host], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=count + 8)
        text = proc.stdout
    except Exception:
        text = ''
    loss_match = re.search(r'([0-9.]+)%\s*packet loss', text)
    stat_match = re.search(r'(?:mdev|stddev)\s*=\s*([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+)', text)
    return {
        'average_ms': float(stat_match.group(2)) if stat_match else None,
        'jitter_ms': float(stat_match.group(4)) if stat_match else None,
        'loss_percent': float(loss_match.group(1)) if loss_match else 100.0,
        'raw': text,
    }

def fnum(value, digits=2):
    return 'NA' if value is None else f'{float(value):.{digits}f}'

def safe_ratio(top, bottom):
    return None if not bottom else top / bottom

payload = tempfile.NamedTemporaryFile(prefix='lazyvps-upload-', suffix='.bin', dir=os.path.dirname(os.path.abspath(out_csv)), delete=False)
payload_path = payload.name
payload.close()
with open(payload_path, 'wb') as f:
    f.truncate(upload_chunk_mb * 1024 * 1024)

try:
    emit('[容量 1/6] HTTP 延迟、P50、P95、抖动与丢包采样')
    http = http_quality(http_sample_count)
    emit('[容量 2/6] 单线下行持续测试')
    down_single = run_phase('down', '单线下行', 1, single_seconds)
    emit(f'[容量 3/6] {threads} 线程下行饱和与峰值测试')
    down_multi = run_phase('down', '多线下行', threads, multi_seconds)
    emit('[容量 4/6] 单线上行持续测试')
    up_single = run_phase('up', '单线上行', 1, single_seconds, payload_path)
    emit(f'[容量 5/6] {threads} 线程上行饱和与峰值测试')
    up_multi = run_phase('up', '多线上行', threads, multi_seconds, payload_path)
    emit('[容量 6/6] ICMP 延迟、抖动与丢包采样')
    icmp = icmp_quality(ping_host, min(20, max(5, http_sample_count // 2)))
finally:
    try: os.unlink(payload_path)
    except Exception: pass

all_samples = down_single['samples'] + down_multi['samples'] + up_single['samples'] + up_multi['samples']
with open(samples_csv, 'w', encoding='utf-8', newline='') as f:
    fields = ['方向', '阶段', '样本序号', '相对时间秒', '瞬时Mbps']
    writer = csv.DictWriter(f, fieldnames=fields)
    writer.writeheader()
    stage_index = {}
    for item in all_samples:
        stage_index[item['阶段']] = stage_index.get(item['阶段'], 0) + 1
        row = dict(item)
        row['样本序号'] = stage_index[item['阶段']]
        writer.writerow({key: row.get(key, '') for key in fields})

status = 'OK' if all(item['bytes'] > 0 for item in [down_single, down_multi, up_single, up_multi]) else 'PARTIAL'
notes = []
if down_single['bytes'] <= 0 or down_multi['bytes'] <= 0: notes.append('下行端点未返回有效流量')
if up_single['bytes'] <= 0 or up_multi['bytes'] <= 0: notes.append('上行端点未返回有效流量')
if http['success_count'] == 0: notes.append('HTTP 延迟采样全部失败')

record = {
    '测试模式': mode,
    '测试端点': endpoint,
    '网络接口': interface or 'NA',
    '单线下行Mbps': fnum(down_single['average_mbps']),
    '多线下行Mbps': fnum(down_multi['average_mbps']),
    '最大下行Mbps': fnum(down_multi['peak_mbps']),
    '下行并发增益x': fnum(safe_ratio(down_multi['average_mbps'], down_single['average_mbps'])),
    '下行持续利用率%': fnum(safe_ratio(down_multi['average_mbps'] * 100, down_multi['peak_mbps'])),
    '下行多线程数': threads,
    '单线下行持续秒': down_single['elapsed_seconds'],
    '多线下行持续秒': down_multi['elapsed_seconds'],
    '单线上行Mbps': fnum(up_single['average_mbps']),
    '多线上行Mbps': fnum(up_multi['average_mbps']),
    '最大上行Mbps': fnum(up_multi['peak_mbps']),
    '上行并发增益x': fnum(safe_ratio(up_multi['average_mbps'], up_single['average_mbps'])),
    '上行持续利用率%': fnum(safe_ratio(up_multi['average_mbps'] * 100, up_multi['peak_mbps'])),
    '上行多线程数': threads,
    '单线上行持续秒': up_single['elapsed_seconds'],
    '多线上行持续秒': up_multi['elapsed_seconds'],
    'HTTP平均延迟ms': fnum(http['average_ms']),
    'HTTP_P50ms': fnum(http['p50_ms']),
    'HTTP_P95ms': fnum(http['p95_ms']),
    'HTTP抖动ms': fnum(http['jitter_ms']),
    'HTTP层丢包率%': fnum(http['loss_percent']),
    'HTTP样本数': http['sample_count'],
    'ICMP平均延迟ms': fnum(icmp['average_ms']),
    'ICMP抖动ms': fnum(icmp['jitter_ms']),
    'ICMP丢包率%': fnum(icmp['loss_percent']),
    '估算下行流量MB': fnum((down_single['bytes'] + down_multi['bytes']) / 1_000_000),
    '估算上行流量MB': fnum((up_single['bytes'] + up_multi['bytes']) / 1_000_000),
    '状态': status,
    '备注': '；'.join(notes) if notes else '容量与质量采样完成',
}

fields = list(record.keys())
with open(out_csv, 'w', encoding='utf-8', newline='') as f:
    writer = csv.DictWriter(f, fieldnames=fields)
    writer.writeheader()
    writer.writerow(record)

raw = {
    'schema': 'lazyvps.capacity.v2.1',
    'mode': mode,
    'endpoint': endpoint,
    'network_interface': interface,
    'methodology': {
        'single_stream': '1 HTTP worker sustained average',
        'multi_stream': f'{threads} concurrent HTTP workers sustained average',
        'maximum': 'approximately 1-second rolling peak from Linux interface byte counters',
        'http_jitter': 'population standard deviation of successful HTTP latency samples',
    },
    'download_single': down_single,
    'download_multi': down_multi,
    'upload_single': up_single,
    'upload_multi': up_multi,
    'http_quality': http,
    'icmp_quality': icmp,
    'summary': record,
}
with open(out_json, 'w', encoding='utf-8') as f:
    json.dump(raw, f, ensure_ascii=False, indent=2)

emit('容量压测完成：')
emit(f"  Down 单线 {record['单线下行Mbps']} / 多线 {record['多线下行Mbps']} / 最大 {record['最大下行Mbps']} Mb/s")
emit(f"  Up   单线 {record['单线上行Mbps']} / 多线 {record['多线上行Mbps']} / 最大 {record['最大上行Mbps']} Mb/s")
emit(f"  HTTP Avg {record['HTTP平均延迟ms']} / P50 {record['HTTP_P50ms']} / P95 {record['HTTP_P95ms']} ms / Loss {record['HTTP层丢包率%']}%")
PYCODE

  log "容量压测结果：$CAPACITY_CSV"
  log "容量原始数据：$CAPACITY_JSON"
  log "容量时间序列：$CAPACITY_SAMPLES_CSV"
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
  python3 - "$BASEINFO_MD" "$LATENCY_CSV" "$SPEED_CSV" "$OVERVIEW_CSV" "$ROUTE_CSV" "$REPORT_MD" "$MODE" "$VERSION" "$CAPACITY_CSV" "$CAPACITY_JSON" "$CAPACITY_SAMPLES_CSV" <<'PYCODE'
import sys, csv, os
base, lat, speed, overview, route_csv, report, mode, version, capacity, capacity_json, capacity_samples = sys.argv[1:12]

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
    f.write(f'# LazyVPS 中国三网 VPS 综合测试报告 · v{version}\n\n')
    f.write('![三网测速可视化报告](report.svg)\n\n')
    f.write(f'- 测试模式：{mode}\n')
    f.write(f'- 输出目录：`{os.path.basename(os.path.dirname(report))}`\n')
    f.write('- 口径说明：本测试面向 VPS 中国方向网络质量评估，**非家宽评分口径**。\n')
    f.write('- 容量口径：单线/多线为持续平均；最大上下行为约 1 秒滚动峰值。\n')
    f.write('- 注意：综合评分与评级仅供参考，请结合高峰复测、业务类型、回程路由与稳定性综合判断。\n\n')
    f.write('## 1. 上下行容量与 HTTP / ICMP 品质\n\n'); f.write(md_table(capacity))
    f.write(f'\n- 容量原始 JSON：`{os.path.basename(capacity_json)}`\n')
    f.write(f'- 容量时间序列：`{os.path.basename(capacity_samples)}`\n')
    f.write('\n## 2. 三网综合评分总表\n\n'); f.write(md_table(overview))
    f.write('\n## 3. 路由骨干观察摘要\n\n'); f.write(md_table(route_csv))
    f.write('\n## 4. VPS 基础信息与出口来源地\n\n'); f.write(read_file(base))
    f.write('\n## 5. Ping / TCP 连通明细\n\n'); f.write(md_table(lat, max_rows=80))
    f.write('\n## 6. Ookla Speedtest 明细\n\n'); f.write(md_table(speed, max_rows=30))
    f.write('\n## 7. 结果解读说明\n\n')
    f.write('- 本脚本优先看的是 VPS 对中国三网方向的网络质量，不是家用宽带跑满带宽的考核模型。\n')
    f.write('- 容量压测会产生实际流量；不同端点、时段与 TCP 拥塞控制会影响结果。\n')
    f.write('- DNS/官网目标可能存在禁 Ping、CDN 调度或 ICMP 限制，不能单项定结论。\n')
    f.write('- 路由骨干识别基于 MTR / Traceroute 关键字自动判断，仅适合粗判回程特征。\n')
    f.write('- 建议至少对比 **普通时段** 与 **晚高峰** 两轮结果，再决定是否作为主力线路。\n')
PYCODE
}

make_svg_report() {
  python3 - "$OVERVIEW_CSV" "$ROUTE_CSV" "$BASEINFO_MD" "$REPORT_SVG" "$MODE" "$VERSION" "$CAPACITY_CSV" "$CAPACITY_SAMPLES_CSV" <<'PYCODE'
import csv
import math
import os
import re
import sys
from xml.sax.saxutils import escape

overview_path, route_path, base_path, output_path, mode, version, capacity_path, capacity_samples_path = sys.argv[1:9]

ISP_META = {
    'CT': ('中国电信', '#38bdf8', '#0c4a6e'),
    'CU': ('中国联通', '#fbbf24', '#713f12'),
    'CM': ('中国移动', '#34d399', '#064e3b'),
}
MODE_NAMES = {
    'quick': '快速体验',
    'standard': '标准综合',
    'deep': '深度三网',
    'capacity': '容量压测',
    'route': '路由延迟',
}

def read_csv(path):
    try:
        with open(path, encoding='utf-8-sig') as f:
            return list(csv.DictReader(f))
    except Exception:
        return []

def read_base(path):
    data = {}
    try:
        for raw in open(path, encoding='utf-8', errors='ignore'):
            line = raw.strip()
            if not line.startswith('- ') or '：' not in line:
                continue
            key, value = line[2:].split('：', 1)
            data[key.strip()] = value.strip()
    except Exception:
        pass
    return data

def num(value):
    try:
        text = str(value).strip()
        if text.upper() in {'', 'NA', 'N/A', '--', 'NAN'}:
            return None
        return float(text)
    except Exception:
        return None

def fmt(value, digits=1, suffix=''):
    value = num(value)
    return '--' if value is None else f'{value:.{digits}f}{suffix}'

def limit(text, count=34):
    text = re.sub(r'\s+', ' ', str(text or '')).strip()
    return text if len(text) <= count else text[:count - 1] + '…'

def esc(text):
    return escape(str(text), {'"': '&quot;'})

def score_color(score):
    score = num(score) or 0
    if score >= 82:
        return '#34d399'
    if score >= 66:
        return '#38bdf8'
    if score >= 56:
        return '#fbbf24'
    return '#fb7185'

def nice_max(values, floor, step):
    values = [value for value in values if value is not None]
    peak = max(values, default=0)
    return max(floor, int(math.ceil(peak * 1.12 / step) * step))

def route_short(text):
    text = str(text or '未识别')
    replacements = [
        ('电信国际/CTG 或 163 出口', 'CTG / 163'),
        ('电信 163 骨干', '163 骨干'),
        ('CN2 精品网', 'CN2'),
        ('联通 169 骨干 / AS4837', '169 / AS4837'),
        ('联通 A 网 / CUII / 9929 疑似', '9929 / CUII'),
        ('移动 CMNET 骨干 / AS9808', 'CMNET / AS9808'),
        ('移动国际 CMI', 'CMI'),
    ]
    for before, after in replacements:
        text = text.replace(before, after)
    return limit(text, 28)

def line_path(series, x, y, width, height, max_value):
    if len(series) < 2 or max_value <= 0:
        return ''
    times = [num(item.get('相对时间秒')) or 0 for item in series]
    values = [num(item.get('瞬时Mbps')) or 0 for item in series]
    tmax = max(times) or 1
    points = []
    for t, value in zip(times, values):
        px = x + (t / tmax) * width
        py = y + height - max(0, min(1, value / max_value)) * height
        points.append(f'{px:.1f},{py:.1f}')
    return 'M ' + ' L '.join(points)

rows = read_csv(overview_path)
rows.sort(key=lambda row: num(row.get('综合评分')) or 0, reverse=True)
routes = {row.get('ISP', ''): row for row in read_csv(route_path)}
base = read_base(base_path)
capacity_rows = read_csv(capacity_path)
capacity = capacity_rows[0] if capacity_rows else {}
capacity_samples = read_csv(capacity_samples_path)
down_series = [row for row in capacity_samples if row.get('方向') == '下行' and row.get('阶段') == '多线下行']
up_series = [row for row in capacity_samples if row.get('方向') == '上行' and row.get('阶段') == '多线上行']

down_max = nice_max([num(row.get('平均下载Mbps')) for row in rows], 100, 100)
up_max = nice_max([num(row.get('平均上传Mbps')) for row in rows], 50, 50)

footer_y = 676 + len(rows[:3]) * 300 + 22
width, height = 1200, footer_y + 182
out = []
add = out.append
add(f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="title desc">')
add('<title id="title">LazyVPS 容量压测与中国三网 VPS 综合报告</title>')
add('<desc id="desc">单线、多线与最大上下行容量，HTTP 与 ICMP 品质，以及中国三网延迟、丢包、速度和回程骨干可视化。</desc>')
add('''<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#07111f"/><stop offset="0.55" stop-color="#0b1730"/><stop offset="1" stop-color="#11102b"/></linearGradient>
  <linearGradient id="hero" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#22d3ee"/><stop offset="0.5" stop-color="#60a5fa"/><stop offset="1" stop-color="#c084fc"/></linearGradient>
  <linearGradient id="speed" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#22d3ee"/><stop offset="1" stop-color="#818cf8"/></linearGradient>
  <filter id="glow" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="7" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
  <pattern id="grid" width="42" height="42" patternUnits="userSpaceOnUse"><path d="M42 0H0V42" fill="none" stroke="#94a3b8" stroke-opacity="0.045"/></pattern>
  <style>
    text{font-family:Inter,"Noto Sans CJK SC","Microsoft YaHei","PingFang SC",system-ui,sans-serif}
    .mono{font-family:"JetBrains Mono","Cascadia Code",Consolas,monospace}
    .muted{fill:#8ea0b9}.label{fill:#93a4bd;font-size:15px;letter-spacing:.8px}.value{fill:#f8fafc;font-size:26px;font-weight:700}
    .small{fill:#a9b8cc;font-size:14px}.card{fill:#101d33;fill-opacity:.84;stroke:#31425c;stroke-width:1}.metric{fill:#0b1628;stroke:#263752;stroke-width:1}
  </style>
</defs>''')
add(f'<rect width="{width}" height="{height}" rx="28" fill="url(#bg)"/>')
add(f'<rect width="{width}" height="{height}" rx="28" fill="url(#grid)"/>')
add('<circle cx="1050" cy="10" r="230" fill="#7c3aed" opacity=".10" filter="url(#glow)"/>')
add('<circle cx="70" cy="310" r="190" fill="#0891b2" opacity=".08" filter="url(#glow)"/>')

# Header
add('<rect x="42" y="38" width="8" height="92" rx="4" fill="url(#hero)"/>')
add('<text x="70" y="77" fill="#dff8ff" font-size="35" font-weight="800" letter-spacing="1.3">LAZYVPS CN3 SPEEDTEST</text>')
add('<text x="70" y="111" fill="#8fa6c5" font-size="18">全量容量压测 · HTTP / ICMP 品质 · 中国三网回程</text>')
add(f'<text x="1150" y="70" text-anchor="end" fill="#67e8f9" font-size="18" font-weight="700">v{esc(version)}</text>')
add(f'<text x="1150" y="100" text-anchor="end" fill="#a5b4fc" font-size="15">{esc(MODE_NAMES.get(mode, mode))}</text>')

# Base information
add('<rect class="card" x="42" y="150" width="1116" height="148" rx="22"/>')
add('<text x="68" y="185" fill="#67e8f9" font-size="14" font-weight="700" letter-spacing="1.6">VPS TELEMETRY</text>')
base_items = [
    ('IPv4', base.get('IPv4', '--')),
    ('ASN', base.get('ASN', '--')),
    ('位置', base.get('归属地', '--')),
]
base_x = [68, 330, 545]
for (label, value), x, max_len in zip(base_items, base_x, [24, 18, 17]):
    add(f'<text class="label" x="{x}" y="221">{esc(label)}</text>')
    add(f'<text class="value mono" x="{x}" y="257" font-size="{22 if label != "位置" else 19}">{esc(limit(value, max_len))}</text>')
add('<text class="label" x="1132" y="221" text-anchor="end">测试时间</text>')
add(f'<text class="value mono" x="1132" y="257" text-anchor="end" font-size="20">{esc(limit(base.get("测试时间", "--"), 26))}</text>')
add('<text x="68" y="282" class="small">评分为 VPS 中国方向参考模型；建议普通时段与晚高峰各测一轮。</text>')

# Capacity stress card
cap_y = 326
add(f'<rect class="card" x="42" y="{cap_y}" width="1116" height="320" rx="24"/>')
add(f'<rect x="42" y="{cap_y}" width="7" height="320" rx="4" fill="url(#hero)"/>')
add(f'<text x="68" y="{cap_y+39}" fill="#67e8f9" font-size="16" font-weight="800" letter-spacing="1.4">CAPACITY STRESS / 全量容量压测</text>')
add(f'<text x="1132" y="{cap_y+39}" text-anchor="end" fill="#a5b4fc" font-size="14">{esc(capacity.get("下行多线程数", "--"))} THREADS · {esc(capacity.get("状态", "NOT RUN"))}</text>')

cap_metrics = [
    ('DOWN 1', capacity.get('单线下行Mbps'), '#38bdf8'),
    ('DOWN N', capacity.get('多线下行Mbps'), '#22d3ee'),
    ('DOWN MAX', capacity.get('最大下行Mbps'), '#60a5fa'),
    ('UP 1', capacity.get('单线上行Mbps'), '#c084fc'),
    ('UP N', capacity.get('多线上行Mbps'), '#a78bfa'),
    ('UP MAX', capacity.get('最大上行Mbps'), '#e879f9'),
]
for metric_index, (label, value, color) in enumerate(cap_metrics):
    x = 68 + metric_index * 177
    add(f'<rect class="metric" x="{x}" y="{cap_y+61}" width="160" height="76" rx="14"/>')
    add(f'<text class="label" x="{x+14}" y="{cap_y+88}">{label}</text>')
    add(f'<text class="mono" x="{x+14}" y="{cap_y+121}" fill="{color}" font-size="23" font-weight="800">{esc(fmt(value, 1, " Mb/s"))}</text>')

# Capacity time series
chart_x, chart_y, chart_w, chart_h = 68, cap_y + 174, 650, 112
all_cap_values = [num(row.get('瞬时Mbps')) for row in down_series + up_series]
cap_scale = nice_max(all_cap_values, 100, 100)
add(f'<rect class="metric" x="{chart_x}" y="{chart_y}" width="{chart_w}" height="{chart_h}" rx="14"/>')
for grid_index in range(1, 4):
    gy = chart_y + chart_h * grid_index / 4
    add(f'<path d="M {chart_x+14} {gy:.1f} H {chart_x+chart_w-14}" stroke="#334155" stroke-width="1" stroke-dasharray="4 6"/>')
down_path = line_path(down_series, chart_x+14, chart_y+20, chart_w-28, chart_h-36, cap_scale)
up_path = line_path(up_series, chart_x+14, chart_y+20, chart_w-28, chart_h-36, cap_scale)
if down_path:
    add(f'<path d="{down_path}" fill="none" stroke="#22d3ee" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>')
if up_path:
    add(f'<path d="{up_path}" fill="none" stroke="#c084fc" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>')
add(f'<text x="{chart_x+15}" y="{chart_y+18}" fill="#67e8f9" font-size="12">DOWN</text>')
add(f'<text x="{chart_x+75}" y="{chart_y+18}" fill="#d8b4fe" font-size="12">UP</text>')
add(f'<text x="{chart_x+chart_w-15}" y="{chart_y+18}" text-anchor="end" fill="#64748b" font-size="11">0–{cap_scale} Mb/s</text>')

# HTTP / ICMP quality panel
quality_x, quality_y, quality_w, quality_h = 744, chart_y, 380, chart_h
add(f'<rect class="metric" x="{quality_x}" y="{quality_y}" width="{quality_w}" height="{quality_h}" rx="14"/>')
add(f'<text class="label" x="{quality_x+18}" y="{quality_y+27}">HTTP QUALITY</text>')
add(f'<text class="mono" x="{quality_x+18}" y="{quality_y+57}" fill="#f8fafc" font-size="18">AVG {esc(fmt(capacity.get("HTTP平均延迟ms"),1))} · P50 {esc(fmt(capacity.get("HTTP_P50ms"),1))} · P95 {esc(fmt(capacity.get("HTTP_P95ms"),1))} ms</text>')
add(f'<text class="mono" x="{quality_x+18}" y="{quality_y+83}" fill="#a5b4fc" font-size="15">JITTER {esc(fmt(capacity.get("HTTP抖动ms"),1))} ms · LOSS {esc(fmt(capacity.get("HTTP层丢包率%"),1))}%</text>')
add(f'<text class="small mono" x="{quality_x+18}" y="{quality_y+105}">ICMP {esc(fmt(capacity.get("ICMP平均延迟ms"),1))} ms · Jitter {esc(fmt(capacity.get("ICMP抖动ms"),1))} · Loss {esc(fmt(capacity.get("ICMP丢包率%"),1))}%</text>')

# ISP cards
card_y = 676
for index, row in enumerate(rows[:3], start=1):
    isp = row.get('ISP', '')
    name, accent, accent_dark = ISP_META.get(isp, (row.get('运营商', isp), '#94a3b8', '#334155'))
    y = card_y + (index - 1) * 300
    score = num(row.get('综合评分')) or 0
    ring = 2 * math.pi * 48
    dash = ring * max(0, min(100, score)) / 100
    color = score_color(score)
    route = routes.get(isp, {})
    route_name = route_short(route.get('回程骨干识别'))
    key = limit(route.get('关键特征') or '建议查看原始 MTR / Traceroute', 43)
    down = num(row.get('平均下载Mbps'))
    up = num(row.get('平均上传Mbps'))
    down_width = 430 * max(0, min(1, (down or 0) / down_max))
    up_width = 430 * max(0, min(1, (up or 0) / up_max))

    add(f'<rect class="card" x="42" y="{y}" width="1116" height="274" rx="24"/>')
    add(f'<rect x="42" y="{y}" width="7" height="274" rx="4" fill="{accent}"/>')
    add(f'<circle cx="82" cy="{y+43}" r="21" fill="{accent_dark}" stroke="{accent}"/>')
    add(f'<text x="82" y="{y+50}" text-anchor="middle" fill="{accent}" font-size="18" font-weight="800">{index}</text>')
    add(f'<text x="116" y="{y+42}" fill="#f8fafc" font-size="27" font-weight="800">{esc(name)}</text>')
    add(f'<text x="116" y="{y+67}" fill="{accent}" font-size="14" font-weight="700" letter-spacing="1.3">{esc(isp)} NETWORK</text>')
    add(f'<rect x="276" y="{y+23}" width="86" height="32" rx="16" fill="{accent_dark}"/>')
    add(f'<text x="319" y="{y+45}" text-anchor="middle" fill="{accent}" font-size="15" font-weight="700">Grade {esc(row.get("评级", "--"))}</text>')

    # Score ring
    add(f'<circle cx="1064" cy="{y+75}" r="48" fill="none" stroke="#22334e" stroke-width="10"/>')
    add(f'<circle cx="1064" cy="{y+75}" r="48" fill="none" stroke="{color}" stroke-width="10" stroke-linecap="round" stroke-dasharray="{dash:.1f} {ring:.1f}" transform="rotate(-90 1064 {y+75})"/>')
    add(f'<text x="1064" y="{y+78}" text-anchor="middle" fill="#f8fafc" font-size="27" font-weight="800">{score:.1f}</text>')
    add(f'<text x="1064" y="{y+99}" text-anchor="middle" fill="#8ea0b9" font-size="11">SCORE</text>')

    metrics = [
        ('PING', fmt(row.get('平均Pingms'), 1, ' ms')),
        ('LOSS', fmt(row.get('平均Ping丢包%'), 1, '%')),
        ('TCP OK', fmt(row.get('TCP成功率%'), 1, '%')),
    ]
    for metric_index, (label, value) in enumerate(metrics):
        x = 68 + metric_index * 194
        add(f'<rect class="metric" x="{x}" y="{y+91}" width="176" height="73" rx="14"/>')
        add(f'<text class="label" x="{x+16}" y="{y+116}">{label}</text>')
        add(f'<text class="value mono" x="{x+16}" y="{y+150}">{esc(value)}</text>')

    # Speed bars
    add(f'<text class="label" x="68" y="{y+195}">DOWN</text>')
    add(f'<rect x="135" y="{y+184}" width="430" height="13" rx="6.5" fill="#22334e"/>')
    add(f'<rect x="135" y="{y+184}" width="{down_width:.1f}" height="13" rx="6.5" fill="url(#speed)"/>')
    add(f'<text class="mono" x="582" y="{y+197}" fill="#7dd3fc" font-size="18" font-weight="700">{esc(fmt(down, 1, " Mb/s"))}</text>')
    add(f'<text class="label" x="68" y="{y+232}">UP</text>')
    add(f'<rect x="135" y="{y+221}" width="430" height="13" rx="6.5" fill="#22334e"/>')
    add(f'<rect x="135" y="{y+221}" width="{up_width:.1f}" height="13" rx="6.5" fill="#a78bfa"/>')
    add(f'<text class="mono" x="582" y="{y+234}" fill="#c4b5fd" font-size="18" font-weight="700">{esc(fmt(up, 1, " Mb/s"))}</text>')
    add(f'<text class="small" x="135" y="{y+255}">标尺：Down {down_max} / Up {up_max} Mb/s</text>')

    # Route capsule
    add(f'<rect class="metric" x="750" y="{y+133}" width="374" height="110" rx="16"/>')
    add(f'<text class="label" x="772" y="{y+162}">RETURN PATH / 回程骨干</text>')
    add(f'<text x="772" y="{y+195}" fill="{accent}" font-size="22" font-weight="800">{esc(route_name)}</text>')
    add(f'<text class="small mono" x="772" y="{y+222}">{esc(key)}</text>')

# Footer
add(f'<rect x="42" y="{footer_y}" width="1116" height="128" rx="20" fill="#0b1628" stroke="#263752"/>')
add(f'<text x="68" y="{footer_y+34}" fill="#67e8f9" font-size="15" font-weight="700">READING GUIDE</text>')
add(f'<text x="68" y="{footer_y+60}" class="small">• 单线/多线为持续平均；MAX 为网卡计数器约 1 秒滚动峰值。容量测试会产生实际上下行流量。</text>')
add(f'<text x="68" y="{footer_y+84}" class="small">• HTTP Jitter 为成功样本标准差；HTTP Loss 为失败请求占比。不同端点和时段会影响结果。</text>')
add(f'<text x="68" y="{footer_y+108}" class="small">• 三网路由用于快速筛选；最终请结合 MTR、Traceroute、晚高峰复测与实际业务。</text>')
add(f'<text x="1132" y="{footer_y+108}" text-anchor="end" fill="#64748b" font-size="12">{esc(os.path.basename(output_path))}</text>')
add('</svg>')

with open(output_path, 'w', encoding='utf-8', newline='\n') as f:
    f.write('\n'.join(out) + '\n')
PYCODE
  log "SVG 可视化报告已生成：$REPORT_SVG"
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
  section_title "测试完成：BBS 信息板结果页"
  info_note "CMD 显示整理后的可视化结果；完整长路由保存在 mtr/ 与 traceroute/。"
  printf '\n'

  if [[ ! -s "$OVERVIEW_CSV" ]]; then warn "没有生成总表。"; return 0; fi

  python3 - "$OVERVIEW_CSV" "$ROUTE_CSV" "$BASEINFO_MD" "$REPORT_MD" "$REPORT_SVG" "$LATENCY_CSV" "$SPEED_CSV" "$OUT_DIR" "$CAPACITY_CSV" "$CAPACITY_JSON" "$CAPACITY_SAMPLES_CSV" <<'PYCODE'
import sys, csv, re, textwrap
overview, route_csv, base_info, report_md, report_svg, latency_csv, speed_csv, out_dir, capacity_csv, capacity_json, capacity_samples = sys.argv[1:12]

RESET="\033[0m"; BOLD="\033[1m"; DIM="\033[2m"
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; MAGENTA="\033[35m"; CYAN="\033[36m"; WHITE="\033[37m"
if not sys.stdout.isatty():
    RESET=BOLD=DIM=RED=GREEN=YELLOW=BLUE=MAGENTA=CYAN=WHITE=""

ansi_re=re.compile(r'\x1b\[[0-9;]*m')
def strip(s): return ansi_re.sub('', str(s))
def num(x):
    try:
        sx=str(x).strip()
        if sx.upper() in ('NA','N/A','--',''): return None
        return float(sx)
    except Exception:
        return None
def fmt(v, nd=1):
    x=num(v); return '--' if x is None else f'{x:.{nd}f}'
def pct(v):
    x=num(v); return '--' if x is None else f'{x:.1f}%'
def color_score(v):
    x=num(v) or 0
    return GREEN if x>=82 else CYAN if x>=66 else YELLOW if x>=56 else RED
def color_loss(v):
    x=num(v)
    if x is None: return YELLOW
    return GREEN if x<=2 else CYAN if x<=8 else YELLOW if x<=20 else RED
def color_good(v):
    x=num(v)
    if x is None: return YELLOW
    return GREEN if x>=90 else CYAN if x>=70 else YELLOW if x>=50 else RED
def bar(v,width=26,maxv=100,low_good=False):
    x=num(v)
    if x is None:
        return DIM+'░'*width+RESET
    pctv=max(0,min(100,x/maxv*100 if maxv else 0))
    if low_good:
        col=GREEN if x<=70 else CYAN if x<=120 else YELLOW if x<=180 else RED
    else:
        col=color_score(pctv)
    n=round(pctv/100*width)
    return col+'█'*n+DIM+'░'*(width-n)+RESET
def read_csv(p):
    try:
        with open(p, encoding='utf-8-sig') as f:
            return list(csv.DictReader(f))
    except Exception:
        return []
def read_base(p):
    data={}
    try:
        for line in open(p, encoding='utf-8', errors='ignore'):
            line=line.strip()
            for key in ['IPv4','IPv6','归属地','ASN','组织/运营商','默认网关']:
                if line.startswith(f'- {key}：'):
                    data[key]=line.split('：',1)[1].strip()
    except Exception:
        pass
    return data
def isp_code(r):
    isp=r.get('ISP',''); name=r.get('运营商','')
    if isp=='CT' or '电信' in name: return 'CT'
    if isp=='CU' or '联通' in name: return 'CU'
    if isp=='CM' or '移动' in name: return 'CM'
    return isp or name[:2]
def isp_cn(code):
    return {'CT':'中国电信','CU':'中国联通','CM':'中国移动'}.get(code,code)
def use_label(score):
    x=num(score) or 0
    return '主力' if x>=82 else '可用' if x>=66 else '备用' if x>=56 else '轻量'
def speed_state(r):
    dn=num(r.get('平均下载Mbps')); up=num(r.get('平均上传Mbps')); n=num(r.get('测速点数'))
    if dn is not None or up is not None: return 'OK'
    if n is None or n==0: return 'NO-ST'
    return 'FAIL'
routes=read_csv(route_csv)
route_map={r.get('ISP',''):{'bb':r.get('回程骨干识别',''), 'ft':r.get('关键特征','')} for r in routes}
def route_short(isp):
    bb=(route_map.get(isp,{}) or {}).get('bb','') or 'UNKNOWN'
    for a,b in [
        ('电信国际/CTG 或 163 出口','CTG/163'),('电信 163 骨干','163'),('CN2 精品网','CN2'),
        ('联通 169 骨干 / AS4837','169/4837'),('联通 A 网 / CUII / 9929 疑似','9929/CUII'),
        ('联通国际精品 / AS10099','AS10099'),('移动 CMNET 骨干 / AS9808','CMNET'),('移动国际 CMI','CMI'),
        ('快速模式未执行路由采样','NO-ROUTE'),('路由隐藏较多，暂无法自动识别','HIDDEN'),
        ('未识别到典型骨干标记','CHECK-RAW'),('未取得路由样本','NO-SAMPLE')]:
        bb=bb.replace(a,b)
    return bb.replace(' / ','+')
def key_short(isp):
    ft=(route_map.get(isp,{}) or {}).get('ft','') or ''
    keys=['59.43','202.97','219.158','218.105','210.51','210.52','221.183','221.176','223.120','223.121','223.118','AS4837','AS9929','AS9808','CTG','CMI','CN2']
    out=[]
    for k in keys:
        if k.lower() in ft.lower() and k not in out:
            out.append(k)
    return '/'.join(out[:6]) if out else 'CHECK-RAW'
def section(title):
    print()
    print(CYAN+'='*92+RESET)
    print(CYAN+'◆ '+BOLD+title+RESET)
    print(CYAN+'-'*92+RESET)
def wrap_print(prefix, text, width=86):
    text=str(text or '').replace('\n',' ')
    lines=textwrap.wrap(text, width=width-len(prefix), break_long_words=False, replace_whitespace=True) or ['']
    for i,line in enumerate(lines):
        print((prefix if i==0 else ' '*len(prefix)) + line)
def compact_advice(s):
    s=str(s or '').replace('\n',' ')
    replacements=[
        ('波动或样本偏弱，建议结合路由与高峰复测再判断','波动偏弱，建议晚高峰复测'),
        ('基础可用，更适合作为备用或轻量线路','基础可用，偏备用/轻量'),
        ('中等偏上，可用性尚可，建议结合实际业务与高峰表现判断','可用，需结合业务体感'),
        ('整体良好，日常使用问题不大，兼顾主力/备用均可','整体良好，可主备两用'),
        ('整体很强，可作为主力使用；建议晚高峰再复测确认','整体很强，建议高峰确认'),
    ]
    for a,b in replacements:
        s=s.replace(a,b)
    return s

rows=read_csv(overview)
rows.sort(key=lambda r: num(r.get('综合评分')) or 0, reverse=True)
base=read_base(base_info)
capacity_rows=read_csv(capacity_csv)
capacity=capacity_rows[0] if capacity_rows else {}

section('一、VPS 基础信息')
print(f"IPv4        : {base.get('IPv4','--')}")
print(f"IPv6        : {base.get('IPv6','--')}")
print(f"归属地      : {base.get('归属地','--')}")
print(f"ASN/组织    : {base.get('ASN','--')} / {base.get('组织/运营商','--')}")
print(f"默认网关    : {base.get('默认网关','--')}")

section('二、全量容量压测')
if capacity:
    cap_values=[num(capacity.get(key)) for key in ['单线下行Mbps','多线下行Mbps','最大下行Mbps','单线上行Mbps','多线上行Mbps','最大上行Mbps']]
    cap_scale=max([value for value in cap_values if value is not None] or [100])
    cap_scale=max(100, cap_scale*1.08)
    print(f"模式/端点   : {capacity.get('测试模式','--')} / {capacity.get('测试端点','--')}")
    print(f"网卡/线程   : {capacity.get('网络接口','--')} / {capacity.get('下行多线程数','--')} threads")
    print()
    print(CYAN+BOLD+'DOWN 下行'+RESET)
    for label,key in [('单线','单线下行Mbps'),('多线','多线下行Mbps'),('最大','最大下行Mbps')]:
        print(f"  {label:<4} {bar(capacity.get(key),32,cap_scale)} {fmt(capacity.get(key)):>8} Mb/s")
    print()
    print(MAGENTA+BOLD+'UP 上行'+RESET)
    for label,key in [('单线','单线上行Mbps'),('多线','多线上行Mbps'),('最大','最大上行Mbps')]:
        print(f"  {label:<4} {bar(capacity.get(key),32,cap_scale)} {fmt(capacity.get(key)):>8} Mb/s")
    print()
    print(f"HTTP        : Avg {fmt(capacity.get('HTTP平均延迟ms'))} ms / P50 {fmt(capacity.get('HTTP_P50ms'))} / P95 {fmt(capacity.get('HTTP_P95ms'))}")
    print(f"HTTP 品质   : Jitter {fmt(capacity.get('HTTP抖动ms'))} ms / Loss {pct(capacity.get('HTTP层丢包率%'))} / Samples {capacity.get('HTTP样本数','--')}")
    print(f"ICMP 品质   : Avg {fmt(capacity.get('ICMP平均延迟ms'))} ms / Jitter {fmt(capacity.get('ICMP抖动ms'))} / Loss {pct(capacity.get('ICMP丢包率%'))}")
    print(f"并发增益    : Down ×{fmt(capacity.get('下行并发增益x'),2)} / Up ×{fmt(capacity.get('上行并发增益x'),2)} / 持续利用 {pct(capacity.get('下行持续利用率%'))} / {pct(capacity.get('上行持续利用率%'))}")
    print(f"实际流量    : Down {fmt(capacity.get('估算下行流量MB'))} MB / Up {fmt(capacity.get('估算上行流量MB'))} MB / Status {capacity.get('状态','--')}")
    if capacity.get('备注'):
        wrap_print('说明        : ', capacity.get('备注'), 88)
else:
    print('本轮未执行容量压测，或没有生成有效容量数据。')

section('三、三网核心总览')
print('说明：Score 为综合参考分；Down/Up 单位 Mb/s；-- 表示本轮无有效 Speedtest。')
for i,r in enumerate(rows,1):
    code=isp_code(r)
    score=r.get('综合评分','0')
    col=color_score(score)
    print()
    print(col+BOLD+f"[{i}] {code} {isp_cn(code)}  Score {fmt(score)} / Grade {r.get('评级','--')} / Use {use_label(score)}"+RESET)
    print(f"    Score : {bar(score,30,100)}  {fmt(score)}/100")
    print(f"    Ping  : {bar(r.get('平均Pingms'),18,220,True)}  {fmt(r.get('平均Pingms'))} ms")
    print(f"    Loss  : {color_loss(r.get('平均Ping丢包%'))}{pct(r.get('平均Ping丢包%'))}{RESET}    "
          f"TCP : {color_good(r.get('TCP成功率%'))}{pct(r.get('TCP成功率%'))}{RESET}")
    print(f"    Speed : Down {bar(r.get('平均下载Mbps'),14,500)} {fmt(r.get('平均下载Mbps'))} Mb/s    "
          f"Up {bar(r.get('平均上传Mbps'),14,200)} {fmt(r.get('平均上传Mbps'))} Mb/s    ST {speed_state(r)}")
    print(f"    Route : {CYAN}{route_short(r.get('ISP',''))}{RESET}    Key {CYAN}{key_short(r.get('ISP',''))}{RESET}")
    wrap_print("    Note  : ", compact_advice(r.get('建议','')), 88)

section('四、三网组合柱状图')
for r in rows:
    code=isp_code(r)
    print(f"{code} Score {bar(r.get('综合评分'),16,100)} {fmt(r.get('综合评分')):>5}  "
          f"Ping {bar(r.get('平均Pingms'),10,220,True)} {fmt(r.get('平均Pingms')):>6}ms  "
          f"Loss {bar(r.get('平均Ping丢包%'),10,50)} {pct(r.get('平均Ping丢包%')):>7}  "
          f"TCP {bar(r.get('TCP成功率%'),10,100)} {pct(r.get('TCP成功率%')):>7}")
    print(f"   Down {bar(r.get('平均下载Mbps'),14,500)} {fmt(r.get('平均下载Mbps')):>6} Mb/s  "
          f"Up {bar(r.get('平均上传Mbps'),14,200)} {fmt(r.get('平均上传Mbps')):>6} Mb/s  "
          f"Backbone {route_short(r.get('ISP',''))}")

section('五、回程骨干识别')
for r in rows:
    code=isp_code(r); bb=route_short(r.get('ISP','')); ks=key_short(r.get('ISP',''))
    if 'CN2' in bb or '9929' in bb or 'CMI' in bb:
        tip='疑似优质/国际骨干，建议晚高峰复核'
    elif '163' in bb or '169' in bb or 'CMNET' in bb:
        tip='普通骨干，重点看晚高峰拥塞'
    else:
        tip='建议查看原始 MTR / Traceroute'
    print(f"{code:<2} Backbone : {bb:<18}  Key : {ks:<26}  Tip : {tip}")

section('六、结论')
for r in rows:
    code=isp_code(r)
    print(f"- {code}: score {r.get('综合评分')} / {r.get('评级')} / Ping {fmt(r.get('平均Pingms'))}ms / "
          f"Loss {pct(r.get('平均Ping丢包%'))} / TCP {pct(r.get('TCP成功率%'))} / "
          f"Down {fmt(r.get('平均下载Mbps'))} Mb/s / Up {fmt(r.get('平均上传Mbps'))} Mb/s")
if rows:
    top=rows[0]
    print(YELLOW+f"\n一句话：本轮优先看 {isp_code(top)}，综合 {top.get('综合评分')} 分；是否做主力仍建议晚高峰 + 业务实测确认。"+RESET)

if rows and all(speed_state(r)!='OK' for r in rows):
    print()
    print(RED+BOLD+"Speedtest 提示：本轮没有有效 Down/Up Mb/s。若要显示上下行速度，请先运行菜单 5 安装依赖，或执行 --install --standard。"+RESET)
    print(RED+BOLD+"命令：bash cn3_vps_server_test.sh --install --standard"+RESET)

section('七、输出文件')
print(f"- Markdown 报告 : {report_md}")
print(f"- SVG 可视化    : {report_svg}")
print(f"- 容量总表 CSV  : {capacity_csv}")
print(f"- 容量原始 JSON : {capacity_json}")
print(f"- 容量时间序列  : {capacity_samples}")
print(f"- 总表 CSV      : {overview}")
print(f"- 路由摘要      : {route_csv}")
print(f"- 延迟明细      : {latency_csv}")
print(f"- 测速明细      : {speed_csv}")
print(f"- MTR/Traceroute: {out_dir}/{{mtr,traceroute}}")
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
  if [[ "$RUN_CAPACITY" -eq 1 ]]; then
    printf '%s容量参数：单线=%ss / 多线=%ss / 线程=%s / HTTP=%s 样本%s\n' "$DIM" "$CAP_SINGLE_SECONDS" "$CAP_MULTI_SECONDS" "$CAP_THREADS" "$CAP_HTTP_SAMPLES" "$RESET"
  fi
  info_note '本脚本评估的是 VPS 对中国三网方向的综合网络质量，并非家用宽带测速模型。'
  info_note '综合评分与评级仅供参考，建议结合晚高峰复测、业务类型与回程骨干观察综合判断。'
  printf '\n'

  public_ip_info "$BASEINFO_MD"
  run_capacity_stress
  if [[ "$CAPACITY_ONLY" -ne 1 ]]; then
    run_latency_tests
    run_speedtests
    build_route_summary
    aggregate_results
  else
    info_note "容量专测模式：已跳过中国三网 Ping / TCP / MTR / Ookla。"
  fi
  make_markdown_report
  make_svg_report
  render_summary_screen
}

main() {
  parse_args "$@"
  if [[ "$NON_INTERACTIVE" -eq 0 ]]; then interactive_menu; fi
  run_all
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
