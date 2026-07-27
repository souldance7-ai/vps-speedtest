#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/three-net-upload-relay"
ENV_FILE="/etc/three-net-upload-relay.env"
CLIENT_ENV_FILE="/root/three-net-upload-relay-client.env"
SERVICE_FILE="/etc/systemd/system/three-net-upload-relay.service"
SOURCE_IP=""
PUBLIC_HOST=""
PORT="29881"
UPSTREAM_URL="https://china-3net-route-report.souldance4.chatgpt.site/api/reports"
ROTATE_SECRET=0

usage() {
  cat <<'EOF'
台北101中国三网报告受控上传中继安装器

用法：
  bash install-upload-relay.sh --source-ip Hoyo公网IPv4 --public-host 台北101公网IPv4

可选：
  --port 29881
  --upstream-url https://example.com/api/reports
  --rotate-secret

安全模型：
  1. 仅接受 --source-ip 指定的来源；
  2. 请求使用 HMAC-SHA256 签名，密钥不在网络中直接传送；
  3. 时间窗与随机 nonce 防止重放；
  4. 只转发 JSON 到固定报告 API，不提供通用代理能力。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-ip) SOURCE_IP="${2:-}"; shift 2 ;;
    --public-host) PUBLIC_HOST="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --upstream-url) UPSTREAM_URL="${2:-}"; shift 2 ;;
    --rotate-secret) ROTATE_SECRET=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "[ERROR] 未知参数：$1"; usage; exit 2 ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "[ERROR] 请使用 root 执行。"
  exit 3
fi
if [[ -z "$SOURCE_IP" || -z "$PUBLIC_HOST" ]]; then
  echo "[ERROR] 必须同时填写 --source-ip 与 --public-host。"
  usage
  exit 4
fi

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "[ERROR] 缺少 python3/curl，且当前系统没有 apt-get。"
    exit 5
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq python3 curl ca-certificates
fi

python3 - "$SOURCE_IP" "$PUBLIC_HOST" "$PORT" "$UPSTREAM_URL" <<'PY'
import ipaddress
import sys
from urllib.parse import urlsplit

source, public_host, port_text, upstream = sys.argv[1:]
try:
    source_address = ipaddress.ip_address(source)
except ValueError as exc:
    raise SystemExit(f"[ERROR] source-ip 不是有效 IP：{exc}")
if source_address.version != 4:
    raise SystemExit("[ERROR] 当前安装器的 source-ip 仅接受公网 IPv4")
try:
    public_address = ipaddress.ip_address(public_host)
except ValueError as exc:
    raise SystemExit(f"[ERROR] public-host 不是有效 IP：{exc}")
if public_address.version != 4:
    raise SystemExit("[ERROR] 当前安装器的 public-host 仅接受公网 IPv4")
try:
    port = int(port_text)
except ValueError:
    raise SystemExit("[ERROR] port 必须是数字")
if not 1024 <= port <= 65535:
    raise SystemExit("[ERROR] port 必须在 1024～65535")
parts = urlsplit(upstream)
if parts.scheme != "https" or not parts.netloc or not parts.path:
    raise SystemExit("[ERROR] upstream-url 必须是完整 HTTPS API 地址")
PY

install -d -m 0755 "$APP_DIR"

cat >"$APP_DIR/server.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import hmac
import ipaddress
import json
import os
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND = os.environ.get("RELAY_BIND", "0.0.0.0")
PORT = int(os.environ.get("RELAY_PORT", "29881"))
SECRET = os.environ["RELAY_SECRET"].encode("utf-8")
UPSTREAM_URL = os.environ["RELAY_UPSTREAM_URL"]
MAX_BODY = int(os.environ.get("RELAY_MAX_BODY", str(2 * 1024 * 1024)))
MAX_SKEW = int(os.environ.get("RELAY_MAX_SKEW", "180"))
ALLOWED = [
    ipaddress.ip_network(item.strip(), strict=False)
    for item in os.environ["RELAY_ALLOWED_IPS"].split(",")
    if item.strip()
]
NONCES: dict[str, int] = {}
NONCE_LOCK = threading.Lock()
DIRECT_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def allowed_peer(value: str) -> bool:
    try:
        address = ipaddress.ip_address(value)
        if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
            address = address.ipv4_mapped
    except ValueError:
        return False
    return any(address in network for network in ALLOWED)


def consume_nonce(nonce: str, timestamp: int) -> bool:
    now = int(time.time())
    with NONCE_LOCK:
        expired = [key for key, seen in NONCES.items() if now - seen > MAX_SKEW]
        for key in expired:
            NONCES.pop(key, None)
        if nonce in NONCES:
            return False
        NONCES[nonce] = timestamp
    return True


