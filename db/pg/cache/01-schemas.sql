-- 01-schemas.sql
-- Create application schemas and configure search_path.
-- Separates concerns: partman internals, graph catalog, app data.

\echo '=== Setting up schemas ==='

-- Partition management internals (pg_partman already installed here by 00-extensions.sql)
-- Schema 'partman' was created in 00-extensions.sql
\echo '  partman schema verified'

-- Application data schema (keeps public clean)
CREATE SCHEMA IF NOT EXISTS app;
COMMENT ON SCHEMA app IS 'Application tables, views, and functions';
\echo '  app schema created'

-- Analytics / reporting schema
CREATE SCHEMA IF NOT EXISTS analytics;
COMMENT ON SCHEMA analytics IS 'Analytical views, materialized views, and reporting functions';
\echo '  analytics schema created'

-- Set default search_path for the postgres superuser
-- ag_catalog is needed for Apache AGE Cypher queries
ALTER ROLE postgres SET search_path = public, app, analytics, partman, ag_catalog;
\echo '  search_path configured for postgres role'

-- Pre-load AGE in every new session for this database
-- This avoids the need to manually run LOAD 'age' each time
ALTER DATABASE "athena-mcp" SET session_preload_libraries = 'age';
\echo '  age auto-loaded via session_preload_libraries'

\echo '=== Schemas ready ==='
