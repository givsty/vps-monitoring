#!/bin/sh
# Grafana не умеет подставлять секреты в contact points без потери типа
# (chat_id становится числом), поэтому рендерим provisioning сами.
set -eu

: "${ALERT_EMAIL_TO:?ALERT_EMAIL_TO is not set}"
: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is not set}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID is not set}"

src=/etc/grafana/provisioning
dst=/tmp/provisioning

rm -rf "$dst"
mkdir -p "$dst"
cp -a "$src"/. "$dst"/

esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

find "$dst" -type f \( -name '*.yml' -o -name '*.yaml' \) -exec sed -i \
  -e "s|__ALERT_EMAIL_TO__|$(esc "$ALERT_EMAIL_TO")|g" \
  -e "s|__TELEGRAM_BOT_TOKEN__|$(esc "$TELEGRAM_BOT_TOKEN")|g" \
  -e "s|__TELEGRAM_CHAT_ID__|$(esc "$TELEGRAM_CHAT_ID")|g" \
  {} +

exec /run.sh
