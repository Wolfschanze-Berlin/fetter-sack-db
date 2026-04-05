-- 04-vector.sql
-- pgvector configuration, embedding infrastructure, and comprehensive indexing.
-- Assumes: vector extension already created (00-extensions.sql).
--
-- Index strategy:
--   HNSW    — primary ANN index on embedding column (fast queries, higher memory)
--   GIN     — metadata JSONB containment queries (@>)
--   GIN     — content full-text search (tsvector)
--   BTREE   — source lookups, time range queries, common metadata fields
--   BRIN    — created_at for time-range partition pruning on large tables
--   PARTIAL — optional filtered HNSW for active-only rows

\echo '=== Configuring pgvector ==='

-- ---------------------------------------------------------------------------
-- Embedding storage schema
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS embeddings;
COMMENT ON SCHEMA embeddings IS 'Vector embeddings storage for semantic search and RAG';

ALTER ROLE postgres SET search_path = public, app, analytics, embeddings, partman, ag_catalog;

\echo '  embeddings schema created'

-- ---------------------------------------------------------------------------
-- Performance tuning for vector operations
-- ---------------------------------------------------------------------------

-- HNSW search quality: higher ef_search = better recall, slower queries
-- 40 (default) -> 100 (production) -> 200 (high-recall RAG)
ALTER DATABASE postgres SET hnsw.ef_search = 100;

-- IVFFlat probe count: higher = better recall on IVFFlat indexes
-- Only matters if you use IVFFlat (large tables, memory-constrained)
ALTER DATABASE postgres SET ivfflat.probes = 10;

-- Increase maintenance_work_mem for index builds (session-level override)
-- Larger = faster HNSW/IVFFlat builds. 2GB is good for million-row tables.
-- The compose.yml global is 4GB which is fine; this is a safety net.
\echo '  hnsw.ef_search=100, ivfflat.probes=10'

-- ---------------------------------------------------------------------------
-- Helper: create an embeddings table with comprehensive indexing
--
-- Creates:
--   1. Table with proper column types
--   2. HNSW index on embedding (primary ANN search)
--   3. UNIQUE constraint on (source_type, source_id) for upsert
--   4. GIN index on metadata JSONB (filtered search)
--   5. GIN index on content via tsvector (full-text search)
--   6. BTREE index on created_at (time-range queries)
--   7. BTREE expression index on metadata->>'category' (common filter)
--   8. BRIN index on created_at (efficient range scans on large tables)
--
-- Usage:
--   SELECT create_embedding_table('documents', 1536);
--   SELECT create_embedding_table('images', 768, 'l2');
--   SELECT create_embedding_table('code', 1024, 'cosine', 24, 128);
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_embedding_table(
    p_name TEXT,
    p_dimensions INTEGER,
    p_distance TEXT DEFAULT 'cosine',
    p_hnsw_m INTEGER DEFAULT 24,
    p_hnsw_ef_construction INTEGER DEFAULT 128
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_table TEXT;
    v_ops TEXT;
BEGIN
    v_table := format('embeddings.%I', p_name);

    -- Validate distance metric
    v_ops := CASE p_distance
        WHEN 'cosine' THEN 'vector_cosine_ops'
        WHEN 'l2'     THEN 'vector_l2_ops'
        WHEN 'ip'     THEN 'vector_ip_ops'
        ELSE NULL
    END;
    IF v_ops IS NULL THEN
        RAISE EXCEPTION 'Invalid distance metric: %. Use cosine, l2, or ip', p_distance;
    END IF;

    -- Create table
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %s (
            id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            source_id TEXT NOT NULL,
            source_type TEXT NOT NULL DEFAULT %L,
            content TEXT,
            content_tsv TSVECTOR GENERATED ALWAYS AS (to_tsvector(%L, coalesce(content, %L))) STORED,
            embedding vector(%s) NOT NULL,
            metadata JSONB NOT NULL DEFAULT %L::jsonb,
            is_active BOOLEAN NOT NULL DEFAULT true,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )',
        v_table, p_name, 'english', '', p_dimensions, '{}'
    );

    -- 1. HNSW index: primary vector similarity search
    --    m=24 (connections per node, higher = better recall + more memory)
    --    ef_construction=128 (build quality, higher = slower build + better index)
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS idx_%s_hnsw ON %s USING hnsw (embedding %s) WITH (m = %s, ef_construction = %s)',
        p_name, v_table, v_ops, p_hnsw_m, p_hnsw_ef_construction
    );

    -- 2. UNIQUE constraint on (source_type, source_id) — enables ON CONFLICT upsert
    --    Also serves as a btree index for source lookups
    EXECUTE format(
        'ALTER TABLE %s ADD CONSTRAINT uq_%s_source UNIQUE (source_type, source_id)',
        v_table, p_name
    );

    -- 3. GIN index on metadata JSONB — enables @> containment queries
    --    e.g., WHERE metadata @> '{"category": "tech", "lang": "en"}'
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS idx_%s_metadata_gin ON %s USING gin (metadata jsonb_path_ops)',
        p_name, v_table
    );

    -- 4. GIN index on content_tsv — full-text search on content
    --    e.g., WHERE content_tsv @@ to_tsquery('python & machine & learning')
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS idx_%s_content_fts ON %s USING gin (content_tsv)',
        p_name, v_table
    );

    -- 5. BTREE on created_at — time-range queries
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS idx_%s_created ON %s (created_at)',
        p_name, v_table
    );

    -- 6. BRIN on created_at — efficient for large tables with naturally ordered inserts
    --    BRIN uses ~1000x less space than btree; great for append-only time-series
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS idx_%s_created_brin ON %s USING brin (created_at) WITH (pages_per_range = 32)',
        p_name, v_table
    );

    -- 7. Partial HNSW index on active rows only
    --    If you soft-delete embeddings (is_active=false), this keeps the index lean
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS idx_%s_hnsw_active ON %s USING hnsw (embedding %s) WITH (m = %s, ef_construction = %s) WHERE is_active = true',
        p_name, v_table, v_ops, p_hnsw_m, p_hnsw_ef_construction
    );

    -- 8. Filtered index for source_type — fast per-type queries
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS idx_%s_source_type ON %s (source_type)',
        p_name, v_table
    );

    EXECUTE format(
        'COMMENT ON TABLE %s IS %L',
        v_table,
        format('Vector embeddings (%s dim, %s distance, HNSW m=%s ef=%s). Indexes: HNSW, GIN(metadata+FTS), BTREE, BRIN, partial HNSW(active).',
               p_dimensions, p_distance, p_hnsw_m, p_hnsw_ef_construction)
    );
