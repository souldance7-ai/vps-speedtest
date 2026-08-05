#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.0.0"
APP_NAME="HuRi Link Console"
REPOSITORY="souldance7-ai/vps-speedtest"
RAW_BASE="https://raw.githubusercontent.com/${REPOSITORY}/main/huri-panel"

CONFIG_DIR="${HURI_CONFIG_DIR:-/etc/huri-panel}"
STATE_DIR="${HURI_STATE_DIR:-/var/lib/huri-panel}"
BACKUP_DIR="${HURI_BACKUP_DIR:-/var/backups/huri-panel}"
EXPORT_DIR="${HURI_EXPORT_DIR:-/root/huri-panel-exports}"
NODES_FILE="${STATE_DIR}/mieru-nodes.json"
WG_STATE_FILE="${STATE_DIR}/wireguard-instances.json"
WG_PEERS_FILE="${STATE_DIR}/wireguard-peers.json"
OPTIMIZE_FILE="/etc/sysctl.d/99-huri-panel.conf"
INSTALLED_SCRIPT="/usr/local/sbin/huri-panel"

IX_SCRIPT_URL="https://raw.githubusercontent.com/${REPOSITORY}/main/ix-route.sh"
CHINA3NET_URL="https://raw.githubusercontent.com/${REPOSITORY}/main/3net-route.sh"
CHINA3NET_SPEED_URL="https://raw.githubusercontent.com/${REPOSITORY}/main/3net-route-speed.sh"

TEMP_PATHS=()
PUBLIC_IP_CACHE=""
NO_COLOR="${NO_COLOR:-}"

