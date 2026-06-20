#!/usr/bin/env bash
# LazyVPS CN3 Client Probe for Linux/macOS
# 中国本地 Linux/macOS 客户端去程与代理体感测试
set -Eeuo pipefail

VERSION="3.0.0-open"
HOST=""
PORTS="22"
PROXY=""
PING_COUNT=10
OUT_DIR=""

usage(){
cat <<USAGE
LazyVPS CN3 Client Probe v${VERSION}

用法：
  bash cn3_client_probe.sh --host <VPS_IP> [--ports 22,443] [--proxy http://127.0.0.1:7890]

示例：
  bash cn3_client_probe.sh --host 1.2.3.4 --ports 22,443,8443 --proxy http://127.0.0.1:7890
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2;;
    --ports) PORTS="${2:-22}"; shift 2;;
    --proxy) PROXY="${2:-}"; shift 2;;
    --ping-count) PING_COUNT="${2:-10}"; shift 2;;
    --out) OUT_DIR="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "未知参数：$1"; usage; exit 1;;
  esac
done

if [[ -z "$HOST" ]]; then read -rp "请输入 VPS IP 或域名：" HOST; fi
if [[ -z "$HOST" ]]; then echo "未输入 VPS 地址"; exit 1; fi
if [[ -z "$OUT_DIR" ]]; then OUT_DIR="cn3_client_test_$(date +%Y%m%d_%H%M%S)"; fi
mkdir -p "$OUT_DIR"

CYAN=$'\033[36m'; GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'; DIM=$'\033[2m'
if [[ ! -t 1 ]]; then CYAN=""; GREEN=""; RED=""; YELLOW=""; RESET=""; DIM=""; fi

bar(){
  local v="${1:-0}" width="${2:-30}" n
  n=$(awk -v v="$v" -v w="$width" 'BEGIN{if(v<0)v=0;if(v>100)v=100;printf "%d", v/100*w+0.5}')
  printf '%*s' "$n" '' | tr ' ' '█'
  printf '%*s' "$((width-n))" '' | tr ' ' '░'
}

ping_out="$OUT_DIR/ping_to_vps.txt"
ping -c "$PING_COUNT" -W 1 "$HOST" > "$ping_out" 2>&1 || true
loss=$(awk -F',' '/packet loss/{for(i=1;i<=NF;i++){if($i~/packet loss/){gsub(/[^0-9.]/,"",$i);print $i;exit}}}' "$ping_out")
avg=$(awk -F'=' '/min\/avg\/max|round-trip/{split($2,a,"/");gsub(/ /,"",a[2]);print a[2];exit}' "$ping_out")
loss="${loss:-100}"; avg="${avg:-NA}"

tcp_csv="$OUT_DIR/tcp_ports.csv"
echo "Port,Status,LatencyMs" > "$tcp_csv"
IFS=',' read -ra ports <<< "$PORTS"
tcp_ok=0
for p in "${ports[@]}"; do
  start=$(date +%s%3N 2>/dev/null || date +%s000)
  if timeout 3 bash -c ': >/dev/tcp/$0/$1' "$HOST" "$p" >/dev/null 2>&1; then
    end=$(date +%s%3N 2>/dev/null || date +%s000)
    ms=$((end-start))
    echo "$p,OK,$ms" >> "$tcp_csv"
    tcp_ok=$((tcp_ok+1))
  else
    echo "$p,FAIL,NA" >> "$tcp_csv"
  fi
done
tcp_rate=$(awk -v ok="$tcp_ok" -v total="${#ports[@]}" 'BEGIN{if(total<=0)print 0;else printf "%.2f", ok/total*100}')

trace_file="$OUT_DIR/traceroute_to_vps.txt"
if command -v traceroute >/dev/null 2>&1; then traceroute "$HOST" > "$trace_file" 2>&1 || true; else echo "traceroute not found" > "$trace_file"; fi

proxy_csv="$OUT_DIR/proxy_experience.csv"
echo "Name,Status,HttpCode,LatencyMs" > "$proxy_csv"
if [[ -n "$PROXY" ]]; then
  for item in "Cloudflare|https://www.cloudflare.com/cdn-cgi/trace" "Google204|https://www.gstatic.com/generate_204" "GitHub|https://github.com" "OpenAI|https://chat.openai.com/cdn-cgi/trace"; do
    name="${item%%|*}"; url="${item#*|}"
    start=$(date +%s%3N 2>/dev/null || date +%s000)
    code=$(curl -x "$PROXY" -L -s -o /dev/null -w "%{http_code}" --max-time 12 "$url" || echo "000")
    end=$(date +%s%3N 2>/dev/null || date +%s000)
    ms=$((end-start))
    if [[ "$code" =~ ^2|3 ]]; then status="OK"; else status="FAIL"; fi
    echo "$name,$status,$code,$ms" >> "$proxy_csv"
  done
fi

score=$(awk -v avg="$avg" -v loss="$loss" -v tcp="$tcp_rate" 'BEGIN{
  s=100;
  if(avg=="NA") s-=35; else { if(avg>80)s-=(avg-80)*0.10; if(avg>160)s-=(avg-160)*0.08; }
  s-=loss*1.2; s-=(100-tcp)*0.45;
  if(s<0)s=0;if(s>100)s=100;printf "%.1f",s
}')
grade=$(awk -v s="$score" 'BEGIN{if(s>=90)print "A+ 优秀"; else if(s>=82)print "A 主力"; else if(s>=74)print "B+ 良好"; else if(s>=66)print "B 可用"; else if(s>=56)print "C 备用"; else print "D 谨慎"}')

summary="$OUT_DIR/client_summary.csv"
cat > "$summary" <<EOF_SUM
Item,Value
VpsHost,$HOST
PingAvgMs,$avg
PingLossPercent,$loss
TcpSuccessPercent,$tcp_rate
Score,$score
Grade,$grade
Proxy,${PROXY:-NA}
EOF_SUM

report="$OUT_DIR/client_report.md"
cat > "$report" <<EOF_MD
# LazyVPS Client Probe 本地端测试报告

- VPS：$HOST
- Ping 平均：$avg ms
- Ping 丢包：$loss%
- TCP 成功率：$tcp_rate%
- 综合评分：$score
- 评级：$grade
- 代理：${PROXY:-未设置}

## 输出文件

- client_summary.csv
- tcp_ports.csv
- proxy_experience.csv
- ping_to_vps.txt
- traceroute_to_vps.txt
EOF_MD

echo "${CYAN}+--------------------------------------------------------------------------------+${RESET}"
echo "${CYAN}| LazyVPS 中国本地端去程 / 代理体感 CMD 仪表盘                                  |${RESET}"
echo "${CYAN}+--------------------------------------------------------------------------------+${RESET}"
echo "目标 VPS：$HOST"
echo "综合评分：$score / $grade  $(bar "$score" 30)"
echo "Ping/丢包：Avg ${avg} ms / Loss ${loss}%"
echo "TCP成功率：${tcp_rate}%"
echo "${CYAN}+----------+----------+------------+${RESET}"
echo "${CYAN}| Port     | Status   | LatencyMs  |${RESET}"
echo "${CYAN}+----------+----------+------------+${RESET}"
tail -n +2 "$tcp_csv" | while IFS=, read -r p st ms; do printf "| %-8s | %-8s | %-10s |\n" "$p" "$st" "$ms"; done
echo "${CYAN}+----------+----------+------------+${RESET}"
echo
echo "输出文件：$OUT_DIR"
echo "一句话：本地到 VPS 的去程评分 $score / $grade；搭配 VPS 端回程测试才是完整闭环。"
