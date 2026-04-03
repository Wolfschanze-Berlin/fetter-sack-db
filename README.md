# Fetter Sack DB

High-performance PostgreSQL 17 analytics stack with automatic partitioning, vector search, graph queries, message queues, connection pooling, and a REST API — all from a single `docker compose up`.

## Architecture

```mermaid
graph TD
    Clients["Clients / Applications"]

    Clients -->|":46433 REST"| PostgREST
    Clients -->|":46434 SQL"| PgBouncer
    Clients -->|":46432 SQL (admin)"| PostgreSQL

    subgraph REST["fetter-sack-rest"]
        PostgREST["PostgREST v12.2<br/>Auto-generated REST API"]
    end

    subgraph Pool["fetter-sack-bouncer"]
        PgBouncer["PgBouncer<br/>Connection Pooler<br/>2000 clients → 150 backends"]
    end

    PostgREST --> PgBouncer
    PgBouncer --> PostgreSQL

    subgraph DB["fetter-sack-db"]
        PostgreSQL["PostgreSQL 17"]

        subgraph Extensions["15 Extensions"]
            direction LR
            partman["pg_partman<br/>Partitioning"]
            vector["pgvector<br/>Vector Search"]
            age["Apache AGE<br/>Graph DB"]
            duckdb["pg_duckdb<br/>OLAP"]
            pgmq["pgmq<br/>Queues"]
            cron["pg_cron<br/>Scheduler"]
            net["pg_net<br/>HTTP"]
            graphql["pg_graphql<br/>GraphQL"]
            hashids["pg_hashids<br/>Short IDs"]
            postgis["PostGIS<br/>Geospatial"]
        end
    end

    style Clients fill:#4a90d9,color:#fff
    style REST fill:#2ecc71,color:#fff
    style Pool fill:#e67e22,color:#fff
    style DB fill:#3498db,color:#fff
    style Extensions fill:#2c3e50,color:#fff
```

### Services

| Service | Container | Port | Purpose |
|---------|-----------|------|---------|
| PostgreSQL 17 | `fetter-sack-db` | `46432` | Database (direct access for admin, migrations, DuckDB) |
| PgBouncer | `fetter-sack-bouncer` | `46434` | Connection pooler (apps should connect here) |
| PostgREST | `fetter-sack-rest` | `46433` | Auto-generated REST API from database schema |

### Extensions (15)

| Extension | Version | Purpose |
|-----------|---------|---------|
| pg_partman | 5.4.0 | Automatic time/ID-based table partitioning |
| pg_duckdb | 1.1.0 | Embedded DuckDB OLAP engine (Parquet reads) |
| Apache AGE | 1.6.0 | Graph database with Cypher query language |
| pgvector | 0.8.1 | Vector similarity search (HNSW + IVFFlat) |
| pgmq | 1.9.0 | Lightweight message queue (SQS-like) |
| pg_cron | 1.6 | SQL-level job scheduler |
| pg_net | 0.20.2 | HTTP client from SQL |
| pg_graphql | 1.5.12 | GraphQL API from database schema |
| pg_hashids | 1.3 | Short unique IDs from integers |
| uuid-ossp | 1.1 | UUID generation (v1, v4) |
| pgcrypto | 1.3 | Cryptographic functions |
| PostGIS | 3.6.2 | Geospatial types and queries |
| RUM | 1.3 | Advanced full-text search indexes |
| pg_stat_statements | 1.11 | Query performance tracking |
| system_stats | 3.0 | OS-level system metrics from SQL |

## Quick Start

```bash
# Start everything
docker compose up -d

# Verify
docker ps --filter "name=fetter-sack"

# Connect via PgBouncer (recommended for apps)
psql postgres://postgres:postgres@localhost:46434/athena-mcp

# Connect directly (admin/migrations)
psql postgres://postgres:postgres@localhost:46432/athena-mcp

# REST API
curl http://localhost:46433/
```

### First-Time Setup

On first start, PostgreSQL automatically runs init scripts from `db/pg/cache/` that install all extensions, create schemas, configure partitioning, set up queues, and create developer tools. This takes ~30 seconds.

## Database Schemas

| Schema | Purpose |
|--------|---------|
| `public` | Default schema, helper functions, developer views |
| `api` | PostgREST endpoints (views/functions exposed as REST) |
| `app` | Application tables (hidden from REST API) |
| `analytics` | Analytical views and materialized views |
| `embeddings` | Vector embedding tables |
| `partman` | pg_partman internal configuration |
| `ag_catalog` | Apache AGE graph catalog |

