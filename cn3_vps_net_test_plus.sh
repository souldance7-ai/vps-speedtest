#!/usr/bin/env bash
# LazyVPS CN3 历史入口兼容层
# 新项目统一使用 cn3_vps_server_test.sh；本文件仅为旧命令保留兼容。

set -Eeuo pipefail

REPO_RAW="https://raw.githubusercontent.com/souldance7-ai/vps-speedtest/main"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OFFICIAL="$SCRIPT_DIR/cn3_vps_server_test.sh"

printf '[兼容提示] cn3_vps_net_test_plus.sh 已合并到 cn3_vps_server_test.sh。\n' >&2

if [[ -f "$OFFICIAL" ]]; then
  exec bash "$OFFICIAL" "$@"
fi

if ! command -v curl >/dev/null 2>&1; then
  printf '[错误] 找不到 curl，无法下载正式入口。\n' >&2
  exit 1
fi

tmp_script="$(mktemp "${TMPDIR:-/tmp}/lazyvps-cn3.XXXXXX.sh")"
trap 'rm -f "$tmp_script"' EXIT
curl -fsSL "$REPO_RAW/cn3_vps_server_test.sh" -o "$tmp_script"
bash "$tmp_script" "$@"
