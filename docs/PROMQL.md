# PromQL для дашбордов

Готовые запросы под панели Grafana. Всё проверено на метриках этого стека.

## 0. Перед началом

**Откуда что берётся**

| Метрика | Источник | Где |
|---|---|---|
| `node_*` | node_exporter | VPN-сервер и монитор |
| `awg_*` | amneziawg-exporter | VPN-сервер, порт 9351 |
| `push_time_seconds`, `vpn_heartbeat` | pushgateway | VPN-сервер пушит сам |
| `chebur_*` | `scripts/cheburcheck_probe.py` → textfile | монитор |
| `up`, `scrape_duration_seconds` | сам Prometheus | везде |

**Проверить, что метрика вообще есть:**

```bash
curl -s http://<vpn-ip>:9100/metrics | grep node_load1
curl -s http://<vpn-ip>:9351/metrics | grep awg_latest_handshake
curl -s http://127.0.0.1:9100/metrics | grep chebur_
```

**Переменные дашборда** (Dashboard settings → Variables):

| Переменная | Тип | Query |
|---|---|---|
| `instance` | Query | `label_values(up, instance)` |
| `client` | Query | `label_values(awg_latest_handshake_seconds, client_name)` |
| `verdict` | Query | `label_values(chebur_probe_verdict_count, verdict)` |

**Важно про `client_name`:** он появляется только если у экспортёра включён
`AWG_EXPORTER_CLIENTS_TABLE_ENABLED=true` и подложен `clientsTable`. Без этого
все пиры будут `unidentified`.

**Важно про `awg_latest_handshake_seconds`:** это Unix-timestamp последнего
хендшейка, не «сколько секунд назад». Поэтому везде `time() - ...`.

---

## 1. Сервер

| Панель | Тип | Запрос |
|---|---|---|
| CPU, % | Time series | `100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)` |
| RAM, % | Time series | `100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)` |
| RAM, байты | Time series | `node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes` |
| Диск, % | Time series | `100 * (1 - node_filesystem_avail_bytes{fstype!~"tmpfs\|overlay\|squashfs"} / node_filesystem_size_bytes{fstype!~"tmpfs\|overlay\|squashfs"})` |
| Диск, свободно | Stat | `node_filesystem_avail_bytes{fstype!~"tmpfs\|overlay\|squashfs",mountpoint="/"}` |
| LA | Time series | `node_load1` / `node_load5` / `node_load15` |
| Сеть RX | Time series | `sum by (instance) (rate(node_network_receive_bytes_total{device!~"lo\|veth.*\|docker.*\|br-.*"}[5m]))` |
| Сеть TX | Time series | `sum by (instance) (rate(node_network_transmit_bytes_total{device!~"lo\|veth.*\|docker.*\|br-.*"}[5m]))` |
| Uptime | Stat | `time() - node_boot_time_seconds` |
| Conntrack, % | Gauge | `100 * node_nf_conntrack_entries / node_nf_conntrack_entries_limit` |
| Ошибки UDP | Time series | `rate(node_netstat_UdpRcvbufErrors[5m])` |
| File descriptors, % | Gauge | `100 * node_filefd_allocated / node_filefd_maximum` |
| Disk IO | Time series | `rate(node_disk_read_bytes_total[5m])` и `rate(node_disk_written_bytes_total[5m])` |
| Температура | Time series | `node_hwmon_temp_celsius` (если датчик есть) |

Легенда для панелей с несколькими хостами: `{{instance}}`, для дисков — `{{instance}} {{mountpoint}}`.

> `node_netstat_UdpRcvbufErrors` — частая причина «VPN тормозит» на слабых VPS.
> Если растёт — поднимай `net.core.rmem_max` / `net.core.rmem_default`.

---

## 2. Пользователи VPN

| Панель | Тип | Запрос |
|---|---|---|
| Всего пиров | Stat | `count(count by (peer) (awg_latest_handshake_seconds))` |
| Онлайн сейчас | Stat | `count((time() - awg_latest_handshake_seconds) < 180)` |
| Онлайн по клиентам | Table | `count by (client_name) ((time() - awg_latest_handshake_seconds) < 180)` |
| Возраст хендшейка | Table | `time() - awg_latest_handshake_seconds` |
| Статус клиента (1/0) | State timeline | `(time() - awg_latest_handshake_seconds) < 180` |
| Подключались за 30 дней | Stat | `count((time() - awg_latest_handshake_seconds) < 2592000)` |
| Состояние экспортёра | Stat | `awg_status` |

«Онлайн» = хендшейк моложе 180 секунд (стандартный таймаут WireGuard).
Пир, который ни разу не подключался, отдаёт `0`, поэтому `time() - 0` огромно — он честно offline.

Для таблиц включи **Instant** и **Format: Table**, иначе получишь по строке на каждый шаг.

---

## 3. Трафик

