# Docker Images

## PostgreSQL 17 Analytics Stack

Custom PostgreSQL image combining **time-series**, **graph database**, and **columnar analytics** capabilities.

### Features

| Component | Version | Purpose |
|-----------|---------|---------|
| PostgreSQL | 17.7 | Base database system |
| TimescaleDB | 2.25.0 | Time-series hypertables, compression, continuous aggregates |
| Apache AGE | 1.6.0 | Graph queries via Cypher for fraud link detection |
| pg_mooncake | 0.2.0 | Columnar analytics via DuckDB, Apache Iceberg export |
| pg_duckdb | 1.0.0 | DuckDB integration (bundled with pg_mooncake) |
| postgres_fdw | 1.1 | Foreign Data Wrapper for remote PostgreSQL connections |
| pgmq | 1.9.0 | Lightweight message queue (like AWS SQS on Postgres) |

### Build

```bash
# From project root
docker compose build postgres

# Or directly
docker build -t athena-mpc-pg:latest -f docker/Dockerfile.pg-age-timescale docker/
```

**Build time**: ~5 minutes (includes compilation of Apache AGE from source)

**Image size**: ~2GB

### Run

```bash
# Start container via docker compose (recommended)
docker compose up -d postgres

# Or standalone
docker run -d \
  -p 46432:5432 \
  -e POSTGRES_DB=athena-mpc \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -v pg_data:/var/lib/postgresql/data \
  --shm-size=512mb \
  --name athena-mcp-pg \
  athena-mpc-pg:latest
```

### Validation

Run comprehensive tests:

```bash
./docker/validate-pg-extensions.sh
```

Or manually:

```bash
# Check extensions are available
docker exec athena-mcp-pg psql -U postgres -d athena-mpc -c \
  "SELECT name, default_version FROM pg_available_extensions
   WHERE name IN ('timescaledb', 'age', 'pg_mooncake', 'pg_duckdb');"

# Create all extensions (in order!)
docker exec athena-mcp-pg psql -U postgres -d athena-mpc -c \
  "CREATE EXTENSION IF NOT EXISTS timescaledb;
   CREATE EXTENSION IF NOT EXISTS age;
   CREATE EXTENSION IF NOT EXISTS pg_mooncake CASCADE;"
```

### Extension Installation Order

**IMPORTANT**: Extensions must be installed in this order to avoid conflicts:

```sql
-- 1. TimescaleDB first (claims time_bucket function)
CREATE EXTENSION IF NOT EXISTS timescaledb;

-- 2. Apache AGE second
CREATE EXTENSION IF NOT EXISTS age;
LOAD 'age';
SET search_path = ag_catalog, public;

-- 3. pg_mooncake last (auto-installs pg_duckdb)
CREATE EXTENSION IF NOT EXISTS pg_mooncake CASCADE;
-- Note: pg_mooncake will use duckdb.time_bucket instead

-- 4. pgmq for message queues
CREATE EXTENSION IF NOT EXISTS pgmq;
```

### Usage Examples

#### TimescaleDB: Time-Series Cache

```sql
-- Create partitioned cache table
CREATE TABLE athena_daily_metrics (
    time TIMESTAMPTZ NOT NULL,
    membercode TEXT,
    stake_amount DECIMAL(18,4),
    winlost_amount DECIMAL(18,4)
);

-- Convert to hypertable (partitions by time)
SELECT create_hypertable('athena_daily_metrics', 'time');

-- Enable compression
ALTER TABLE athena_daily_metrics SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'membercode'
);

-- Auto-compress data older than 1 day
SELECT add_compression_policy('athena_daily_metrics', INTERVAL '1 day');
```

#### Apache AGE: Fraud Link Detection

```sql
-- Load AGE extension
LOAD 'age';
SET search_path = ag_catalog, public;

-- Create fraud investigation graph
SELECT create_graph('fraud_network');

-- Create member nodes with shared IP relationships
SELECT * FROM cypher('fraud_network', $$
    CREATE (m1:Member {code: 'ABC123', ip: '1.2.3.4'})
    CREATE (m2:Member {code: 'DEF456', ip: '1.2.3.4'})
    CREATE (m1)-[:SHARES_IP]->(m2)
$$) as (result agtype);

-- Find all members sharing IPs (potential multi-accounting)
SELECT * FROM cypher('fraud_network', $$
    MATCH (m1:Member)-[:SHARES_IP]-(m2:Member)
    RETURN m1.code, m2.code, m1.ip
$$) as (member1 agtype, member2 agtype, shared_ip agtype);
```

