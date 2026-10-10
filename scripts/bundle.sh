#!/usr/bin/env bash
# Empaqueta el borde en un .tar para copiarlo al servidor sin clonar el repo.
# Usa `git archive`: solo contenido COMMITEADO (sin .env, certs ni dist/).
# Uso: scripts/bundle.sh   → dist/sig-infra-<version>.tar
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "$(git status --porcelain -- edge scripts Makefile README.md docs)" ]]; then
  echo "AVISO: hay cambios sin commitear; el .tar solo incluye lo commiteado." >&2
fi
VERSION="$(git describe --tags --always --dirty=-wip)"
NAME="sig-infra-${VERSION}"
mkdir -p dist
git archive --format=tar --prefix="${NAME}/" -o "dist/${NAME}.tar" HEAD \
  edge scripts Makefile README.md docs/runbook.md
echo "dist/${NAME}.tar"
echo "Servidor:  tar xf ${NAME}.tar && cd ${NAME} && cp edge/.env.example edge/.env && make up"
