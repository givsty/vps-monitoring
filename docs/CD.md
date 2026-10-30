# CD: деплой по кнопке

Инструкция для первого запуска. Рассчитана на то, что сервер уже существует,
на нём стоит Docker с плагином compose, а репозиторий склонирован.

## Как это работает

```
Actions → Deploy → Run workflow
        │
        ▼
GitHub Actions (ubuntu-latest)
        │  ssh deploy@<сервер>
        ▼
/opt/vps-monitoring/scripts/deploy.sh <sha>
        │
        ├─ 1. предполёт: git, docker, compose, доступ к демону
        ├─ 2. git fetch + git reset --hard <sha>   ← сервер = точная копия коммита
        ├─ 3. scripts/check-env.sh                 ← .env заполнен?
        ├─ 4. docker compose pull && up -d
        ├─ 5. scripts/healthcheck.sh               ← prometheus и grafana отвечают?
        └─ 6. если 3–5 упали → git reset --hard <предыдущий> и up -d
```

Ключевая идея: **сервер — расходник**. Всё состояние в git, `.env` живёт на сервере
и не перезаписывается. Откат — это предыдущий коммит, а не «бэкап перед деплоем».

## Шаг 1. Пользователь на сервере

```bash
adduser --disabled-password --gecos "" deploy
usermod -aG docker deploy
```

> После `usermod` нужен новый вход, чтобы группа применилась. GitHub Actions
> открывает новую сессию каждый раз, так что для деплоя это не проблема.

Проверка:

```bash
sudo -u deploy docker info >/dev/null && echo "docker ок"
```

## Шаг 2. Каталог и клон от имени deploy

```bash
install -d -o deploy -g deploy /opt/vps-monitoring
sudo -u deploy git clone https://github.com/givsty/vps-monitoring /opt/vps-monitoring

# .env создаётся один раз и в git не попадает
sudo -u deploy cp /opt/vps-monitoring/.env.example /opt/vps-monitoring/.env
sudo -u deploy nano /opt/vps-monitoring/.env
```

Важно: каталог должен принадлежать `deploy`. Иначе git скажет
`detected dubious ownership` и деплой остановится.

```bash
sudo chown -R deploy:deploy /opt/vps-monitoring
sudo -u deploy git -C /opt/vps-monitoring status --short   # не должно быть fatal
```

## Шаг 3. SSH-ключ для деплоя

На **своём маке**:

```bash
ssh-keygen -t ed25519 -N "" -C "vps-monitoring-deploy" -f ~/.ssh/vps-monitoring-deploy
```

`-N ""` — без пароля: в CI некому его вводить.

Публичный ключ кладём на сервер:

```bash
cat ~/.ssh/vps-monitoring-deploy.pub | ssh root@<IP> '
  install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
  cat >> /home/deploy/.ssh/authorized_keys
  chown deploy:deploy /home/deploy/.ssh/authorized_keys
  chmod 600 /home/deploy/.ssh/authorized_keys
'
```

Проверяем, что заходит без пароля:

```bash
ssh -i ~/.ssh/vps-monitoring-deploy deploy@<IP> 'echo ok'
```

## Шаг 4. Секреты в GitHub

Settings → Secrets and variables → Actions → **New repository secret**:

| Имя | Что вставлять |
|---|---|
| `SSH_HOST` | IP сервера |
| `SSH_USER` | `deploy` |
| `SSH_KEY` | **весь** файл `~/.ssh/vps-monitoring-deploy`, включая строки `-----BEGIN/END OPENSSH PRIVATE KEY-----` |
| `SSH_KNOWN_HOSTS` | вывод `ssh-keyscan -H <IP> 2>/dev/null` |
| `SSH_PORT` | только если SSH не на 22 |

> Вкладка важна: **Secrets**, а не **Variables**. В Variables значения тоже
> хранятся, но workflow читает их через `vars.*`, а у нас `secrets.*` — с переменными
> шаг «Проверить секреты» упадёт с «не задан».
>
> Имена — ровно `SSH_HOST`, `SSH_USER`, `SSH_KEY`, `SSH_KNOWN_HOSTS` (заглавные,
> без пробелов и дефисов).

Посмотреть приватный ключ, чтобы скопировать целиком:

```bash
cat ~/.ssh/vps-monitoring-deploy
```

`SSH_KNOWN_HOSTS` генерируется так:

```bash
ssh-keyscan -H <IP> 2>/dev/null
# если порт не 22:
ssh-keyscan -p <PORT> -H <IP> 2>/dev/null
```

Опционально, вкладка **Variables** → `DEPLOY_PATH` = `/opt/vps-monitoring`
(по умолчанию и так он).

Environment `production` создастся сам при первом запуске. Если хочешь,
чтобы деплой ждал твоего подтверждения: Settings → Environments → `production`
→ Required reviewers.

## Шаг 5. Первый запуск

1. Убедись, что коммит **запушен** — сервер умеет брать только то, что есть на GitHub.
2. Actions → **Deploy** → Run workflow → ref: `main` → Run.

Что должно быть в логе:

```
✓ Проверить секреты        ok: секреты на месте, ключ выглядит целым
✓ Настроить SSH            ok: приватный ключ читается
✓ Проверить SSH-соединение ok: SSH работает
✓ Деплой                   ==> <старый sha> -> <новый sha>
                           ==> проверка .env
                           ==> обновление образов
                           ==> запуск
                           ==> healthcheck
                           ✓ prometheus
                           ✓ grafana
                           ✓ задеплоено: <sha>
```

## Как откатиться

Actions → Deploy → Run workflow → в поле `ref` вставь SHA предыдущего коммита.
Сервер сделает `git reset --hard <этот sha>` и поднимет контейнеры.

Автоматический откат тоже есть: если после `up -d` не прошёл healthcheck,
`deploy.sh` сам вернёт предыдущий коммит и попробует поднять его.

## Частые ошибки

| В логе | Что делать |
|---|---|
| `Permission denied (publickey)` | ключ не в `authorized_keys` у `deploy`, или пользователя нет |
| `Connection refused` | sshd на другом порту → секрет `SSH_PORT` |
| `Host key verification failed` | `SSH_KNOWN_HOSTS` от другого хоста — перегенерируй `ssh-keyscan` |
| `no such identity` / `invalid format` | `SSH_KEY` пустой, обрезан или это публичный ключ |
| `detected dubious ownership` | `sudo chown -R deploy:deploy /opt/vps-monitoring` |
| `docker compose v2 не найден` | `apt install docker-compose-plugin` или `docker-compose-v2` |
| `нет доступа к docker daemon` | `usermod -aG docker deploy` и новая сессия |
| `fatal: couldn't find remote ref` | коммит не запушен в GitHub |
| `check-env: не заполнено ...` | поправь `.env` на сервере |

## Хочешь автодеплой на push

Сейчас деплой только ручной — это осознанно. Если захочешь автоматически:

```yaml
on:
  push:
    branches: [main]
  workflow_dispatch: { inputs: { ref: { default: main } } }
```

Но тогда любой merge в main сразу уезжает в прод. Для соло-проекта с одним
сервером я бы оставил ручную кнопку.