END;
$$;

COMMENT ON FUNCTION public.create_embedding_table IS
'Create a vector embeddings table with comprehensive indexing:
HNSW (ANN search), GIN (metadata + full-text), BTREE (time/source),
BRIN (time-range), partial HNSW (active-only). Includes content_tsv
generated column for full-text search and is_active for soft deletes.';

\echo '  create_embedding_table() helper created'

-- ---------------------------------------------------------------------------
-- Helper: create an IVFFlat-indexed table (for large datasets, lower memory)
-- IVFFlat is better when: >1M rows, memory constrained, can retrain periodically
--
-- Usage:
--   SELECT create_embedding_table_ivfflat('large_corpus', 1536, 'cosine', 1000);
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_embedding_table_ivfflat(
    p_name TEXT,
    p_dimensions INTEGER,
    p_distance TEXT DEFAULT 'cosine',
    p_lists INTEGER DEFAULT 100  -- sqrt(n_rows) is a good starting point
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_table TEXT;
    v_ops TEXT;
BEGIN
    v_table := format('embeddings.%I', p_name);

    v_ops := CASE p_distance
        WHEN 'cosine' THEN 'vector_cosine_ops'
        WHEN 'l2'     THEN 'vector_l2_ops'
        WHEN 'ip'     THEN 'vector_ip_ops'
        ELSE NULL
    END;
    IF v_ops IS NULL THEN
        RAISE EXCEPTION 'Invalid distance metric: %. Use cosine, l2, or ip', p_distance;
    END IF;

    -- Create table (same schema as HNSW version)
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %s (
            id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            source_id TEXT NOT NULL,
            source_type TEXT NOT NULL DEFAULT %L,
            content TEXT,
            content_tsv TSVECTOR GENERATED ALWAYS AS (to_tsvector(%L, coalesce(content, %L))) STORED,
            embedding vector(%s) NOT NULL,
            metadata JSONB NOT NULL DEFAULT %L::jsonb,
            is_active BOOLEAN NOT NULL DEFAULT true,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )',
        v_table, p_name, 'english', '', p_dimensions, '{}'
    );

    -- IVFFlat index (requires data to exist for training; create empty, rebuild later)
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS idx_%s_ivfflat ON %s USING ivfflat (embedding %s) WITH (lists = %s)',
        p_name, v_table, v_ops, p_lists
    );

    -- Same supporting indexes as HNSW version
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT uq_%s_source UNIQUE (source_type, source_id)', v_table, p_name);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_metadata_gin ON %s USING gin (metadata jsonb_path_ops)', p_name, v_table);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_content_fts ON %s USING gin (content_tsv)', p_name, v_table);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_created ON %s (created_at)', p_name, v_table);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_created_brin ON %s USING brin (created_at) WITH (pages_per_range = 32)', p_name, v_table);
    EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%s_source_type ON %s (source_type)', p_name, v_table);

    EXECUTE format(
        'COMMENT ON TABLE %s IS %L',
        v_table,
        format('Vector embeddings (%s dim, %s distance, IVFFlat lists=%s). IMPORTANT: REINDEX after bulk load.',
               p_dimensions, p_distance, p_lists)
    );
