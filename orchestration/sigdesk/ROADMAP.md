# ROADMAP — SIG-Desk en producción (MKS)

Metas y restricciones: [GOALS.md](GOALS.md). Operación de los servicios: [README.md](README.md).

**Regla:** cada fase termina en un **punto de revisión**. Héctor Cruz la revisa y aprueba antes de iniciar la
siguiente. Ninguna fase detiene, reinicia ni reconfigura servicios existentes del servidor.

Orden: **Fase 1 (Docker) → Fase 2 (.exe ↔ Docker) → Fase 3 (PostgreSQL nativo) → Fase 4 (RAG sobre
pgvector nativo)**. Las fases 1 y 2 usan temporalmente el Postgres en contenedor que ya define
`compose.prod.yaml`; la Fase 3 lo reemplaza. La Fase 4 necesita la instancia nativa de la Fase 3.

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
| 3.1 | **Inventario de solo lectura** del PostgreSQL nativo que ya corre en el MKS: versión, puerto, quién lo usa y si es el mismo que usa Django/SLC. **Hallazgo 2026-10-14:** el único Postgres nativo escucha en `127.0.0.1:65432` y es el **embebido de ManageEngine ServiceDesk Plus** (servicio `servicedesk`, `wrapper.exe` → `java`); su único cliente es ese `java`. SIG-Desk hoy usa el contenedor `sig-desk-backend-postgres-1` (`127.0.0.1:5432`, volumen `sig-desk-backend_postgres_data`). Falta la versión (la carpeta de ManageEngine exige administrador). | Ninguno |
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

## Fase 4 — RAG sobre pgvector nativo  (fuera de GOALS.md hasta que se apruebe)

**Decisión 2026-10-14 (Héctor Cruz):** el índice de `rag_service` vive en la instancia **nativa** de la Fase 3,
con la extensión pgvector instalada, y no en el contenedor `postgres_rag`. `rag_indexador`, `rag_buscador`,
`tei` y `tei_reranker` siguen en Docker. Base `sigdesk_rag` con rol propio `rag_app` (ADR-0002); el mismo SQL de
aprovisionamiento ya existe en `SIG-Desk-Backend/deploy/prod/postgres/init-prod-rag.sh`.

| # | Tarea | Riesgo |
|---|---|---|
| 4.1 | Preflight de solo lectura: disco para las imágenes y los pesos de TEI (BGE-M3 ~2,3 GB + reranker), RAM y CPU libres (TEI corre en CPU), versión exacta del PostgreSQL 16 nativo (`SELECT version()`). | Ninguno |
| 4.2 | **Compilar pgvector `v0.8.0` fuera del servidor** (equipo de desarrollo o CI con Visual Studio Build Tools; el MKS no las tiene y no conviene instalarlas en prod): `x64 Native Tools Command Prompt` → `set "PGROOT=<ruta del PG16>"` → `nmake /F Makefile.win`. El binario tiene que ser del mismo **major (16) y x64** que la instancia. Guardar `vector.dll`, `vector.control` y `vector--*.sql` con su `SHA256SUMS`. | Ninguno |
| 4.3 | Instalar en la instancia `SIGDesk-postgres`: `vector.dll` → `lib\`, `vector.control` + `vector--*.sql` → `share\extension\`. **No requiere reiniciar** (pgvector no usa `shared_preload_libraries`). | Bajo: archivos nuevos, nada que reiniciar |
| 4.4 | Como superusuario: rol `rag_app`, `CREATE DATABASE sigdesk_rag OWNER rag_app`, `REVOKE ALL ... FROM PUBLIC`, `CREATE EXTENSION vector` dentro de `sigdesk_rag` (rag_app no es superusuario). Verificar con `SELECT extversion FROM pg_extension WHERE extname = 'vector'`. | Bajo |
| 4.5 | Conectividad contenedor → Postgres nativo: desde un contenedor descartable, `psql` contra `host.docker.internal:<puerto>`. Confirmar desde qué dirección llega la conexión que reenvía Docker Desktop y ajustar `pg_hba.conf` a esa dirección exacta, **sin** escuchar en `0.0.0.0`. | Bajo: `pg_hba.conf` + reload de la instancia de SIG-Desk |
| 4.6 | PR en `SIG-Desk-Backend` (`compose.prod.yaml`): `RAG_DATABASE_URL` → `postgres://rag_app:${PG_RAG_PASSWORD:?}@host.docker.internal:<puerto>/sigdesk_rag`; `depends_on: !override` sin `postgres_rag`; `TICKETS_SERVICE_URL`/`ORGANIZATION_SERVICE_URL` → `18080`/`18081` (los defaults `8080`/`8081` apuntan a servicios ajenos del MKS); `:?` en `ORGANIZATION_INTERNAL_SECRET` y `RAG_S3_*`; decidir si `minio` se levanta o se quita del `depends_on` mientras solo se indexan tickets. | Ninguno (cambio de código, revisado por PR) |
| 4.7 | `up -d tei tei_reranker` y esperar *healthy* (el primer arranque descarga los pesos). Luego `run --rm rag_buscador esquema`: aplica el esquema y las migraciones como `rag_app`. | Bajo |
| 4.8 | `up -d rag_indexador rag_buscador`. Verificar en logs `backfill de alcance completo` con `usuarios > 0` (si es 0, el índice queda vacío por fail-closed) y el diagnóstico: `chunks_indexados`, `usuarios_en_mapa`, `mensajes_en_dead_letter`. | Bajo |
| 4.9 | **Decisión (Héctor): tickets históricos.** `alcance_ticket` solo se llena con `TicketCreado` desde Kafka (retención default de 7 días, `TODO-004`); el backfill HTTP cubre usuarios, no tickets. Los tickets anteriores se excluyen con motivo `creador_desconocido`. (a) Indexar solo hacia adelante, o (b) desarrollar un backfill de tickets antes de abrir el RAG a usuarios. | Depende de la decisión |
| 4.10 | Backups: sumar `sigdesk_rag` a la tarea `SIGDesk-backup` (3.7). La prueba de restauración exige pgvector instalado en el destino. | Ninguno |
| 4.11 | Prueba de `Buscar()` por gRPC (`ai_advisor_service/evals/run_retrieval_baseline.py` o `grpcurl`) con un actor de una compañía y otro de otra: el segundo obtiene **cero**. | Ninguno |

**Entregables:** pgvector instalado y versionado, `sigdesk_rag` aprovisionada, indexador y buscador corriendo,
evidencia de 4.8 y 4.11, y la decisión 4.9 registrada.

> 🔍 **Punto de revisión 4:** aprobar la decisión 4.9 y el PR de 4.6 **antes** de 4.7; revisar `pg_hba.conf`, que
> ningún puerto RAG quede publicado en `0.0.0.0` y que los servicios ajenos sigan como estaban.

---

## Rollback por fase

| Fase | Cómo volver atrás |
|---|---|
| 1 | `docker compose -f compose.yaml -f compose.prod.yaml -f compose.edge.yaml down` (sin `-v`) |
| 2 | `sigdesk-services.ps1 -Action uninstall -Apply`; Kong vuelve a dar 502 |
| 3 | Restaurar `DATABASE_URL` al Postgres en contenedor (volumen conservado) y reiniciar solo `SIGDesk-*` |
| 4 | `docker compose ... stop rag_indexador rag_buscador tei tei_reranker` (sin `-v`). `sigdesk_rag` y la extensión quedan sin uso y no afectan a las demás bases; borrarlas solo si se abandona el RAG |
