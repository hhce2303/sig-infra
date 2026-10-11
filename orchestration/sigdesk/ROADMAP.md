# ROADMAP — SIG-Desk en producción (MKS)

Metas y restricciones: [GOALS.md](GOALS.md). Operación de los servicios: [README.md](README.md).

**Regla:** cada fase termina en un **punto de revisión**. Héctor Cruz la revisa y aprueba antes de iniciar la
siguiente. Ninguna fase detiene, reinicia ni reconfigura servicios existentes del servidor.

Orden: **Fase 1 (Docker) → Fase 2 (.exe ↔ Docker) → Fase 3 (PostgreSQL nativo)**. Las fases 1 y 2 usan
temporalmente el Postgres en contenedor que ya define `compose.prod.yaml`; la Fase 3 lo reemplaza.

---

## Fase 1 — Levantar el stack Docker de SIG-Desk  (meta G2)

| # | Tarea | Riesgo para otros servicios |
|---|---|---|
| 1.1 | Preflight de solo lectura: puertos 9092, 7233 y 5432 libres en `127.0.0.1`, red `sig-edge` presente, espacio en disco. | Ninguno |
| 1.2 | `.env` de producción en `SIG-Desk-Backend` (fuera de git): `POSTGRES_PASSWORD`, `TICKETS_INTERNAL_SECRET`. Los pone Héctor. | Ninguno |
| 1.3 | `docker compose -f compose.yaml -f compose.prod.yaml -f compose.edge.yaml config` y revisión del merge. | Ninguno |
| 1.4 | `up -d postgres kafka temporal kong` (sin frontend, TEI ni RAG). | Bajo: contenedores nuevos, proyecto compose propio |
| 1.5 | Verificar: contenedores *healthy*, Kong en `sig-edge` como `sigdesk-kong`, ningún puerto en `0.0.0.0` (`docker ps`, `netstat`). `make smoke` en sig-infra: `desk-api` pasa de "no resuelve" a 502 de upstream. | Ninguno |
| 1.6 | Reinicio controlado de **solo** los contenedores SIG-Desk para comprobar `restart: unless-stopped`. | Ninguno |

**Entregables:** stack corriendo, salida de la verificación, nota de rollback (`docker compose ... down`, sin `-v`).

> 🔍 **Punto de revisión 1:** revisar el merge de compose, los puertos publicados y que el stack de SLC y
> `sig-edge-nginx` sigan intactos.

---

## Fase 2 — Comunicación de los .exe con Docker  (meta G1)

| # | Tarea | Riesgo |
|---|---|---|
| 2.1 | Publicar commits y etiquetar `v0.1.0`. El CI (`release-windows.yml`) genera los .exe y `SHA256SUMS`. | Ninguno |
| 2.2 | `C:\SIG\SIGDesk\config\*.env` con secretos reales (Héctor). `DATABASE_URL` apunta al Postgres de la Fase 1. | Ninguno |
| 2.3 | `sigdesk-services.ps1 -Action preflight` e `install` en **dry-run**, y revisión del plan. | Ninguno |
| 2.4 | `install -Apply` con PowerShell de administrador, con Héctor presente. Solo crea servicios `SIGDesk-*`. | Bajo: servicios nuevos; no se toca ninguno existente |
| 2.5 | Arrancar en orden: organization, resource, tickets, workflow. | Ninguno |
| 2.6 | Pruebas de comunicación: Kong → `host.docker.internal:1808x` (loopback); .exe → Kafka `127.0.0.1:9092` y Temporal `127.0.0.1:7233`; desde otra máquina de la LAN, 18080–18083 **no** responden. | Ninguno |
| 2.7 | Prueba de punta a punta: `desk.sig.systems:8091/desk-api/me` responde desde organization_service (401 sin token y 200 con token). `make smoke` en verde. | Ninguno |
| 2.8 | Ensayo de `update` y `rollback` con el mismo release. | Ninguno |
| 2.9 | Reinicio del servidor en ventana acordada: todo vuelve solo (Docker Desktop → contenedores → servicios de inicio retardado). | **Medio:** reinicia el servidor completo. Solo con aprobación y ventana explícitas. |

**Entregables:** servicios `SIGDesk-*` en ejecución, evidencia de cada prueba, procedimiento de update/rollback probado.

> 🔍 **Punto de revisión 2:** validar el flujo completo `desk-api`, el aislamiento de la LAN y que los
> servicios ajenos (`Get-Service`) siguen como estaban.

---

## Fase 3 — PostgreSQL hosteado en el servidor  (meta G3)

| # | Tarea | Riesgo |
|---|---|---|
| 3.1 | **Inventario de solo lectura** del PostgreSQL nativo que ya corre en el MKS: versión, puerto, quién lo usa y si es el mismo que usa Django/SLC. | Ninguno |
| 3.2 | **Decisión (Héctor):** (a) una instancia **nueva** y dedicada de PostgreSQL 16 como servicio Windows `SIGDesk-postgres` en otro puerto, o (b) bases y rol nuevos en la instancia existente. La (b) **toca un servicio en marcha** (no lo detiene, pero sí cambia su contenido y quizá `pg_hba.conf`/reload). La recomendada es la (a), que cumple la restricción 1 sin excepciones. | Depende de la decisión |
| 3.3 | Instalar o crear: rol `sigdesk` con contraseña fuerte, una base por servicio (`sigdesk_<svc>`, ADR-0002), escucha solo en `127.0.0.1`. | Bajo con (a) |
| 3.4 | Migrar datos del Postgres en contenedor: `pg_dump` de cada base, `pg_restore` en el nativo y verificar conteos. Ventana corta con los servicios `SIGDesk-*` detenidos (solo esos). | Bajo |
| 3.5 | Cambiar `DATABASE_URL` en `config\*.env`, reinstalar el entorno de los servicios y arrancar. Retirar `postgres` de `compose.prod.yaml` (sin borrar su volumen hasta cerrar la observación). | Bajo |
| 3.6 | **Acceso de Django (SLC):** rol de solo lectura `sigdesk_django` por defecto. Si Django debe *gestionar* datos, usar modelos `managed = False` sobre las tablas existentes: el esquema lo siguen aplicando los servicios Go (`AplicarEsquema`), nunca las migraciones de Django. Conexión desde el contenedor `web` de SLC vía `host.docker.internal`. | Bajo: cambio en SLC por PR, desplegado en su propia ventana |
| 3.7 | Backups: `pg_dump` diario programado (tarea `SIGDesk-backup`), retención y prueba de restauración. | Ninguno |

**Entregables:** PostgreSQL nativo con las bases de SIG-Desk, datos migrados y verificados, acceso de Django
documentado y backups probados.

> 🔍 **Punto de revisión 3:** aprobar la decisión 3.2 **antes** de ejecutar 3.3; revisar la migración, los permisos
> del rol de Django y la restauración de backup.

---

## Rollback por fase

| Fase | Cómo volver atrás |
|---|---|
| 1 | `docker compose -f compose.yaml -f compose.prod.yaml -f compose.edge.yaml down` (sin `-v`) |
| 2 | `sigdesk-services.ps1 -Action uninstall -Apply`; Kong vuelve a dar 502 |
| 3 | Restaurar `DATABASE_URL` al Postgres en contenedor (volumen conservado) y reiniciar solo `SIGDesk-*` |
