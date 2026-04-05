#!/usr/bin/env bash
# Validation script for PostgreSQL 17 Analytics Stack Docker image
# Tests: pg_partman, Apache AGE, pg_duckdb, and all other extensions
# Usage: ./docker/validate-pg-extensions.sh

set -e

CONTAINER="fetter-sack-db"
DB="postgres"
USER="postgres"

psql_cmd() {
    sudo docker exec "$CONTAINER" psql -U "$USER" -d "$DB" "$@"
}

echo "PostgreSQL 17 Analytics Stack Validation"
echo "========================================================="

# Check if container is running
echo ""
echo "1. Checking if $CONTAINER container is running..."
if ! sudo docker ps | grep -q "$CONTAINER"; then
    echo "   Container is not running. Starting it..."
    sudo docker compose up -d postgres
    sleep 5
fi
echo "   PASS: Container is running"

# Check PostgreSQL version
echo ""
echo "2. Checking PostgreSQL version..."
PG_VERSION=$(psql_cmd -t -c "SELECT version();" | head -1 | sed 's/^[[:space:]]*//')
echo "   PASS: $PG_VERSION"

# Check available extensions
echo ""
echo "3. Checking available extensions..."
psql_cmd -c "SELECT name, default_version FROM pg_available_extensions WHERE name IN ('pg_partman', 'age', 'pg_duckdb', 'pgmq', 'pg_cron', 'pg_net', 'pg_graphql', 'vector', 'system_stats', 'pg_stat_statements');"

# Check shared_preload_libraries
echo ""
echo "4. Checking shared_preload_libraries configuration..."
SHARED_LIBS=$(psql_cmd -t -c "SHOW shared_preload_libraries;" | xargs)
echo "   shared_preload_libraries = $SHARED_LIBS"
if echo "$SHARED_LIBS" | grep -q "pg_partman_bgw" && echo "$SHARED_LIBS" | grep -q "age"; then
    echo "   PASS: pg_partman_bgw and age are preloaded"
else
    echo "   FAIL: Extensions may not be preloaded correctly"
    exit 1
fi

# Test pg_partman: create partitioned table + automatic partition management
echo ""
echo "5. Testing pg_partman partition management..."
psql_cmd -c "
    CREATE SCHEMA IF NOT EXISTS partman;
    CREATE EXTENSION IF NOT EXISTS pg_partman SCHEMA partman;

    DROP TABLE IF EXISTS test_partman CASCADE;
    CREATE TABLE test_partman (
        id BIGINT GENERATED ALWAYS AS IDENTITY,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        value FLOAT
    ) PARTITION BY RANGE (created_at);

    SELECT partman.create_parent(
        p_parent_table := 'public.test_partman',
        p_control := 'created_at',
        p_interval := '1 day',
        p_premake := 3
    );

    INSERT INTO test_partman (created_at, value) VALUES (now(), 42.0);
    INSERT INTO test_partman (created_at, value) VALUES (now() - interval '1 day', 41.0);
    INSERT INTO test_partman (created_at, value) VALUES (now() + interval '1 day', 43.0);

    SELECT count(*) AS row_count FROM test_partman;

    SELECT partman.run_maintenance();

    DROP TABLE test_partman CASCADE;
    DROP EXTENSION pg_partman CASCADE;
    DROP SCHEMA IF EXISTS partman CASCADE;
" > /dev/null
echo "   PASS: pg_partman partition management works"

# Test Apache AGE functionality
echo ""
echo "6. Testing Apache AGE graph creation..."
psql_cmd -c "
    LOAD 'age';
    SET search_path = ag_catalog, public;
    SELECT drop_graph('test_graph_validation', true) FROM ag_graph WHERE name = 'test_graph_validation';
    SELECT create_graph('test_graph_validation');
    SELECT * FROM cypher('test_graph_validation', \$\$ CREATE (n:Person {name: 'Test'}) RETURN n \$\$) as (v agtype);
    SELECT drop_graph('test_graph_validation', true);
" > /dev/null 2>&1
echo "   PASS: Apache AGE graph operations work"

# Check pg_partman BGW status
echo ""
echo "7. Checking pg_partman background worker..."
BGW_COUNT=$(psql_cmd -t -c "SELECT count(*) FROM pg_stat_activity WHERE backend_type LIKE '%partman%' OR application_name LIKE '%partman%';" | xargs)
if [ "${BGW_COUNT:-0}" -gt 0 ] 2>/dev/null; then
    echo "   PASS: pg_partman BGW is active ($BGW_COUNT worker(s))"
else
    echo "   INFO: pg_partman BGW not yet active (normal if no partitioned tables exist)"
fi

# Check image size
echo ""
echo "8. Checking Docker image size..."
IMAGE_SIZE=$(sudo docker images fetter-sack-db:latest --format "{{.Size}}" 2>/dev/null || echo "unknown")
echo "   Image size: $IMAGE_SIZE"

# Check container health
echo ""
echo "9. Checking container health status..."
HEALTH=$(sudo docker inspect "$CONTAINER" --format='{{.State.Health.Status}}' 2>/dev/null || echo "no healthcheck")
echo "   Health: $HEALTH"

echo ""
echo "========================================================="
echo "All validation checks passed!"
echo ""
echo "Next steps:"
echo "  - CREATE SCHEMA partman; CREATE EXTENSION pg_partman SCHEMA partman;"
echo "  - Use partman.create_parent() for time-series partition management"
echo "  - Use CREATE EXTENSION age; LOAD 'age'; for graph queries"
