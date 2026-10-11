#!/usr/bin/env bash
# Smoke test del borde por host (HTTPS). Uso: scripts/smoke.sh [puerto] [ip]  (default 8091 127.0.0.1)
# --resolve fuerza SNI y Host reales contra este servidor, sin depender del DNS público.
set -euo pipefail
PORT="${1:-8091}"; IP="${2:-127.0.0.1}"
# INSECURE=1 solo para probar con un certificado autofirmado; en producción el certificado se verifica.
K=""; [[ "${INSECURE:-0}" == 1 ]] && K="-k"
ok=1
check() { # nombre host ruta codigos_esperados(espacio)
  local code; code=$(curl -s $K -o /dev/null -w '%{http_code}' --resolve "$2:$PORT:$IP" "https://$2:$PORT$3" || true)
  if [[ " $4 " == *" $code "* ]]; then echo "OK   $1 ($code)"; else echo "FAIL $1 (got $code, want $4)"; ok=0; fi
}
check "SLC health"            api.sig.systems   /api/v1/health/  "200"
check "SIG-Desk via Kong"     desk.sig.systems  /desk-api/       "200 401 403 404"
check "desk raiz = 404"       desk.sig.systems  /                "404"
check "nexus pagina"          nexus.sig.systems /                "200"
check "nexus API via Kong"    nexus.sig.systems /desk-api/me     "401"
# HTTP plano al puerto TLS → redirección 308 a https
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: api.sig.systems' "http://$IP:$PORT/api/v1/health/" || true)
if [[ "$code" == "308" ]]; then echo "OK   http→https (308)"; else echo "FAIL http→https (got $code, want 308)"; ok=0; fi
[[ $ok == 1 ]]