END;
$$;

COMMENT ON FUNCTION public.create_embedding_table_ivfflat IS
'Create a vector table with IVFFlat index. Better for >1M rows or memory-constrained
environments. IMPORTANT: After bulk loading data, run REINDEX to retrain centroids.
Use ivfflat.probes (default 10) to tune recall vs speed.';

\echo '  create_embedding_table_ivfflat() helper created'

-- ---------------------------------------------------------------------------
-- Helper: semantic search with full-text pre-filter (hybrid search)
-- Combines: full-text keyword match + vector similarity
-- This is the gold standard for RAG: keyword recall + semantic ranking
--
-- Usage:
--   SELECT * FROM hybrid_search('documents', query_vec, 'python API', 20);
--   SELECT * FROM hybrid_search('documents', query_vec, 'error handling', 10, 0.5);
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.hybrid_search(
    p_table TEXT,
    p_query_embedding vector,
    p_text_query TEXT,
    p_limit INTEGER DEFAULT 10,
    p_min_similarity FLOAT DEFAULT 0.0,
    p_metadata_filter JSONB DEFAULT NULL
)
RETURNS TABLE (
    id BIGINT,
    source_id TEXT,
    source_type TEXT,
    content TEXT,
    metadata JSONB,
    similarity FLOAT,
    text_rank FLOAT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_table TEXT;
    v_filter TEXT := '';
    v_tsquery TEXT;
BEGIN
    v_table := format('embeddings.%I', p_table);
    v_tsquery := plainto_tsquery('english', p_text_query)::text;

    IF p_metadata_filter IS NOT NULL THEN
        v_filter := format(' AND t.metadata @> %L', p_metadata_filter);
    END IF;

    RETURN QUERY EXECUTE format(
        'SELECT
            t.id,
            t.source_id,
            t.source_type,
            t.content,
            t.metadata,
            (1 - (t.embedding <=> $1))::float AS similarity,
            ts_rank_cd(t.content_tsv, plainto_tsquery(%L, $4))::float AS text_rank
        FROM %s t
        WHERE t.is_active = true
          AND t.content_tsv @@ plainto_tsquery(%L, $4)
          AND (1 - (t.embedding <=> $1))::float >= $2
          %s
        ORDER BY
            -- Hybrid score: 70% semantic + 30% text relevance
            0.7 * (1 - (t.embedding <=> $1))::float
            + 0.3 * ts_rank_cd(t.content_tsv, plainto_tsquery(%L, $4))::float DESC
        LIMIT $3',
        'english', v_table, 'english', v_filter, 'english'
    ) USING p_query_embedding, p_min_similarity, p_limit, p_text_query;
END;
$$;

COMMENT ON FUNCTION public.hybrid_search IS
'Hybrid search combining full-text keyword matching (GIN) with vector similarity (HNSW).
Pre-filters by text match (fast via GIN), then ranks by 70% semantic + 30% text relevance.
Best for RAG pipelines where keyword recall matters alongside semantic understanding.';

\echo '  hybrid_search() helper created'

-- ---------------------------------------------------------------------------
-- Helper: semantic search (vector-only, no text filter)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.semantic_search(
    p_table TEXT,
    p_query_embedding vector,
    p_limit INTEGER DEFAULT 10,
    p_min_similarity FLOAT DEFAULT 0.0,
    p_metadata_filter JSONB DEFAULT NULL
)
RETURNS TABLE (
    id BIGINT,
    source_id TEXT,
    source_type TEXT,
    content TEXT,
    metadata JSONB,
    similarity FLOAT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_table TEXT;
    v_filter TEXT := 'WHERE t.is_active = true';
BEGIN
    v_table := format('embeddings.%I', p_table);

    IF p_metadata_filter IS NOT NULL THEN
        v_filter := v_filter || format(' AND t.metadata @> %L', p_metadata_filter);
    END IF;

    IF p_min_similarity > 0.0 THEN
        v_filter := v_filter || format(' AND (1 - (t.embedding <=> $1))::float >= %s', p_min_similarity);
    END IF;

    RETURN QUERY EXECUTE format(
        'SELECT
            t.id, t.source_id, t.source_type, t.content, t.metadata,
            (1 - (t.embedding <=> $1))::float AS similarity
        FROM %s t
        %s
        ORDER BY t.embedding <=> $1
        LIMIT $2',
        v_table, v_filter
    ) USING p_query_embedding, p_limit;
END;
$$;

COMMENT ON FUNCTION public.semantic_search IS
'Pure vector similarity search using HNSW index. Filters by is_active and optional metadata.
For keyword+semantic search, use hybrid_search() instead.';

\echo '  semantic_search() helper created'

-- ---------------------------------------------------------------------------
-- Helper: upsert embedding
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.upsert_embedding(
    p_table TEXT,
    p_source_id TEXT,
    p_source_type TEXT,
    p_embedding vector,
    p_content TEXT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_table TEXT;
    v_id BIGINT;
BEGIN
    v_table := format('embeddings.%I', p_table);

    EXECUTE format(
        'INSERT INTO %s (source_id, source_type, embedding, content, metadata)
         VALUES ($1, $2, $3, $4, $5)
         ON CONFLICT (source_type, source_id)
            DO UPDATE SET
                embedding = EXCLUDED.embedding,
                content = EXCLUDED.content,
                metadata = EXCLUDED.metadata,
                updated_at = now()
         RETURNING id',
        v_table
    ) INTO v_id
    USING p_source_id, p_source_type, p_embedding, p_content, p_metadata;

    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.upsert_embedding IS
'Insert or update embedding by (source_type, source_id). On conflict: updates embedding,
content, and merges metadata (existing || new). Uses the UNIQUE constraint for ON CONFLICT.';

\echo '  upsert_embedding() helper created'

-- ---------------------------------------------------------------------------
-- Helper: reindex IVFFlat after bulk load (retrains centroids for accuracy)
-- Usage: SELECT reindex_ivfflat('large_corpus');
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reindex_ivfflat(p_name TEXT)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    EXECUTE format('REINDEX INDEX CONCURRENTLY embeddings.idx_%s_ivfflat', p_name);
END;
$$;

COMMENT ON FUNCTION public.reindex_ivfflat IS
'Reindex IVFFlat index after bulk data loading. This retrains centroids using
the actual data distribution, dramatically improving recall. Run CONCURRENTLY
so the table remains queryable during reindexing.';

\echo '  reindex_ivfflat() helper created'

-- ---------------------------------------------------------------------------
-- View: comprehensive vector index statistics
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.vector_index_status AS
SELECT
    schemaname,
    tablename,
    indexname,
    CASE
        WHEN indexdef LIKE '%hnsw%' THEN 'HNSW'
        WHEN indexdef LIKE '%ivfflat%' THEN 'IVFFlat'
        WHEN indexdef LIKE '%gin%' AND indexdef LIKE '%jsonb%' THEN 'GIN (JSONB)'
        WHEN indexdef LIKE '%gin%' AND indexdef LIKE '%tsvector%' THEN 'GIN (FTS)'
        WHEN indexdef LIKE '%gin%' THEN 'GIN'
        WHEN indexdef LIKE '%brin%' THEN 'BRIN'
        WHEN indexdef LIKE '%UNIQUE%' OR indexdef LIKE '%unique%' THEN 'BTREE (UNIQUE)'
        WHEN indexdef LIKE '%btree%' THEN 'BTREE'
        ELSE 'OTHER'
    END AS index_type,
    CASE WHEN indexdef LIKE '%WHERE%' THEN 'PARTIAL' ELSE 'FULL' END AS scope,
    pg_size_pretty(pg_relation_size(quote_ident(schemaname) || '.' || quote_ident(indexname))) AS index_size,
    pg_size_pretty(pg_relation_size(quote_ident(schemaname) || '.' || quote_ident(tablename))) AS table_size
FROM pg_indexes
WHERE schemaname = 'embeddings'
ORDER BY schemaname, tablename, indexname;

COMMENT ON VIEW public.vector_index_status IS
'All indexes in the embeddings schema with type classification (HNSW, IVFFlat, GIN, BRIN, BTREE),
scope (FULL/PARTIAL), and sizes. Use to verify index strategy and monitor growth.';

\echo '  vector_index_status view created'

\echo '=== pgvector configured ==='
\echo ''
\echo 'Index strategy per embedding table:'
\echo '  HNSW          — primary ANN search on embedding column'
\echo '  HNSW(partial) — ANN search on active rows only (is_active=true)'
\echo '  GIN(jsonb)    — metadata @> containment filter'
\echo '  GIN(tsvector) — full-text search on content'
\echo '  BTREE         — created_at, source_type, source_id (unique)'
\echo '  BRIN          — created_at range scans (large tables)'
