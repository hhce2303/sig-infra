#!/usr/bin/env bash
# nginx -t sobre la config completa del borde en un contenedor desechable.
# No requiere que los backends existan (los upstreams se resuelven por petición).
set -euo pipefail
cd "$(dirname "$0")/../edge"
CERTS="$(mktemp -d)"; trap 'rm -rf "$CERTS"' EXIT
docker run --rm \
  -v "$PWD/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$PWD/nginx/conf.d:/etc/nginx/conf.d:ro" \
  -v "$PWD/nginx/snippets:/etc/nginx/snippets:ro" \
  -v "$CERTS:/etc/nginx/certs:ro" \
  nginx:1.27-alpine nginx -t
