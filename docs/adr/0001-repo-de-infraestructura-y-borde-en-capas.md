# ADR-0001: Repo de infraestructura compartida y borde en capas (nginx → Kong)

- Estado: Propuesto (2026-10-09)
- Decide: Héctor Cruz (dueño del borde)

## Contexto

SLC-SIG_platform (Django, MySQL, productos installations/inventory) es dueño del nginx que ya fronta también a SIG-Desk (Go, Kong) mediante un overlay opcional y la red `sig-edge`, creada a mano y sin dueño. SIG-Desk correrá en producción. Los certificados son manuales.

## Decisión

1. Crear `sig-infra` como repo de infraestructura compartida; `edge/` es el primer módulo y dueño de nginx, la red `sig-edge`, certificados y puerto público.
2. Mantener dos capas: **nginx** (puerta pública, vhosts, TLS, `/media/`, SSE de Django) delante de **Kong** (políticas de API de SIG-Desk). ADR-0016 de SIG-Desk descarta nginx+Lua como gateway de API, no nginx como proxy de entrada.
3. Un vhost por consumidor, con CODEOWNERS; el dueño del borde revisa seguridad, TLS y puertos.
4. No se mueven apps Django ni conexiones de BD: son ORM acoplado a `installations` y SIG-Desk (Go) no puede reutilizarlas. Los siguientes candidatos compartidos entran por contrato de red, cada uno con su ADR.
5. Strangler fig: copiar los server blocks, cortar un host a la vez, conservar rollback al nginx de SLC.

## Consecuencias

- Un único punto de falla para `api.` y `desk.`; se mitiga con `nginx -t` previo, `reload` y upstreams resueltos por petición.
- SLC debe unir `web` a `sig-edge` con alias `slc-web` y compartir el volumen de media (o migrar media a otro almacenamiento).
- Pendiente: terminación de TLS (Fase 3, ADR conjunto con SIG-Desk), orquestación (Fase 5).
