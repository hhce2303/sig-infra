# sig-infra

Infraestructura compartida de SIG. Primer módulo: **`edge/`**, el nginx que es la única puerta pública de SLC-SIG_platform y de SIG-Desk (Kong). Pensado para crecer (otros servicios compartidos y, más adelante, orquestación; ver `orchestration/`).

Estado: **Fase 2** — repo creado, **sin corte de tráfico** (el nginx de SLC sigue siendo el que atiende producción). Contexto y plan: `SIG-SLC/reports/Extraer nginx a servicios compartidos.md`.

## Contrato del borde

```
cliente ──► sig-edge-nginx ──┬─ api.sig.systems (y cualquier otro Host / IP, default_server) ──► slc-web:8000   (Django, SLC-SIG_platform)
   :8091                     └─ desk.sig.systems /desk-api/*  ──► sigdesk-kong:8000 ──► servicios (SIG-Desk-Backend)
```

| Tema | Decisión |
|---|---|
| Red | `sig-edge` (bridge externa), creada por `make network` |
| Alias en la red | `slc-web` (Django de SLC), `sigdesk-kong` (Kong) |
| Puerto público | `8091` (`NGINX_PORT`) |
| Upstreams | Resueltos por petición (`resolver 127.0.0.11` + variable): el borde arranca aunque un backend esté caído; 502 solo en ese host |
| Vhosts | Un archivo por consumidor en `edge/nginx/conf.d/` |
| Media de SLC | Volumen externo de SLC montado solo lectura en `/app/media` (`SLC_MEDIA_VOLUME`) |
| TLS | Pendiente (Fase 3). Certificados **manuales** en `edge/certs/` (fuera de git) |
| Reload | `make reload` (`nginx -t` + `nginx -s reload`). Los mounts son de directorio, por eso el reload ve los cambios tras un `git pull` |
| Dueño del borde y aprobador de rutas | Héctor Cruz (`CODEOWNERS`) |

## Quién es dueño de qué

| Pieza | Dueño |
|---|---|
| nginx, red `sig-edge`, certificados, puerto, `nginx.conf`, snippets | Dueño del borde |
| `conf.d/api.sig.systems.conf` | Equipo SLC |
| `conf.d/desk.sig.systems.conf` | Equipo SIG-Desk |
| Políticas de API (auth, CORS, rutas) | Kong, en SIG-Desk-Backend |

## Uso

```bash
cp edge/.env.example edge/.env   # ajustar SLC_MEDIA_VOLUME
make up        # crea la red y levanta el borde
make check     # nginx -t con la config completa
make reload    # tras cambiar un vhost
make smoke     # prueba por host
```

Corte desde el nginx de SLC y rollback: `docs/runbook.md`. Decisión de diseño: `docs/adr/0001-repo-de-infraestructura-y-borde-en-capas.md`.
