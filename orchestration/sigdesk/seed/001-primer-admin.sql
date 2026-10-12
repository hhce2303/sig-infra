-- Bootstrap de un administrador de SIG-Desk (SIG-Desk-Backend: Docs/howto/bootstrap-primer-admin.md,
-- ADR-0017). Contra la base de organization_service. Idempotente: re-ejecutarlo no duplica nada.
-- Sirve para el primer admin de un entorno y para dar de alta admins adicionales por SQL.
--
--   psql -U sigdesk -d sigdesk_organization_local \
--        -v empresa='SIGSystems' -v admin_nombre='Hector Cruz' \
--        -v admin_email='hector.cruz@sig.systems' -f 001-primer-admin.sql
--
-- admin_email debe ser EXACTAMENTE el que reporta SIGTools (GET /api/v1/web-auth/me/):
-- es la clave que une el login de SLC con el usuario de SIG-Desk.
--
-- El rol es el "Administrador" CANÓNICO que organization_service siembra al arrancar
-- (schema.sql, id fijo ...0004, CRUD global). Desde v0.2.0 este seed ya no crea un rol propio:
-- organization_service tiene que haber arrancado al menos una vez contra esta base.
\set ON_ERROR_STOP on
BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM roles WHERE id = '00000000-0000-0000-0000-000000000004') THEN
    RAISE EXCEPTION 'Falta el rol Administrador canónico (...0004): arranca organization_service una vez contra esta base';
  END IF;
END $$;

-- 1. Empresa raíz
INSERT INTO companies (id, nombre, tipo, parent_id)
SELECT gen_random_uuid(), :'empresa', 'empresa', NULL
WHERE NOT EXISTS (SELECT 1 FROM companies WHERE tipo = 'empresa' AND nombre = :'empresa');

-- 2. Usuario administrador (rol canónico)
INSERT INTO usuarios (id, nombre, email, company_id, role_id, estado)
SELECT gen_random_uuid(), :'admin_nombre', lower(:'admin_email'),
       (SELECT id FROM companies WHERE tipo = 'empresa' AND nombre = :'empresa' LIMIT 1),
       '00000000-0000-0000-0000-000000000004',
       'activo'
WHERE NOT EXISTS (SELECT 1 FROM usuarios WHERE lower(email) = lower(:'admin_email'));

COMMIT;

-- Resumen
SELECT u.email, u.nombre, u.estado, c.nombre AS empresa, r.nombre AS rol,
       (SELECT count(*) FROM permisos p WHERE p.role_id = r.id) AS permisos
FROM usuarios u JOIN companies c ON c.id = u.company_id JOIN roles r ON r.id = u.role_id
WHERE lower(u.email) = lower(:'admin_email');
