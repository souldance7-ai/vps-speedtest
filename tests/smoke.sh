#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lazyvps-smoke.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

bash -n "$ROOT/cn3_vps_server_test.sh"
bash -n "$ROOT/cn3_vps_net_test_plus.sh"
bash -n "$ROOT/cn3_client_probe.sh"
PYTHONPYCACHEPREFIX="$TMP/pycache" python3 -m py_compile "$ROOT/merge_lazyvps_report.py"

export NO_COLOR=1
export NO_ANIMATION=1
# shellcheck source=../cn3_vps_server_test.sh
source "$ROOT/cn3_vps_server_test.sh"

OUT_DIR="$TMP/report"
mkdir -p "$OUT_DIR/mtr" "$OUT_DIR/traceroute"
LATENCY_CSV="$ROOT/tests/fixtures/latency_summary.csv"
SPEED_CSV="$ROOT/tests/fixtures/speedtest_summary.csv"
ROUTE_CSV="$ROOT/tests/fixtures/route_backbone_summary.csv"
BASEINFO_MD="$ROOT/tests/fixtures/base_info.md"
OVERVIEW_CSV="$OUT_DIR/cn3_overview.csv"
REPORT_MD="$OUT_DIR/report.md"
REPORT_SVG="$OUT_DIR/report.svg"
MODE="standard"
VERSION="2.0.0-test"

aggregate_results
make_markdown_report
make_svg_report >/dev/null
render_summary_screen > "$TMP/terminal.txt"

python3 - "$REPORT_SVG" "$OVERVIEW_CSV" "$REPORT_MD" "$TMP/terminal.txt" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, overview, markdown, terminal = sys.argv[1:5]
root = ET.parse(path).getroot()
assert root.tag.endswith('svg')
text = open(path, encoding='utf-8').read()
for expected in ['LAZYVPS CN3 SPEEDTEST', '中国电信', '中国联通', '中国移动', '428.6 Mb/s', 'CN2']:
    assert expected in text, expected
overview_text = open(overview, encoding='utf-8').read()
markdown_text = open(markdown, encoding='utf-8').read()
terminal_text = open(terminal, encoding='utf-8').read()
assert '综合评分' in overview_text
assert 'report.svg' in markdown_text
assert 'SVG 可视化' in terminal_text
PY

printf 'LazyVPS smoke test: OK\n'