#### pg_mooncake: Columnar Analytics

```sql
-- Create columnstore table (uses DuckDB engine for queries)
CREATE TABLE analytics_events (
    event_id BIGINT,
    member_code TEXT,
    event_type TEXT,
    created_at TIMESTAMPTZ,
    payload JSONB
) USING mooncake;

-- Note: For data operations, pg_mooncake requires Iceberg storage
-- Configure with S3/MinIO for production use

-- Fast analytical queries (powered by DuckDB)
SELECT
    member_code,
    COUNT(*) as event_count,
    COUNT(DISTINCT event_type) as unique_events
FROM analytics_events
WHERE created_at >= NOW() - INTERVAL '7 days'
GROUP BY member_code
ORDER BY event_count DESC
LIMIT 100;

-- Use DuckDB's time_bucket if TimescaleDB is installed
SELECT
    duckdb.time_bucket('1 hour', created_at) as hour,
    COUNT(*) as events
FROM analytics_events
GROUP BY 1
ORDER BY 1;
```

#### postgres_fdw: Remote PostgreSQL Access

```sql
-- Create FDW extension
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- Define connection to remote PostgreSQL server
CREATE SERVER remote_warehouse
    FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'warehouse.example.com', port '5432', dbname 'analytics');

-- Map local user to remote credentials
CREATE USER MAPPING FOR postgres
    SERVER remote_warehouse
    OPTIONS (user 'readonly_user', password 'secret');

-- Import a specific table from remote server
CREATE FOREIGN TABLE remote_daily_metrics (
    time TIMESTAMPTZ,
    membercode TEXT,
    stake_amount DECIMAL(18,4)
)
SERVER remote_warehouse
OPTIONS (schema_name 'public', table_name 'daily_metrics');

-- Or import entire schema
IMPORT FOREIGN SCHEMA public
    LIMIT TO (daily_metrics, member_profiles)
    FROM SERVER remote_warehouse
    INTO local_schema;

-- Query remote data as if it's local
SELECT membercode, SUM(stake_amount)
FROM remote_daily_metrics
WHERE time >= NOW() - INTERVAL '7 days'
GROUP BY membercode;
```

#### pgmq: Message Queue

```sql
-- Create extension
CREATE EXTENSION IF NOT EXISTS pgmq;

-- Create a queue for investigation tasks
SELECT pgmq.create('investigation_tasks');

-- Send a message (returns message ID)
SELECT pgmq.send(
    'investigation_tasks',
    '{"task": "investigate_member", "membercode": "ABC123", "priority": "high"}'
);

-- Read messages (visibility timeout 60 seconds, batch size 5)
SELECT * FROM pgmq.read('investigation_tasks', 60, 5);

-- Archive a processed message
SELECT pgmq.archive('investigation_tasks', 1);

-- Delete a message permanently
SELECT pgmq.delete('investigation_tasks', 1);

-- Create a FIFO queue (strict ordering)
SELECT pgmq.create('fifo_queue', is_fifo => true);

-- Send with delay (message visible after 30 seconds)
SELECT pgmq.send('investigation_tasks', '{"delayed": true}', delay => 30);

-- Purge all messages from a queue
SELECT pgmq.purge_queue('investigation_tasks');

-- List all queues
SELECT * FROM pgmq.list_queues();

-- Drop a queue
SELECT pgmq.drop_queue('investigation_tasks');
```

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                 PostgreSQL 17 Analytics Stack                    │
│                      (athena-mcp-pg)                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐  ┌───────────────┐  ┌────────────────────┐   │
│  │ TimescaleDB  │  │  Apache AGE   │  │   pg_mooncake      │   │
│  │   2.25.0     │  │    1.6.0      │  │      0.2.0         │   │
│  ├──────────────┤  ├───────────────┤  ├────────────────────┤   │
│  │ Hypertables  │  │ Graph Queries │  │ Columnar Storage   │   │
│  │ Compression  │  │ Cypher DSL    │  │ DuckDB Engine      │   │
│  │ Continuous   │  │ Link Analysis │  │ Iceberg Export     │   │
│  │ Aggregates   │  │               │  │ OLAP Analytics     │   │
│  └──────────────┘  └───────────────┘  └────────────────────┘   │
│         │                 │                    │                │
│         └─────────────────┼────────────────────┘                │
│                           ▼                                      │
│                 PostgreSQL 17.7 Core                             │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
                           │
        ┌──────────────────┼──────────────────┐
        ▼                  ▼                  ▼
  ┌───────────┐     ┌───────────┐     ┌────────────┐
  │ Time-Series│     │  Fraud    │     │ Analytics  │
  │  Cache    │     │  Graphs   │     │ Data Lake  │
  └───────────┘     └───────────┘     └────────────┘