`awg_sent_bytes` и `awg_received_bytes` — это **gauge** с накопленным значением
(экспортёр кладёт туда цифру из `awg show`). `increase()` работает и на них:
при переподключении пира счётчик падает, и `increase()` это компенсирует.
`delta()` — не компенсирует, поэтому не используй.

| Панель | Тип | Запрос |
|---|---|---|
| Скачано за 24ч по клиентам | Bar gauge | `sum by (client_name) (increase(awg_received_bytes[24h]))` |
| Отдано за 24ч по клиентам | Bar gauge | `sum by (client_name) (increase(awg_sent_bytes[24h]))` |
| Скорость RX сейчас | Time series | `sum by (client_name) (rate(awg_received_bytes[5m]))` |
| Скорость TX сейчас | Time series | `sum by (client_name) (rate(awg_sent_bytes[5m]))` |
| Суммарно за 24ч | Stat | `sum(increase(awg_received_bytes[24h])) + sum(increase(awg_sent_bytes[24h]))` |
| Топ-5 за час | Table | `topk(5, sum by (client_name) (increase(awg_received_bytes[1h])))` |
| Накоплено всего | Stat | `sum(awg_received_bytes)` + `sum(awg_sent_bytes)` |

В Grafana удобнее `$__rate_interval` вместо жёстких `[5m]` — тогда интервал
подстраивается под масштаб графика:

```promql
sum by (client_name) (rate(awg_received_bytes[$__rate_interval]))
```

---

## 4. Доступность и блокировки DPI

| Панель | Тип | Запрос |
|---|---|---|
| Все таргеты | Table | `up` |
| VPN отвечает | Stat | `up{job="node-vpn"}` |
| Доступность за 24ч, % | Stat | `avg_over_time(up{job="node-vpn"}[24h]) * 100` |
| Возраст heartbeat | Stat | `time() - push_time_seconds{job="vpn-heartbeat"}` |
| Heartbeat живой | Stat | `(time() - push_time_seconds{job="vpn-heartbeat"}) < 180` |
| Вердикты сканеров | Bar gauge | `chebur_probe_verdict_count` |
| Доля ТСПУ, % | Stat | `100 * chebur_probe_verdict_ratio{verdict="tspu_block"}` |
| Заблокировано сканеров | Stat | `chebur_probe_blocked_probes` |
| Ответило сканеров | Stat | `chebur_probe_responses` (и `chebur_probe_online` — сколько было доступно) |
| В реестре РКН | Stat | `chebur_listed_in_rkn` |
| Свежесть cheburcheck | Stat | `time() - chebur_last_success_timestamp` |
| Таймлайн блокировки | State timeline | `chebur_probe_verdict_count{verdict="tspu_block"} > 0` |
| Длительность скрейпа | Time series | `scrape_duration_seconds` |

**Как читать связку heartbeat + up:**

```promql
# сервер жив, но из РФ не пускает
up{job="node-vpn"} == 0 and (time() - push_time_seconds{job="vpn-heartbeat"}) < 180

# сервер мёртв
up{job="node-vpn"} == 0 and (time() - push_time_seconds{job="vpn-heartbeat"}) > 180
```

**Таймлайн блокировок** — самая полезная панель для «когда началось»:
State timeline по `chebur_probe_verdict_count{verdict="tspu_block"} > 0`, значение
`1` = блокируют, `0` = нет. Хорошо ложится рядом с графиком `up{job="node-vpn"}`.

---

## 5. Алерты

Алертинг теперь в Grafana, а не в Prometheus, поэтому метрики `ALERTS` в Prometheus
больше нет — правила там не вычисляются.

Смотреть состояния: **Alerting → Alert rules** (список правил и их состояние)
и **Alerting → Active alerts** (что горит прямо сейчас, с историей и silences).

Если хочется видеть алерты на дашборде — используй нативную панель **Alert list**
(тип `alertlist`), она показывает алерты Grafana без всяких запросов. PromQL тут не нужен.

## 6. Чего пока нет

Эти метрики появятся вместе с DDNS-таймером (сейчас не реализованы):

* `vpn_public_ip_age_seconds` — сколько живёт текущий IP;
* `vpn_ddns_record_matches` — совпадает ли A-запись с реальным адресом;
* `vpn_public_ip_info{ip="..."}` — текущий IP.

До этого момента алерты `VPNIPChanged` и `VPNDDNSMismatch` молчат (метрик нет),
а текущий IP смотри в `.env` → `VPN_IP` или в `up{job="node-vpn"}`.

---

## 7. Шпаргалка по панелям

* **Stat** — одно число: онлайн, возраст heartbeat, % диска. Включи thresholds.
* **Time series** — динамика: CPU, трафик, `up`.
* **Table** + Instant — списки: клиенты, таргеты, алерты.
* **Bar gauge** — сравнение: трафик по клиентам, вердикты сканеров.
* **State timeline** — 0/1 состояния: блокировка, онлайн клиента.

Единицы: `percent` (0–100), `bytes`, `seconds`, `Bps` для скоростей.
Легенда: `{{client_name}}`, `{{instance}}`, `{{verdict}}`.
