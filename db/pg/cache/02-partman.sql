-- 02-partman.sql
-- pg_partman configuration, helper functions, and automated maintenance.
-- Assumes: pg_partman extension exists (00), partman schema exists (01).

\echo '=== Configuring pg_partman ==='

-- ---------------------------------------------------------------------------
-- pg_cron job: run partition maintenance every 30 minutes
-- This creates future partitions and drops expired ones per retention policy.
-- The BGW (pg_partman_bgw) also runs maintenance on its own interval (1h),
-- but pg_cron gives us more control and visibility via cron.job_run_details.
-- ---------------------------------------------------------------------------
SELECT cron.schedule(
    'partman-maintenance',
    '*/30 * * * *',
    $$SELECT partman.run_maintenance(p_analyze := false)$$
);
\echo '  pg_cron maintenance job scheduled (every 30 min)'

-- ---------------------------------------------------------------------------
-- Helper: create a time-partitioned table with sane defaults
-- Usage:
--   SELECT partman_create_daily('app.events', 'created_at');
--   SELECT partman_create_daily('app.events', 'created_at', '7 days', 30);
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.partman_create_daily(
    p_table TEXT,
    p_time_column TEXT,
    p_retention TEXT DEFAULT NULL,
    p_premake INTEGER DEFAULT 7
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    -- Register with pg_partman
    PERFORM partman.create_parent(
        p_parent_table := p_table,
        p_control := p_time_column,
        p_interval := '1 day',
        p_premake := p_premake
    );

    -- Set retention if specified
    IF p_retention IS NOT NULL THEN
        UPDATE partman.part_config
        SET retention = p_retention,
            retention_keep_table = false,
            retention_keep_index = false
        WHERE parent_table = p_table;
    END IF;

    -- Run initial maintenance to create partitions
    PERFORM partman.run_maintenance(p_parent_table := p_table);
END;
$$;

COMMENT ON FUNCTION public.partman_create_daily IS
'Register a PARTITION BY RANGE table with pg_partman for daily partitions.
Creates future partitions (default 7 days ahead) and optionally sets retention.
Table must already exist with PARTITION BY RANGE(time_column).';

\echo '  partman_create_daily() helper function created'

-- ---------------------------------------------------------------------------
-- Helper: create hourly partitions (for high-volume tables)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.partman_create_hourly(
    p_table TEXT,
    p_time_column TEXT,
    p_retention TEXT DEFAULT NULL,
    p_premake INTEGER DEFAULT 48
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM partman.create_parent(
        p_parent_table := p_table,
        p_control := p_time_column,
        p_interval := '1 hour',
        p_premake := p_premake
    );

    IF p_retention IS NOT NULL THEN
        UPDATE partman.part_config
        SET retention = p_retention,
            retention_keep_table = false,
            retention_keep_index = false
        WHERE parent_table = p_table;
    END IF;

    PERFORM partman.run_maintenance(p_parent_table := p_table);
END;
$$;

COMMENT ON FUNCTION public.partman_create_hourly IS
'Register a PARTITION BY RANGE table with pg_partman for hourly partitions.
Creates future partitions (default 48 hours ahead) and optionally sets retention.';

\echo '  partman_create_hourly() helper function created'

-- ---------------------------------------------------------------------------
-- Helper: create monthly partitions (for slow-growing tables)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.partman_create_monthly(
    p_table TEXT,
    p_time_column TEXT,
    p_retention TEXT DEFAULT NULL,
    p_premake INTEGER DEFAULT 3
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM partman.create_parent(
        p_parent_table := p_table,
        p_control := p_time_column,
        p_interval := '1 month',
        p_premake := p_premake
    );

    IF p_retention IS NOT NULL THEN
        UPDATE partman.part_config
        SET retention = p_retention,
            retention_keep_table = false,
            retention_keep_index = false
        WHERE parent_table = p_table;
    END IF;

    PERFORM partman.run_maintenance(p_parent_table := p_table);
END;
$$;

COMMENT ON FUNCTION public.partman_create_monthly IS
'Register a PARTITION BY RANGE table with pg_partman for monthly partitions.
Creates future partitions (default 3 months ahead) and optionally sets retention.';

\echo '  partman_create_monthly() helper function created'

-- ---------------------------------------------------------------------------
-- View: partition overview — see all managed tables and their config at a glance
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.partition_status AS
SELECT
    pc.parent_table,
    pc.control,
    pc.partition_interval,
    pc.premake,
    pc.retention,
    pc.datetime_string,
    (SELECT count(*) FROM partman.show_partitions(pc.parent_table)) AS partition_count,
    pc.automatic_maintenance
FROM partman.part_config pc
ORDER BY pc.parent_table;

COMMENT ON VIEW public.partition_status IS
'Overview of all pg_partman-managed partitioned tables with config and partition counts.';

\echo '  partition_status view created'

\echo '=== pg_partman configured ==='