if [[ -t 1 && -z "$NO_COLOR" ]]; then
  RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
  BLACK=$'\033[30m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BLUE=$'\033[34m'; MAGENTA=$'\033[35m'; CYAN=$'\033[36m'; WHITE=$'\033[37m'
  BBLACK=$'\033[90m'; BRED=$'\033[91m'; BGREEN=$'\033[92m'; BYELLOW=$'\033[93m'
  BBLUE=$'\033[94m'; BMAGENTA=$'\033[95m'; BCYAN=$'\033[96m'; BWHITE=$'\033[97m'
  BG_BLUE=$'\033[44m'; BG_MAGENTA=$'\033[45m'; BG_CYAN=$'\033[46m'; BG_WHITE=$'\033[47m'
else
  RESET=""; BOLD=""; DIM=""; BLACK=""; RED=""; GREEN=""; YELLOW=""
  BLUE=""; MAGENTA=""; CYAN=""; WHITE=""; BBLACK=""; BRED=""; BGREEN=""
  BYELLOW=""; BBLUE=""; BMAGENTA=""; BCYAN=""; BWHITE=""; BG_BLUE=""
  BG_MAGENTA=""; BG_CYAN=""; BG_WHITE=""
fi

cleanup() {
  local path
  [[ -t 1 ]] && printf '\033[?25h' 2>/dev/null || true
  for path in "${TEMP_PATHS[@]:-}"; do
    [[ -n "$path" && "$path" == /tmp/* ]] || continue
    if [[ -d "$path" ]]; then
      rm -rf -- "$path"
    else
      rm -f -- "$path"
    fi
  done
}

on_error() {
  local code="$1" line="$2"
  printf '\n%s[错误]%s 第 %s 行执行失败，退出码：%s。\n' "$BRED" "$RESET" "$line" "$code" >&2
}

trap cleanup EXIT INT TERM
trap 'on_error "$?" "$LINENO"' ERR

hide_cursor() { printf '\033[?25l'; }
show_cursor() { printf '\033[?25h'; }
clear_screen() { printf '\033[2J\033[H'; }
now() { date '+%Y-%m-%d %H:%M:%S %z'; }
stamp() { date '+%Y%m%d-%H%M%S'; }

die() {
  printf '%s[错误]%s %s\n' "$BRED" "$RESET" "$*" >&2
  exit 1
}

warn() { printf '%s[警告]%s %s\n' "$BYELLOW" "$RESET" "$*"; }
info() { printf '%s[信息]%s %s\n' "$BCYAN" "$RESET" "$*"; }
ok() { printf '%s[完成]%s %s\n' "$BGREEN" "$RESET" "$*"; }

register_temp() {
  TEMP_PATHS+=("$1")
}

pause_screen() {
  [[ -t 0 ]] || return 0
  show_cursor
  printf '\n%s按 Enter 返回面板…%s' "$DIM" "$RESET"
  IFS= read -r _ || true
  hide_cursor
}

confirm() {
  local prompt="$1" default="${2:-N}" reply suffix
  [[ "$default" == "Y" ]] && suffix="[Y/n]" || suffix="[y/N]"
  show_cursor
  printf '%s %s ' "$prompt" "$suffix"
  IFS= read -r reply || reply=""
  hide_cursor
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy]$ ]]
}

ask() {
  local __var="$1" prompt="$2" default="${3:-}" value
  show_cursor
  if [[ -n "$default" ]]; then
    printf '%s [%s]：' "$prompt" "$default"
  else
    printf '%s：' "$prompt"
  fi
  IFS= read -r value || value=""
  hide_cursor
  value="${value:-$default}"
  printf -v "$__var" '%s' "$value"
}

ask_secret() {
  local __var="$1" prompt="$2" generated="$3" value
  show_cursor
  printf '%s（直接回车使用自动生成值）：' "$prompt"
  IFS= read -rs value || value=""
  printf '\n'
  hide_cursor
  value="${value:-$generated}"
  printf -v "$__var" '%s' "$value"
}

ask_secret_required() {
  local __var="$1" prompt="$2" value
  show_cursor
  printf '%s：' "$prompt"
  IFS= read -rs value || value=""
  printf '\n'
  hide_cursor
  printf -v "$__var" '%s' "$value"
}

is_integer() { [[ "${1:-}" =~ ^(0|[1-9][0-9]*)$ ]]; }

valid_port() {
  is_integer "${1:-}" && (( 10#$1 >= 1025 && 10#$1 <= 65535 ))
}

valid_mtu() {
  is_integer "${1:-}" && (( 10#$1 >= 1280 && 10#$1 <= 1500 ))
}

valid_host() {
  local value="${1:-}"
  [[ -n "$value" && ${#value} -le 253 && "$value" =~ ^[A-Za-z0-9._:-]+$ ]]
}

valid_username() {
  [[ "${1:-}" =~ ^[A-Za-z0-9._-]{1,32}$ ]]
}

safe_file_component() {
  local value="${1:-}" safe
  safe="$(printf '%s' "$value" | tr -cs 'A-Za-z0-9._-' '_' | sed -E 's/^_+|_+$//g')"
  [[ -n "$safe" ]] || safe="client-$(openssl rand -hex 3)"
  printf '%.64s' "$safe"
}

valid_prefix24() {
  local value="${1:-}" a b c
  [[ "$value" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"; c="${BASH_REMATCH[3]}"
  (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 ))
}

require_root() {
  (( EUID == 0 )) || die "请使用 root 身份运行：sudo bash huri-panel.sh"
}

debian_major() {
  local version=""
  [[ -r /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "debian" ]] || return 1
  version="${VERSION_ID%%.*}"
  printf '%s' "$version"
}

require_supported_os() {
  local major
  major="$(debian_major 2>/dev/null || true)"
  [[ "$major" == "12" || "$major" == "13" ]] || \
    die "本工具仅支持全新或现有 Debian 12 / Debian 13；当前系统不在支持范围。"
}

ensure_layout() {
  install -d -m 0700 "$CONFIG_DIR" "$STATE_DIR" "$BACKUP_DIR" "$EXPORT_DIR"
  [[ -f "$NODES_FILE" ]] || printf '[]\n' > "$NODES_FILE"
  [[ -f "$WG_STATE_FILE" ]] || printf '[]\n' > "$WG_STATE_FILE"
  [[ -f "$WG_PEERS_FILE" ]] || printf '[]\n' > "$WG_PEERS_FILE"
  chmod 0600 "$NODES_FILE" "$WG_STATE_FILE" "$WG_PEERS_FILE"
}

apt_install() {
  local packages=("$@")
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends "${packages[@]}"
}

ensure_base_dependencies() {
  local missing=() cmd
  for cmd in curl jq openssl ip ss python3; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]})); then
    info "正在安装基础依赖：curl、jq、ca-certificates、openssl、iproute2、python3。"
    apt_install curl jq ca-certificates openssl iproute2 python3 procps kmod
  fi
}

local_ipv4() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

default_iface() {
  ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}'
}

public_ipv4() {
  local candidate=""
  if [[ -n "$PUBLIC_IP_CACHE" ]]; then
    printf '%s' "$PUBLIC_IP_CACHE"
    return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    candidate="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    [[ "$candidate" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || \
      candidate="$(curl -4fsS --max-time 5 https://ifconfig.me/ip 2>/dev/null || true)"
  fi
  [[ "$candidate" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || candidate=""
  PUBLIC_IP_CACHE="$candidate"
  printf '%s' "$candidate"
}

is_private_ipv4() {
  local ip="${1:-}"
  [[ "$ip" =~ ^10\. || "$ip" =~ ^192\.168\. || "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. || "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]
}

mita_status_short() {
  if ! command -v mita >/dev/null 2>&1; then
    printf '未安装'
    return
  fi
  if timeout 3 mita status 2>/dev/null | grep -q 'RUNNING'; then
    printf '运行中'
  elif systemctl is-active --quiet mita 2>/dev/null; then
    printf '待配置'
  else
    printf '已停止'
  fi
}

wg_instance_count() {
  local count=0 file
  shopt -s nullglob
  for file in /etc/wireguard/wg-huri*.conf; do
    [[ -f "$file" ]] && ((count += 1))
  done
  shopt -u nullglob
  printf '%s' "$count"
}

draw_logo() {
  local major local_ip pub mita_s wg_s
  major="$(debian_major 2>/dev/null || printf '?')"
  local_ip="$(local_ipv4 2>/dev/null || true)"; local_ip="${local_ip:---}"
  pub="${PUBLIC_IP_CACHE:---}"
  mita_s="$(mita_status_short)"; wg_s="$(wg_instance_count)"
  printf '%s%s╔══════════════════════════════════════════════════════════════════════╗%s\n' "$BOLD" "$BCYAN" "$RESET"
  printf '%s%s║%s  %s▓▒░  H U R I   L I N K   C O N S O L E  ░▒▓%s                   %s%s║%s\n' "$BOLD" "$BCYAN" "$RESET" "$BMAGENTA" "$RESET" "$BOLD" "$BCYAN" "$RESET"
  printf '%s%s║%s  沪日合规隧道交付面板 · Debian 12/13 · v%-25s%s%s║%s\n' "$BOLD" "$BCYAN" "$RESET" "$VERSION" "$BOLD" "$BCYAN" "$RESET"
  printf '%s%s╠══════════════════════════════════════════════════════════════════════╣%s\n' "$BOLD" "$BCYAN" "$RESET"
  printf '%s%s║%s  OS D%-2s  本机 %-15s  公网 %-15s                 %s%s║%s\n' "$BOLD" "$BCYAN" "$RESET" "$major" "$local_ip" "$pub" "$BOLD" "$BCYAN" "$RESET"
  printf '%s%s║%s  Mieru %-8s  WireGuard %-2s套  模式：仅合规隧道                   %s%s║%s\n' "$BOLD" "$BCYAN" "$RESET" "$mita_s" "$wg_s" "$BOLD" "$BCYAN" "$RESET"
  printf '%s%s╚══════════════════════════════════════════════════════════════════════╝%s\n' "$BOLD" "$BCYAN" "$RESET"
}

rule_wall() {
  printf '%s合规边界：%s仅部署 Mieru / WireGuard；不创建 SS、HTTP(S)、TLS、VLESS、\n' "$BYELLOW" "$RESET"
  printf '          VMess、Trojan、TUIC、Hysteria 等供应商明确禁止的入口协议。\n'
}

action_header() {
  clear_screen
  draw_logo
  printf '\n%s%s── %s ─────────────────────────────────────────────────────────%s\n\n' "$BOLD" "$BMAGENTA" "$1" "$RESET"
}

read_key() {
  local key rest
  IFS= read -rsn1 key || { printf 'QUIT'; return; }
  if [[ "$key" == $'\x1b' ]]; then
    IFS= read -rsn2 -t 0.08 rest || rest=""
    case "$rest" in
      '[A') printf 'UP' ;;
      '[B') printf 'DOWN' ;;
      '[C') printf 'RIGHT' ;;
      '[D') printf 'LEFT' ;;
      *) printf 'ESC' ;;
    esac
  elif [[ "$key" == "" ]]; then
    printf 'ENTER'
  elif [[ "$key" == "q" || "$key" == "Q" ]]; then
    printf 'QUIT'
  else
    printf '%s' "$key"
  fi
}

health_check() {
  action_header "系统体检 / HEALTH CHECK"
  ensure_base_dependencies
  ensure_layout

  local report os kernel arch virt cpu mem disk iface lip pip nat cc qdisc sync uptime_value
  report="${EXPORT_DIR}/HuRi-Health-$(stamp).txt"
  os="$(. /etc/os-release; printf '%s %s' "$PRETTY_NAME" "${VERSION_CODENAME:-}")"
  kernel="$(uname -r)"; arch="$(uname -m)"
  virt="$(systemd-detect-virt 2>/dev/null || printf 'unknown')"
  cpu="$(nproc 2>/dev/null || printf '?')"
  mem="$(awk '/MemTotal/{printf "%.0f MB",$2/1024}' /proc/meminfo)"
  disk="$(df -hP / | awk 'NR==2 {print $3" / "$2"（"$5"）"}')"
  iface="$(default_iface)"; lip="$(local_ipv4)"; pip="$(public_ipv4)"
  nat="否"; { is_private_ipv4 "$lip" || [[ -n "$pip" && "$lip" != "$pip" ]]; } && nat="是／需核对商家端口映射"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'unknown')"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || printf 'unknown')"
  sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || printf 'unknown')"
  uptime_value="$(uptime -p 2>/dev/null || true)"

  {
    printf 'HuRi Link Console 系统体检报告\n'
    printf '生成时间：%s\n' "$(now)"
    printf '============================================================\n'
    printf '系统：%s\n内核：%s\n架构：%s\n虚拟化：%s\n' "$os" "$kernel" "$arch" "$virt"
    printf 'CPU：%s vCPU\n内存：%s\n磁盘：%s\n运行时间：%s\n' "$cpu" "$mem" "$disk" "$uptime_value"
    printf '默认网卡：%s\n本机 IPv4：%s\n公网 IPv4：%s\nNAT：%s\n' "$iface" "${lip:-unknown}" "${pip:-unknown}" "$nat"
    printf 'TCP 拥塞控制：%s\n默认队列：%s\n时间同步：%s\n' "$cc" "$qdisc" "$sync"
    printf 'Mieru：%s\nWireGuard 实例：%s\n' "$(mita_status_short)" "$(wg_instance_count)"
    printf 'IPv4 转发：%s\n' "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || printf 'unknown')"
    printf '============================================================\n'
    printf '监听端口（TCP/UDP）：\n'
    ss -H -lntup 2>/dev/null || true
  } | tee "$report"

  printf '\n'
  [[ "$sync" == "yes" ]] || warn "系统时间未确认同步。Mieru 密钥计算依赖系统时间，部署前应先校时。"
  [[ "$nat" == "否" ]] || warn "检测到 NAT/内网地址：客户端必须填写商家公网 IP 与公网端口，不能填写本机内网地址。"
  ok "体检报告已保存：$report"
  PUBLIC_IP_CACHE="$pip"
  pause_screen
}

show_ports_services() {
  action_header "端口与服务 / PORTS & SERVICES"
  printf '%s监听端口：%s\n' "$BCYAN" "$RESET"
  ss -tulpn 2>/dev/null || true
  printf '\n%sMieru 服务：%s\n' "$BCYAN" "$RESET"
  systemctl --no-pager --full status mita 2>/dev/null | sed -n '1,18p' || printf '未安装 mita。\n'
  printf '\n%sWireGuard：%s\n' "$BCYAN" "$RESET"
  wg show 2>/dev/null || printf '没有运行中的 WireGuard 接口。\n'
  pause_screen
}

apply_optimization() {
  action_header "保守网络优化 / BBR + FQ"
  rule_wall
  printf '\n本项仅调整 TCP Mieru 的系统参数；WireGuard 为 UDP，不会因 BBR 直接提速。\n'
  printf '不会修改 SSH 端口、路由表、商家 NAT 映射或现有协议配置。\n\n'
  confirm "确认写入可回滚的 sysctl 配置？" "N" || { pause_screen; return; }
  ensure_base_dependencies
  apt_install iproute2 procps kmod

  local ts backup_marker ram_kb buf tmp available
  ts="$(stamp)"
  if [[ -f "$OPTIMIZE_FILE" ]]; then
    backup_marker="${BACKUP_DIR}/99-huri-panel.conf.${ts}.bak"
    cp -a -- "$OPTIMIZE_FILE" "$backup_marker"
  else
    backup_marker="${BACKUP_DIR}/99-huri-panel.conf.${ts}.absent"
    : > "$backup_marker"
  fi

  modprobe tcp_bbr 2>/dev/null || true
  modprobe sch_fq 2>/dev/null || true
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  ram_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
  if (( ram_kb < 2097152 )); then buf=16777216; else buf=33554432; fi

  tmp="$(mktemp /tmp/huri-sysctl.XXXXXX)"; register_temp "$tmp"
  {
    printf '# HuRi Link Console v%s - conservative TCP tuning\n' "$VERSION"
    printf 'net.core.default_qdisc = fq\n'
    [[ " $available " == *" bbr "* ]] && printf 'net.ipv4.tcp_congestion_control = bbr\n'
    printf 'net.ipv4.tcp_mtu_probing = 1\n'
    printf 'net.ipv4.tcp_fastopen = 3\n'
    printf 'net.ipv4.tcp_slow_start_after_idle = 0\n'
    printf 'net.core.rmem_max = %s\n' "$buf"
    printf 'net.core.wmem_max = %s\n' "$buf"
    printf 'net.ipv4.tcp_rmem = 4096 131072 %s\n' "$buf"
    printf 'net.ipv4.tcp_wmem = 4096 16384 %s\n' "$buf"
  } > "$tmp"
  install -m 0644 "$tmp" "$OPTIMIZE_FILE"
  if ! sysctl --system; then
    warn "sysctl --system 返回非零状态，请检查上方输出；配置文件与备份均已保留。"
  fi

  printf '\n当前拥塞控制：%s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  printf '当前默认队列：%s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  [[ " $available " == *" bbr "* ]] || warn "当前内核没有提供 BBR，脚本已保留其他安全参数，未安装第三方内核模块。"
  ok "优化已应用；回滚标记：$backup_marker"
  warn "现有网卡队列可能需重启后完全采用新的默认 qdisc；脚本不会强制中断当前 SSH。"
  pause_screen
}

rollback_optimization() {
  action_header "回滚最近一次网络优化"
  local latest=""
  latest="$(find "$BACKUP_DIR" -maxdepth 1 -type f \
    \( -name '99-huri-panel.conf.*.bak' -o -name '99-huri-panel.conf.*.absent' \) \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk 'NR==1{$1=""; sub(/^ /,""); print}')"
  if [[ -z "$latest" ]]; then
    warn "没有找到可回滚记录。"
    pause_screen
    return
  fi
  printf '最近备份：%s\n' "$latest"
  confirm "确认恢复该状态？" "N" || { pause_screen; return; }
  if [[ "$latest" == *.absent ]]; then
    rm -f -- "$OPTIMIZE_FILE"
  else
    cp -a -- "$latest" "$OPTIMIZE_FILE"
  fi
  if ! sysctl --system; then
    warn "回滚文件已恢复，但系统中另有 sysctl 项返回错误，请根据上方输出核对。"
  fi
  ok "已恢复最近一次优化前状态。"
  pause_screen
}

install_mieru() {
  action_header "安装 / 升级官方 Mieru 服务端"
  rule_wall
  printf '\n安装源：enfein/mieru 官方 GitHub Release；下载 .deb 与官方 SHA-256 校验文件。\n'
  confirm "继续安装或升级 mita？" "N" || { pause_screen; return; }
  ensure_base_dependencies

  local arch release tag version asset sum_asset url sum_url tmp_dir deb sum expected
  arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64|arm64) ;;
    *) warn "当前架构 $arch 暂未纳入自动安装；仅支持 amd64 / arm64。"; pause_screen; return ;;
  esac

  release="$(curl -fsSL --retry 3 --connect-timeout 10 \
    https://api.github.com/repos/enfein/mieru/releases/latest)"
  tag="$(jq -r '.tag_name // empty' <<<"$release")"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "无法识别官方最新版本标签。"
  version="${tag#v}"
  asset="mita_${version}_${arch}.deb"
  sum_asset="${asset}.sha256.txt"
  url="$(jq -r --arg name "$asset" '.assets[] | select(.name==$name) | .browser_download_url' <<<"$release")"
  sum_url="$(jq -r --arg name "$sum_asset" '.assets[] | select(.name==$name) | .browser_download_url' <<<"$release")"
  [[ -n "$url" && -n "$sum_url" ]] || die "官方 Release 中缺少 $asset 或校验文件。"

  tmp_dir="$(mktemp -d /tmp/huri-mieru.XXXXXX)"; register_temp "$tmp_dir"
  deb="${tmp_dir}/${asset}"; sum="${tmp_dir}/${sum_asset}"
  curl -fL --retry 3 "$url" -o "$deb"
  curl -fL --retry 3 "$sum_url" -o "$sum"
  expected="$(awk 'NR==1 {print $1}' "$sum")"
  [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || die "官方 SHA-256 文件格式异常。"
  printf '%s  %s\n' "$expected" "$deb" | sha256sum -c -
  apt-get install -y "$deb"
  systemctl enable --now mita
  command -v mita >/dev/null 2>&1 || die "mita 安装后仍不可用。"
  ok "Mieru 服务端已安装：${tag}"
  mita status || true
  pause_screen
}

port_in_use() {
  local port="$1" proto="$2"
  if [[ "$proto" == "TCP" ]]; then
    ss -H -lntp 2>/dev/null | awk '{print $4" "$NF}' | grep -Eq "(^|:)${port}[[:space:]]"
  else
    ss -H -lnup 2>/dev/null | awk '{print $4" "$NF}' | grep -Eq "(^|:)${port}[[:space:]]"
  fi
}

backup_mita_description() {
  local file="${BACKUP_DIR}/mita-described-$(stamp).txt"
  if command -v mita >/dev/null 2>&1; then
    mita describe config > "$file" 2>&1 || true
    chmod 0600 "$file"
    printf '%s' "$file"
  fi
}

registry_add_node() {
  local name="$1" server="$2" port="$3" transport="$4" username="$5" password="$6" mtu="$7"
  local id created tmp
  id="$(date +%s)-$(openssl rand -hex 3)"
  created="$(date --iso-8601=seconds)"
  tmp="$(mktemp /tmp/huri-nodes.XXXXXX)"; register_temp "$tmp"
  jq --arg id "$id" --arg name "$name" --arg server "$server" \
    --argjson port "$port" --arg transport "$transport" --arg username "$username" \
    --arg password "$password" --argjson mtu "$mtu" --arg created "$created" \
    '. + [{id:$id,name:$name,server:$server,port:$port,transport:$transport,
      username:$username,password:$password,mtu:$mtu,multiplexing:"MULTIPLEXING_LOW",
      handshakeMode:"HANDSHAKE_STANDARD",enabled:true,createdAt:$created}]' \
    "$NODES_FILE" > "$tmp"
  install -m 0600 "$tmp" "$NODES_FILE"
}

maybe_open_ufw() {
  local port="$1" proto="$2" lower
  lower="${proto,,}"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    if confirm "UFW 已启用，是否放行本机 ${port}/${lower}？" "Y"; then
      ufw allow "${port}/${lower}" comment 'HuRi Link Console'
    fi
  else
    info "未检测到启用中的 UFW；不修改本机防火墙。"
  fi
}

configure_mieru_server() {
  action_header "新购交机：建立 Mieru 节点"
  rule_wall
  ensure_base_dependencies
  ensure_layout
  if ! command -v mita >/dev/null 2>&1; then
    warn "尚未安装 mita，请先在 Mieru 页执行“安装／升级官方 Mieru”。"
    pause_screen
    return
  fi
  if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" != "yes" ]]; then
    warn "系统时间尚未确认同步；Mieru 认证依赖两端时间。"
    if confirm "尝试启用系统 NTP 自动校时？" "Y"; then
      timedatectl set-ntp true 2>/dev/null || warn "无法自动启用 NTP，请稍后手动校时。"
      sleep 2
    fi
  fi

  local existing node_name endpoint mapping_count username generated_password password mtu
  local i public_port local_port transport ports_json mappings_json config tmp backup_file node_label
  existing="$(mita describe config 2>/dev/null || true)"
  if [[ -n "$existing" && "$existing" != *'{}'* ]]; then
    warn "检测到现有 mita 配置。本操作使用官方合并语义添加端口／用户，不会自动清空旧配置。"
    confirm "确认在备份当前描述后继续合并？" "N" || { pause_screen; return; }
  fi

  ask node_name "节点名称" "沪日-Mieru"
  [[ -n "$node_name" && ${#node_name} -le 80 && ! "$node_name" =~ $'\n' ]] || \
    { warn "节点名称无效或超过 80 个字符。"; pause_screen; return; }
  endpoint="$(public_ipv4)"
  ask endpoint "客户端使用的公网 IP / 域名" "${endpoint:-}"
  valid_host "$endpoint" || { warn "公网地址格式无效。"; pause_screen; return; }
  ask mapping_count "端口映射数量（1-8）" "1"
  is_integer "$mapping_count" && ((mapping_count >= 1 && mapping_count <= 8)) || \
    { warn "端口映射数量必须为 1-8。"; pause_screen; return; }
  mapping_count=$((10#$mapping_count))

  generated_password="$(openssl rand -hex 18)"
  ask username "Mieru 用户名（字母、数字、点、下划线、横线）" "huri_$(openssl rand -hex 3)"
  valid_username "$username" || { warn "用户名格式无效。"; pause_screen; return; }
  ask_secret password "Mieru 密码" "$generated_password"
  [[ ${#password} -ge 12 && ! "$password" =~ [[:space:]] ]] || \
    { warn "密码至少 12 位且不能包含空白字符。"; pause_screen; return; }
  ask mtu "传输 MTU（UDP 弱网可用 1280；通用默认 1400）" "1400"
  valid_mtu "$mtu" || { warn "MTU 必须为 1280-1500。"; pause_screen; return; }
  mtu=$((10#$mtu))

  ports_json='[]'; mappings_json='[]'
  for ((i=1; i<=mapping_count; i++)); do
    printf '\n%s第 %s 组端口映射%s\n' "$BMAGENTA" "$i" "$RESET"
    ask public_port "商家公网端口（客户端填写）" "$((10502 + i))"
    valid_port "$public_port" || { warn "公网端口必须为 1025-65535。"; pause_screen; return; }
    public_port=$((10#$public_port))
    ask local_port "VDS 本机监听端口（同端映射直接回车）" "$public_port"
    valid_port "$local_port" || { warn "本机端口必须为 1025-65535。"; pause_screen; return; }
    local_port=$((10#$local_port))
    ask transport "传输协议 TCP / UDP（推荐先 TCP）" "TCP"
    transport="${transport^^}"
    [[ "$transport" == "TCP" || "$transport" == "UDP" ]] || \
      { warn "传输协议只能是 TCP 或 UDP。"; pause_screen; return; }
    if port_in_use "$local_port" "$transport"; then
      warn "本机 ${local_port}/${transport} 已被监听："
      ss -lntup 2>/dev/null | grep -E ":${local_port}[[:space:]]" || true
      confirm "若确认是现有 mita 端口，是否继续合并？" "N" || { pause_screen; return; }
    fi
    ports_json="$(jq --argjson port "$local_port" --arg protocol "$transport" \
      '. + [{port:$port,protocol:$protocol}]' <<<"$ports_json")"
    mappings_json="$(jq --argjson publicPort "$public_port" --argjson localPort "$local_port" \
      --arg protocol "$transport" '. + [{publicPort:$publicPort,localPort:$localPort,protocol:$protocol}]' \
      <<<"$mappings_json")"
  done

  config="$(jq -n --argjson ports "$ports_json" --arg user "$username" --arg pass "$password" \
    --argjson mtu "$mtu" '{portBindings:$ports,users:[{name:$user,password:$pass}],loggingLevel:"INFO",mtu:$mtu}')"
  tmp="$(mktemp /tmp/huri-mita.XXXXXX.json)"; register_temp "$tmp"
  printf '%s\n' "$config" > "$tmp"
  backup_file="$(backup_mita_description)"
  install -m 0600 "$tmp" "${CONFIG_DIR}/mita-$(stamp).json"

  printf '\n将写入以下本机监听：\n'
  jq -r '.[] | "  - \(.localPort)/\(.protocol)  ← 公网 \(.publicPort)/\(.protocol)"' <<<"$mappings_json"
  printf '公网端点：%s\n' "$endpoint"
  confirm "确认应用以上 Mieru 配置？" "N" || { pause_screen; return; }

  mita apply config "$tmp"
  mita stop >/dev/null 2>&1 || true
  sleep 1
  mita start
  sleep 2
  mita status

  for ((i=0; i<mapping_count; i++)); do
    public_port="$(jq -r ".[$i].publicPort" <<<"$mappings_json")"
    local_port="$(jq -r ".[$i].localPort" <<<"$mappings_json")"
    transport="$(jq -r ".[$i].protocol" <<<"$mappings_json")"
    node_label="$node_name"
    (( mapping_count > 1 )) && node_label="${node_name}-${transport}-${public_port}"
    registry_add_node "$node_label" "$endpoint" "$public_port" "$transport" "$username" "$password" "$mtu"
    maybe_open_ufw "$local_port" "$transport"
  done

  ok "Mieru 已启动，节点已加入本机集群清单。"
  [[ -n "$backup_file" ]] && info "原配置描述备份：$backup_file"
  warn "若公网端口与本机端口不同，请在商家后台确认公网 → 内网映射；脚本无法代替商家开端口。"
  generate_mihomo_config false
  pause_screen
}

show_mieru_status() {
  action_header "Mieru 状态与配置"
  local described
  if ! command -v mita >/dev/null 2>&1; then
    warn "mita 未安装。"
    pause_screen
    return
  fi
  systemctl --no-pager --full status mita 2>/dev/null | sed -n '1,20p' || true
  printf '\n%s运行状态：%s\n' "$BCYAN" "$RESET"
  mita status || true
  printf '\n%s当前配置：%s\n' "$BCYAN" "$RESET"
  described="$(mita describe config 2>/dev/null || true)"
  if confirm "是否显示完整配置（可能含密码）？" "N"; then
    printf '%s\n' "$described"
  elif jq -e . >/dev/null 2>&1 <<<"$described"; then
    jq '(.users[]?.password) = "********"' <<<"$described"
  else
    sed -E 's/("password"[[:space:]]*:[[:space:]]*")[^"]*(")/\1********\2/g' <<<"$described"
  fi
  printf '\n%s相关监听：%s\n' "$BCYAN" "$RESET"
  ss -lntup 2>/dev/null | grep -E 'mita|mieru' || true
  pause_screen
}

add_existing_node() {
  action_header "加入已有沪日 Mieru 节点"
  ensure_base_dependencies
  ensure_layout
  local name server port transport username password mtu
  ask name "节点名称" "沪日-$(date +%m%d)-M"
  ask server "公网 IP / 域名" ""
  valid_host "$server" || { warn "地址无效。"; pause_screen; return; }
  ask port "公网业务端口" "10503"
  valid_port "$port" || { warn "端口必须为 1025-65535。"; pause_screen; return; }
  port=$((10#$port))
  ask transport "传输协议 TCP / UDP" "TCP"; transport="${transport^^}"
  [[ "$transport" == "TCP" || "$transport" == "UDP" ]] || { warn "仅支持 TCP / UDP。"; pause_screen; return; }
  ask username "用户名" ""
  valid_username "$username" || { warn "用户名格式无效。"; pause_screen; return; }
  ask_secret_required password "输入已有节点的真实密码"
  [[ ${#password} -ge 8 && ! "$password" =~ [[:space:]] ]] || { warn "密码格式无效。"; pause_screen; return; }
  ask mtu "MTU" "$([[ "$transport" == "UDP" ]] && printf 1280 || printf 1400)"
  valid_mtu "$mtu" || { warn "MTU 必须为 1280-1500。"; pause_screen; return; }
  mtu=$((10#$mtu))
  registry_add_node "$name" "$server" "$port" "$transport" "$username" "$password" "$mtu"
  ok "节点已加入本机清单。"
  generate_mihomo_config false
  pause_screen
}

list_nodes() {
  action_header "沪日节点清单"
  ensure_base_dependencies
  ensure_layout
  local count
  count="$(jq 'length' "$NODES_FILE")"
  if (( count == 0 )); then
    warn "节点清单为空。"
  else
    jq -r 'to_entries[] | "\(.key+1). \(.value.name)｜\(.value.server):\(.value.port)/\(.value.transport)｜用户 \(.value.username)｜MTU \(.value.mtu)"' "$NODES_FILE"
    printf '\n%s共 %s 个节点。密码仅保存在 root 可读的状态文件与导出文件中。%s\n' "$DIM" "$count" "$RESET"
  fi
  pause_screen
}

delete_node() {
  action_header "删除节点清单记录"
  ensure_base_dependencies
  ensure_layout
  local count choice index tmp name
  count="$(jq 'length' "$NODES_FILE")"
  if (( count == 0 )); then warn "节点清单为空。"; pause_screen; return; fi
  jq -r 'to_entries[] | "\(.key+1). \(.value.name)｜\(.value.server):\(.value.port)/\(.value.transport)"' "$NODES_FILE"
  ask choice "输入要删除的序号（只删本机记录，不停止远端服务）" ""
  is_integer "$choice" && ((choice >= 1 && choice <= count)) || { warn "序号无效。"; pause_screen; return; }
  index=$((choice - 1)); name="$(jq -r ".[$index].name" "$NODES_FILE")"
  confirm "确认删除清单记录：${name}？" "N" || { pause_screen; return; }
  tmp="$(mktemp /tmp/huri-delete.XXXXXX)"; register_temp "$tmp"
  jq "del(.[$index])" "$NODES_FILE" > "$tmp"
  install -m 0600 "$tmp" "$NODES_FILE"
  ok "已删除清单记录；远端 Mieru 服务未改动。"
  pause_screen
}

yaml_quote() {
  jq -Rn --arg value "$1" '$value'
}

uri_encode() {
  jq -rn --arg value "$1" '$value|@uri'
}

generate_mihomo_config() {
  local interactive="${1:-true}"
  [[ "$interactive" == "true" ]] && action_header "生成 FLClash / Mihomo 多沪日配置"
  ensure_base_dependencies
  ensure_layout
  local count config_out links_out tmp_config tmp_links i row name server port transport username password mtu
  local qname qserver quser qpass uri_host user_enc pass_enc profile_enc names=()
  count="$(jq '[.[] | select(.enabled == true)] | length' "$NODES_FILE")"
  if (( count == 0 )); then
    warn "没有可导出的 Mieru 节点。"
    [[ "$interactive" == "true" ]] && pause_screen
    return 0
  fi

  config_out="${EXPORT_DIR}/HuRi-Mieru-FLClash.yaml"
  links_out="${EXPORT_DIR}/HuRi-Mieru-ShareLinks.txt"
  tmp_config="$(mktemp /tmp/huri-mihomo.XXXXXX)"; register_temp "$tmp_config"
  tmp_links="$(mktemp /tmp/huri-links.XXXXXX)"; register_temp "$tmp_links"

  {
    printf '# HuRi Link Console v%s\n' "$VERSION"
    printf '# 轮巡与一致性哈希是连接级分流，不是单连接带宽叠加。\n'
    printf 'mixed-port: 7890\nallow-lan: false\nmode: rule\nlog-level: info\nunified-delay: true\ntcp-concurrent: true\n\n'
    printf 'proxies:\n'
  } > "$tmp_config"
  : > "$tmp_links"

  for ((i=0; i<count; i++)); do
    row="$(jq -c '[.[] | select(.enabled == true)]['"$i"']' "$NODES_FILE")"
    name="$(jq -r '.name' <<<"$row")"; server="$(jq -r '.server' <<<"$row")"
    port="$(jq -r '.port' <<<"$row")"; transport="$(jq -r '.transport' <<<"$row")"
    username="$(jq -r '.username' <<<"$row")"; password="$(jq -r '.password' <<<"$row")"
    mtu="$(jq -r '.mtu' <<<"$row")"
    qname="$(yaml_quote "$name")"; qserver="$(yaml_quote "$server")"
    quser="$(yaml_quote "$username")"; qpass="$(yaml_quote "$password")"
    names+=("$name")
    {
      printf '  - name: %s\n' "$qname"
      printf '    type: mieru\n'
      printf '    server: %s\n' "$qserver"
      printf '    port: %s\n' "$port"
      printf '    transport: %s\n' "$transport"
      [[ "$transport" == "UDP" ]] && printf '    mtu: %s\n' "$mtu"
      printf '    username: %s\n' "$quser"
      printf '    password: %s\n' "$qpass"
      printf '    multiplexing: MULTIPLEXING_LOW\n'
      printf '    handshake-mode: HANDSHAKE_STANDARD\n'
    } >> "$tmp_config"

    uri_host="$server"; [[ "$server" == *:* && "$server" != \[*\] ]] && uri_host="[$server]"
    user_enc="$(uri_encode "$username")"; pass_enc="$(uri_encode "$password")"; profile_enc="$(uri_encode "$name")"
    printf '%s\n%s\n\n' "$name" \
      "mierus://${user_enc}:${pass_enc}@${uri_host}?profile=${profile_enc}&mtu=${mtu}&multiplexing=MULTIPLEXING_LOW&handshake-mode=HANDSHAKE_STANDARD&port=${port}&protocol=${transport}" \
      >> "$tmp_links"
  done

  {
    printf '\nproxy-groups:\n'
    printf '  - name: "🇯🇵 沪日节点"\n    type: select\n    proxies:\n'
    printf '      - "🇯🇵 沪日自动"\n      - "🇯🇵 沪日轮巡"\n      - "🇯🇵 沪日并发"\n'
    for name in "${names[@]}"; do printf '      - %s\n' "$(yaml_quote "$name")"; done
    printf '  - name: "🇯🇵 沪日自动"\n    type: url-test\n    proxies:\n'
    for name in "${names[@]}"; do printf '      - %s\n' "$(yaml_quote "$name")"; done
    printf '    url: "https://www.gstatic.com/generate_204"\n    interval: 300\n    tolerance: 50\n'
    printf '  - name: "🇯🇵 沪日轮巡"\n    type: load-balance\n    strategy: round-robin\n    proxies:\n'
    for name in "${names[@]}"; do printf '      - %s\n' "$(yaml_quote "$name")"; done
    printf '    url: "https://www.gstatic.com/generate_204"\n    interval: 300\n'
    printf '  - name: "🇯🇵 沪日并发"\n    type: load-balance\n    strategy: consistent-hashing\n    proxies:\n'
    for name in "${names[@]}"; do printf '      - %s\n' "$(yaml_quote "$name")"; done
    printf '    url: "https://www.gstatic.com/generate_204"\n    interval: 300\n'
    printf '\nrules:\n  - %s\n' "$(yaml_quote 'MATCH,🇯🇵 沪日节点')"
  } >> "$tmp_config"

  install -m 0600 "$tmp_config" "$config_out"
  install -m 0600 "$tmp_links" "$links_out"
  ok "已生成：$config_out"
  ok "已生成：$links_out"
  (( count > 1 )) || warn "当前只有一个节点；轮巡组可用，但不会产生多节点分流效果。"
  warn "导出文件包含节点密码，请勿上传到公开仓库或转发截图。"
  [[ "$interactive" == "true" ]] && pause_screen
  return 0
}

install_wireguard_packages() {
  ensure_base_dependencies
  apt_install wireguard-tools iptables qrencode
  modprobe wireguard 2>/dev/null || true
  command -v wg >/dev/null 2>&1 || die "wireguard-tools 安装失败。"
}

next_wg_iface() {
  local i
  for ((i=0; i<100; i++)); do
    [[ -e "/etc/wireguard/wg-huri${i}.conf" ]] || { printf 'wg-huri%s' "$i"; return; }
  done
  return 1
}

store_wg_instance() {
  local iface="$1" endpoint="$2" public_port="$3" local_port="$4" prefix="$5" server_pub="$6" mtu="$7" out_iface="$8"
  local tmp created
  created="$(date --iso-8601=seconds)"; tmp="$(mktemp /tmp/huri-wg-state.XXXXXX)"; register_temp "$tmp"
  jq --arg iface "$iface" --arg endpoint "$endpoint" --argjson publicPort "$public_port" \
    --argjson localPort "$local_port" --arg prefix "$prefix" --arg serverPublicKey "$server_pub" \
    --argjson mtu "$mtu" --arg outboundInterface "$out_iface" --arg created "$created" \
    '. + [{interface:$iface,endpoint:$endpoint,publicPort:$publicPort,localPort:$localPort,
      prefix:$prefix,serverPublicKey:$serverPublicKey,mtu:$mtu,outboundInterface:$outboundInterface,
      createdAt:$created}]' "$WG_STATE_FILE" > "$tmp"
  install -m 0600 "$tmp" "$WG_STATE_FILE"
}

store_wg_peer() {
  local iface="$1" name="$2" address="$3" public_key="$4" config_file="$5"
  local tmp created
  created="$(date --iso-8601=seconds)"; tmp="$(mktemp /tmp/huri-wg-peer.XXXXXX)"; register_temp "$tmp"
  jq --arg iface "$iface" --arg name "$name" --arg address "$address" --arg publicKey "$public_key" \
    --arg configFile "$config_file" --arg created "$created" \
    '. + [{interface:$iface,name:$name,address:$address,publicKey:$publicKey,
      configFile:$configFile,createdAt:$created}]' "$WG_PEERS_FILE" > "$tmp"
  install -m 0600 "$tmp" "$WG_PEERS_FILE"
}

create_wireguard_server() {
  action_header "新购交机：建立 WireGuard 节点"
  rule_wall
  printf '\nWireGuard 使用 UDP。请先确认该套餐给你的公网 UDP 端口及其本机映射。\n'
  confirm "继续建立新 WireGuard 实例与首个客户端？" "N" || { pause_screen; return; }
  install_wireguard_packages
  ensure_layout
  install -d -m 0700 /etc/wireguard "${EXPORT_DIR}/WireGuard"

  local iface index endpoint public_port local_port prefix mtu out_iface client_name client_file_name dns
  local server_priv server_pub client_priv client_pub psk server_conf client_conf tmp_server tmp_client
  iface="$(next_wg_iface)"; index="${iface##*huri}"
  endpoint="$(public_ipv4)"; ask endpoint "客户端使用的公网 IP / 域名" "${endpoint:-}"
  valid_host "$endpoint" || { warn "公网地址无效。"; pause_screen; return; }
  ask public_port "商家公网 UDP 端口" "$((20000 + index))"
  valid_port "$public_port" || { warn "端口必须为 1025-65535。"; pause_screen; return; }
  public_port=$((10#$public_port))
  ask local_port "VDS 本机监听 UDP 端口" "$public_port"
  valid_port "$local_port" || { warn "端口必须为 1025-65535。"; pause_screen; return; }
  local_port=$((10#$local_port))
  if port_in_use "$local_port" UDP; then warn "${local_port}/UDP 已被占用。"; pause_screen; return; fi
  ask prefix "隧道 /24 前缀（只填前三段）" "10.88.${index}"
  valid_prefix24 "$prefix" || { warn "前缀示例：10.88.0"; pause_screen; return; }
  if ip -4 route show | grep -Eq "(^|[[:space:]])${prefix//./\.}\.0/24([[:space:]]|$)"; then
    warn "路由表中已经存在 ${prefix}.0/24，继续使用可能发生地址冲突。"
    confirm "确认仍使用该网段？" "N" || { pause_screen; return; }
  fi
  ask mtu "WireGuard MTU" "1380"
  valid_mtu "$mtu" || { warn "MTU 必须为 1280-1500。"; pause_screen; return; }
  mtu=$((10#$mtu))
  out_iface="$(default_iface)"; [[ -n "$out_iface" ]] || { warn "未找到默认网卡。"; pause_screen; return; }
  ask client_name "首个客户端名称" "HuRi-Phone-01"
  client_file_name="$(safe_file_component "$client_name")"
  ask dns "客户端 DNS" "1.1.1.1"

  umask 077
  server_priv="$(wg genkey)"; server_pub="$(printf '%s' "$server_priv" | wg pubkey)"
  client_priv="$(wg genkey)"; client_pub="$(printf '%s' "$client_priv" | wg pubkey)"
  psk="$(wg genpsk)"
  server_conf="/etc/wireguard/${iface}.conf"
  client_conf="${EXPORT_DIR}/WireGuard/${client_file_name}-${iface}.conf"
  tmp_server="$(mktemp /tmp/huri-wg-server.XXXXXX)"; register_temp "$tmp_server"
  tmp_client="$(mktemp /tmp/huri-wg-client.XXXXXX)"; register_temp "$tmp_client"

  cat > "$tmp_server" <<EOF
[Interface]
Address = ${prefix}.1/24
ListenPort = ${local_port}
PrivateKey = ${server_priv}
MTU = ${mtu}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -A POSTROUTING -s ${prefix}.0/24 -o ${out_iface} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -D POSTROUTING -s ${prefix}.0/24 -o ${out_iface} -j MASQUERADE

[Peer]
# ${client_name}
PublicKey = ${client_pub}
PresharedKey = ${psk}
AllowedIPs = ${prefix}.2/32
EOF

  cat > "$tmp_client" <<EOF
[Interface]
PrivateKey = ${client_priv}
Address = ${prefix}.2/32
DNS = ${dns}
MTU = ${mtu}

[Peer]
PublicKey = ${server_pub}
PresharedKey = ${psk}
Endpoint = ${endpoint}:${public_port}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

  install -m 0600 "$tmp_server" "$server_conf"
  install -m 0600 "$tmp_client" "$client_conf"
  if [[ -f /etc/sysctl.d/90-huri-wireguard.conf ]]; then
    cp -a /etc/sysctl.d/90-huri-wireguard.conf "${BACKUP_DIR}/90-huri-wireguard.conf.$(stamp).bak"
  fi
  printf 'net.ipv4.ip_forward = 1\n' > /etc/sysctl.d/90-huri-wireguard.conf
  chmod 0644 /etc/sysctl.d/90-huri-wireguard.conf
  sysctl -w net.ipv4.ip_forward=1
  systemctl enable --now "wg-quick@${iface}"
  wg show "$iface"
  store_wg_instance "$iface" "$endpoint" "$public_port" "$local_port" "$prefix" "$server_pub" "$mtu" "$out_iface"
  store_wg_peer "$iface" "$client_name" "${prefix}.2" "$client_pub" "$client_conf"
  maybe_open_ufw "$local_port" UDP

  ok "WireGuard 实例已建立：$iface"
  ok "客户端配置：$client_conf"
  warn "商家侧必须存在 ${endpoint}:${public_port}/UDP → 本机 ${local_port}/UDP 的映射。"
  if command -v qrencode >/dev/null 2>&1 && confirm "立即在终端显示客户端二维码？" "Y"; then
    qrencode -t ANSIUTF8 < "$client_conf"
  fi
  pause_screen
}

select_wg_instance() {
  local __var="$1" count choice
  count="$(jq 'length' "$WG_STATE_FILE")"
  (( count > 0 )) || return 1
  jq -r 'to_entries[] | "\(.key+1). \(.value.interface)｜\(.value.endpoint):\(.value.publicPort)/UDP｜\(.value.prefix).0/24"' "$WG_STATE_FILE"
  ask choice "选择实例序号" "1"
  is_integer "$choice" && ((choice >= 1 && choice <= count)) || return 1
  printf -v "$__var" '%s' "$((choice - 1))"
}

add_wireguard_peer() {
  action_header "WireGuard 增加客户端"
  ensure_base_dependencies
  ensure_layout
  command -v wg >/dev/null 2>&1 || { warn "请先建立 WireGuard 实例。"; pause_screen; return; }
  local idx row iface endpoint public_port prefix mtu name file_name dns host_octet address
  local client_priv client_pub psk server_pub server_conf client_conf tmp_psk
  select_wg_instance idx || { warn "没有可选实例或序号无效。"; pause_screen; return; }
  row="$(jq -c ".[$idx]" "$WG_STATE_FILE")"
  iface="$(jq -r '.interface' <<<"$row")"; endpoint="$(jq -r '.endpoint' <<<"$row")"
  public_port="$(jq -r '.publicPort' <<<"$row")"; prefix="$(jq -r '.prefix' <<<"$row")"
  mtu="$(jq -r '.mtu' <<<"$row")"; server_pub="$(jq -r '.serverPublicKey' <<<"$row")"
  server_conf="/etc/wireguard/${iface}.conf"
  [[ -f "$server_conf" ]] || { warn "找不到 $server_conf。"; pause_screen; return; }

  host_octet=""
  for ((host_octet=2; host_octet<=254; host_octet++)); do
    address="${prefix}.${host_octet}"
    grep -Eq "AllowedIPs[[:space:]]*=[[:space:]]*${address//./\.}/32" "$server_conf" || break
  done
  (( host_octet <= 254 )) || { warn "该 /24 网段没有可用客户端地址。"; pause_screen; return; }
  ask name "客户端名称" "HuRi-Client-${host_octet}"
  file_name="$(safe_file_component "$name")"
  ask dns "客户端 DNS" "1.1.1.1"
  client_conf="${EXPORT_DIR}/WireGuard/${file_name}-${iface}.conf"
  umask 077
  client_priv="$(wg genkey)"; client_pub="$(printf '%s' "$client_priv" | wg pubkey)"; psk="$(wg genpsk)"
  cp -a "$server_conf" "${BACKUP_DIR}/${iface}.conf.$(stamp).bak"
  cat >> "$server_conf" <<EOF

[Peer]
# ${name}
PublicKey = ${client_pub}
PresharedKey = ${psk}
AllowedIPs = ${address}/32
EOF
  cat > "$client_conf" <<EOF
[Interface]
PrivateKey = ${client_priv}
Address = ${address}/32
DNS = ${dns}
MTU = ${mtu}

[Peer]
PublicKey = ${server_pub}
PresharedKey = ${psk}
Endpoint = ${endpoint}:${public_port}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
  chmod 0600 "$server_conf" "$client_conf"
  tmp_psk="$(mktemp /tmp/huri-psk.XXXXXX)"; register_temp "$tmp_psk"
  printf '%s\n' "$psk" > "$tmp_psk"; chmod 0600 "$tmp_psk"
  if ip link show "$iface" >/dev/null 2>&1; then
    wg set "$iface" peer "$client_pub" preshared-key "$tmp_psk" allowed-ips "${address}/32"
  else
    info "接口 $iface 当前未运行，将从已更新的持久配置启动。"
    systemctl enable --now "wg-quick@${iface}"
  fi
  store_wg_peer "$iface" "$name" "$address" "$client_pub" "$client_conf"
  ok "客户端已加入：$name / $address"
  ok "配置文件：$client_conf"
  if command -v qrencode >/dev/null 2>&1 && confirm "显示二维码？" "Y"; then qrencode -t ANSIUTF8 < "$client_conf"; fi
  pause_screen
}

show_wireguard_status() {
  action_header "WireGuard 状态"
  ensure_base_dependencies
  ensure_layout
  if ! command -v wg >/dev/null 2>&1; then
    warn "WireGuard 尚未安装。"
  else
    wg show || true
    printf '\n%s实例清单：%s\n' "$BCYAN" "$RESET"
    jq -r '.[] | "- \(.interface)｜公网 \(.endpoint):\(.publicPort)/UDP → 本机 :\(.localPort)/UDP｜\(.prefix).0/24"' "$WG_STATE_FILE"
    printf '\n%s客户端清单：%s\n' "$BCYAN" "$RESET"
    jq -r '.[] | "- \(.name)｜\(.interface)｜\(.address)｜\(.configFile)"' "$WG_PEERS_FILE"
  fi
  pause_screen
}

run_linked_tool() {
  local label="$1" url="$2"; shift 2
  action_header "$label"
  printf '来源：%s\n\n' "$url"
  warn "测试会消耗流量并可能运行数分钟；业务端口应填写 Mieru TCP 端口，不要填写 SSH 端口。"
  confirm "立即下载固定 main 入口并执行？" "N" || { pause_screen; return; }
  local tmp
  tmp="$(mktemp /tmp/huri-linked-tool.XXXXXX.sh)"; register_temp "$tmp"
  curl -fsSL --retry 3 "$url" -o "$tmp"
  bash -n "$tmp"
  chmod 0700 "$tmp"
  show_cursor
  if ! bash "$tmp" "$@"; then
    warn "测速工具返回非零退出码；面板本身未做配置改动。"
  fi
  hide_cursor
  pause_screen
}

show_speed_links() {
  action_header "测速链接 / FIXED LINKS"
  printf 'IX 入口／隐藏内段核对：\n  %s\n\n' "$IX_SCRIPT_URL"
  printf 'China3Net 标准版：\n  %s\n\n' "$CHINA3NET_URL"
  printf 'China3Net 六地区＋测速版：\n  %s\n' "$CHINA3NET_SPEED_URL"
  pause_screen
}

install_or_update_panel() {
  action_header "安装 / 更新 HuRi 面板"
  ensure_base_dependencies
  local tmp backup=""
  tmp="$(mktemp /tmp/huri-panel.XXXXXX.sh)"; register_temp "$tmp"
  curl -fsSL --retry 3 "${RAW_BASE}/huri-panel.sh" -o "$tmp"
  bash -n "$tmp"
  if [[ -f "$INSTALLED_SCRIPT" ]]; then
    backup="${BACKUP_DIR}/huri-panel.$(stamp).bak"
    cp -a "$INSTALLED_SCRIPT" "$backup"
  fi
  install -m 0750 "$tmp" "$INSTALLED_SCRIPT"
  if [[ ! -e /usr/local/bin/huri || -L /usr/local/bin/huri ]]; then
    ln -sfn "$INSTALLED_SCRIPT" /usr/local/bin/huri
  else
    warn "/usr/local/bin/huri 已存在普通文件，未覆盖；仍可执行 $INSTALLED_SCRIPT。"
  fi
  ok "面板已安装：执行 huri 或 $INSTALLED_SCRIPT"
  [[ -n "$backup" ]] && info "旧版备份：$backup"
  pause_screen
}

show_backups() {
  action_header "备份与导出清单"
  printf '%s备份目录：%s%s\n' "$BCYAN" "$BACKUP_DIR" "$RESET"
  find "$BACKUP_DIR" -maxdepth 1 -type f -printf '%TY-%Tm-%Td %TH:%TM  %9s  %f\n' 2>/dev/null | sort -r | head -80 || true
  printf '\n%s导出目录：%s%s\n' "$BCYAN" "$EXPORT_DIR" "$RESET"
  find "$EXPORT_DIR" -maxdepth 3 -type f -printf '%TY-%Tm-%Td %TH:%TM  %9s  %p\n' 2>/dev/null | sort -r | head -80 || true
  pause_screen
}

show_help() {
  action_header "帮助与边界"
  rule_wall
  cat <<'EOF'

推荐的新购交机顺序：
  1. 系统体检：确认 Debian 12/13、NAT、公网 IP、时间同步与可用端口。
  2. Mieru：安装官方 mita，再建立 TCP 主节点；弱网确有需求时才追加 UDP。
  3. WireGuard：确认商家开放 UDP 后，再生成服务端与客户端二维码。
  4. 集群：把多台沪日节点加入清单，生成 FLClash/Mihomo 配置。
  5. 测速：IX 用于入口/NAT/隐藏内段核对；China3Net 用于公网三网质量观察。

重要口径：
  - “轮巡”按请求轮换节点；“并发”使用一致性哈希分散不同目标连接。
  - 两者都不是单个下载连接的带宽聚合，也不能突破每台机器或本地宽带上限。
  - NAT 套餐的公网端口必须由商家映射；Linux 内监听正常不等于公网一定可达。
  - 脚本不改 SSH 端口，不自动关闭现有服务，不保存任何预置账号或真实节点密码。
EOF
  pause_screen
}

self_test() {
  local failed=0
  printf 'HuRi Link Console %s self-test\n' "$VERSION"
  valid_port 10503 || { printf 'FAIL valid port\n'; failed=1; }
  valid_port 1024 && { printf 'FAIL low port\n'; failed=1; }
  valid_port 65536 && { printf 'FAIL high port\n'; failed=1; }
  valid_mtu 1280 || { printf 'FAIL mtu 1280\n'; failed=1; }
  valid_mtu 1501 && { printf 'FAIL mtu 1501\n'; failed=1; }
  valid_username 'huri_01' || { printf 'FAIL username\n'; failed=1; }
  valid_username 'bad user' && { printf 'FAIL bad username\n'; failed=1; }
  valid_host 'example.com' || { printf 'FAIL host\n'; failed=1; }
  valid_host 'bad host' && { printf 'FAIL bad host\n'; failed=1; }
  valid_prefix24 '10.88.0' || { printf 'FAIL prefix\n'; failed=1; }
  valid_prefix24 '10.999.0' && { printf 'FAIL bad prefix\n'; failed=1; }
  (( failed == 0 )) || return 1
  printf 'PASS validators and offline safety checks\n'
}

usage() {
  cat <<EOF
${APP_NAME} v${VERSION}

用法：
  bash huri-panel.sh              进入方向键彩色面板（需要 root 与 TTY）
  bash huri-panel.sh --health     执行一次系统体检
  bash huri-panel.sh --self-test  离线自检，不修改系统
  bash huri-panel.sh --install    安装/更新为 huri 命令
  bash huri-panel.sh --version
  bash huri-panel.sh --help

方向键：←/→ 切换分页，↑/↓ 选择，Enter 执行，Q 退出。
EOF
}

panel_main() {
  local tabs=("系统" "Mieru" "WireGuard" "集群" "测速" "维护")
  local tab=0 selected=0 key i item_count
  local -a items
  hide_cursor
  while true; do
    case "$tab" in
      0) items=("执行完整系统体检" "应用保守 BBR + FQ 优化" "查看端口与服务") ;;
      1) items=("安装 / 升级官方 Mieru" "新购交机：建立 Mieru" "查看 Mieru 状态与配置") ;;
      2) items=("新购交机：建立 WireGuard" "为 WireGuard 增加客户端" "查看 WireGuard 状态") ;;
      3) items=("加入已有沪日 Mieru 节点" "查看节点清单" "删除节点清单记录" "生成 FLClash 多节点配置") ;;
      4) items=("执行 IX 入口多线测速" "执行 China3Net 三网检测" "执行 China3Net 六地区测速" "查看固定测速链接") ;;
      5) items=("安装 / 更新 huri 命令" "查看备份与导出" "回滚最近一次网络优化" "帮助与边界") ;;
    esac
    item_count="${#items[@]}"; (( selected < item_count )) || selected=0
    clear_screen; draw_logo; printf '\n'
    for ((i=0; i<${#tabs[@]}; i++)); do
      if (( i == tab )); then
        printf ' %s%s[ %s ]%s ' "$BG_CYAN" "$BLACK" "${tabs[$i]}" "$RESET"
      else
        printf ' %s%s %s %s ' "$DIM" "$WHITE" "${tabs[$i]}" "$RESET"
      fi
    done
    printf '\n%s────────────────────────────────────────────────────────────────────────%s\n' "$BBLACK" "$RESET"
    for ((i=0; i<item_count; i++)); do
      if (( i == selected )); then
        printf '  %s%s▶  %s%s\n' "$BG_MAGENTA" "$BWHITE" "${items[$i]}" "$RESET"
      else
        printf '     %s%s%s\n' "$BCYAN" "${items[$i]}" "$RESET"
      fi
    done
    printf '\n'; rule_wall
    printf '\n%s←/→ 分页   ↑/↓ 选择   Enter 执行   Q 退出%s\n' "$DIM" "$RESET"
    key="$(read_key)"
    case "$key" in
      LEFT) tab=$(( (tab + ${#tabs[@]} - 1) % ${#tabs[@]} )); selected=0 ;;
      RIGHT) tab=$(( (tab + 1) % ${#tabs[@]} )); selected=0 ;;
      UP) selected=$(( (selected + item_count - 1) % item_count )) ;;
      DOWN) selected=$(( (selected + 1) % item_count )) ;;
      QUIT|ESC) clear_screen; show_cursor; return ;;
      ENTER)
        case "${tab}:${selected}" in
          0:0) health_check ;; 0:1) apply_optimization ;; 0:2) show_ports_services ;;
          1:0) install_mieru ;; 1:1) configure_mieru_server ;; 1:2) show_mieru_status ;;
          2:0) create_wireguard_server ;; 2:1) add_wireguard_peer ;; 2:2) show_wireguard_status ;;
          3:0) add_existing_node ;; 3:1) list_nodes ;; 3:2) delete_node ;;
          3:3) generate_mihomo_config true ;;
          4:0) run_linked_tool "IX 入口／NAT／隐藏内段核对" "$IX_SCRIPT_URL" --full --speed ;;
          4:1) run_linked_tool "China3Net 三网双程检测" "$CHINA3NET_URL" ;;
          4:2) run_linked_tool "China3Net 六地区＋单线程测速" "$CHINA3NET_SPEED_URL" ;;
          4:3) show_speed_links ;;
          5:0) install_or_update_panel ;; 5:1) show_backups ;;
          5:2) rollback_optimization ;; 5:3) show_help ;;
        esac
        ;;
    esac
  done
}

main() {
  case "${1:-}" in
    --help|-h) usage; return 0 ;;
    --version|-V) printf '%s v%s\n' "$APP_NAME" "$VERSION"; return 0 ;;
    --self-test) self_test; return ;;
  esac

  require_root
  require_supported_os
  ensure_layout
  case "${1:-}" in
    --health) health_check ;;
    --install) install_or_update_panel ;;
    "")
      [[ -t 0 && -t 1 ]] || die "交互面板需要 TTY；Windows CMD 请使用 ssh -t。"
      PUBLIC_IP_CACHE="$(public_ipv4)"
      panel_main
      ;;
    *) usage; die "未知参数：$1" ;;
  esac
}

if [[ "${HURI_LIB_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
