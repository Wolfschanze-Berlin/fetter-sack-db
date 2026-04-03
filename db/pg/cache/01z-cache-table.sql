-- 01b-cache-table.sql
-- In-memory key-value cache table (UNLOGGED = no WAL, wiped on crash).
-- Enforced max size: 15% of shared_buffers via pg_cron eviction.
--
-- UNLOGGED means:
--   - No WAL writes → 2-5x faster inserts/updates than regular tables
--   - Data survives normal restarts (CHECKPOINT still flushes to disk)
--   - Data is TRUNCATED on crash recovery (PostgreSQL wipes unlogged tables)
--   - Not replicated to standby servers
--
-- This is the closest PostgreSQL gets to a pure RAM table.

\echo '=== Setting up in-memory cache table ==='

-- ---------------------------------------------------------------------------
-- Cache table: unlogged key-value store with JSONB data
-- ---------------------------------------------------------------------------
CREATE UNLOGGED TABLE IF NOT EXISTS app.cache (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    namespace TEXT NOT NULL,
    key TEXT NOT NULL,
    data JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE app.cache IS
'In-memory UNLOGGED key-value cache. No WAL, wiped on crash. Max size enforced at 15% of RAM by pg_cron eviction job.';

-- Unique constraint: one key per namespace (enables upsert)
ALTER TABLE app.cache ADD CONSTRAINT uq_cache_ns_key UNIQUE (namespace, key);

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

-- GIN on data JSONB — fast containment queries
CREATE INDEX idx_cache_data_gin ON app.cache USING gin (data jsonb_path_ops);

-- BTREE on namespace — fast namespace-level operations (list, purge)
CREATE INDEX idx_cache_namespace ON app.cache (namespace);

-- BTREE on created_at — eviction ordering (oldest first)
CREATE INDEX idx_cache_created ON app.cache (created_at);

-- BTREE on updated_at — LRU eviction ordering
CREATE INDEX idx_cache_updated ON app.cache (updated_at);

\echo '  app.cache table created (UNLOGGED)'

-- ---------------------------------------------------------------------------
-- Trigger: auto-update updated_at on any UPDATE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.cache_touch_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_cache_updated_at
    BEFORE UPDATE ON app.cache
    FOR EACH ROW
    EXECUTE FUNCTION app.cache_touch_updated_at();

\echo '  updated_at auto-update trigger created'

-- ---------------------------------------------------------------------------
-- Helper: cache_set — upsert a value (insert or update)
-- Usage: SELECT cache_set('session', 'user:123', '{"token": "abc"}');
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cache_set(
    p_namespace TEXT,
    p_key TEXT,
    p_data JSONB
)
RETURNS UUID
LANGUAGE sql
AS $$
    INSERT INTO app.cache (namespace, key, data)
    VALUES (p_namespace, p_key, p_data)
    ON CONFLICT (namespace, key)
        DO UPDATE SET data = EXCLUDED.data
    RETURNING id;
$$;

COMMENT ON FUNCTION public.cache_set IS
'Set a cache entry. Inserts or updates by (namespace, key). Returns the row UUID.';

\echo '  cache_set() helper created'

-- ---------------------------------------------------------------------------
-- Helper: cache_get — retrieve a value
-- Usage: SELECT cache_get('session', 'user:123');
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cache_get(
    p_namespace TEXT,
    p_key TEXT
)
RETURNS JSONB
LANGUAGE sql
AS $$
    SELECT data FROM app.cache
    WHERE namespace = p_namespace AND key = p_key;
$$;

COMMENT ON FUNCTION public.cache_get IS
'Get a cache entry by (namespace, key). Returns JSONB data or NULL if not found.';

\echo '  cache_get() helper created'

-- ---------------------------------------------------------------------------
-- Helper: cache_del — delete a key
-- Usage: SELECT cache_del('session', 'user:123');
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cache_del(
    p_namespace TEXT,
    p_key TEXT
)
RETURNS BOOLEAN
LANGUAGE sql
AS $$
    DELETE FROM app.cache
    WHERE namespace = p_namespace AND key = p_key
    RETURNING true;
$$;

COMMENT ON FUNCTION public.cache_del IS
'Delete a cache entry. Returns true if deleted, NULL if not found.';

\echo '  cache_del() helper created'

-- ---------------------------------------------------------------------------
-- Helper: cache_purge_namespace — delete all keys in a namespace
-- Usage: SELECT cache_purge_namespace('session');
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cache_purge_namespace(p_namespace TEXT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_count BIGINT;
BEGIN
    DELETE FROM app.cache WHERE namespace = p_namespace;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION public.cache_purge_namespace IS
'Delete all entries in a namespace. Returns number of rows deleted.';

\echo '  cache_purge_namespace() helper created'

-- ---------------------------------------------------------------------------
-- Helper: cache_size — current table size in bytes and human-readable
-- Usage: SELECT * FROM cache_size();
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cache_size()
RETURNS TABLE (
    total_size TEXT,
    total_bytes BIGINT,
    row_count BIGINT,
    max_size TEXT,
    max_bytes BIGINT,
    usage_pct NUMERIC
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_total BIGINT;
    v_rows BIGINT;
    v_max BIGINT;
BEGIN
    -- Current total size (data + indexes + toast)
    SELECT pg_total_relation_size('app.cache') INTO v_total;
    SELECT count(*) FROM app.cache INTO v_rows;

    -- Max = 15% of shared_buffers (from pg_settings, in 8KB pages)
    SELECT (setting::bigint * 8192 * 0.15)::bigint
    FROM pg_settings WHERE name = 'shared_buffers'
    INTO v_max;

    RETURN QUERY SELECT
        pg_size_pretty(v_total),
        v_total,
        v_rows,
        pg_size_pretty(v_max),
        v_max,
        round((v_total * 100.0 / NULLIF(v_max, 0))::numeric, 2);
END;
$$;

COMMENT ON FUNCTION public.cache_size IS
'Current cache table size vs 15% RAM limit. Shows bytes, row count, and usage percentage.';

\echo '  cache_size() helper created'

-- ---------------------------------------------------------------------------
-- Eviction: LRU cleanup when cache exceeds 15% of shared_buffers
-- Deletes oldest-updated rows until size is under 12% (headroom)
-- Runs every 5 minutes via pg_cron
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.cache_evict()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_current BIGINT;
    v_max BIGINT;
    v_target BIGINT;
    v_deleted BIGINT := 0;
    v_batch BIGINT := 1000;
BEGIN
    -- 15% of shared_buffers
    SELECT (setting::bigint * 8192 * 0.15)::bigint
    FROM pg_settings WHERE name = 'shared_buffers'
    INTO v_max;

    -- Target: evict down to 12% (leave 3% headroom)
    v_target := (v_max * 0.80)::bigint;  -- 80% of max = 12% of shared_buffers

    SELECT pg_total_relation_size('app.cache') INTO v_current;

    -- Only evict if over limit
    IF v_current <= v_max THEN
        RETURN;
    END IF;

    -- Delete oldest-updated rows in batches until under target
    WHILE v_current > v_target LOOP
        WITH evicted AS (
            DELETE FROM app.cache
            WHERE id IN (
                SELECT id FROM app.cache
                ORDER BY updated_at ASC
                LIMIT v_batch
            )
            RETURNING 1
        )
        SELECT count(*) FROM evicted INTO v_deleted;

        -- Safety: if nothing left to delete, stop
        IF v_deleted = 0 THEN EXIT; END IF;

        SELECT pg_total_relation_size('app.cache') INTO v_current;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION app.cache_evict IS
'LRU eviction: deletes oldest-updated rows when cache exceeds 15% of shared_buffers.
Evicts down to 12% (3% headroom). Called automatically by pg_cron every 5 minutes.';

-- Schedule eviction job (every 5 minutes)
SELECT cron.schedule(
    'cache-eviction',
    '*/5 * * * *',
    $$SELECT app.cache_evict()$$
);

\echo '  cache_evict() + pg_cron job created (every 5 min)'

\echo '=== Cache table ready ==='
\echo ''
\echo 'Usage:'
\echo '  SELECT cache_set(''ns'', ''key'', ''{"value": 1}'');  -- Set'
\echo '  SELECT cache_get(''ns'', ''key'');                     -- Get'
\echo '  SELECT cache_del(''ns'', ''key'');                     -- Delete'
\echo '  SELECT cache_purge_namespace(''ns'');                  -- Purge all in ns'
\echo '  SELECT * FROM cache_size();                            -- Check size vs limit'
