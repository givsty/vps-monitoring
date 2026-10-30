#!/usr/bin/env bash
# Проверяет .env перед `docker compose up`: все ли обязательные ключи заполнены.
# Запускается автоматически через `make up`.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  echo "✗ .env не найден."
  echo "  cp .env.example .env && \$EDITOR .env"
  exit 1
fi

# Не source: docker-compose допускает пробелы в значениях, bash — нет.
value_of() {
  grep -E "^${1}=" .env | tail -n 1 | cut -d= -f2- || true
}

missing=()
for key in VPN_IP GRAFANA_ADMIN_PASSWORD TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID; do
  if [[ -z "$(value_of "$key")" ]]; then
    missing+=("$key")
  fi
done

if (( ${#missing[@]} > 0 )); then
  echo "✗ В .env не заполнено:"
  printf '   - %s\n' "${missing[@]}"
  echo
  echo "  Все ключи с комментариями есть в .env.example."
  echo "  Если .env остался от старой версии — сверь его с .env.example."
  exit 1
fi

VPN_IP="$(value_of VPN_IP)"
if [[ ! "$VPN_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  echo "✗ VPN_IP='${VPN_IP}' не похож на IPv4-адрес"
  exit 1
fi

GRAFANA_BIND="$(value_of GRAFANA_BIND)"
if [[ -z "$GRAFANA_BIND" ]]; then
  echo "⚠ GRAFANA_BIND не задан — Grafana будет только на 127.0.0.1"
  GRAFANA_BIND=127.0.0.1
fi

echo "✓ .env в порядке"
echo "  VPN_IP           = ${VPN_IP}"
echo "  Grafana          = ${GRAFANA_BIND}:3000"
echo "  Pushgateway      = $(value_of PUSHGATEWAY_BIND || true)"
