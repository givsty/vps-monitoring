#!/usr/bin/env bash
# Деплой на сервере. Вызывается из GitHub Actions по SSH:
#   ssh deploy@host 'cd /opt/vps-monitoring && ./scripts/deploy.sh <sha>'
#
# Схема: сервер — чистая копия репозитория, любые правки только через git.
# Предыдущий коммит запоминается, при любой ошибке — откат на него.
set -euo pipefail

SHA="${1:-}"
if [[ ! "$SHA" =~ ^[0-9a-f]{7,40}$ ]]; then
  echo "usage: $0 <git-sha>" >&2
  exit 1
fi

cd "${DEPLOY_DIR:-/opt/vps-monitoring}"

# --- предполётная проверка -----------------------------------------------
# Почти все падения деплоя случаются здесь, поэтому проверяем заранее
# и пишем, что именно чинить.

if ! command -v git >/dev/null 2>&1; then
  echo "✗ git не установлен" >&2
  exit 1
fi

# git отказывается работать, если владелец каталога не совпадает с текущим
# пользователем: "fatal: detected dubious ownership".
GIT_ERR="$(git rev-parse --show-toplevel 2>&1)" || {
  echo "✗ git не может работать с каталогом $PWD" >&2
  echo "  $GIT_ERR" >&2
  echo >&2
  echo "  Обычно помогает вернуть владение деплой-пользователю:" >&2
  echo "    sudo chown -R $(id -un):$(id -gn) $PWD" >&2
  exit 1
}

if ! command -v docker >/dev/null 2>&1; then
  echo "✗ docker не установлен" >&2
  exit 1
fi

# Compose v2 — это плагин `docker compose`, а не старый `docker-compose`.
if ! docker compose version >/dev/null 2>&1; then
  echo "✗ docker compose v2 не найден" >&2
  echo "  Установка:" >&2
  echo "    sudo apt-get install -y docker-compose-plugin   # Docker CE repo" >&2
  echo "    sudo apt-get install -y docker-compose-v2       # Ubuntu repo" >&2
  echo "  Или вручную:" >&2
  echo "    sudo mkdir -p /usr/local/lib/docker/cli-plugins" >&2
  echo "    sudo curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \\" >&2
  echo "      -o /usr/local/lib/docker/cli-plugins/docker-compose" >&2
  echo "    sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "✗ нет доступа к docker daemon" >&2
  echo "  Пользователь $(id -un) должен быть в группе docker:" >&2
  echo "    sudo usermod -aG docker $(id -un)   # и перелогиниться" >&2
  exit 1
fi
# -------------------------------------------------------------------------

git fetch --prune origin

PREV="$(git rev-parse HEAD)"
if [[ "$PREV" == "$SHA" || "${PREV:0:${#SHA}}" == "$SHA" ]]; then
  echo "уже на $SHA, деплой не нужен"
  exit 0
fi

rollback() {
  set +e
  echo "✗ деплой не удался, откат на $PREV" >&2
  git reset --hard "$PREV"
  docker compose up -d --remove-orphans
  ./scripts/healthcheck.sh || true
  exit 1
}

echo "==> $PREV -> $SHA"
git reset --hard "$SHA"

echo "==> проверка .env"
./scripts/check-env.sh || rollback

echo "==> обновление образов"
docker compose pull -q || rollback

echo "==> запуск"
docker compose up -d --remove-orphans || rollback

echo "==> healthcheck"
./scripts/healthcheck.sh || rollback

echo "✓ задеплоено: $SHA"
