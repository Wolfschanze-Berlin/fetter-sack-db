-- 00-extensions.sql
-- Install all extensions in dependency-aware order.
-- Runs automatically on first container init via docker-entrypoint-initdb.d.
--
-- Extension load order matters:
--   1. pg_partman        - partition management (into dedicated schema)
--   2. age               - graph database (Cypher queries)
--   3. pg_duckdb         - embedded DuckDB OLAP engine
--   4. pgmq              - message queue
--   5. pg_cron           - job scheduler
--   6. pg_net            - HTTP client from SQL
--   7. pg_graphql        - GraphQL API
--   8. vector            - pgvector similarity search
--   9. system_stats      - OS-level metrics
--  10. pg_hashids        - short unique IDs from integers
--  11. uuid-ossp         - UUID generation (v1, v4, etc.)
--  12. pgcrypto          - cryptographic functions (gen_random_uuid, digest, etc.)
--  13. postgis           - geospatial
--  14. rum               - full-text search index
--  15. pg_stat_statements - query performance tracking

\echo '=== Installing extensions ==='

-- Core partitioning (install into dedicated schema)
CREATE SCHEMA IF NOT EXISTS partman;
CREATE EXTENSION IF NOT EXISTS pg_partman SCHEMA partman CASCADE;
\echo '  pg_partman installed (schema: partman)'

-- Graph database
CREATE EXTENSION IF NOT EXISTS age CASCADE;
\echo '  age installed'

-- Embedded OLAP
CREATE EXTENSION IF NOT EXISTS pg_duckdb CASCADE;
\echo '  pg_duckdb installed'

-- Message queue
CREATE EXTENSION IF NOT EXISTS pgmq CASCADE;
\echo '  pgmq installed'

-- Job scheduler (requires shared_preload_libraries, already configured)
CREATE EXTENSION IF NOT EXISTS pg_cron CASCADE;
\echo '  pg_cron installed'

-- HTTP client
CREATE EXTENSION IF NOT EXISTS pg_net CASCADE;
\echo '  pg_net installed'

-- GraphQL API (auto-reflects database schema as GraphQL)
CREATE EXTENSION IF NOT EXISTS pg_graphql CASCADE;
\echo '  pg_graphql installed'

-- Vector similarity search
CREATE EXTENSION IF NOT EXISTS vector CASCADE;
\echo '  vector (pgvector) installed'

-- OS metrics
CREATE EXTENSION IF NOT EXISTS system_stats CASCADE;
\echo '  system_stats installed'

-- Short unique IDs from integers (e.g., 347 -> "yr8")
CREATE EXTENSION IF NOT EXISTS pg_hashids CASCADE;
\echo '  pg_hashids installed'

-- UUID generation (uuid_generate_v4(), uuid_generate_v1mc(), etc.)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" CASCADE;
\echo '  uuid-ossp installed'

-- Cryptographic functions (gen_random_uuid(), digest(), hmac(), crypt(), etc.)
CREATE EXTENSION IF NOT EXISTS pgcrypto CASCADE;
\echo '  pgcrypto installed'

-- PostGIS (geospatial)
CREATE EXTENSION IF NOT EXISTS postgis CASCADE;
\echo '  postgis installed'

-- RUM index (full-text search)
CREATE EXTENSION IF NOT EXISTS rum CASCADE;
\echo '  rum installed'

-- Query performance tracking
CREATE EXTENSION IF NOT EXISTS pg_stat_statements CASCADE;
\echo '  pg_stat_statements installed'

\echo '=== All extensions installed ==='
