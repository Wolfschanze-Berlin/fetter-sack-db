-- 001-api-health.sql
-- Idempotent: safe to run on every deploy

CREATE OR REPLACE FUNCTION api.health()
RETURNS json
LANGUAGE sql STABLE
SECURITY DEFINER
AS $$
    SELECT json_build_object(
        'status', 'ok',
        'version', current_setting('server_version'),
        'timestamp', now(),
        'database', current_database()
    );
$$;

GRANT EXECUTE ON FUNCTION api.health() TO anon, webuser;

-- Tell PostgREST to reload its schema cache
SELECT pg_notify('pgrst', 'reload schema');
