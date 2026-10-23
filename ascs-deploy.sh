#!/bin/bash
# ASCS micro instance proxy deploy v2 — runs as user 'micro', no root needed.
# Downloads Xray v26.10.21 (XTLS/Xray-core) and Hysteria2 app/v2.13.0
# (apernet/hysteria) from official GitHub release URLs (or identical-byte
# mirrors via XRAY_URL/HY2_URL env overrides) and verifies SHA256 against
# independently confirmed hashes. Fails closed on any mismatch.
# v2 adds mirror URL overrides because some hosts cannot reach github.com.
set -euo pipefail

# --- pinned versions & independently verified SHA256 hashes ---
XRAY_VER="v26.10.21"
XRAY_SHA256="0eec3ed4163c273d8c8bf821f7d219e257921cf584aa3fb970715e458e631978"
HY2_VER="app/v2.13.0"
HY2_SHA256="907ba8c9693edb104b20582681fb7dc15639d5b64a9cbb616a7b539190a86691"
# Download sources: official GitHub release URLs by default. If the host
# cannot reach github.com, override via env with a mirror serving the
# IDENTICAL bytes (SHA256 pins below still enforced, fail-closed).
XRAY_URL="${XRAY_URL:-https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-64.zip}"
HY2_URL="${HY2_URL:-https://github.com/apernet/hysteria/releases/download/${HY2_VER}/hysteria-linux-amd64}"
# When HY2_URL points to a gzip-compressed binary, set HY2_GZ=1 and provide
# HY2_GZ_SHA256 (hash of the .gz file). The decompressed binary is still
# checked against HY2_SHA256 afterwards.
HY2_GZ="${HY2_GZ:-0}"
HY2_GZ_SHA256="${HY2_GZ_SHA256:-}"
IPV6="2001:470:1f2f:164::554"
VLESS_PORT=8443
HY2_PORT=8444
WS_PATH="/tk-ascs"

HOME_DIR="$HOME"
BIN="$HOME_DIR/bin"
XR="$HOME_DIR/.xray"
HY="$HOME_DIR/.hysteria"
LOG="$HOME_DIR/logs"
mkdir -p "$BIN" "$XR" "$HY" "$LOG"
cd /tmp

dl() { # dl <url> <output> : retry a few times, fail closed
  local url="$1" out="$2" i
  for i in 1 2 3 4 5; do
    if curl -fsSL --max-time 180 -o "$out" "$url"; then return 0; fi
    echo "download attempt $i failed for $url, retrying..."
    sleep 3
  done
  echo "DOWNLOAD FAILED: $url"; return 1
}

echo "=== downloading Xray $XRAY_VER (XTLS/Xray-core, official release) ==="
dl "$XRAY_URL" Xray-linux-64.zip
ACTUAL=$(sha256sum Xray-linux-64.zip | awk '{print $1}')
echo "expected: $XRAY_SHA256"
echo "actual:   $ACTUAL"
[ "$ACTUAL" = "$XRAY_SHA256" ] || { echo "XRAY HASH MISMATCH — aborting"; exit 1; }
echo "Xray hash OK"
if command -v unzip >/dev/null; then
  unzip -o -q Xray-linux-64.zip xray -d "$BIN"
else
  python3 -c "import zipfile; zipfile.ZipFile('Xray-linux-64.zip').extract('xray', '$BIN')"
fi
chmod +x "$BIN/xray"
"$BIN/xray" version | head -2

echo "=== downloading Hysteria2 $HY2_VER (apernet/hysteria, official release) ==="
dl "$HY2_URL" hysteria-dl
if [ "$HY2_GZ" = "1" ]; then
  [ -n "$HY2_GZ_SHA256" ] || { echo "HY2_GZ=1 but HY2_GZ_SHA256 not set — aborting"; exit 1; }
  ACTUAL_XZ=$(sha256sum hysteria-dl | awk '{print $1}')
  echo "expected gz: $HY2_GZ_SHA256"
  echo "actual gz:   $ACTUAL_XZ"
  [ "$ACTUAL_XZ" = "$HY2_GZ_SHA256" ] || { echo "HYSTERIA GZ HASH MISMATCH — aborting"; exit 1; }
  echo "Hysteria gz hash OK"
  gzip -d -c hysteria-dl > hysteria-bin
