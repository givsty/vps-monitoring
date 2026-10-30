SHELL := /bin/bash

.PHONY: check up down logs reload ip

# Проверить .env перед запуском
check:
	./scripts/check-env.sh

# Поднять стек (с проверкой .env)
up: check
	docker compose up -d
	docker compose ps

down:
	docker compose down

logs:
	docker compose logs -f --tail=100

# Перечитать конфиг Prometheus без рестарта
reload:
	curl -fsS -X POST http://127.0.0.1:9090/-/reload
	@echo "prometheus: config reloaded"

# Сменить IP VPN-сервера
ip:
	@read -r -p "Новый IP VPN-сервера: " addr; ./scripts/set-vpn-ip.sh "$$addr"
