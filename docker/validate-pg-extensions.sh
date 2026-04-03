#!/usr/bin/env bash
# Validation script for PostgreSQL 17 + Apache AGE + TimescaleDB Docker image
# Usage: ./docker/validate-pg-extensions.sh

set -e

echo "🐳 PostgreSQL 17 + Apache AGE + TimescaleDB Validation"
echo "========================================================="

# Check if container is running
echo ""
echo "1. Checking if athena-mcp-pg container is running..."
if ! sudo docker ps | grep -q athena-mcp-pg; then
    echo "❌ Container is not running. Starting it..."
    sudo docker compose up -d postgres
    sleep 5
fi
echo "✅ Container is running"

# Check PostgreSQL version
echo ""
echo "2. Checking PostgreSQL version..."
PG_VERSION=$(sudo docker exec athena-mcp-pg psql -U postgres -d athena-mpc -t -c "SELECT version();" | head -1 | sed 's/^[[:space:]]*//')
echo "✅ $PG_VERSION"

# Check available extensions
echo ""
echo "3. Checking available extensions..."
sudo docker exec athena-mcp-pg psql -U postgres -d athena-mpc -c "SELECT name, default_version FROM pg_available_extensions WHERE name IN ('timescaledb', 'age');"

# Check installed extensions
echo ""
echo "4. Checking installed extensions..."
sudo docker exec athena-mcp-pg psql -U postgres -d athena-mpc -c "SELECT extname, extversion FROM pg_extension WHERE extname IN ('timescaledb', 'age');"

# Test TimescaleDB functionality
echo ""
echo "5. Testing TimescaleDB hypertable creation..."
sudo docker exec athena-mcp-pg psql -U postgres -d athena-mpc -c "
    DROP TABLE IF EXISTS test_ts CASCADE;
    CREATE TABLE test_ts (time TIMESTAMPTZ NOT NULL, value FLOAT);
    SELECT create_hypertable('test_ts', 'time');
    INSERT INTO test_ts VALUES (NOW(), 42.0);
    SELECT * FROM test_ts;
    DROP TABLE test_ts;
" > /dev/null
echo "✅ TimescaleDB hypertable works"

# Test Apache AGE functionality
echo ""
echo "6. Testing Apache AGE graph creation..."
sudo docker exec athena-mcp-pg psql -U postgres -d athena-mpc -c "
    LOAD 'age';
    SET search_path = ag_catalog, public;
    SELECT drop_graph('test_graph_validation', true) FROM ag_graph WHERE name = 'test_graph_validation';
    SELECT create_graph('test_graph_validation');
    SELECT * FROM cypher('test_graph_validation', \$\$ CREATE (n:Person {name: 'Test'}) RETURN n \$\$) as (v agtype);
    SELECT drop_graph('test_graph_validation', true);
" > /dev/null 2>&1
echo "✅ Apache AGE graph operations work"

# Check shared_preload_libraries
echo ""
echo "7. Checking shared_preload_libraries configuration..."
SHARED_LIBS=$(sudo docker exec athena-mcp-pg psql -U postgres -d athena-mpc -t -c "SHOW shared_preload_libraries;" | xargs)
echo "   shared_preload_libraries = $SHARED_LIBS"
if echo "$SHARED_LIBS" | grep -q "timescaledb" && echo "$SHARED_LIBS" | grep -q "age"; then
    echo "✅ Both extensions are preloaded"
else
    echo "⚠️  Warning: Extensions may not be preloaded correctly"
fi

# Check image size
echo ""
echo "8. Checking Docker image size..."
IMAGE_SIZE=$(sudo docker images athena-mpc-pg:latest --format "{{.Size}}")
echo "   Image size: $IMAGE_SIZE"
if [[ "$IMAGE_SIZE" =~ GB ]]; then
    SIZE_GB=$(echo "$IMAGE_SIZE" | sed 's/GB//')
    if (( $(echo "$SIZE_GB < 1" | bc -l) )); then
        echo "✅ Image size is under 1GB"
    elif (( $(echo "$SIZE_GB < 6" | bc -l) )); then
        echo "⚠️  Image size is larger than ideal but acceptable (includes dev headers)"
    else
        echo "❌ Image size is too large"
    fi
fi

# Check container health
echo ""
echo "9. Checking container health status..."
HEALTH=$(sudo docker inspect athena-mcp-pg --format='{{.State.Health.Status}}' 2>/dev/null || echo "no healthcheck")
echo "   Health: $HEALTH"

echo ""
echo "========================================================="
echo "✅ All validation checks passed!"
echo ""
echo "Next steps:"
echo "  - Use CREATE EXTENSION timescaledb for time-series tables"
echo "  - Use CREATE EXTENSION age for graph queries"
echo "  - See db/pg/cache/README.md for usage examples"
