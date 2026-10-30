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
| `.github/workflows/` | CI, деплой и ручные операции |
| `docs/PROMQL.md` | Готовые запросы под панели Grafana |
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

## CI/CD

| Workflow | Когда | Что делает |
|---|---|---|
| `ci.yml` | PR и push в main | проверяет `.env` в git, `docker compose config`, конфиг/правила/юнит-тесты Prometheus, шаблон Alertmanager, shellcheck, синтаксис Python |
| `deploy.yml` | **только вручную** (`workflow_dispatch`) | заходит по SSH, гоняет `scripts/deploy.sh`: `git reset --hard <sha>` → проверка `.env` → `compose up` → healthcheck → **автооткат** на предыдущий коммит при провале |
| `ops.yml` | вручную | кнопки: `reload-prometheus`, `restart-stack`, `set-vpn-ip`, `check-block` |

Деплой намеренно не автоматический: продом управляет владелец репозитория.
Хочешь approval-гейт — Settings → Environments → `production` → Required reviewers.

### Что нужно завести в GitHub

Secrets (Settings → Secrets and variables → Actions):

| Secret | Значение |
|---|---|
| `SSH_HOST` | IP сервера мониторинга |
| `SSH_USER` | `deploy` |
| `SSH_KEY` | приватный ключ ed25519 деплой-пользователя |
| `SSH_KNOWN_HOSTS` | `ssh-keyscan -H <IP>` — чтобы не отключать проверку хоста |
| `SSH_PORT` | порт SSH, если не 22 (необязательный) |

Variable (не secret): `DEPLOY_PATH` — путь к репозиторию на сервере, по умолчанию `/opt/vps-monitoring`.

### Требования на сервере

* `git`, `curl`;
* **docker + docker compose v2** — именно плагин `docker compose`, старый
  `docker-compose` v1 не подойдёт;
* пользователь `deploy` в группе `docker`;
* каталог репозитория принадлежит `deploy` — иначе git ругается
  `detected dubious ownership`.

```bash
sudo apt-get update
sudo apt-get install -y docker-compose-plugin || sudo apt-get install -y docker-compose-v2
sudo -u deploy docker compose version
```

### Подготовка сервера

```bash
adduser --disabled-password --gecos "" deploy
usermod -aG docker deploy
install -d -o deploy -g deploy /opt/vps-monitoring
sudo -u deploy git clone https://github.com/givsty/vps-monitoring /opt/vps-monitoring
# публичный ключ из SSH_KEY -> /home/deploy/.ssh/authorized_keys
```

> `deploy` в группе `docker` — это фактически root. Для соло-сервера приемлемо,
> но если хочешь строже — деплой через `sudo` с ограниченным набором команд.

> Если SSH с раннеров GitHub до сервера окажется нестабильным (RU-хостинг),
> поставь self-hosted runner прямо на сервер мониторинга — workflow тот же.

### Если деплой падает с exit code 255

255 — это ошибка `ssh`, а не скрипта. Workflow теперь сам проверяет секреты,
парсит ключ и печатает хвост `ssh -v`, поэтому в логе будет причина:

| Что в логе | Причина |
|---|---|
| `Permission denied (publickey)` | ключ не в `~/.ssh/authorized_keys` у `deploy`, или пользователя нет |
| `Connection refused` | sshd не на 22 порту (задай `SSH_PORT`) или firewall |
| `Host key verification failed` | `SSH_KNOWN_HOSTS` от другого хоста — перегенерируй `ssh-keyscan -H <IP>` |
| `no such identity` / `Load key: invalid format` | `SSH_KEY` пустой, обрезан или это публичный ключ |
| таймаут | с раннера GitHub нет маршрута до сервера — нужен self-hosted runner |
| `detected dubious ownership in repository` | каталог принадлежит не тому пользователю, под которым идёт деплой: `sudo chown -R <SSH_USER>:<SSH_USER> /opt/vps-monitoring` |
| `docker: unknown command: docker compose` | не установлен compose v2 — см. «Требования на сервере» |
| `permission denied ... docker.sock` | `sudo usermod -aG docker deploy` и перелогиниться |

Проверить руками то же самое:

```bash
ssh -v -i ~/.ssh/deploy -p 22 deploy@<IP> 'echo ok'
```

### Правило

На сервере ничего не редактируется руками. Любое изменение: PR → CI → merge →
Deploy. `git reset --hard` в деплое специально затирает локальные правки.

## Полезное

* Диагностика всей цепочки одной командой: `./scripts/diagnose.sh`
* Перечитать конфиг Prometheus без рестарта: `curl -X POST http://127.0.0.1:9090/-/reload`
* Логи: `docker compose logs -f prometheus alertmanager`
* Остановить: `docker compose down` (данные в volumes сохраняются)

## Статус

Сделано: P0 (гигиена стека, закрытые порты, volume, healthcheck, правила, алерты),
интеграция cheburcheck, CI/CD и деплой с откатом.

Дальше по плану: DDNS-метрики, Tailscale-доступ, Ansible-bootstrap.
Дашборды — на владельце, запросы лежат в [docs/PROMQL.md](docs/PROMQL.md).
Подробности — в [PLAN.md](PLAN.md).
