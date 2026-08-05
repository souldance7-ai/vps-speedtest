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

if grep -Eq -- '-----BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY-----|PrivateKey[[:space:]]*=[[:space:]]*[A-Za-z0-9+/]{40,}' \
  "$PANEL" "$INSTALLER" "$ROOT_DIR/README.md"; then
  fail 'embedded private key leaked into source'
fi

printf 'PASS: syntax, offline behavior, feature gates and secret scan\n'
