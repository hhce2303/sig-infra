-- Bootstrap del primer administrador de SIG-Desk en un entorno (SIG-Desk-Backend:
-- Docs/howto/bootstrap-primer-admin.md, ADR-0017). Se ejecuta UNA vez por entorno,
-- contra la base de organization_service. Idempotente: re-ejecutarlo no duplica nada.
--
--   psql -U sigdesk -d sigdesk_organization_local \
--        -v empresa='SIGSystems' -v admin_nombre='Hector Cruz' \
--        -v admin_email='hector.cruz@sig.systems' -f 001-primer-admin.sql
--
-- admin_email debe ser EXACTAMENTE el que reporta SIGTools (GET /api/v1/web-auth/me/):
-- es la clave que une el login de SLC con el usuario de SIG-Desk.
\set ON_ERROR_STOP on
BEGIN;

-- 1. Empresa raíz
INSERT INTO companies (id, nombre, tipo, parent_id)
SELECT gen_random_uuid(), :'empresa', 'empresa', NULL
WHERE NOT EXISTS (SELECT 1 FROM companies WHERE tipo = 'empresa' AND nombre = :'empresa');

-- 2. Rol de administrador
INSERT INTO roles (id, nombre, descripcion)
SELECT gen_random_uuid(), 'Administrador', 'Acceso total al sistema — rol de bootstrap'
WHERE NOT EXISTS (SELECT 1 FROM roles WHERE nombre = 'Administrador');

-- 3. Permisos: CRUD global sobre todas las entidades que verifican backend y frontend
--    (organization_service/application/catalogo_permisos.go y
--    SIGNexus FRONTEND/src/features/auth/AuthProvider.tsx).
INSERT INTO permisos (role_id, entidad, accion, alcance)
SELECT r.id, e.entidad, a.accion, 'global'
FROM roles r
CROSS JOIN (VALUES
  ('usuarios'), ('roles'), ('companies'), ('agentes_it'), ('recursos'),
  ('tickets'), ('catalog'), ('sla_policies'),
  ('changes'), ('change_tasks'), ('change_approvals'), ('change_implementation'),
  ('problems'), ('problem_resolution'),
  ('service_requests'), ('service_request_approvals'),
  ('purchasing_fulfillment'), ('financial_approvals'),
  ('incident_triage'), ('incident_client_actions'),
  ('assets'), ('knowledge'), ('reports'), ('workflows'), ('ai_feedback')
) AS e(entidad)
CROSS JOIN (VALUES ('create'), ('read'), ('update'), ('delete')) AS a(accion)
WHERE r.nombre = 'Administrador'
  AND NOT EXISTS (
    SELECT 1 FROM permisos p
    WHERE p.role_id = r.id AND p.entidad = e.entidad AND p.accion = a.accion AND p.alcance = 'global'
  );

-- 4. Usuario administrador
INSERT INTO usuarios (id, nombre, email, company_id, role_id, estado)
SELECT gen_random_uuid(), :'admin_nombre', lower(:'admin_email'),
       (SELECT id FROM companies WHERE tipo = 'empresa' AND nombre = :'empresa' LIMIT 1),
       (SELECT id FROM roles WHERE nombre = 'Administrador' LIMIT 1),
       'activo'
WHERE NOT EXISTS (SELECT 1 FROM usuarios WHERE lower(email) = lower(:'admin_email'));

COMMIT;

-- Resumen
SELECT u.email, u.nombre, u.estado, c.nombre AS empresa, r.nombre AS rol,
       (SELECT count(*) FROM permisos p WHERE p.role_id = r.id) AS permisos
FROM usuarios u JOIN companies c ON c.id = u.company_id JOIN roles r ON r.id = u.role_id
WHERE lower(u.email) = lower(:'admin_email');
