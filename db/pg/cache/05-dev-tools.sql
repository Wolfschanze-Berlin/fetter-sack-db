-- 05-dev-tools.sql
-- Developer-friendly views, performance diagnostics, and convenience functions.
-- Makes the database self-documenting and easy to inspect.

\echo '=== Setting up developer tools ==='

-- ---------------------------------------------------------------------------
-- View: table sizes (including partitions, toast, indexes)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.table_sizes AS
SELECT
    schemaname AS schema,
    relname AS table_name,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || relname)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname || '.' || relname)) AS data_size,
    pg_size_pretty(pg_indexes_size(schemaname || '.' || relname)) AS index_size,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || relname)
                 - pg_relation_size(schemaname || '.' || relname)
                 - pg_indexes_size(schemaname || '.' || relname)) AS toast_size,
    n_live_tup AS estimated_rows,
    n_dead_tup AS dead_rows,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(schemaname || '.' || relname) DESC;

COMMENT ON VIEW public.table_sizes IS
'All user tables with sizes (data, index, toast), row estimates, and vacuum stats.
Ordered by total size descending.';

\echo '  table_sizes view created'

-- ---------------------------------------------------------------------------
-- View: index usage and effectiveness
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.index_usage AS
SELECT
    schemaname AS schema,
    relname AS table_name,
    indexrelname AS index_name,
    idx_scan AS scans,
    idx_tup_read AS tuples_read,
    idx_tup_fetch AS tuples_fetched,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    CASE
        WHEN idx_scan = 0 THEN 'UNUSED'
        WHEN idx_scan < 10 THEN 'RARELY USED'
        ELSE 'ACTIVE'
    END AS status
FROM pg_stat_user_indexes
ORDER BY idx_scan ASC, pg_relation_size(indexrelid) DESC;

COMMENT ON VIEW public.index_usage IS
'Index usage statistics. Find unused indexes (wasting write performance)
and verify indexes are being scanned. Ordered: least used first.';

\echo '  index_usage view created'

-- ---------------------------------------------------------------------------
-- pg_stat_statements views (comprehensive query performance analysis)
-- Ref: https://supabase.com/docs/guides/database/extensions/pg_stat_statements
-- ---------------------------------------------------------------------------

-- View: slowest queries by average execution time
CREATE OR REPLACE VIEW public.slow_queries AS
SELECT
    queryid,
    left(query, 300) AS query,
    calls,
    round(mean_exec_time::numeric, 2) AS avg_time_ms,
    round(max_exec_time::numeric, 2) AS max_time_ms,
    round(total_exec_time::numeric, 2) AS total_time_ms,
    round(stddev_exec_time::numeric, 2) AS stddev_ms,
    rows,
    round((100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0))::numeric, 1) AS cache_hit_pct
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 50;

COMMENT ON VIEW public.slow_queries IS
'Top 50 slowest queries by average execution time. Shows timing, call count, and cache hit ratio.';

\echo '  slow_queries view created'

-- View: most frequently called queries
CREATE OR REPLACE VIEW public.frequent_queries AS
SELECT
    queryid,
    left(query, 300) AS query,
    calls,
    round(total_exec_time::numeric, 2) AS total_time_ms,
    round(mean_exec_time::numeric, 2) AS avg_time_ms,
    rows,
    round((100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0))::numeric, 1) AS cache_hit_pct
FROM pg_stat_statements
ORDER BY calls DESC
LIMIT 50;

COMMENT ON VIEW public.frequent_queries IS
'Top 50 most-called queries. High-frequency slow queries are prime optimization targets.';

\echo '  frequent_queries view created'

-- View: queries consuming the most total time
CREATE OR REPLACE VIEW public.time_consuming_queries AS
SELECT
    queryid,
    left(query, 300) AS query,
    calls,
    round(total_exec_time::numeric, 2) AS total_time_ms,
    round((total_exec_time / sum(total_exec_time) OVER () * 100)::numeric, 2) AS pct_of_total,
    round(mean_exec_time::numeric, 2) AS avg_time_ms,
    rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 50;

