#!/usr/bin/env bash
# Publica un build de SIGNexus (carpeta con index.html, p. ej. el dist/ de Vite) en
# nexus.sig.systems, servido por el borde desde edge/sites/nexus/.
#
#   scripts/deploy-nexus.sh <carpeta_build>   publica (cambio atómico por rename)
#   scripts/deploy-nexus.sh --rollback        vuelve al build anterior (nexus.prev)
#
# No recarga nginx: los archivos estáticos se leen en cada petición. La versión anterior
# queda en edge/sites/nexus.prev/ para el rollback.
set -euo pipefail
SITES="$(cd "$(dirname "$0")/../edge/sites" && pwd)"
LIVE="$SITES/nexus"; PREV="$SITES/nexus.prev"; NEW="$SITES/nexus.new"

if [[ "${1:-}" == "--rollback" ]]; then
  [[ -f "$PREV/index.html" ]] || { echo "No hay build anterior en $PREV"; exit 1; }
  rm -rf "$NEW"; mv "$LIVE" "$NEW"; mv "$PREV" "$LIVE"; mv "$NEW" "$PREV"
  echo "Rollback hecho (el build que estaba publicado quedó en nexus.prev)."; exit 0
fi

SRC="${1:?uso: deploy-nexus.sh <carpeta_build> | --rollback}"
[[ -f "$SRC/index.html" ]] || { echo "$SRC no parece un build (falta index.html)"; exit 1; }

rm -rf "$NEW"; cp -r "$SRC" "$NEW"
rm -rf "$PREV"
[[ -d "$LIVE" ]] && mv "$LIVE" "$PREV"
mv "$NEW" "$LIVE"
echo "Publicado $(cat "$LIVE/.version" 2>/dev/null || echo '(sin .version)') en nexus.sig.systems."
