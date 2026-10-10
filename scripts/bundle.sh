#!/usr/bin/env bash
# Empaqueta TODOS los compose (borde + SLC + SIG-Desk) en un solo .tar para copiarlo
# al servidor sin clonar los repos. Usa `git archive` de cada repo (solo lo commiteado:
# sin .env, certificados ni claves). Uso: scripts/bundle.sh  → dist/sig-infra-<version>.tar
#
#   SLC_REPO     (default ../SLC-SIG_platform)
#   SIGDESK_REPO (default ../SIG-Desk/SIG-Desk-Backend)
set -euo pipefail
cd "$(dirname "$0")/.."
INFRA="$PWD"
SLC_REPO="$(cd "${SLC_REPO:-../SLC-SIG_platform}" && pwd)"
SIGDESK_REPO="$(cd "${SIGDESK_REPO:-../SIG-Desk/SIG-Desk-Backend}" && pwd)"

VERSION="$(git describe --tags --always --dirty=-wip)"
NAME="sig-infra-${VERSION}"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$NAME" dist

sha() { printf '%s%s' "$(git -C "$1" rev-parse --short HEAD)" "$([[ -n "$(git -C "$1" status --porcelain)" ]] && echo ' (con cambios sin commitear: NO incluidos)')"; }

# 1) borde (este repo)
git archive --format=tar HEAD edge scripts Makefile README.md docs/runbook.md | tar -x -C "$STAGE/$NAME"

# 2) SLC-SIG_platform: conserva la disposición docker/ (los compose usan ../.env y ./nginx.conf)
mkdir -p "$STAGE/$NAME/slc"
git -C "$SLC_REPO" archive --format=tar HEAD \
  .env.example docker/docker-compose.yml docker/docker-compose.override.yml \
  docker/docker-compose.local.yml docker/docker-compose.dev.yml docker/docker-compose.ssl.yml \
  docker/docker-compose.sigdesk.yml docker/nginx.conf docker/init-db docker/Dockerfile \
  docker/entrypoint.sh | tar -x -C "$STAGE/$NAME/slc"

# 3) SIG-Desk-Backend
mkdir -p "$STAGE/$NAME/sigdesk"
git -C "$SIGDESK_REPO" archive --format=tar HEAD \
  compose.yaml compose.override.yaml compose.edge.yaml kong.yml .env.example \
  scripts/init-multiple-dbs.sh | tar -x -C "$STAGE/$NAME/sigdesk"

cat > "$STAGE/$NAME/MANIFEST.txt" <<EOM
sig-infra:  $(sha "$INFRA")
slc:        $(sha "$SLC_REPO") ($(git -C "$SLC_REPO" branch --show-current))
sigdesk:    $(sha "$SIGDESK_REPO") ($(git -C "$SIGDESK_REPO" branch --show-current))
generado:   $(date -Iseconds)
EOM

cat > "$STAGE/$NAME/BUNDLE.md" <<'EOM'
# Bundle de despliegue SIG

Contiene SOLO los archivos de compose y lo que montan (configs, init de BD). No contiene
código fuente, `.env`, certificados ni claves: se colocan a mano en el servidor.

| Carpeta | Qué es | Archivos que debes crear |
|---|---|---|
| `edge/` | Borde nginx compartido (`make up`) | `edge/.env` (de `.env.example`), certs en `edge/certs/` |
| `slc/` | SLC-SIG_platform (`docker/docker-compose*.yml`) | `slc/.env` (de `.env.example`), `slc/docker/certs/` si usas ssl |
| `sigdesk/` | SIG-Desk-Backend (`compose*.yaml`, `kong.yml`) | `sigdesk/.env` (de `.env.example`) |

## Limitaciones: servicios con `build:`

Estos servicios se CONSTRUYEN desde código fuente, que no viaja en el .tar. Sin el repo,
`docker compose up` falla en ellos salvo que lleves la imagen ya construida
(`docker save` / `docker load`, o un registry) y la referencies con `image:`:

- SLC: `web` y `poller` (`slc/docker/Dockerfile`, contexto = repo completo).
- SIG-Desk: `rag_service` (x2), `knowledge_service`, `ai_advisor_service` y, por el override, `cli_gateway`.
- Los microservicios Go de SIG-Desk (organization, resource, tickets, workflow, notification,
  change, problem) NO están en compose: hoy corren como procesos de host (`go run .`).

Lo que sí levanta sin código fuente: infraestructura con imágenes públicas (Postgres, Kafka, Kong, etc.).

## Orden sugerido

1. `cd edge && cp .env.example .env` y `make -C .. network` (crea `sig-edge`).
2. Backends con sus compose (SLC con `-f docker/docker-compose.yml -f docker/docker-compose.sigdesk.yml`).
3. `make up` (borde). El corte desde el nginx de SLC está en `docs/runbook.md`.
EOM

tar -cf "dist/${NAME}.tar" -C "$STAGE" "$NAME"
echo "dist/${NAME}.tar"