COMMENT ON VIEW public.time_consuming_queries IS
'Top 50 queries by total execution time with percentage of all query time. Shows where your DB spends its time.';

\echo '  time_consuming_queries view created'

-- View: queries with worst cache hit ratio (reading from disk)
CREATE OR REPLACE VIEW public.cache_miss_queries AS
SELECT
    queryid,
    left(query, 300) AS query,
    calls,
    shared_blks_read AS disk_reads,
    shared_blks_hit AS cache_hits,
    round((100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0))::numeric, 1) AS cache_hit_pct,
    round(mean_exec_time::numeric, 2) AS avg_time_ms
FROM pg_stat_statements
WHERE shared_blks_read > 0
ORDER BY shared_blks_read DESC
LIMIT 50;

COMMENT ON VIEW public.cache_miss_queries IS
'Queries with the most disk reads (cache misses). Low cache_hit_pct = needs more shared_buffers or better indexing.';

\echo '  cache_miss_queries view created'

-- View: overall pg_stat_statements summary
CREATE OR REPLACE VIEW public.query_stats_summary AS
SELECT
    count(*) AS total_tracked_queries,
    sum(calls) AS total_calls,
    round(sum(total_exec_time)::numeric / 1000, 2) AS total_exec_seconds,
    round(avg(mean_exec_time)::numeric, 2) AS avg_query_time_ms,
    round(max(max_exec_time)::numeric, 2) AS slowest_query_ms,
    round((100.0 * sum(shared_blks_hit) / NULLIF(sum(shared_blks_hit + shared_blks_read), 0))::numeric, 1) AS overall_cache_hit_pct,
    sum(rows) AS total_rows_processed
FROM pg_stat_statements;

COMMENT ON VIEW public.query_stats_summary IS
'Aggregate summary of all tracked queries: total calls, execution time, cache hit ratio.';

\echo '  query_stats_summary view created'

-- Function: reset pg_stat_statements (clear all tracked query stats)
-- Usage: SELECT reset_query_stats();
CREATE OR REPLACE FUNCTION public.reset_query_stats()
RETURNS void
LANGUAGE sql
AS $$
    SELECT pg_stat_statements_reset();
$$;

COMMENT ON FUNCTION public.reset_query_stats IS
'Reset all pg_stat_statements counters. Use to establish a clean baseline before benchmarking.';

\echo '  reset_query_stats() helper created'

-- ---------------------------------------------------------------------------
-- View: active queries and locks
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.active_queries AS
SELECT
    pid,
    usename AS user,
    application_name AS app,
    client_addr,
    state,
    wait_event_type,
    wait_event,
    now() - query_start AS duration,
    left(query, 200) AS query_preview
FROM pg_stat_activity
WHERE state != 'idle'
  AND pid != pg_backend_pid()
ORDER BY query_start ASC;

COMMENT ON VIEW public.active_queries IS
'Currently running queries with duration and wait events. Excludes idle connections.';

\echo '  active_queries view created'

-- ---------------------------------------------------------------------------
-- View: blocking queries (who is blocking whom)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.blocking_queries AS
SELECT
    blocked.pid AS blocked_pid,
    blocked.usename AS blocked_user,
    left(blocked.query, 100) AS blocked_query,
    now() - blocked.query_start AS blocked_duration,
    blocker.pid AS blocker_pid,
    blocker.usename AS blocker_user,
    left(blocker.query, 100) AS blocker_query
