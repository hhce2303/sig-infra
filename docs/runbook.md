# Runbook del borde

## Requisitos previos al corte (aplicados el 2026-10-10)

1. **SLC web en `sig-edge` con alias `slc-web`.** En SLC-SIG_platform, el servicio `web` debe unirse a la red externa `sig-edge` con `aliases: [slc-web]` (overlay propio, p. ej. `docker-compose.edge.yml`). Sin esto el borde responde 502 en `api.`.
2. **Volumen de media.** Confirmar el nombre real (`docker volume ls | grep media_data`) y ponerlo en `edge/.env` (`SLC_MEDIA_VOLUME`).
3. **Kong** sigue uniéndose a `sig-edge` como `sigdesk-kong` (`SIG-Desk-Backend/compose.edge.yaml`).
4. **Django detrás del proxy:** `TRUST_PROXY_HEADERS=true` en SLC solo cuando el borde termine TLS (Fase 3).
5. Certificados manuales (si aplica) en `edge/certs/`; nunca en git.

## Corte (un host a la vez, ventana corta)

1. `make network && cd edge && docker compose config -q` y `make check`.
2. En el servidor, parar el nginx de SLC: `docker compose -f docker/docker-compose.yml stop nginx` (libera el puerto 8091).
3. `make up` en `sig-infra`.
4. `make smoke`. Verificar además: `/media/` de un plano indoor, un stream SSE de `/api/`, login de SIG-Desk (`/desk-api/`).
5. Observar una semana antes de borrar el nginx de SLC (Fase 2 → cierre).

## Rollback

1. `cd edge && docker compose down`.
2. En SLC: `docker compose -f docker/docker-compose.yml up -d nginx` (con los mismos overlays de antes).
3. `curl -I http://localhost:8091/api/v1/health/` para confirmar.

Tiempo esperado: menos de un minuto; el nginx de SLC no se borra hasta cerrar la observación.

## Operación

- Cambiar un vhost: PR → `make check` en CI → merge → en el servidor `git pull && make reload`.
- Si `nginx -t` falla en `make reload`, nginx sigue con la config anterior (no hay corte).
- Certificados manuales: reemplazar archivos en `edge/certs/` y `make reload`.

## Fase 3 — 8091 pasa a HTTPS (+ nexus.sig.systems)

Cambio con impacto: todo cliente que use `http://…:8091` recibe un 308 a `https://`. Los navegadores lo
siguen solos; los clientes de API que no siguen redirecciones deben cambiar su URL. Los que entran **por IP**
(`https://192.168.1.69:8091`) verán un aviso de certificado (el wildcard solo cubre `*.sig.systems`).

Previo:
1. Certificado en `edge/certs/sig_systems_cert.pem` (cert + intermedios) y `edge/certs/sig_systems_key.pem`.
   Verificar: `openssl x509 -in edge/certs/sig_systems_cert.pem -noout -subject -enddate` y que cert y clave coincidan.
2. `make check` en verde.

Corte (ventana corta, solo afecta a `sig-edge-nginx`):
1. `cd edge && docker compose up -d` (recrea el contenedor con el puerto 8091→443 y el mount de `sites/`).
2. `make smoke` (ya en HTTPS; verifica el certificado real).

Después, en SLC (su propio PR y ventana): `TRUST_PROXY_HEADERS=true` y añadir los orígenes `https://…:8091`
a `CSRF_TRUSTED_ORIGINS`, para que Django reconozca las peticiones como HTTPS.

Rollback: `git checkout <commit anterior> -- edge scripts && cd edge && docker compose up -d` (vuelve a HTTP en el 8091).
