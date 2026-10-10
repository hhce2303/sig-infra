#!/usr/bin/env bash
# Smoke test del borde por host. Uso: scripts/smoke.sh [base_url]  (default http://localhost:8091)
set -euo pipefail
BASE="${1:-http://localhost:8091}"
ok=1
check() { # nombre host ruta codigos_esperados(espacio)
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $2" "$BASE$3" || true)
  if [[ " $4 " == *" $code "* ]]; then echo "OK   $1 ($code)"; else echo "FAIL $1 (got $code, want $4)"; ok=0; fi
}
check "SLC health"        api.sig.systems  /api/v1/health/  "200"
check "SIG-Desk via Kong" desk.sig.systems /desk-api/       "200 401 403 404"
check "desk raiz = 404"   desk.sig.systems /                "404"
[[ $ok == 1 ]]
