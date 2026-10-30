#!/bin/sh
# Генерирует file_sd-таргеты из VPN_IP при старте контейнера.
# Так рабочий IP не попадает в публичный git и меняется в одном месте — .env
set -eu

: "${VPN_IP:?VPN_IP is not set}"

dir=/tmp/prometheus-targets
mkdir -p "$dir"

printf '[{"targets": ["%s:9100"], "labels": {"env": "prod", "role": "vpn"}}]\n' \
  "$VPN_IP" > "$dir/node-vpn.json"
printf '[{"targets": ["%s:9351"], "labels": {"env": "prod", "service": "vpn"}}]\n' \
  "$VPN_IP" > "$dir/awg.json"

exec /bin/prometheus "$@"
