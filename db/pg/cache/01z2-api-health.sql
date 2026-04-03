-- 01z2-api-health.sql
-- Create a health endpoint in the api schema so PostgREST always has
-- at least one relation to serve (avoids 503 on empty api schema).

\echo '=== Setting up API health endpoint ==='

-- Health check function — returns server status
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

COMMENT ON FUNCTION api.health IS 'Health check endpoint: GET /rpc/health';

\echo '  api.health() endpoint created'
\echo '  Usage: curl https://<host>/rpc/health'
\echo '=== API health endpoint ready ==='
