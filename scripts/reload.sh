#!/usr/bin/env bash
# Recarga sin cortar tráfico: valida primero; si la config es inválida, nginx sigue con la anterior.
set -euo pipefail
cd "$(dirname "$0")/../edge"
docker compose exec -T nginx nginx -t
docker compose exec -T nginx nginx -s reload
echo "reload OK"
