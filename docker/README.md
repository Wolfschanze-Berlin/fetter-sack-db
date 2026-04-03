# Docker Images

## PostgreSQL 17 Analytics Stack

Custom PostgreSQL image combining **partition management**, **graph database**, and **columnar analytics** capabilities.

### Features

| Component | Version | Purpose |
|-----------|---------|---------|
| PostgreSQL | 17 | Base database system |
| pg_duckdb | 1.1.x | Embedded DuckDB OLAP engine (DuckDB 1.4.3) |
| pg_partman | 5.4.0 | Automatic time/id-based partition management |
| Apache AGE | 1.6.0 | Graph queries via Cypher |
| pgmq | 1.9.0 | Lightweight message queue (like AWS SQS on Postgres) |
| pg_cron | 1.6.7 | Job scheduler (cron syntax from SQL) |
| pg_net | 0.20.2 | HTTP client from SQL |
| pg_graphql | 1.5.12 | GraphQL API |
| pgvector | 0.8.1 | Vector similarity search |
| system_stats | 3.2 | OS-level system metrics from SQL |
| PostGIS | 3 | Geospatial |
| RUM | - | Full-text search index |

### Build

```bash
# From project root (BuildKit required)
docker compose build postgres

# Or directly
DOCKER_BUILDKIT=1 docker build -t fetter-sack-db:latest \
  -f docker/Dockerfile.pg-analytics-stack docker/
```

**Build time**: ~15 min cold, ~3-5 min warm (BuildKit parallel stages + ccache)

### Run

```bash
# Start container via docker compose (recommended)
docker compose up -d postgres

# Or standalone
docker run -d \
  -p 46432:5432 \
  -e POSTGRES_DB=athena-mcp \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -v pg_data:/home/postgres/pgdata \
  --shm-size=20gb \
  --name fetter-sack-db \
  fetter-sack-db:latest
```

### Validation

Run comprehensive tests:

```bash
./docker/validate-pg-extensions.sh
```

Or manually:

```bash
# Check extensions are available
docker exec fetter-sack-db psql -U postgres -d athena-mcp -c \
  "SELECT name, default_version FROM pg_available_extensions
   WHERE name IN ('pg_partman', 'age', 'pg_duckdb', 'pgmq', 'pg_cron',
                  'pg_net', 'pg_graphql', 'vector', 'system_stats');"
```

### Extension Installation Order

```sql
-- 1. pg_partman (partition management with BGW)
CREATE SCHEMA IF NOT EXISTS partman;
CREATE EXTENSION IF NOT EXISTS pg_partman SCHEMA partman;

-- 2. Apache AGE (graph database)
CREATE EXTENSION IF NOT EXISTS age;
LOAD 'age';
SET search_path = ag_catalog, public;

-- 3. pg_duckdb (embedded OLAP)
CREATE EXTENSION IF NOT EXISTS pg_duckdb;

-- 4. pgmq (message queues)
CREATE EXTENSION IF NOT EXISTS pgmq;

-- 5. pg_cron (job scheduler)
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- 6. pg_net (HTTP client)
CREATE EXTENSION IF NOT EXISTS pg_net;

-- 7. pg_graphql (GraphQL API)
CREATE EXTENSION IF NOT EXISTS pg_graphql;

-- 8. pgvector (vector search)
CREATE EXTENSION IF NOT EXISTS vector;

-- 9. system_stats (OS metrics)
CREATE EXTENSION IF NOT EXISTS system_stats;
```

### Usage Examples

#### pg_partman: Time-Series Partition Management

