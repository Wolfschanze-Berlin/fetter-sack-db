-- 000-postgrest-roles.sql
-- Idempotent: safe to run on every deploy
-- Ensures PostgREST roles exist (authenticator, anon, webuser)
-- This is needed because init scripts (db/pg/cache/) only run on first boot.

DO $$
BEGIN
    -- authenticator: PostgREST connects as this role
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticator') THEN
        CREATE ROLE authenticator LOGIN NOINHERIT PASSWORD 'authenticator';
        RAISE NOTICE 'Created role: authenticator';
    END IF;

    -- anon: unauthenticated REST API access
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
        CREATE ROLE anon NOLOGIN;
        RAISE NOTICE 'Created role: anon';
    END IF;

    -- webuser: JWT-authenticated REST API access
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'webuser') THEN
        CREATE ROLE webuser NOLOGIN;
        RAISE NOTICE 'Created role: webuser';
    END IF;
END
$$;

-- Grant membership (idempotent — no error if already granted)
GRANT anon TO authenticator;
GRANT webuser TO authenticator;

-- Ensure api schema exists
CREATE SCHEMA IF NOT EXISTS api;
CREATE SCHEMA IF NOT EXISTS app;

-- Grant schema usage to API roles
GRANT USAGE ON SCHEMA api TO anon, webuser;
GRANT USAGE ON SCHEMA app TO anon, webuser;
GRANT USAGE ON SCHEMA public TO anon, webuser;

-- Default privileges for future objects
ALTER DEFAULT PRIVILEGES IN SCHEMA api GRANT SELECT ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA api GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO webuser;
ALTER DEFAULT PRIVILEGES IN SCHEMA api GRANT EXECUTE ON FUNCTIONS TO anon, webuser;
ALTER DEFAULT PRIVILEGES IN SCHEMA api GRANT USAGE ON SEQUENCES TO webuser;

ALTER DEFAULT PRIVILEGES IN SCHEMA app GRANT SELECT ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA app GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO webuser;
ALTER DEFAULT PRIVILEGES IN SCHEMA app GRANT USAGE ON SEQUENCES TO webuser;
