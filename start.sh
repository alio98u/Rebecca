#!/bin/sh
# AHB panel: panel and VLESS/WS inbound behind one domain via nginx

PORT="${PORT:-8080}"
PANEL_PORT=2053
WS_PORT=10000
WS_PATH="${WS_PATH:-/ws}"
PANEL_USER="${PANEL_USER:-admin}"
PANEL_PASS="${PANEL_PASS:-change-me-now}"
PANEL_PATH="${PANEL_PATH:-/admin/}"   # must start and end with /

cd /app || exit 1
mkdir -p /etc/x-ui

# 1) panel settings
./x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" \
  -port "$PANEL_PORT" -webBasePath "$PANEL_PATH"

# 2) nginx: WS path -> xray inbound, everything else -> panel
cat > /etc/nginx/nginx.conf <<EOF
worker_processes 1;
pid /tmp/nginx.pid;
events { worker_connections 1024; }
http {
  map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
  server {
    listen $PORT;
    location $WS_PATH {
      proxy_pass http://127.0.0.1:$WS_PORT;
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
      proxy_set_header Host \$host;
      proxy_read_timeout 86400s;
    }
    location / {
      proxy_pass http://127.0.0.1:$PANEL_PORT;
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
    }
  }
}
EOF

# 3) start panel + nginx
./x-ui &
nginx -g 'daemon off;' &

# 4) auto-create inbound on first run
(
  BASE="http://127.0.0.1:$PANEL_PORT${PANEL_PATH%/}"
  JAR=/tmp/cj
  for i in $(seq 1 30); do
    curl -s -o /dev/null "$BASE/" && break
    sleep 2
  done
  curl -s -c $JAR -X POST "$BASE/login" \
    --data-urlencode "username=$PANEL_USER" \
    --data-urlencode "password=$PANEL_PASS" > /dev/null

  EXISTING=$(curl -s -b $JAR "$BASE/panel/api/inbounds/list" | jq '.obj | length' 2>/dev/null)
  if [ "$EXISTING" = "0" ]; then
    UUID=$(cat /proc/sys/kernel/random/uuid)
    SUB=$(cat /proc/sys/kernel/random/uuid | tr -d '-' | cut -c1-16)
    SETTINGS="{\"clients\":[{\"id\":\"$UUID\",\"email\":\"ahb\",\"flow\":\"\",\"limitIp\":0,\"totalGB\":0,\"expiryTime\":0,\"enable\":true,\"subId\":\"$SUB\"}],\"decryption\":\"none\",\"fallbacks\":[]}"
    STREAM="{\"network\":\"ws\",\"security\":\"none\",\"wsSettings\":{\"path\":\"$WS_PATH\",\"headers\":{}}}"
    SNIFF='{"enabled":true,"destOverride":["http","tls"]}'
    curl -s -b $JAR -X POST "$BASE/panel/api/inbounds/add" \
      --data-urlencode "up=0" --data-urlencode "down=0" \
      --data-urlencode "total=0" --data-urlencode "remark=ahb" \
      --data-urlencode "enable=true" --data-urlencode "expiryTime=0" \
      --data-urlencode "listen=127.0.0.1" --data-urlencode "port=$WS_PORT" \
      --data-urlencode "protocol=vless" \
      --data-urlencode "settings=$SETTINGS" \
      --data-urlencode "streamSettings=$STREAM" \
      --data-urlencode "sniffing=$SNIFF" > /tmp/add.log
    DOMAIN="${RAILWAY_PUBLIC_DOMAIN:-YOUR-DOMAIN}"
    ENC_PATH=$(echo "$WS_PATH" | sed 's#/#%2F#g')
    echo "=============================================="
    echo "AHB inbound created. Client config link:"
    echo "vless://$UUID@$DOMAIN:443?type=ws&security=tls&path=$ENC_PATH&host=$DOMAIN&sni=$DOMAIN&encryption=none#ahb"
    echo "Panel: https://$DOMAIN${PANEL_PATH}"
    echo "=============================================="
  fi
) &

wait
