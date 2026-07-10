#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lazyvps-smoke.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

bash -n "$ROOT/cn3_vps_server_test.sh"
bash -n "$ROOT/cn3_vps_net_test_plus.sh"
bash -n "$ROOT/cn3_client_probe.sh"
PYTHONPYCACHEPREFIX="$TMP/pycache" python3 -m py_compile "$ROOT/merge_lazyvps_report.py"
sed -n '/^  python3 -u - .*CAPACITY_CSV/,/^PYCODE$/p' "$ROOT/cn3_vps_server_test.sh" | sed '1d;$d' > "$TMP/capacity_probe.py"
PYTHONPYCACHEPREFIX="$TMP/pycache" python3 -m py_compile "$TMP/capacity_probe.py"

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
CAPACITY_CSV="$ROOT/tests/fixtures/capacity_summary.csv"
CAPACITY_JSON="$ROOT/tests/fixtures/capacity_raw.json"
CAPACITY_SAMPLES_CSV="$ROOT/tests/fixtures/capacity_timeseries.csv"
MODE="standard"
VERSION="2.1.0-test"

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
for expected in ['LAZYVPS CN3 SPEEDTEST', 'CAPACITY STRESS', '914.8 Mb/s', '中国电信', '中国联通', '中国移动', '428.6 Mb/s', 'CN2']:
    assert expected in text, expected
overview_text = open(overview, encoding='utf-8').read()
markdown_text = open(markdown, encoding='utf-8').read()
terminal_text = open(terminal, encoding='utf-8').read()
assert '综合评分' in overview_text
assert 'report.svg' in markdown_text
assert '单线下行Mbps' in markdown_text
assert '全量容量压测' in terminal_text
assert 'SVG 可视化' in terminal_text
PY

# 使用本地 mock 执行一次完整容量引擎，验证传输、HTTP、ICMP、CSV/JSON 和时间序列链路。
chmod +x "$ROOT/tests/mocks/curl" "$ROOT/tests/mocks/ping"
OUT_BASE="$TMP/capacity-live"
RUN_CAPACITY=1
MODE="capacity"
CAP_THREADS=2
CAP_SINGLE_SECONDS=2
CAP_MULTI_SECONDS=3
CAP_HTTP_SAMPLES=5
CAP_ENDPOINT="https://speed.cloudflare.com"
CAP_PING_HOST="1.1.1.1"
prepare_outdir
PATH="$ROOT/tests/mocks:$PATH" LAZYVPS_TEST_FAST=1 run_capacity_stress > "$TMP/capacity-terminal.txt"

python3 - "$CAPACITY_CSV" "$CAPACITY_JSON" "$CAPACITY_SAMPLES_CSV" <<'PY'
import csv, json, sys
summary, raw, samples = sys.argv[1:4]
row = next(csv.DictReader(open(summary, encoding='utf-8')))
assert row['状态'] == 'OK', row
assert float(row['单线下行Mbps']) > 0
assert float(row['多线下行Mbps']) > 0
assert float(row['单线上行Mbps']) > 0
assert float(row['多线上行Mbps']) > 0
assert float(row['HTTP_P95ms']) >= float(row['HTTP_P50ms'])
assert json.load(open(raw, encoding='utf-8'))['schema'] == 'lazyvps.capacity.v2.1'
assert len(list(csv.DictReader(open(samples, encoding='utf-8')))) > 0
PY

printf 'LazyVPS smoke test: OK\n'