FROM pg_stat_activity blocked
JOIN pg_locks blocked_locks ON blocked.pid = blocked_locks.pid AND NOT blocked_locks.granted
JOIN pg_locks blocker_locks ON blocked_locks.locktype = blocker_locks.locktype
    AND blocked_locks.database IS NOT DISTINCT FROM blocker_locks.database
    AND blocked_locks.relation IS NOT DISTINCT FROM blocker_locks.relation
    AND blocked_locks.page IS NOT DISTINCT FROM blocker_locks.page
    AND blocked_locks.tuple IS NOT DISTINCT FROM blocker_locks.tuple
    AND blocked_locks.virtualxid IS NOT DISTINCT FROM blocker_locks.virtualxid
    AND blocked_locks.transactionid IS NOT DISTINCT FROM blocker_locks.transactionid
    AND blocked_locks.classid IS NOT DISTINCT FROM blocker_locks.classid
    AND blocked_locks.objid IS NOT DISTINCT FROM blocker_locks.objid
    AND blocked_locks.objsubid IS NOT DISTINCT FROM blocker_locks.objsubid
    AND blocker_locks.granted
JOIN pg_stat_activity blocker ON blocker_locks.pid = blocker.pid
WHERE blocked.pid != blocker.pid;

COMMENT ON VIEW public.blocking_queries IS
'Shows lock contention: which queries are blocked and by whom. Essential for deadlock debugging.';

\echo '  blocking_queries view created'

-- ---------------------------------------------------------------------------
-- View: database overview
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.db_overview AS
SELECT
    pg_database.datname AS database,
    pg_size_pretty(pg_database_size(pg_database.datname)) AS size,
    numbackends AS connections,
    xact_commit AS commits,
    xact_rollback AS rollbacks,
    blks_read,
    blks_hit,
    round(blks_hit * 100.0 / NULLIF(blks_hit + blks_read, 0), 1) AS cache_hit_pct,
    tup_returned,
    tup_fetched,
    tup_inserted,
    tup_updated,
    tup_deleted,
    conflicts,
    deadlocks
FROM pg_stat_database
JOIN pg_database ON pg_database.datname = pg_stat_database.datname
WHERE pg_database.datname = current_database();

COMMENT ON VIEW public.db_overview IS
'Current database statistics: size, connections, cache hit ratio, tuple counts, deadlocks.';

\echo '  db_overview view created'

-- ---------------------------------------------------------------------------
-- View: extension versions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.extensions AS
SELECT
    extname AS name,
    extversion AS version,
    nspname AS schema
FROM pg_extension
JOIN pg_namespace ON pg_namespace.oid = extnamespace
WHERE extname != 'plpgsql'
ORDER BY extname;

COMMENT ON VIEW public.extensions IS
'Installed extensions with versions and schemas.';

\echo '  extensions view created'