```

### Configuration

**Environment Variables**:
- `POSTGRES_DB=athena-mpc` - Database name
- `POSTGRES_USER=postgres` - Superuser name
- `POSTGRES_PASSWORD=postgres` - Superuser password
- `POSTGRES_SHARED_PRELOAD_LIBRARIES=timescaledb,age,pg_duckdb,pg_mooncake` - Auto-load extensions
- `DUCKDB_ALLOW_COMMUNITY_EXTENSIONS=true` - Enable DuckDB extensions

**Resource Limits** (in compose.yml):
- Memory: 4GB limit, 1GB reservation
- Shared memory: 512MB (required for DuckDB + AGE operations)

**Port**: 46432 (host) → 5432 (container)

**Volume**: `pg_data` mounted to `/var/lib/postgresql/data`

### Known Limitations

1. **time_bucket conflict**: Both TimescaleDB and pg_duckdb define `time_bucket()`. When both are installed, use `duckdb.time_bucket()` for DuckDB queries.

2. **JSONB in pg_mooncake**: pg_mooncake has limited JSONB support due to DuckDB type system differences. Simple arrays work, nested structures may not.

3. **Iceberg storage required**: pg_mooncake columnstore tables require S3/MinIO for data operations. Table DDL works without storage, but INSERT/SELECT needs Iceberg config.

4. **Moonlink service**: pg_mooncake runs a background Moonlink service for replication. Check logs for `Moonlink service started successfully`.

### Troubleshooting

#### Extensions not available

```bash
# Check preload libraries
docker exec athena-mcp-pg psql -U postgres -d athena-mpc -c \
  "SHOW shared_preload_libraries;"

# Should show: timescaledb,age,pg_duckdb,pg_mooncake
```

#### AGE graph operations fail

```sql
-- Ensure AGE is loaded in session
LOAD 'age';
SET search_path = ag_catalog, public;

-- Then run graph queries
```

#### pg_mooncake INSERT fails

Check if Iceberg storage is configured:

```sql
-- Verify mooncake settings
SELECT name, setting FROM pg_settings WHERE name LIKE 'mooncake%';
```

For local testing without S3, use regular heap tables and DuckDB for analytics:

```sql
-- Use DuckDB to query regular tables
SELECT * FROM duckdb.read_parquet('/path/to/file.parquet');
```

#### Out of shared memory

Increase `shm_size` in compose.yml:

```yaml
services:
  postgres:
    shm_size: '1gb'  # Increase from 512mb
```

#### Container fails to start

Check logs for Moonlink service errors:

```bash
docker logs athena-mcp-pg 2>&1 | grep -i moonlink
```

### References

- **Apache AGE**: https://age.apache.org/
- **TimescaleDB**: https://docs.timescale.com/
- **pg_mooncake**: https://github.com/Mooncake-Labs/pg_mooncake
- **pg_duckdb**: https://github.com/duckdb/pg_duckdb
- **PostgreSQL 17**: https://www.postgresql.org/docs/17/
- **Project docs**: `/home/francis/rnd-athena-mcp/db/pg/cache/README.md`
