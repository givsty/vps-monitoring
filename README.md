# vps-monitoring

Мониторинг VPN-сервера (AmneziaWG) и алерты в Telegram, включая **детект блокировок DPI/ТСПУ** через [cheburcheck.ru](https://cheburcheck.ru).

Стек: Prometheus + Alertmanager + Pushgateway + Node Exporter + Grafana.

## Что внутри

| Компонент | Зачем |
|---|---|
| `prometheus/` | Сбор метрик, правила алертов |
| `alertmanager/` | Отправка в Telegram (токен подставляется из `.env`) |
| `pushgateway/` | Heartbeat с VPN-сервера — отличает «заблокировали» от «сервер умер» |
| `node-exporter` | Метрики самого монитора + textfile-метрики |
| `grafana/` | Дашборды (provisioning) |
| `scripts/cheburcheck_probe.py` | Опрос cheburcheck + динамическое сканирование ТСПУ → метрики |
| `systemd/` | Таймер для скрипта cheburcheck |
| `PLAN.md` | Полный план развития (мониторинг, CI/CD, DPI) |

## Быстрый старт

```bash
cp .env.example .env
$EDITOR .env                 # VPN_IP, пароль Grafana, токен бота, chat_id

mkdir -p /var/lib/node_exporter/textfile   # сюда пишутся textfile-метрики
docker compose up -d
docker compose ps
```

`VPN_IP` — публичный адрес VPN-сервера. Он живёт только в `.env` (файл в `.gitignore`),
потому что репозиторий публичный. Prometheus при старте сам превращает его
в file_sd-таргеты, поэтому IP есть ровно в одном месте.

Проверка:

* Prometheus — http://127.0.0.1:9090/-/healthy
* Alertmanager — http://127.0.0.1:9093/-/healthy
* Grafana — http://127.0.0.1:3000 (логин из `.env`)

Prometheus, Alertmanager и node-exporter всегда слушают только `127.0.0.1`.
Grafana — `GRAFANA_BIND` (по умолчанию тоже localhost; публичный IP — если нужен
доступ извне, с сильным паролем). Pushgateway — `PUSHGATEWAY_BIND`, его имеет смысл
повесить на Tailscale-адрес `100.x.y.z`.

## Что настроить на VPN-сервере

1. **node_exporter** на `:9100` и **amneziawg-exporter** на `:9351`, оба доступны только
   с IP монитора (firewall).
2. **DDNS**: systemd-таймер обновляет A-запись (`vpn-xxx.duckdns.org` → текущий IP)
   раз в минуту. Это же имя прописывается в `prometheus/prometheus.yml` (две строки
   `names:`) — по нему Prometheus находит сервер после смены IP.
3. **Heartbeat** раз в 30 секунд:

   ```bash
   printf 'vpn_heartbeat 1\n' | curl -fsS --data-binary @- \
     "http://<монитор>:9091/metrics/job/vpn-heartbeat/instance/vpn"
   ```

4. **Число пользователей** считается из `awg_latest_handshake_seconds`
   (см. `PLAN.md`, раздел A2). Включи `AWG_EXPORTER_CLIENTS_TABLE_ENABLED=true`,
   иначе все пиры будут `unidentified`.

## Детект блокировок DPI (cheburcheck)

Скрипт раз в 15 минут спрашивает cheburcheck, не заблокирован ли IP, и запускает
динамическое сканирование: ~36 сканеров в российских сетях пробуют достучаться
до цели и возвращают вердикты `tspu_block`, `sni_block`, `dns_spoofing`, `ok`,
`uncertain`.

Установка:

```bash
sudo install -m 0755 scripts/cheburcheck_probe.py /usr/local/bin/
sudo install -m 0644 systemd/cheburcheck.service systemd/cheburcheck.timer /etc/systemd/system/
echo 'CHEBUR_TARGET=vpn-xxx.duckdns.org' | sudo tee /etc/default/cheburcheck
sudo systemctl daemon-reload
sudo systemctl enable --now cheburcheck.timer
```

Проверить руками:

```bash
sudo /usr/local/bin/cheburcheck_probe.py --target vpn-xxx.duckdns.org \
  --out /var/lib/node_exporter/textfile/chebur.prom
cat /var/lib/node_exporter/textfile/chebur.prom
```

Метрики:

| Метрика | Смысл |
|---|---|
| `chebur_listed_in_rkn` | IP найден в списках РКН/CDN |
| `chebur_probe_verdict_count{verdict="tspu_block"}` | сколько российских сканеров видят блокировку IP |
| `chebur_probe_verdict_ratio{verdict="..."}` | то же в долях от числа ответивших |
| `chebur_probe_responses` / `chebur_probe_online` | сколько сканеров ответило / было онлайн |
| `chebur_last_success_timestamp` | когда последний раз всё отработало |

Алерты (в `prometheus/rules/alerts.yml`):

* **VPNBlockedByTSPU** — `tspu_block` хотя бы у одного сканера, 10 минут → critical.
* **VPNBlockedBySNI** — `sni_block`, 15 минут → warning.
* **VPNListedInRKN** — попали в реестр, 30 минут → warning.
* **CheburcheckStale** — скрипт не отчитывался больше часа → warning.

Порог можно поднять, если одиночные сканеры шумят: замени `> 0` на `> 2`
в правиле `VPNBlockedByTSPU`.

## Смена IP VPN-сервера

Пока не заведён DDNS, адрес меняется одной командой:

```bash
./scripts/set-vpn-ip.sh 46.8.100.230
```

Скрипт правит `VPN_IP` в `.env`, пересоздаёт контейнер Prometheus и ждёт healthcheck.
Сами таргеты генерируются в `prometheus/entrypoint.sh` — руками ничего править не нужно.

Когда появится DuckDNS, `file_sd` в `prometheus/prometheus.yml` меняется на `dns_sd`,
и шаг с IP исчезает совсем.

## Полезное

* Перечитать конфиг Prometheus без рестарта: `curl -X POST http://127.0.0.1:9090/-/reload`
* Логи: `docker compose logs -f prometheus alertmanager`
* Остановить: `docker compose down` (данные в volumes сохраняются)

## Статус

Сделано: P0 (гигиена стека, закрытые порты, volume, healthcheck, правила, алерты)
и интеграция cheburcheck.

Дальше по плану: Tailscale-доступ, DDNS-метрики, дашборды, CI/CD, Ansible-bootstrap.
Подробности — в [PLAN.md](PLAN.md).
