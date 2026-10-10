.PHONY: network up down reload check smoke
network: ## Crea la red compartida sig-edge (idempotente)
	@docker network inspect sig-edge >/dev/null 2>&1 || docker network create sig-edge
up: network ## Levanta el borde
	cd edge && docker compose up -d
down: ## Baja el borde
	cd edge && docker compose down
reload: ## Valida y recarga nginx sin cortar tráfico
	./scripts/reload.sh
check: ## nginx -t con la config completa
	./scripts/check.sh
smoke: ## Smoke test por host
	./scripts/smoke.sh
