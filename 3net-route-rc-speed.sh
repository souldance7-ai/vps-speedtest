#!/usr/bin/env bash
set -Eeuo pipefail

CORE_URL="https://raw.githubusercontent.com/souldance7-ai/vps-speedtest/main/3net-route-rc.sh"
TMP_SCRIPT="$(mktemp /tmp/3net-route-rc-speed.XXXXXX.sh)"
cleanup() {
  rm -f -- "$TMP_SCRIPT"
}
trap cleanup EXIT INT TERM

curl -fsSL --retry 3 "$CORE_URL" -o "$TMP_SCRIPT"
bash "$TMP_SCRIPT" --extended --speed "$@"