else
  cp hysteria-dl hysteria-bin
fi
ACTUAL_H=$(sha256sum hysteria-bin | awk '{print $1}')
echo "expected: $HY2_SHA256"
echo "actual:   $ACTUAL_H"
[ "$ACTUAL_H" = "$HY2_SHA256" ] || { echo "HYSTERIA HASH MISMATCH — aborting"; exit 1; }
echo "Hysteria2 hash OK"
cp hysteria-bin "$BIN/hysteria"
chmod +x "$BIN/hysteria"
"$BIN/hysteria" version 2>&1 | head -3

echo "=== generating credentials & self-signed TLS cert ==="
UUID=$("$BIN/xray" uuid)
HY_PASS=$(openssl rand -hex 16)
echo "UUID=$UUID"
echo "HY_PASS set (24 hex chars)"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$XR/key.pem" -out "$XR/cert.pem" -days 3650 \
  -subj "/CN=ascs-node" \
  -addext "subjectAltName=IP:${IPV6}" 2>/dev/null
cp "$XR/cert.pem" "$HY/cert.pem"
cp "$XR/key.pem" "$HY/key.pem"
chmod 600 "$XR/key.pem" "$HY/key.pem"
openssl x509 -in "$XR/cert.pem" -noout -subject -ext subjectAltName

echo "=== writing xray config (VLESS+WS+TLS :$VLESS_PORT) ==="
cat > "$XR/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $VLESS_PORT,
      "listen": "::",
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$UUID" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            { "certificateFile": "$XR/cert.pem", "keyFile": "$XR/key.pem" }
          ]
        },
        "wsSettings": { "path": "$WS_PATH" }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF
"$BIN/xray" -test -config "$XR/config.json" && echo "xray config test OK"

echo "=== writing hysteria2 config (UDP :$HY2_PORT) ==="
cat > "$HY/config.yaml" <<EOF
listen: :$HY2_PORT

tls:
  cert: $HY/cert.pem
  key: $HY/key.pem

auth:
  type: password
  password: $HY_PASS

masquerade:
  type: proxy
  proxy:
    url: https://example.com
    rewriteHost: true
EOF

echo "=== writing starter script ==="
cat > "$BIN/start-proxies.sh" <<'SEOF'
#!/bin/bash
pkill -f 'bin/xray run' 2>/dev/null || true
pkill -f 'bin/hysteria server' 2>/dev/null || true
sleep 1
setsid "$HOME/bin/xray" run -config "$HOME/.xray/config.json" >>"$HOME/logs/xray.log" 2>&1 < /dev/null &
setsid "$HOME/bin/hysteria" server --config "$HOME/.hysteria/config.yaml" >>"$HOME/logs/hysteria.log" 2>&1 < /dev/null &
sleep 3
echo "--- processes ---"
ps aux | grep -E '[b]in/xray run|[b]in/hysteria server' || echo "NO PROXY PROCESSES FOUND"
echo "--- recent log tails ---"
tail -5 "$HOME/logs/xray.log" 2>/dev/null || true
tail -5 "$HOME/logs/hysteria.log" 2>/dev/null || true
SEOF
chmod +x "$BIN/start-proxies.sh"

echo "=== persistence: @reboot cron ==="
( crontab -l 2>/dev/null | grep -v 'start-proxies.sh' ; echo "@reboot $BIN/start-proxies.sh" ) | crontab -
crontab -l | grep start-proxies || echo "CRON WRITE FAILED"

echo "=== starting services ==="
"$BIN/start-proxies.sh"

echo "=== saving client parameters ==="
{
  echo "ipv6=$IPV6"
  echo "vless_port=$VLESS_PORT"
  echo "vless_uuid=$UUID"
  echo "vless_path=$WS_PATH"
  echo "vless_sni=ascs-node"
  echo "hy2_port=$HY2_PORT"
  echo "hy2_password=$HY_PASS"
  echo "hy2_sni=ascs-node"
  echo "xray_ver=$XRAY_VER"
  echo "hy2_ver=$HY2_VER"
} > "$HOME/proxy-params.env"
chmod 600 "$HOME/proxy-params.env"
echo "DEPLOY_DONE"
