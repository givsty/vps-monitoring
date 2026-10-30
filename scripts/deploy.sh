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
