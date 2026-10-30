#!/usr/bin/env bash
# Проверяет всю цепочку мониторинга и печатает отчёт: где что сломалось.
# Запускать на сервере мониторинга из корня репозитория:
#   ./scripts/diagnose.sh
set -uo pipefail

cd "$(dirname "$0")/.."

failures=0
ok()   { printf '✓ %s\n' "$*"; }
bad()  { printf '✗ %s\n' "$*"; failures=$((failures + 1)); }
note() { printf '  %s\n' "$*"; }
head_() { printf '\n== %s ==\n' "$*"; }

value_of() {
  grep -E "^${1}=" .env 2>/dev/null | tail -n 1 | cut -d= -f2- || true
}

head_ "1. Конфигурация"

if [[ -f .env ]]; then
  ok ".env найден"
else
  bad ".env отсутствует — cp .env.example .env"
fi

VPN_IP="$(value_of VPN_IP)"
if [[ -n "$VPN_IP" ]]; then
  ok "VPN_IP = $VPN_IP"
else
  bad "VPN_IP не задан в .env"
fi

head_ "2. Docker и compose"

if docker compose version >/dev/null 2>&1; then
  ok "docker compose: $(docker compose version --short 2>/dev/null || echo v2)"
else
  bad "docker compose v2 не найден"
fi

running="$(docker compose ps --services --filter status=running 2>/dev/null | tr '\n' ' ')"
if [[ -n "$running" ]]; then
  ok "запущены: $running"
else
  bad "ни один контейнер не запущен (docker compose up -d)"
fi

head_ "3. Prometheus"

if curl -fsS -m 5 http://127.0.0.1:9090/-/healthy >/dev/null 2>&1; then
  ok "Prometheus отвечает на 127.0.0.1:9090"
else
  bad "Prometheus не отвечает на 127.0.0.1:9090/-/healthy"
fi

jobs="$(curl -fsS -m 5 http://127.0.0.1:9090/api/v1/label/job/values 2>/dev/null \
  | python3 -c 'import sys,json; print(" ".join(json.load(sys.stdin)["data"]))' 2>/dev/null)"

if [[ -n "$jobs" ]]; then
  note "jobs: $jobs"
  if [[ " $jobs " == *" node-vpn "* ]]; then
    ok "job=node-vpn есть — конфиг новый"
  else
    bad "job=node-vpn отсутствует — Prometheus работает со старым конфигом"
    note "лечится: docker compose up -d --force-recreate prometheus"
  fi
else
  bad "не удалось получить список job'ов"
fi

targets_json="$(mktemp)"
if curl -fsS -m 5 http://127.0.0.1:9090/api/v1/targets >"$targets_json" 2>/dev/null; then
  note "таргеты:"
  python3 - "$targets_json" <<'PY'
import json, sys
targets = json.load(open(sys.argv[1]))["data"]["activeTargets"]
for t in sorted(targets, key=lambda x: x["labels"].get("job", "")):
    err = (t.get("lastError") or "")[:60]
    print("    {:<14} {:<45} {:<7} {}".format(
        t["labels"].get("job", "?"), t["scrapeUrl"], t["health"], err))
PY
fi
rm -f "$targets_json"

head_ "4. node_exporter и textfile"

if curl -fsS -m 5 http://127.0.0.1:9100/metrics >/dev/null 2>&1; then
  ok "node_exporter отвечает на 127.0.0.1:9100"
  chebur_count="$(curl -fsS -m 5 http://127.0.0.1:9100/metrics 2>/dev/null | grep -c '^chebur_' || true)"
  if [[ "$chebur_count" -gt 0 ]]; then
    ok "chebur-метрик в node_exporter: $chebur_count"
  else
    bad "chebur-метрик нет — файл не читается или скрипт не отрабатывал"
  fi
else
  bad "node_exporter не отвечает на 127.0.0.1:9100"
fi

if [[ -d /var/lib/node_exporter/textfile ]]; then
  files="$(ls -1 /var/lib/node_exporter/textfile 2>/dev/null | tr '\n' ' ')"
  if [[ -n "$files" ]]; then
    ok "textfile-каталог: $files"
    for f in /var/lib/node_exporter/textfile/*.prom; do
      [[ -f "$f" ]] && note "$f: $(stat -c '%y' "$f" 2>/dev/null | cut -d. -f1) — $(wc -l < "$f") строк"
    done
  else
    bad "textfile-каталог пуст"
  fi
else
  bad "нет каталога /var/lib/node_exporter/textfile"
fi

head_ "5. Скрипт cheburcheck"

if [[ -x /usr/local/bin/cheburcheck_probe.py ]]; then
  ok "/usr/local/bin/cheburcheck_probe.py на месте"
else
  bad "скрипт не установлен в /usr/local/bin"
fi

if [[ -f /etc/default/cheburcheck ]]; then
  target="$(grep -E '^CHEBUR_TARGET=' /etc/default/cheburcheck 2>/dev/null | cut -d= -f2- || true)"
  if [[ -n "$target" ]]; then
    ok "CHEBUR_TARGET = $target"
  else
    bad "в /etc/default/cheburcheck не задан CHEBUR_TARGET"
  fi
else
  bad "нет /etc/default/cheburcheck"
fi

if systemctl is-active --quiet cheburcheck.timer 2>/dev/null; then
  ok "cheburcheck.timer активен"
  systemctl list-timers cheburcheck.timer --no-pager 2>/dev/null | sed -n '2p' | sed 's/^/  /'
else
  bad "cheburcheck.timer не активен (systemctl enable --now cheburcheck.timer)"
fi

if systemctl is-failed --quiet cheburcheck.service 2>/dev/null; then
  bad "последний запуск cheburcheck.service упал:"
  journalctl -u cheburcheck.service -n 15 --no-pager 2>/dev/null | sed 's/^/  /'
fi

head_ "6. VPN-сервер"

if [[ -n "$VPN_IP" ]]; then
  for port in 9100 9351; do
    if curl -fsS -m 5 "http://${VPN_IP}:${port}/metrics" >/dev/null 2>&1; then
      ok "${VPN_IP}:${port} отвечает"
    else
      bad "${VPN_IP}:${port} не отвечает (экспортёр не запущен или firewall)"
    fi
  done
fi

printf '\n'
if [[ "$failures" -eq 0 ]]; then
  echo "Итог: всё на месте."
  exit 0
fi

echo "Итог: проблем — $failures. Смотри ✗ выше."
exit 1
