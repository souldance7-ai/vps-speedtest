#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY="souldance7-ai/vps-speedtest"
RAW_URL="https://raw.githubusercontent.com/${REPOSITORY}/main/huri-panel/huri-panel.sh"
TARGET="/usr/local/sbin/huri-panel"
LINK="/usr/local/bin/huri"

red=$'\033[91m'; green=$'\033[92m'; cyan=$'\033[96m'; reset=$'\033[0m'

die() {
  printf '%s[错误]%s %s\n' "$red" "$reset" "$*" >&2
  exit 1
}

(( EUID == 0 )) || die "请使用 root 身份运行安装器。"
[[ -r /etc/os-release ]] || die "无法识别操作系统。"

# shellcheck disable=SC1091
. /etc/os-release
major="${VERSION_ID%%.*}"
[[ "${ID:-}" == "debian" && ( "$major" == "12" || "$major" == "13" ) ]] || \
  die "仅支持 Debian 12 / Debian 13。"

export DEBIAN_FRONTEND=noninteractive
if ! command -v curl >/dev/null 2>&1; then
  apt-get update
  apt-get install -y --no-install-recommends curl ca-certificates
fi

tmp="$(mktemp /tmp/huri-panel-install.XXXXXX.sh)"
cleanup() { rm -f -- "$tmp"; }
trap cleanup EXIT INT TERM

printf '%s[信息]%s 正在从公开仓库下载固定 main 入口…\n' "$cyan" "$reset"
curl -fsSL --retry 3 --connect-timeout 10 "$RAW_URL" -o "$tmp"
bash -n "$tmp"

install -d -m 0755 /usr/local/sbin /usr/local/bin
install -m 0750 "$tmp" "$TARGET"
if [[ ! -e "$LINK" || -L "$LINK" ]]; then
  ln -sfn "$TARGET" "$LINK"
else
  printf '%s[警告]%s %s 已存在普通文件，未覆盖。\n' "$red" "$reset" "$LINK"
fi

printf '%s[完成]%s HuRi Link Console 已安装。\n' "$green" "$reset"
printf '以后登录 VPS 后直接执行：%shuri%s\n' "$cyan" "$reset"

if [[ -t 0 && -t 1 && "${1:-}" != "--no-start" ]]; then
  exec "$TARGET"
fi
