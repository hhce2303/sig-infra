# GOALS — SIG-Desk en producción (MKS)

## Objetivo

Dejar SIG-Desk-Backend corriendo en producción en el MKS (192.168.1.69), detrás del borde compartido
`sig-edge-nginx:8091`, sin afectar ningún otro servicio del servidor.

```
cliente ► sig-edge-nginx:8091 ► sigdesk-kong (Docker) ► host.docker.internal:1808x ► SIGDesk-*.exe (Windows)
                                                                                        │
                                                                                        ▼
                                                                    PostgreSQL nativo del servidor
                                                                    (gestionable desde Django / SLC)
```

## Metas

| # | Meta | Criterio de "hecho" |
|---|---|---|
| G1 | **Los .exe se comunican con Docker** | Kong (contenedor) llega a los 4 servicios Windows en `127.0.0.1:18080–18083`. Los .exe llegan a Kafka y Temporal (contenedores) en `127.0.0.1`. `desk.sig.systems/desk-api/*` responde desde los servicios, ya no da 502. |
| G2 | **El stack Docker de SIG-Desk levantado** | Kong, Kafka y Temporal corriendo con `compose.prod.yaml` y `restart: unless-stopped`. Ningún puerto queda publicado a la LAN. Todo sobrevive a un reinicio del servidor. |
| G3 | **PostgreSQL hosteado en el servidor (no en contenedor)** | Las bases de SIG-Desk viven en un PostgreSQL nativo de Windows, con rol propio, backups y acceso solo local. Django (SLC) puede leerlas o gestionarlas sin romper el esquema que aplica cada servicio Go. |

## Restricciones no negociables

1. **No tocar ningún servicio que ya corre en el servidor.** Eso incluye Apache, MySQL, ManageEngine
   ServiceDesk, `SIGTicketAPI`, `SIGJobs`, `SIGAgentHub`, `SIGCircuitCheck`, el PostgreSQL existente, el stack
   de SLC y `sig-edge-nginx`. No se detienen, no se reinician y no se cambia su configuración.
2. Solo se crean recursos nuevos con prefijo `SIGDesk-` o `sigdesk`.
3. Ningún cambio en el firewall. Todo escucha en `127.0.0.1`, salvo el borde (8091), que ya existe.
4. **Cada fase la revisa y aprueba Héctor Cruz antes de pasar a la siguiente.** Ninguna acción con
   privilegios de administrador se ejecuta sin su aprobación explícita.
5. Los secretos nunca van a git (ADR-0013).

## Fuera de alcance

- Frontend de SIG-Desk (aún no desplegado).
- TLS y certificados (Fase 3 del borde, en sig-infra).
- `notification_service`, `audit_service`, `ai_advisor_service` y RAG/TEI.
- Dockerizar los servicios Go (opción A, a futuro).