-- ---------------------------------------------------------------------------
-- Function: explain analyze wrapper (returns JSON plan)
-- Usage: SELECT * FROM explain_json('SELECT * FROM my_table WHERE id = 1');
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.explain_json(p_query TEXT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_result JSONB;
BEGIN
    EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || p_query INTO v_result;
    RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.explain_json IS
'Run EXPLAIN ANALYZE with BUFFERS in JSON format. Returns full query plan as JSONB.
WARNING: Actually executes the query. Use with caution on write queries.';

\echo '  explain_json() helper created'

-- ---------------------------------------------------------------------------
-- Function: quick table stats
-- Usage: SELECT * FROM table_stats('app.my_table');
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.table_stats(p_table TEXT)
RETURNS TABLE (
    metric TEXT,
    value TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count BIGINT;
    v_size TEXT;
    v_index_size TEXT;
    v_live_tuples BIGINT;
    v_dead_tuples BIGINT;
BEGIN
    EXECUTE format('SELECT count(*) FROM %s', p_table) INTO v_count;
    SELECT pg_size_pretty(pg_total_relation_size(p_table)) INTO v_size;
    SELECT pg_size_pretty(pg_indexes_size(p_table)) INTO v_index_size;
    SELECT n_live_tup, n_dead_tup INTO v_live_tuples, v_dead_tuples
    FROM pg_stat_user_tables
    WHERE (schemaname || '.' || relname) = p_table
       OR relname = p_table;

    RETURN QUERY VALUES
        ('exact_rows', v_count::TEXT),
        ('total_size', v_size),
        ('index_size', v_index_size),
        ('estimated_live', COALESCE(v_live_tuples, 0)::TEXT),
        ('estimated_dead', COALESCE(v_dead_tuples, 0)::TEXT);
END;
$$;

COMMENT ON FUNCTION public.table_stats IS
'Quick stats for a table: exact row count, sizes, live/dead tuple estimates.';

\echo '  table_stats() helper created'

-- ---------------------------------------------------------------------------
-- Function: kill a query by PID
-- Usage: SELECT kill_query(12345);
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.kill_query(p_pid INTEGER)
RETURNS BOOLEAN
LANGUAGE sql
AS $$
    SELECT pg_cancel_backend(p_pid);
$$;

COMMENT ON FUNCTION public.kill_query IS
'Cancel a running query by PID (graceful). Use pg_terminate_backend() for force-kill.';

\echo '  kill_query() helper created'

-- ---------------------------------------------------------------------------
-- Performance: set statement_timeout for dev safety (prevent runaway queries)
-- 5 minutes is generous for development; reduce for production
-- ---------------------------------------------------------------------------
ALTER DATABASE "athena-mcp" SET statement_timeout = '5min';
ALTER DATABASE "athena-mcp" SET lock_timeout = '30s';
ALTER DATABASE "athena-mcp" SET idle_in_transaction_session_timeout = '10min';

\echo '  timeout safety nets configured (statement=5m, lock=30s, idle_txn=10m)'

-- ---------------------------------------------------------------------------
-- Reset pg_stat_statements for clean baseline
-- ---------------------------------------------------------------------------
SELECT pg_stat_statements_reset();
\echo '  pg_stat_statements reset for clean baseline'

\echo '=== Developer tools ready ==='
\echo ''
\echo 'Available views:'
\echo '  SELECT * FROM table_sizes;              -- All tables with sizes'
\echo '  SELECT * FROM index_usage;              -- Index effectiveness'
\echo '  SELECT * FROM slow_queries;             -- Top 50 slowest queries'
\echo '  SELECT * FROM frequent_queries;         -- Most-called queries'
\echo '  SELECT * FROM time_consuming_queries;   -- Queries using most total time'
\echo '  SELECT * FROM cache_miss_queries;       -- Queries with most disk reads'
\echo '  SELECT * FROM query_stats_summary;      -- Overall query performance'
\echo '  SELECT * FROM active_queries;           -- Currently running queries'
\echo '  SELECT * FROM blocking_queries;         -- Lock contention'
\echo '  SELECT * FROM db_overview;              -- Database stats'
\echo '  SELECT * FROM extensions;               -- Installed extensions'
\echo '  SELECT * FROM partition_status;         -- pg_partman overview'
\echo '  SELECT * FROM queue_status;             -- pgmq overview'
\echo '  SELECT * FROM vector_index_status;      -- pgvector indexes'
\echo ''
\echo 'Available functions:'
\echo '  SELECT explain_json(''...'');                         -- EXPLAIN ANALYZE as JSON'
\echo '  SELECT * FROM table_stats(''schema.table'');          -- Quick table stats'
\echo '  SELECT kill_query(pid);                               -- Cancel a query'
\echo '  SELECT reset_query_stats();                            -- Reset pg_stat_statements'
\echo '  SELECT partman_create_daily(''t'', ''col'');          -- Daily partitions'
\echo '  SELECT partman_create_hourly(''t'', ''col'');         -- Hourly partitions'
\echo '  SELECT partman_create_monthly(''t'', ''col'');        -- Monthly partitions'
\echo '  SELECT create_embedding_table(''name'', 1536);       -- Vector table + HNSW'
\echo '  SELECT * FROM semantic_search(''name'', vec, 10);    -- Similarity search'
\echo '  SELECT mq_send(''queue'', ''{"k":"v"}'');            -- Send to queue'
