# Servicios Go de SIG-Desk en el MKS (opción B: procesos del host)

Los 4 servicios HTTP de SIG-Desk corren como **servicios de Windows (NSSM)**, detrás de Kong
(contenedor), que a su vez está detrás del borde (`sig-edge-nginx`). Es una solución transitoria hasta
que cada servicio tenga Dockerfile; ver `SIG-Desk-Backend/kong.yml` (cabecera).

```
cliente ► sig-edge-nginx:8091 ► sigdesk-kong:8000 (Docker) ► host.docker.internal:1808x ► SIGDesk-<servicio> (Windows)
```

| Servicio de Windows | Binario | Puerto (solo 127.0.0.1) |
|---|---|---|
| `SIGDesk-tickets` | `tickets_service.exe` | 18080 |
| `SIGDesk-organization` | `organization_service.exe` | 18081 |
| `SIGDesk-resource` | `resource_service.exe` | 18082 |
| `SIGDesk-workflow` | `workflow_service.exe` | 18083 |

**Por qué 1808x y no 8080–8083:** en el MKS el 8080 lo usa ManageEngine ServiceDesk (java) y el 8082
Apache (xampp). Kong apunta a estos puertos mediante `SIG-Desk-Backend/kong.prod.yml`.

## Garantías (el MKS aloja otros servicios que no se deben tocar)

- `sigdesk-services.ps1` solo opera sobre servicios `SIGDesk-*` cuyo `ImagePath` sea
  `C:\SIG\SIGDesk\bin\nssm.exe`. Cualquier otro nombre se rechaza (`BLOQUEADO`), nunca se detiene ni se modifica.
- **No toca el firewall.** Los servicios escuchan en `127.0.0.1` (`LISTEN_HOST`); Docker Desktop alcanza el
  host por loopback, la LAN no.
- Sin `-Apply` todo es un **dry-run**. `preflight` y `status` son siempre de solo lectura.
- Reutiliza el `nssm.exe` que ya existe (`C:\Program Files\SIGCircuitCheck\nssm.exe`) **copiándolo**; no se descarga
  nada y no se modifica el original ni los servicios `SIG*` existentes.
- Los binarios se verifican contra `SHA256SUMS` antes de instalar o actualizar.

## Estructura en el servidor

```
C:\SIG\SIGDesk\
  bin\nssm.exe        copia de NSSM
  current\            binarios en uso
  releases\<fecha>\   backup previo a cada update (para rollback)
  config\<svc>.env    secretos (ACL: solo SYSTEM y Administradores) — fuera de git
  logs\<svc>.out|err.log   con rotación a 10 MB
```

## Puesta en marcha

Todo desde `sig-infra\orchestration\sigdesk`. Pasos 5–6 en PowerShell **como Administrador**.

1. **Secretos de los servicios:** copiar `env\*.env.example` a `C:\SIG\SIGDesk\config\<svc>.env` y reemplazar todo
   `CAMBIAR_*`. `JWT_SECRET` ≥ 32 caracteres e **igual** en organization, resource y tickets. Si la
   contraseña de Postgres tiene caracteres especiales, va codificada como URL en `DATABASE_URL`.
2. **Infraestructura de SIG-Desk (Docker)**, desde `SIG-Desk-Backend` con `POSTGRES_PASSWORD` y
   `TICKETS_INTERNAL_SECRET` en su `.env`:
   `docker compose -f compose.yaml -f compose.prod.yaml -f compose.edge.yaml up -d postgres kafka temporal kong`
   (no levanta el frontend; `tei`/`rag_*` descargan ~2,3 GB y se activan aparte).
3. **Binarios:** `gh release download vX.Y.Z --repo hhce2303/SIG-Desk-Backend --dir C:\SIG\SIGDesk\incoming`
4. **Revisar sin cambiar nada:**
   `.\sigdesk-services.ps1 -Action preflight` y `.\sigdesk-services.ps1 -Action install -Source C:\SIG\SIGDesk\incoming`
5. **Instalar:** `.\sigdesk-services.ps1 -Action install -Source C:\SIG\SIGDesk\incoming -Apply`
6. **Arrancar** (los servicios salen con error si Postgres/Kafka no están; NSSM reintenta cada 10 s):
   `Start-Service SIGDesk-organization,SIGDesk-resource,SIGDesk-tickets,SIGDesk-workflow`
7. **Verificar:** `.\sigdesk-services.ps1 -Action status` y `make smoke` en `sig-infra`
   (`/desk-api/` ya no debe dar 502).

## Operación

| Qué | Comando |
|---|---|
| Actualizar a un release | `.\sigdesk-services.ps1 -Action update -Tag vX.Y.Z -Apply` (uno a uno; si falla, revierte ese servicio y se detiene) |
| Volver al release anterior | `.\sigdesk-services.ps1 -Action rollback -Apply` |
| Estado | `.\sigdesk-services.ps1 -Action status` |
| Quitar SOLO estos servicios | `.\sigdesk-services.ps1 -Action uninstall -Apply` (no borra logs, config ni binarios) |

Los servicios inician con **inicio automático retardado**, para dar tiempo a Docker Desktop. Docker Desktop
debe arrancar con el equipo, y debe haber `restart: unless-stopped` (ya en `compose.prod.yaml`).

## Límites conocidos

- No hay endpoint de salud en los servicios: el chequeo de `update` es "el puerto acepta conexión y el proceso
  sigue vivo 8 s".
- Los secretos viven en el registro del servicio (clave restringida a SYSTEM, Administradores y LocalService) y en
  `config\`; el gestor de secretos definitivo sigue pendiente (ADR-0013).
- `notification_service` y `audit_service` no se despliegan todavía.