class Handler(BaseHTTPRequestHandler):
    server_version = "ThreeNetUploadRelay/1.0"
    sys_version = ""

    def log_message(self, fmt: str, *args: object) -> None:
        print(
            time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            self.client_address[0],
            fmt % args,
            flush=True,
        )

    def send_json(self, status: int, payload: dict[str, object]) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path != "/health":
            self.send_json(404, {"ok": False, "error": "not found"})
            return
        self.send_json(200, {"ok": True, "service": "three-net-upload-relay"})

    def do_POST(self) -> None:
        if self.path != "/upload":
            self.send_json(404, {"ok": False, "error": "not found"})
            return
        peer = self.client_address[0]
        if not allowed_peer(peer):
            self.send_json(403, {"ok": False, "error": "source not allowed"})
            return
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self.send_json(411, {"ok": False, "error": "invalid content length"})
            return
        if not 2 <= length <= MAX_BODY:
            self.send_json(413, {"ok": False, "error": "invalid body size"})
            return
        body = self.rfile.read(length)
        timestamp_text = self.headers.get("X-Relay-Timestamp", "")
        nonce = self.headers.get("X-Relay-Nonce", "")
        signature = self.headers.get("X-Relay-Signature", "")
        try:
            timestamp = int(timestamp_text)
        except ValueError:
            self.send_json(401, {"ok": False, "error": "invalid timestamp"})
            return
        if abs(int(time.time()) - timestamp) > MAX_SKEW:
            self.send_json(401, {"ok": False, "error": "expired request"})
            return
        if len(nonce) != 32 or any(ch not in "0123456789abcdef" for ch in nonce):
            self.send_json(401, {"ok": False, "error": "invalid nonce"})
            return
        signed = f"{timestamp_text}\n{nonce}\n".encode("ascii") + body
        expected = hmac.new(SECRET, signed, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(signature, expected):
            self.send_json(401, {"ok": False, "error": "signature mismatch"})
            return
        if not consume_nonce(nonce, timestamp):
            self.send_json(409, {"ok": False, "error": "replayed request"})
            return
        try:
            parsed = json.loads(body.decode("utf-8"))
            if not isinstance(parsed, dict):
                raise ValueError("JSON root must be object")
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
            self.send_json(400, {"ok": False, "error": "invalid JSON report"})
            return

        request = urllib.request.Request(
            UPSTREAM_URL,
            data=body,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
                "Cache-Control": "no-cache",
                "User-Agent": "ix-route/0.1",
            },
        )
        try:
            with DIRECT_OPENER.open(request, timeout=45) as response:
                status = int(response.status)
                response_body = response.read(1024 * 1024)
                content_type = response.headers.get(
                    "Content-Type", "application/json; charset=utf-8"
                )
        except urllib.error.HTTPError as exc:
            status = int(exc.code)
            response_body = exc.read(1024 * 1024)
            content_type = exc.headers.get(
                "Content-Type", "application/json; charset=utf-8"
            )
        except Exception as exc:
            self.send_json(502, {"ok": False, "error": f"upstream failure: {exc}"})
            return

        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(response_body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(response_body)


if __name__ == "__main__":
    if len(SECRET) < 32:
        raise SystemExit("RELAY_SECRET must contain at least 32 characters")
    if not ALLOWED:
        raise SystemExit("RELAY_ALLOWED_IPS cannot be empty")
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    print(f"three-net-upload-relay listening on {BIND}:{PORT}", flush=True)
    server.serve_forever()
PY
chmod 0755 "$APP_DIR/server.py"

EXISTING_SECRET=""
if [[ -r "$ENV_FILE" && "$ROTATE_SECRET" -eq 0 ]]; then
  EXISTING_SECRET="$(sed -n 's/^RELAY_SECRET=//p' "$ENV_FILE" | head -n1)"
fi
if [[ "$EXISTING_SECRET" =~ ^[0-9a-f]{64}$ ]]; then
  RELAY_SECRET="$EXISTING_SECRET"
else
  RELAY_SECRET="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"
fi

umask 077
cat >"$ENV_FILE" <<EOF
RELAY_BIND=0.0.0.0
RELAY_PORT=$PORT
RELAY_SECRET=$RELAY_SECRET
RELAY_ALLOWED_IPS=$SOURCE_IP/32
RELAY_UPSTREAM_URL=$UPSTREAM_URL
RELAY_MAX_BODY=2097152
RELAY_MAX_SKEW=180
EOF
chmod 0600 "$ENV_FILE"

cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=China 3Net controlled report upload relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStart=/usr/bin/python3 $APP_DIR/server.py
User=nobody
Group=nogroup
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictAddressFamilies=AF_INET AF_INET6
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$SERVICE_FILE"

cat >"$CLIENT_ENV_FILE" <<EOF
THREE_NET_RELAY_URL=http://$PUBLIC_HOST:$PORT/upload
THREE_NET_RELAY_SECRET=$RELAY_SECRET
EOF
chmod 0600 "$CLIENT_ENV_FILE"

systemctl daemon-reload
systemctl enable --now three-net-upload-relay.service
systemctl restart three-net-upload-relay.service

for _ in 1 2 3 4 5; do
  if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null; then
    break
  fi
  sleep 1
done
if ! curl -fsS --max-time 3 "http://127.0.0.1:$PORT/health" >/dev/null; then
  systemctl --no-pager --full status three-net-upload-relay.service || true
  echo "[ERROR] 中继服务没有通过本机健康检查。"
  exit 6
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -n1 | grep -q "Status: active"; then
  ufw allow from "$SOURCE_IP" to any port "$PORT" proto tcp >/dev/null
  echo "[OK] 已加入 UFW 来源白名单：$SOURCE_IP → TCP $PORT"
else
  echo "[INFO] UFW 未启用；应用层仍只接受 $SOURCE_IP。若另有云防火墙，请放行该来源到 TCP $PORT。"
fi

CLIENT_B64="$(base64 -w0 "$CLIENT_ENV_FILE")"
echo
echo "[OK] 台北101受控上传中继已启动"
echo "服务：three-net-upload-relay.service"
echo "监听：$PUBLIC_HOST:$PORT"
echo "来源：仅 $SOURCE_IP"
echo "客户端配置备份：$CLIENT_ENV_FILE（权限 600）"
echo
echo "下一步只在 Hoyo 执行下面这一行："
echo "umask 077; echo '$CLIENT_B64' | base64 -d > /etc/three-net-upload-relay-client.env; chmod 600 /etc/three-net-upload-relay-client.env; curl -fsS --max-time 5 'http://$PUBLIC_HOST:$PORT/health'"