## Features

### Partitioned Tables (pg_partman)

Create time-partitioned tables with one function call:

```sql
-- Create partitioned table
CREATE TABLE app.events (
    id BIGINT GENERATED ALWAYS AS IDENTITY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    event_type TEXT,
    payload JSONB
) PARTITION BY RANGE (created_at);

-- Register with pg_partman: daily partitions, 7 days ahead, 90-day retention
SELECT partman_create_daily('app.events', 'created_at', '90 days');

-- Also available:
SELECT partman_create_hourly('app.events', 'created_at', '7 days');
SELECT partman_create_monthly('app.events', 'created_at', '2 years');

-- Check status
SELECT * FROM partition_status;
```

Maintenance runs automatically via pg_cron every 30 minutes.

### Vector Search (pgvector)

Create embedding tables with comprehensive indexing:

```sql
-- Create table with HNSW index (1536-dim, cosine distance)
SELECT create_embedding_table('documents', 1536);

-- Or with custom settings
SELECT create_embedding_table('images', 768, 'l2', 32, 128);

-- For large datasets (>1M rows), use IVFFlat instead
SELECT create_embedding_table_ivfflat('large_corpus', 1536, 'cosine', 1000);

-- Insert embeddings
SELECT upsert_embedding('documents', 'doc-123', 'article', embedding_vector, 'Article about...');

-- Semantic search (vector similarity)
SELECT * FROM semantic_search('documents', query_vector, 10, 0.7);

-- Hybrid search (keyword + vector, best for RAG)
SELECT * FROM hybrid_search('documents', query_vector, 'machine learning API', 20);

-- Check index status
SELECT * FROM vector_index_status;
```

Each embedding table gets 9 indexes automatically:

| Index | Type | Purpose |
|-------|------|---------|
| HNSW (full) | ANN search | Primary vector similarity |
| HNSW (partial) | ANN search | Active rows only (`is_active=true`) |
| GIN (jsonb) | Containment | Metadata filter (`@>`) |
| GIN (tsvector) | Full-text | Content keyword search |
| BTREE (unique) | Upsert | `ON CONFLICT (source_type, source_id)` |
| BTREE (created_at) | Range | Time-based queries |
| BRIN (created_at) | Range | Large table time scans |
| BTREE (source_type) | Equality | Per-type filtering |
| PK (id) | Primary | Row identity |

### Message Queues (pgmq)

```sql
-- Pre-configured queues: tasks, events, dead_letters
SELECT mq_send('tasks', '{"action": "process", "id": 123}');
SELECT mq_send('tasks', '{"action": "notify"}', 30);  -- 30s delay

-- Read messages (visibility timeout = 60s, batch = 5)
SELECT * FROM pgmq.read('tasks', 60, 5);

-- Send failed messages to dead letter queue
SELECT mq_dead_letter('tasks', 42, 'parsing failed', original_payload);

-- Check queue status
SELECT * FROM queue_status;
```

### In-Memory Cache (UNLOGGED table)

```sql
-- Key-value cache that stays in RAM (UNLOGGED = no WAL, wiped on crash)
SELECT cache_set('session', 'user:123', '{"token": "abc"}');
SELECT cache_get('session', 'user:123');
SELECT cache_del('session', 'user:123');
SELECT cache_purge_namespace('session');

-- Monitor cache size vs 15% RAM limit
SELECT * FROM cache_size();
```

Automatic LRU eviction via pg_cron (every 5 min) when cache exceeds 15% of `shared_buffers`.

### Graph Queries (Apache AGE)

AGE is auto-loaded in every session (`session_preload_libraries`):

```sql
-- Create a graph
SELECT create_graph('fraud_network');

-- Cypher queries
SELECT * FROM cypher('fraud_network', $$
    CREATE (m1:Member {code: 'ABC', ip: '1.2.3.4'})
    CREATE (m2:Member {code: 'DEF', ip: '1.2.3.4'})
    CREATE (m1)-[:SHARES_IP]->(m2)
$$) as (result agtype);

SELECT * FROM cypher('fraud_network', $$
    MATCH (m1:Member)-[:SHARES_IP]-(m2:Member)
    RETURN m1.code, m2.code, m1.ip
$$) as (member1 agtype, member2 agtype, ip agtype);
```

