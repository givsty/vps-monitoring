#!/usr/bin/env bash
# Меняет IP VPN-сервера в .env и перезапускает Prometheus с новыми таргетами.
#
#   ./scripts/set-vpn-ip.sh 46.8.100.230
#
# Позже, когда появится DDNS, этот шаг уйдёт совсем: Prometheus будет
# резолвить имя сам (dns_sd_configs).
set -euo pipefail

IP="${1:-}"
if [[ ! "$IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  echo "usage: $0 <ipv4>" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  echo ".env не найден. Сначала: cp .env.example .env" >&2
  exit 1
fi

sed -i.bak -E "s/^VPN_IP=.*/VPN_IP=${IP}/" .env
rm -f .env.bak

echo "VPN_IP=${IP} записан в .env, пересоздаю prometheus..."
if [[ -f /etc/default/cheburcheck ]]; then
  echo "не забудь: CHEBUR_TARGET в /etc/default/cheburcheck тоже должен указывать на ${IP}"
fi
docker compose up -d prometheus

echo -n "ожидание healthcheck: "
for _ in $(seq 1 30); do
  if docker compose exec -T prometheus wget -qO- http://localhost:9090/-/healthy >/dev/null 2>&1; then
    echo "ok"
    exit 0
  fi
  echo -n "."
  sleep 2
done

echo
echo "Prometheus не поднялся за 60 секунд, смотри: docker compose logs prometheus" >&2
exit 1
