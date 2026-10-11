#!/usr/bin/env bash
# nginx -t sobre la config completa del borde en un contenedor desechable.
# No requiere que los backends existan (los upstreams se resuelven por petición).
# Usa un certificado autofirmado temporal con los mismos nombres de archivo que el real
# (edge/certs/ no está en git), así CI y cualquier máquina pueden validar la config.
set -euo pipefail
cd "$(dirname "$0")/../edge"
CERTS="$(mktemp -d)"; trap 'rm -rf "$CERTS"' EXIT
MSYS_NO_PATHCONV=1 docker run --rm -v "$CERTS:/c" alpine/openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
  -subj "/CN=*.sig.systems" -keyout /c/sig.systems.key -out /c/sig.systems.crt >/dev/null 2>&1
docker run --rm \
  -v "$PWD/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$PWD/nginx/conf.d:/etc/nginx/conf.d:ro" \
  -v "$PWD/nginx/snippets:/etc/nginx/snippets:ro" \
  -v "$CERTS:/etc/nginx/certs:ro" \
  nginx:1.27-alpine nginx -t