### REST API (PostgREST)

Expose any table as a REST endpoint:

```sql
-- 1. Create table
CREATE TABLE app.todos (id serial, task text, done boolean default false);

-- 2. Grant permissions
GRANT SELECT ON app.todos TO anon;
GRANT ALL ON app.todos TO webuser;

-- 3. Expose via API
SELECT api_expose('app.todos');
GRANT SELECT ON api.todos TO anon;
GRANT ALL ON api.todos TO webuser;

-- 4. Reload PostgREST schema
NOTIFY pgrst, 'reload schema';
```

```bash
# Query
curl http://localhost:46433/todos

# Filter
curl "http://localhost:46433/todos?done=eq.false&order=id.desc"

# Insert (requires JWT for webuser role)
curl -X POST http://localhost:46433/todos \
  -H "Content-Type: application/json" \
  -d '{"task": "Buy milk", "done": false}'

# EXPLAIN plan (developer debugging)
curl -H "Accept: application/vnd.pgrst.plan+json" \
  http://localhost:46433/todos

# OpenAPI spec
curl http://localhost:46433/
```

**Roles**: `anon` (read-only, no JWT), `webuser` (read-write, JWT required), `authenticator` (PostgREST's login role)

### Developer Tools

Pre-built views for performance debugging:

```sql
-- Table sizes with vacuum stats
SELECT * FROM table_sizes;

-- Find unused indexes
SELECT * FROM index_usage;

-- Slowest queries (by avg time)
SELECT * FROM slow_queries;

-- Most frequently called queries
SELECT * FROM frequent_queries;

-- Queries consuming the most total time
SELECT * FROM time_consuming_queries;

-- Queries with worst cache hit ratio
SELECT * FROM cache_miss_queries;

-- Overall query performance summary
SELECT * FROM query_stats_summary;

-- Currently running queries
SELECT * FROM active_queries;

-- Lock contention (who blocks whom)
SELECT * FROM blocking_queries;

-- Database overview (size, connections, cache hit %)
SELECT * FROM db_overview;

-- All installed extensions
SELECT * FROM extensions;
```

Helper functions:

```sql
SELECT explain_json('SELECT * FROM app.my_table WHERE id = 1');  -- EXPLAIN as JSON
SELECT * FROM table_stats('app.my_table');                        -- Quick table stats
SELECT kill_query(12345);                                         -- Cancel a query by PID
SELECT reset_query_stats();                                       -- Reset pg_stat_statements
```

Safety nets (auto-configured):
- `statement_timeout = 5 min` (prevent runaway queries)
- `lock_timeout = 30s` (prevent lock contention stalls)
- `idle_in_transaction_session_timeout = 10 min` (prevent abandoned transactions)

## Configuration

### PostgreSQL (65GB container)

| Setting | Value | Purpose |
|---------|-------|---------|
| `shared_buffers` | 16 GB | 25% of container RAM |
| `effective_cache_size` | 48 GB | 75% of RAM |
| `work_mem` | 512 MB | Per-operation sort/hash |
| `maintenance_work_mem` | 4 GB | VACUUM, CREATE INDEX |
| `max_connections` | 300 | Connection ceiling |
| `max_worker_processes` | 24 | Background workers |
| `max_parallel_workers_per_gather` | 8 | Per-query parallelism |
| `synchronous_commit` | off | 3-5x write speedup |
| `wal_compression` | zstd | Compressed WAL |
| `jit` | on | JIT compilation for complex queries |
| `random_page_cost` | 1.1 | SSD-optimized planner |

### PgBouncer

| Setting | Value | Purpose |
|---------|-------|---------|
| `pool_mode` | transaction | Release backend after each txn |
| `default_pool_size` | 40 | Connections per user/db |
| `min_pool_size` | 10 | Pre-warmed connections |
| `max_client_conn` | 2000 | Max client connections |
| `max_db_connections` | 150 | Max actual PG connections |
| `server_reset_query` | DISCARD ALL | Clean state between txns |
| Wildcard `*` database | all | All DBs/schemas accessible |

### PostgREST

| Setting | Value | Purpose |
|---------|-------|---------|
| `db_schemas` | api | Exposed schema |
| `db_anon_role` | anon | Unauthenticated role |
| `db_prepared_statements` | false | Required for PgBouncer txn mode |
| `db_aggregates_enabled` | true | count(), avg(), sum() in queries |
| `db_plan_enabled` | true | EXPLAIN via Accept header |
| `db_channel_enabled` | true | Auto-reload on NOTIFY |
| `jwt_cache_max_lifetime` | 300s | Cache validated JWTs |

## Project Structure

```
fetter-sack-db/
+-- compose.yml                        # All services: PG + PgBouncer + PostgREST
+-- docker/
|   +-- Dockerfile.pg-analytics-stack  # Custom PG image (9 extensions from source)
|   +-- validate-pg-extensions.sh      # Extension smoke tests
|   +-- README.md                      # Docker-specific docs
|   +-- pgbouncer/
|       +-- pgbouncer.ini              # PgBouncer config
|       +-- userlist.txt               # Auth credentials
+-- db/pg/cache/                       # Init scripts (run on first start)
|   +-- 00-extensions.sql              # Install all 15 extensions
|   +-- 01-schemas.sql                 # Create schemas + search_path
|   +-- 01y-postgrest.sql              # PostgREST roles + API schema
|   +-- 01z-cache-table.sql            # UNLOGGED cache table + helpers
|   +-- 02-partman.sql                 # pg_partman config + helper functions
|   +-- 03-pgmq.sql                    # Message queues + helpers
|   +-- 04-vector.sql                  # pgvector config + HNSW/IVFFlat helpers
|   +-- 05-dev-tools.sql               # Developer views + functions
+-- bench/                             # Go benchmark tool
    +-- main.go                        # Full-stack benchmark (13 tests)
    +-- fetter-bench.exe               # Compiled binary
```

## Benchmarks

Run the Go benchmark tool:

```bash
cd bench

# Quick run (5s per test, 10 goroutines)
go run . -c 10 -d 5s

# Heavy load
go run . -c 50 -d 30s -seed 50000

# JSON output
go run . -c 10 -d 5s -json > report.json
```

Sample results (Docker Desktop, 10 concurrent, 5s per test):

| Test | ops/sec | p50 | p99 |
|------|---------|-----|-----|
| INSERT (single row) | 12.2K | 527us | 1.4ms |
| SELECT (point lookup) | 14.7K | 523us | 1.5ms |
| PARTITION INSERT (daily) | 11.2K | 525us | 1.3ms |
| PARTITION QUERY (1-day) | 3.4K | 1.6ms | 3.2ms |
| VECTOR INSERT (384-dim) | 2.0K | 3.1ms | 6.6ms |
| VECTOR SEARCH (HNSW top-10) | 3.3K | 1.6ms | 3.9ms |
| CACHE SET (UNLOGGED) | 9.5K | 532us | 1.5ms |
| CACHE GET (UNLOGGED) | 14.2K | 525us | 1.3ms |
| PGMQ SEND | 9.9K | 542us | 1.6ms |
| REST GET (PostgREST) | 2.6K | 3.2ms | 10ms |
| Direct PG (SELECT 1) | 13.3K | 519us | 1.4ms |
| PgBouncer (SELECT 1) | 5.5K | 1.1ms | 2.2ms |
| PgBouncer (real query) | 745 | 8.5ms | 12ms |

PgBouncer adds overhead on trivial queries but matches or beats direct connections on real-world queries. Its primary value is connection multiplexing (2000 clients into 150 backends) and connection storm resilience.

## Building the Docker Image

The image builds 9 extensions from source in parallel using BuildKit:

```bash
# Build
DOCKER_BUILDKIT=1 docker build -t fetter-sack-db:latest \
  -f docker/Dockerfile.pg-analytics-stack docker/

# Or via compose
docker compose build postgres
```

Cold build: ~10-15 min. Warm rebuild: ~3-5 min (BuildKit caching + ccache).

## Operations

### Reset database (full wipe)

```bash
docker compose down -v && docker compose up -d
```

### View logs

```bash
docker logs fetter-sack-db        # PostgreSQL
docker logs fetter-sack-bouncer   # PgBouncer
docker logs fetter-sack-rest      # PostgREST
```

### Reload PostgREST schema (after DDL changes)

```sql
NOTIFY pgrst, 'reload schema';
```

### PgBouncer stats

```bash
# Connect to pgbouncer admin console
psql -U postgres -h localhost -p 46434 pgbouncer -c "SHOW POOLS;"
psql -U postgres -h localhost -p 46434 pgbouncer -c "SHOW STATS;"
```

### Validate extensions

```bash
./docker/validate-pg-extensions.sh
```
