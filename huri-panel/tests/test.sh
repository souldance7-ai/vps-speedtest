#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PANEL="${ROOT_DIR}/huri-panel.sh"
INSTALLER="${ROOT_DIR}/install.sh"
TEST_ROOT="$(mktemp -d /tmp/huri-panel-test.XXXXXX)"
cleanup() { rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

bash -n "$PANEL"
bash -n "$INSTALLER"
NO_COLOR=1 bash "$PANEL" --self-test | grep -q '^PASS '

wide_preview="$(NO_COLOR=1 COLUMNS=96 HURI_PREVIEW_PUBLIC_IP=203.0.113.10 bash "$PANEL" --preview-ui)"
grep -q '██╗  ██╗ ██╗   ██╗ ██████╗' <<<"$wide_preview" || fail 'wide fire ANSI logo is missing'
grep -q '沪日 IPLC 专线 · 日本 BGP 独立出口' <<<"$wide_preview" || \
  fail 'wide fire subtitle is missing'
grep -q '░▒▓█▀▀' <<<"$wide_preview" || fail 'wide ANSI shadow layer is missing'
grep -q '即时动态硬件监控' <<<"$wide_preview" || fail 'wide hardware status panel is missing'
grep -q '专线网络与服务参数' <<<"$wide_preview" || fail 'wide network status panel is missing'
grep -q '203.0.113.10' <<<"$wide_preview" || fail 'preview public IP override is missing'

compact_preview="$(NO_COLOR=1 COLUMNS=70 HURI_PREVIEW_PUBLIC_IP=203.0.113.10 bash "$PANEL" --preview-ui)"
grep -q 'HuRi Link Console │ SH→JP COMPLIANT TUNNEL' <<<"$compact_preview" || \
  fail 'compact header fallback is missing'
if grep -q '即时动态硬件监控' <<<"$compact_preview"; then
  fail 'compact header did not collapse below 86 columns'
fi

privacy_preview="$(NO_COLOR=1 COLUMNS=96 HURI_PREVIEW_PUBLIC_IP=203.0.113.10 bash "$PANEL" --privacy --preview-ui)"
grep -q '脱敏 ON' <<<"$privacy_preview" || fail 'privacy badge is missing'
grep -q '主机已隐藏' <<<"$privacy_preview" || fail 'privacy mode did not hide hostname'
grep -q '203.0.x.x' <<<"$privacy_preview" || fail 'privacy mode did not mask public IP'
if grep -q '203.0.113.10' <<<"$privacy_preview"; then
  fail 'privacy mode leaked the complete preview IP'
fi

HURI_LIB_ONLY=1 \
HURI_CONFIG_DIR="${TEST_ROOT}/etc" \
HURI_STATE_DIR="${TEST_ROOT}/state" \
HURI_BACKUP_DIR="${TEST_ROOT}/backups" \
HURI_EXPORT_DIR="${TEST_ROOT}/exports" \
NO_COLOR=1 \
bash -c '
  set -Eeuo pipefail
  source "$1"
  ensure_layout
  registry_add_node "沪日-A" "203.0.113.10" 10503 TCP "huri_a" "p#ss:&word-123456" 1400
  registry_add_node "沪日-B" "2001:db8::10" 10504 UDP "huri_b" "second-password-123" 1280
  generate_mihomo_config false >/dev/null
  safe="$(safe_file_component "../../root/unsafe")"
  [[ "$safe" != */* && -n "$safe" ]]
' _ "$PANEL"

if python3 -c 'import yaml' >/dev/null 2>&1; then
python3 - "${TEST_ROOT}/exports/HuRi-Mieru-FLClash.yaml" <<'PY'
import sys
import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    data = yaml.safe_load(stream)

assert len(data["proxies"]) == 2
assert data["proxies"][0]["password"] == "p#ss:&word-123456"
assert data["proxies"][1]["server"] == "2001:db8::10"
groups = {item["name"]: item for item in data["proxy-groups"]}
assert groups["🇯🇵 沪日轮巡"]["strategy"] == "round-robin"
assert groups["🇯🇵 沪日并发"]["strategy"] == "consistent-hashing"
assert data["rules"] == ["MATCH,🇯🇵 沪日节点"]
PY
else
  grep -q 'server: "2001:db8::10"' "${TEST_ROOT}/exports/HuRi-Mieru-FLClash.yaml" || \
    fail 'generated YAML is missing the IPv6 node'
  grep -q 'password: "p#ss:&word-123456"' "${TEST_ROOT}/exports/HuRi-Mieru-FLClash.yaml" || \
    fail 'generated YAML did not quote a special-character password'
  grep -q 'strategy: round-robin' "${TEST_ROOT}/exports/HuRi-Mieru-FLClash.yaml" || \
    fail 'generated YAML is missing round-robin'
  grep -q 'strategy: consistent-hashing' "${TEST_ROOT}/exports/HuRi-Mieru-FLClash.yaml" || \
    fail 'generated YAML is missing consistent-hashing'
fi

grep -q 'p%23ss%3A%26word-123456' "${TEST_ROOT}/exports/HuRi-Mieru-ShareLinks.txt" || \
  fail 'share link credentials were not URI encoded'

grep -q 'Debian 12 / Debian 13' "$PANEL" || fail 'missing Debian guard'
grep -q 'sha256sum -c' "$PANEL" || fail 'missing Mieru release checksum verification'
grep -q 'HANDSHAKE_STANDARD' "$PANEL" || fail 'missing Mieru handshake mode'
grep -q 'strategy: round-robin' "$PANEL" || fail 'missing round-robin group'
grep -q 'strategy: consistent-hashing' "$PANEL" || fail 'missing consistent-hashing group'
grep -q 'PersistentKeepalive = 25' "$PANEL" || fail 'missing NAT keepalive'
grep -q 'ix-route.sh' "$PANEL" || fail 'missing IX tool link'
grep -q '3net-route-speed.sh' "$PANEL" || fail 'missing China3Net speed link'
grep -q -- '--preview-ui' "$PANEL" || fail 'missing UI preview mode'
grep -q 'hostname -s' "$PANEL" || fail 'hostname is not read dynamically'
grep -q '/proc/meminfo' "$PANEL" || fail 'memory is not read dynamically'
grep -q 'df -hP /' "$PANEL" || fail 'disk is not read dynamically'
grep -q '/proc/uptime' "$PANEL" || fail 'uptime is not read dynamically'
grep -q 'net.ipv4.tcp_congestion_control' "$PANEL" || fail 'TCP state is not read dynamically'
grep -q 'mita status' "$PANEL" || fail 'Mieru state is not read dynamically'

python3 - "$PANEL" "$INSTALLER" "$ROOT_DIR/README.md" <<'PY'
import ipaddress
import pathlib
import re
import sys

allowed_public = {ipaddress.ip_address("1.1.1.1")}
documentation = (
    ipaddress.ip_network("192.0.2.0/24"),
    ipaddress.ip_network("198.51.100.0/24"),
    ipaddress.ip_network("203.0.113.0/24"),
)

for filename in sys.argv[1:]:
    text = pathlib.Path(filename).read_text(encoding="utf-8")
    if re.search(r"\bnbnet-[0-9]+\b", text, flags=re.IGNORECASE):
        raise SystemExit(f"production-like hostname leaked into {filename}")
    for raw in re.findall(r"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])", text):
        try:
            address = ipaddress.ip_address(raw)
        except ValueError:
            continue
        if address in allowed_public or any(address in network for network in documentation):
            continue
        if address.is_private or address.is_loopback or address.is_link_local or address.is_unspecified:
            continue
        raise SystemExit(f"unexpected public IPv4 {address} leaked into {filename}")
PY

if grep -Eq -- '-----BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY-----|PrivateKey[[:space:]]*=[[:space:]]*[A-Za-z0-9+/]{40,}' \
  "$PANEL" "$INSTALLER" "$ROOT_DIR/README.md"; then
  fail 'embedded private key leaked into source'
fi

printf 'PASS: syntax, offline behavior, feature gates and secret scan\n'