```sql
-- Setup
CREATE SCHEMA IF NOT EXISTS partman;
CREATE EXTENSION IF NOT EXISTS pg_partman SCHEMA partman;

-- Create partitioned table
CREATE TABLE daily_metrics (
    id BIGINT GENERATED ALWAYS AS IDENTITY,
    time TIMESTAMPTZ NOT NULL,
    membercode TEXT,
    stake_amount DECIMAL(18,4),
    winlost_amount DECIMAL(18,4)
) PARTITION BY RANGE (time);

-- Let pg_partman manage daily partitions (pre-create 7 days ahead)
SELECT partman.create_parent(
    p_parent_table := 'public.daily_metrics',
    p_control := 'time',
    p_interval := '1 day',
    p_premake := 7
);

-- Set retention policy (drop partitions older than 90 days)
UPDATE partman.part_config
SET retention = '90 days',
    retention_keep_table = false
WHERE parent_table = 'public.daily_metrics';

-- Run maintenance manually (BGW does this automatically)
SELECT partman.run_maintenance();

-- Check partition info
SELECT * FROM partman.show_partitions('public.daily_metrics');
```

#### Apache AGE: Graph Queries

```sql
LOAD 'age';
SET search_path = ag_catalog, public;

-- Create graph
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

#### pgmq: Message Queue

```sql
CREATE EXTENSION IF NOT EXISTS pgmq;

-- Create a queue
SELECT pgmq.create('investigation_tasks');

-- Send a message
SELECT pgmq.send(
    'investigation_tasks',
    '{"task": "investigate_member", "membercode": "ABC123", "priority": "high"}'
);

-- Read messages (visibility timeout 60s, batch 5)
SELECT * FROM pgmq.read('investigation_tasks', 60, 5);

-- Archive processed message
SELECT pgmq.archive('investigation_tasks', 1);
```

### Architecture

```
+-----------------------------------------------------------+
|              PostgreSQL 17 Analytics Stack                  |
|                    (fetter-sack-db)                          |
+-----------------------------------------------------------+
|                                                             |
|  +-------------+  +--------------+  +------------------+   |
|  | pg_partman  |  | Apache AGE   |  | pg_duckdb        |   |
|  |   5.4.0     |  |   1.6.0      |  |   1.1.x          |   |
|  +-------------+  +--------------+  +------------------+   |
|  | Declarative |  | Graph Queries|  | Embedded OLAP    |   |
|  | Partitions  |  | Cypher DSL   |  | Parquet Reads    |   |
|  | Auto-Maint  |  | Link Analysis|  | Analytics        |   |
|  +-------------+  +--------------+  +------------------+   |
|        |                |                  |                |
|        +----------------+------------------+                |
|                         v                                   |
|                PostgreSQL 17 Core                           |
|  + pgmq + pg_cron + pg_net + pgvector + pg_graphql          |
|  + system_stats + PostGIS + RUM + pg_stat_statements       |
+-----------------------------------------------------------+
```

### Configuration

**Environment Variables** (see compose.yml for full list):
- `POSTGRES_DB=athena-mcp` - Database name
- `POSTGRES_USER=postgres` - Superuser name
- `POSTGRES_PASSWORD=postgres` - Superuser password
- `POSTGRES_SHARED_PRELOAD_LIBRARIES=pg_partman_bgw,pg_stat_statements,age,pg_duckdb,pg_cron,pg_net`

**pg_partman BGW settings**:
- `pg_partman_bgw.interval=3600` - Run maintenance every hour (seconds)
- `pg_partman_bgw.dbname='athena-mcp'` - Target database

**Port**: 46432 (host) -> 5432 (container)

**Volume**: `pg_data` mounted to `/home/postgres/pgdata`

### Troubleshooting

#### Extensions not available

```bash
docker exec fetter-sack-db psql -U postgres -d athena-mcp -c \
  "SHOW shared_preload_libraries;"
# Should show: pg_partman_bgw,age,pg_duckdb,pg_cron,pg_net,...
```

#### AGE graph operations fail

```sql
-- Ensure AGE is loaded in session
LOAD 'age';
SET search_path = ag_catalog, public;
```

#### Out of shared memory

Increase `shm_size` in compose.yml (default 20gb for the 65GB container config).

### References

- **pg_partman**: https://github.com/pgpartman/pg_partman
- **Apache AGE**: https://age.apache.org/
- **pg_duckdb**: https://github.com/duckdb/pg_duckdb
- **pgmq**: https://github.com/tembo-io/pgmq
- **PostgreSQL 17**: https://www.postgresql.org/docs/17/
