#!/usr/bin/env bash
# Ждёт, пока поднимутся веб-интерфейсы стека. Используется деплоем и руками.
set -euo pipefail

cd "$(dirname "$0")/.."

value_of() {
  grep -E "^${1}=" .env 2>/dev/null | tail -n 1 | cut -d= -f2- || true
}

GRAFANA_BIND="$(value_of GRAFANA_BIND)"
GRAFANA_BIND="${GRAFANA_BIND:-127.0.0.1}"
if [[ "$GRAFANA_BIND" == "0.0.0.0" ]]; then
  GRAFANA_BIND=127.0.0.1
fi

failed=0

wait_for() {
  local name="$1" url="$2"
  for _ in $(seq 1 30); do
    if curl -fsS -m 3 "$url" >/dev/null 2>&1; then
      echo "✓ $name"
      return 0
    fi
    sleep 2
  done
  echo "✗ $name ($url) не ответил за 60 секунд" >&2
  return 1
}

wait_for prometheus http://127.0.0.1:9090/-/healthy || failed=1
wait_for alertmanager http://127.0.0.1:9093/-/healthy || failed=1
wait_for grafana "http://${GRAFANA_BIND}:3000/api/health" || failed=1

exit "$failed"
