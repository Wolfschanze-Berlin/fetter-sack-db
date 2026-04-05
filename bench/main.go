package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"math/rand"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ─── Configuration ──────────────────────────────────────────────────────────

type Config struct {
	DirectDSN   string
	PooledDSN   string
	RestURL     string
	Concurrency int
	Duration    time.Duration
	Verbose     bool
}

// ─── Result Types ───────────────────────────────────────────────────────────

type BenchResult struct {
	Name       string        `json:"name"`
	Operations int64         `json:"operations"`
	Duration   time.Duration `json:"duration"`
	OpsPerSec  float64       `json:"ops_per_sec"`
	AvgLatency time.Duration `json:"avg_latency"`
	P50        time.Duration `json:"p50"`
	P95        time.Duration `json:"p95"`
	P99        time.Duration `json:"p99"`
	MinLatency time.Duration `json:"min_latency"`
	MaxLatency time.Duration `json:"max_latency"`
	Errors     int64         `json:"errors"`
}

type Report struct {
	Timestamp   time.Time      `json:"timestamp"`
	Config      Config         `json:"config"`
	Results     []BenchResult  `json:"results"`
	SystemInfo  map[string]any `json:"system_info"`
}

// ─── Latency Collector ──────────────────────────────────────────────────────

type LatencyCollector struct {
	mu        sync.Mutex
	latencies []time.Duration
	errors    int64
}

func NewLatencyCollector() *LatencyCollector {
	return &LatencyCollector{latencies: make([]time.Duration, 0, 100000)}
}

func (lc *LatencyCollector) Record(d time.Duration) {
	lc.mu.Lock()
	lc.latencies = append(lc.latencies, d)
	lc.mu.Unlock()
}

func (lc *LatencyCollector) Error() {
	atomic.AddInt64(&lc.errors, 1)
}

func (lc *LatencyCollector) Result(name string, totalDuration time.Duration) BenchResult {
	lc.mu.Lock()
	defer lc.mu.Unlock()

	n := int64(len(lc.latencies))
	if n == 0 {
		return BenchResult{Name: name, Errors: lc.errors}
	}

	sort.Slice(lc.latencies, func(i, j int) bool { return lc.latencies[i] < lc.latencies[j] })

	var total time.Duration
	for _, l := range lc.latencies {
		total += l
	}

	return BenchResult{
		Name:       name,
		Operations: n,
		Duration:   totalDuration,
		OpsPerSec:  float64(n) / totalDuration.Seconds(),
		AvgLatency: total / time.Duration(n),
		P50:        lc.latencies[n*50/100],
		P95:        lc.latencies[n*95/100],
		P99:        lc.latencies[n*99/100],
		MinLatency: lc.latencies[0],
		MaxLatency: lc.latencies[n-1],
		Errors:     lc.errors,
	}
}

// ─── Benchmark Runner ───────────────────────────────────────────────────────

func runBench(name string, concurrency int, duration time.Duration, fn func(ctx context.Context) error) BenchResult {
	lc := NewLatencyCollector()
	ctx, cancel := context.WithTimeout(context.Background(), duration)
	defer cancel()

	var wg sync.WaitGroup
	start := time.Now()

	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-ctx.Done():
					return
				default:
					t := time.Now()
					if err := fn(ctx); err != nil {
						if ctx.Err() == nil {
							lc.Error()
						}
					} else {
						lc.Record(time.Since(t))
					}
				}
			}
		}()
	}

	wg.Wait()
	elapsed := time.Since(start)
	return lc.Result(name, elapsed)
}

// ─── Benchmark Suites ───────────────────────────────────────────────────────

func benchInsert(pool *pgxpool.Pool, concurrency int, duration time.Duration) BenchResult {
	return runBench("INSERT (single row)", concurrency, duration, func(ctx context.Context) error {
		_, err := pool.Exec(ctx,
			"INSERT INTO bench.kv (key, value, data) VALUES ($1, $2, $3)",
			fmt.Sprintf("key-%d", rand.Int63()), rand.Float64(),
			map[string]any{"ts": time.Now().UnixNano()})
		return err
	})
}

func benchSelect(pool *pgxpool.Pool, concurrency int, duration time.Duration) BenchResult {
	return runBench("SELECT (point lookup)", concurrency, duration, func(ctx context.Context) error {
		var val float64
		err := pool.QueryRow(ctx,
			"SELECT value FROM bench.kv WHERE key = $1",
			fmt.Sprintf("key-%d", rand.Int63n(10000))).Scan(&val)
		if err == pgx.ErrNoRows {
			return nil // Cache miss is not an error
		}
		return err
	})
}

func benchPartitionInsert(pool *pgxpool.Pool, concurrency int, duration time.Duration) BenchResult {
	return runBench("PARTITION INSERT (daily)", concurrency, duration, func(ctx context.Context) error {
		ts := time.Now().Add(-time.Duration(rand.Intn(5*24)) * time.Hour)
		_, err := pool.Exec(ctx,
			"INSERT INTO bench.events (created_at, event_type, payload) VALUES ($1, $2, $3)",
			ts, "bench_event",
			map[string]any{"value": rand.Float64()})
		return err
	})
}

func benchPartitionQuery(pool *pgxpool.Pool, concurrency int, duration time.Duration) BenchResult {
	return runBench("PARTITION QUERY (1-day range)", concurrency, duration, func(ctx context.Context) error {
		start := time.Now().Add(-24 * time.Hour)
		rows, err := pool.Query(ctx,
			"SELECT count(*) FROM bench.events WHERE created_at >= $1 AND created_at < $2",
			start, time.Now())
		if err != nil {
			return err
		}
		rows.Close()
		return rows.Err()
	})
}

func benchVectorInsert(pool *pgxpool.Pool, concurrency int, duration time.Duration) BenchResult {
	return runBench("VECTOR INSERT (384-dim)", concurrency, duration, func(ctx context.Context) error {
		vec := makeRandomVector(384)
		_, err := pool.Exec(ctx,
			"INSERT INTO bench.vectors (source_id, source_type, embedding, content) VALUES ($1, $2, $3::vector, $4)",
			fmt.Sprintf("doc-%d", rand.Int63()), "bench",
			vecToString(vec), "benchmark content")
		return err
	})
}

func benchVectorSearch(pool *pgxpool.Pool, concurrency int, duration time.Duration) BenchResult {
	queryVec := makeRandomVector(384)
	vecStr := vecToString(queryVec)
	return runBench("VECTOR SEARCH (HNSW top-10)", concurrency, duration, func(ctx context.Context) error {
		rows, err := pool.Query(ctx,
			"SELECT id, 1 - (embedding <=> $1::vector) AS similarity FROM bench.vectors ORDER BY embedding <=> $1::vector LIMIT 10",
			vecStr)
		if err != nil {
			return err
		}
		rows.Close()
		return rows.Err()
	})
}

func benchCacheSet(pool *pgxpool.Pool, concurrency int, duration time.Duration) BenchResult {
	return runBench("CACHE SET (UNLOGGED upsert)", concurrency, duration, func(ctx context.Context) error {
		_, err := pool.Exec(ctx,
			"SELECT cache_set('bench', $1, $2)",
			fmt.Sprintf("key-%d", rand.Int63n(10000)),
			map[string]any{"v": rand.Float64()})
		return err
	})
}

func benchCacheGet(pool *pgxpool.Pool, concurrency int, duration time.Duration) BenchResult {
	return runBench("CACHE GET (UNLOGGED read)", concurrency, duration, func(ctx context.Context) error {
		var data any
		return pool.QueryRow(ctx,
			"SELECT cache_get('bench', $1)",
			fmt.Sprintf("key-%d", rand.Int63n(10000))).Scan(&data)
	})
}

func benchQueueSend(pool *pgxpool.Pool, concurrency int, duration time.Duration) BenchResult {
	return runBench("PGMQ SEND", concurrency, duration, func(ctx context.Context) error {
		_, err := pool.Exec(ctx,
			"SELECT pgmq.send('bench_queue', $1)",
			fmt.Sprintf(`{"id":%d}`, rand.Int63()))
		return err
	})
}

func benchQueueSendRead(pool *pgxpool.Pool, concurrency int, duration time.Duration) BenchResult {
	return runBench("PGMQ SEND+READ (roundtrip)", concurrency, duration, func(ctx context.Context) error {
		// Send
		var msgID int64
		err := pool.QueryRow(ctx,
			"SELECT pgmq.send('bench_queue', $1)",
			fmt.Sprintf(`{"id":%d}`, rand.Int63())).Scan(&msgID)
		if err != nil {
			return err
		}
		// Read + archive
		var readMsgID int64
		err = pool.QueryRow(ctx,
			"SELECT msg_id FROM pgmq.read('bench_queue', 0, 1) LIMIT 1").Scan(&readMsgID)
		if err != nil {
			return nil // Queue contention — another goroutine grabbed it
		}
		_, err = pool.Exec(ctx, "SELECT pgmq.archive('bench_queue', $1)", readMsgID)
		return err
	})
}

func benchHTTPGet(restURL string, concurrency int, duration time.Duration) BenchResult {
	client := &http.Client{Timeout: 5 * time.Second}
	url := restURL + "/bench_kv?limit=10"
	return runBench("REST GET (PostgREST /bench_kv)", concurrency, duration, func(ctx context.Context) error {
		req, _ := http.NewRequestWithContext(ctx, "GET", url, nil)
		resp, err := client.Do(req)
		if err != nil {
			return err
		}
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		if resp.StatusCode >= 400 {
			return fmt.Errorf("HTTP %d", resp.StatusCode)
		}
		return nil
	})
}

func benchPooledVsDirect(directPool, pooledPool *pgxpool.Pool, concurrency int, duration time.Duration) (BenchResult, BenchResult) {
	query := "SELECT 1"
	direct := runBench("DIRECT PG (SELECT 1)", concurrency, duration, func(ctx context.Context) error {
		var v int
		return directPool.QueryRow(ctx, query).Scan(&v)
	})
	pooled := runBench("PGBOUNCER (SELECT 1)", concurrency, duration, func(ctx context.Context) error {
		var v int
		return pooledPool.QueryRow(ctx, query).Scan(&v)
	})
	return direct, pooled
}

func benchPooledVsDirectReal(directPool, pooledPool *pgxpool.Pool, concurrency int, duration time.Duration) (BenchResult, BenchResult) {
	// Real-world query: JSON aggregation with filtering (typical API backend query)
	query := `SELECT json_agg(row_to_json(t)) FROM (
		SELECT key, value, data, created_at FROM bench.kv
		WHERE value > 0.5 ORDER BY created_at DESC LIMIT 20
	) t`

	direct := runBench("DIRECT PG (real query)", concurrency, duration, func(ctx context.Context) error {
		var result any
		return directPool.QueryRow(ctx, query).Scan(&result)
	})
	pooled := runBench("PGBOUNCER (real query)", concurrency, duration, func(ctx context.Context) error {
		var result any
		return pooledPool.QueryRow(ctx, query).Scan(&result)
	})
	return direct, pooled
}

func benchConnectionStorm(directDSN, pooledDSN string, duration time.Duration) (BenchResult, BenchResult) {
	// Simulate 100 short-lived connections each doing one query then disconnecting.
	// This is the worst case for PostgreSQL (fork overhead) and best case for PgBouncer.
	concurrency := 100

	direct := runBench("CONN STORM DIRECT (100 clients)", concurrency, duration, func(ctx context.Context) error {
		conn, err := pgx.Connect(ctx, directDSN)
		if err != nil {
			return err
		}
		defer conn.Close(ctx)
		var v int
		return conn.QueryRow(ctx, "SELECT 1").Scan(&v)
	})

	pooled := runBench("CONN STORM POOLED (100 clients)", concurrency, duration, func(ctx context.Context) error {
		conn, err := pgx.Connect(ctx, pooledDSN)
		if err != nil {
			return err
		}
		defer conn.Close(ctx)
		var v int
		return conn.QueryRow(ctx, "SELECT 1").Scan(&v)
	})

	return direct, pooled
}

// ─── Setup / Teardown ───────────────────────────────────────────────────────

func setupBenchTables(ctx context.Context, pool *pgxpool.Pool) error {
	queries := []string{
		"CREATE SCHEMA IF NOT EXISTS bench",
		// KV table
		`CREATE TABLE IF NOT EXISTS bench.kv (
			id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
			key TEXT NOT NULL,
			value DOUBLE PRECISION,
			data JSONB,
			created_at TIMESTAMPTZ DEFAULT now()
		)`,
		"CREATE INDEX IF NOT EXISTS idx_bench_kv_key ON bench.kv (key)",
		// Partitioned events table
		`CREATE TABLE IF NOT EXISTS bench.events (
			id BIGINT GENERATED ALWAYS AS IDENTITY,
			created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
			event_type TEXT,
			payload JSONB
		) PARTITION BY RANGE (created_at)`,
		// Vector table (384-dim for speed)
		`CREATE TABLE IF NOT EXISTS bench.vectors (
			id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
			source_id TEXT NOT NULL,
			source_type TEXT NOT NULL DEFAULT 'bench',
			content TEXT,
			embedding vector(384) NOT NULL,
			created_at TIMESTAMPTZ DEFAULT now()
		)`,
		"CREATE INDEX IF NOT EXISTS idx_bench_vectors_hnsw ON bench.vectors USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64)",
		// PGMQ queue
		"SELECT pgmq.create('bench_queue')",
		// PostgREST API view
		"CREATE OR REPLACE VIEW api.bench_kv AS SELECT * FROM bench.kv",
		"GRANT SELECT ON api.bench_kv TO anon",
		"NOTIFY pgrst, 'reload schema'",
	}

	for _, q := range queries {
		if _, err := pool.Exec(ctx, q); err != nil {
			// Ignore "already exists" errors
			if !strings.Contains(err.Error(), "already exists") {
				return fmt.Errorf("setup %q: %w", q[:min(len(q), 60)], err)
			}
		}
	}

	// Register with pg_partman — clean slate approach
	// Remove stale config if exists (from previous incomplete teardown)
	pool.Exec(ctx, "DELETE FROM partman.part_config WHERE parent_table = 'bench.events'")

	_, err := pool.Exec(ctx,
		"SELECT partman.create_parent(p_parent_table := 'bench.events', p_control := 'created_at', p_interval := '1 day', p_premake := 7)")
	if err != nil {
		return fmt.Errorf("partman setup: %w", err)
	}
	// Run maintenance to create partitions
	_, err = pool.Exec(ctx, "SELECT partman.run_maintenance(p_parent_table := 'bench.events')")
	if err != nil {
		return fmt.Errorf("partman maintenance: %w", err)
	}

	return nil
}

func seedData(ctx context.Context, pool *pgxpool.Pool, count int) error {
	fmt.Printf("  Seeding %d rows per table...\n", count)

	// Seed KV
	batch := &pgx.Batch{}
	for i := 0; i < count; i++ {
		batch.Queue("INSERT INTO bench.kv (key, value, data) VALUES ($1, $2, $3)",
			fmt.Sprintf("key-%d", i), rand.Float64(),
			map[string]any{"i": i})
	}
	br := pool.SendBatch(ctx, batch)
	for i := 0; i < count; i++ {
		if _, err := br.Exec(); err != nil {
			br.Close()
			return fmt.Errorf("seed kv: %w", err)
		}
	}
	br.Close()

	// Seed events (stay within partman's pre-created range: -6 to +6 days)
	batch = &pgx.Batch{}
	for i := 0; i < count; i++ {
		ts := time.Now().Add(-time.Duration(rand.Intn(5*24)) * time.Hour)
		batch.Queue("INSERT INTO bench.events (created_at, event_type, payload) VALUES ($1, $2, $3)",
			ts, "seed", map[string]any{"i": i})
	}
	br = pool.SendBatch(ctx, batch)
	for i := 0; i < count; i++ {
		if _, err := br.Exec(); err != nil {
			br.Close()
			return fmt.Errorf("seed events: %w", err)
		}
	}
	br.Close()

	// Seed vectors
	batch = &pgx.Batch{}
	for i := 0; i < min(count, 5000); i++ { // Cap vectors at 5k (HNSW build time)
		vec := makeRandomVector(384)
		batch.Queue("INSERT INTO bench.vectors (source_id, source_type, embedding, content) VALUES ($1, $2, $3::vector, $4)",
			fmt.Sprintf("seed-%d", i), "bench", vecToString(vec), fmt.Sprintf("content %d", i))
	}
	br = pool.SendBatch(ctx, batch)
	for i := 0; i < min(count, 5000); i++ {
		if _, err := br.Exec(); err != nil {
			br.Close()
			return fmt.Errorf("seed vectors: %w", err)
		}
	}
	br.Close()

	// Seed cache
	batch = &pgx.Batch{}
	for i := 0; i < min(count, 10000); i++ {
		batch.Queue("SELECT cache_set('bench', $1, $2)",
			fmt.Sprintf("key-%d", i), map[string]any{"v": i})
	}
	br = pool.SendBatch(ctx, batch)
	for i := 0; i < min(count, 10000); i++ {
		if _, err := br.Exec(); err != nil {
			br.Close()
			return fmt.Errorf("seed cache: %w", err)
		}
	}
	br.Close()

	// Seed queue
	batch = &pgx.Batch{}
	for i := 0; i < min(count, 1000); i++ {
		batch.Queue("SELECT pgmq.send('bench_queue', $1)", fmt.Sprintf(`{"i":%d}`, i))
	}
	br = pool.SendBatch(ctx, batch)
	for i := 0; i < min(count, 1000); i++ {
		if _, err := br.Exec(); err != nil {
			br.Close()
			return fmt.Errorf("seed queue: %w", err)
		}
	}
	br.Close()

	return nil
}

func teardown(ctx context.Context, pool *pgxpool.Pool) {
	pool.Exec(ctx, "DROP VIEW IF EXISTS api.bench_kv CASCADE")
	pool.Exec(ctx, "DELETE FROM partman.part_config WHERE parent_table = 'bench.events'")
	pool.Exec(ctx, "DROP TABLE IF EXISTS bench.events CASCADE")
	pool.Exec(ctx, "DROP TABLE IF EXISTS bench.kv CASCADE")
	pool.Exec(ctx, "DROP TABLE IF EXISTS bench.vectors CASCADE")
	pool.Exec(ctx, "SELECT pgmq.drop_queue('bench_queue')")
	pool.Exec(ctx, "SELECT cache_purge_namespace('bench')")
	pool.Exec(ctx, "DROP SCHEMA IF EXISTS bench CASCADE")
	pool.Exec(ctx, "NOTIFY pgrst, 'reload schema'")
}

func getSystemInfo(ctx context.Context, pool *pgxpool.Pool) map[string]any {
	info := map[string]any{}

	var pgVersion string
	pool.QueryRow(ctx, "SELECT version()").Scan(&pgVersion)
	info["pg_version"] = pgVersion

	var sharedBuffers string
	pool.QueryRow(ctx, "SHOW shared_buffers").Scan(&sharedBuffers)
	info["shared_buffers"] = sharedBuffers

	var workMem string
	pool.QueryRow(ctx, "SHOW work_mem").Scan(&workMem)
	info["work_mem"] = workMem

	var maxConn string
	pool.QueryRow(ctx, "SHOW max_connections").Scan(&maxConn)
	info["max_connections"] = maxConn

	var extCount int
	pool.QueryRow(ctx, "SELECT count(*) FROM pg_extension WHERE extname != 'plpgsql'").Scan(&extCount)
	info["extensions"] = extCount

	return info
}

// ─── Helpers ────────────────────────────────────────────────────────────────

func makeRandomVector(dim int) []float32 {
	vec := make([]float32, dim)
	for i := range vec {
		vec[i] = rand.Float32()*2 - 1
	}
	// Normalize
	var norm float64
	for _, v := range vec {
		norm += float64(v) * float64(v)
	}
	norm = math.Sqrt(norm)
	for i := range vec {
		vec[i] = float32(float64(vec[i]) / norm)
	}
	return vec
}

func vecToString(vec []float32) string {
	parts := make([]string, len(vec))
	for i, v := range vec {
		parts[i] = fmt.Sprintf("%.6f", v)
	}
	return "[" + strings.Join(parts, ",") + "]"
}

func formatDuration(d time.Duration) string {
	if d < time.Microsecond {
		return fmt.Sprintf("%.0fns", float64(d.Nanoseconds()))
	}
	if d < time.Millisecond {
		return fmt.Sprintf("%.1fus", float64(d.Microseconds()))
	}
	if d < time.Second {
		return fmt.Sprintf("%.2fms", float64(d.Microseconds())/1000)
	}
	return fmt.Sprintf("%.2fs", d.Seconds())
}

func formatOps(ops float64) string {
	if ops >= 1000000 {
		return fmt.Sprintf("%.1fM", ops/1000000)
	}
	if ops >= 1000 {
		return fmt.Sprintf("%.1fK", ops/1000)
	}
	return fmt.Sprintf("%.0f", ops)
}

// ─── Report Printer ─────────────────────────────────────────────────────────

func printReport(report Report) {
	w := os.Stdout
	line := strings.Repeat("─", 100)

	fmt.Fprintln(w)
	fmt.Fprintln(w, line)
	fmt.Fprintln(w, "  FETTER-SACK-DB BENCHMARK REPORT")
	fmt.Fprintf(w, "  %s | Concurrency: %d | Duration: %s per test\n",
		report.Timestamp.Format("2006-01-02 15:04:05"), report.Config.Concurrency, report.Config.Duration)
	fmt.Fprintln(w, line)

	// System info
	fmt.Fprintln(w, "\n  SYSTEM INFO")
	fmt.Fprintln(w, "  "+strings.Repeat("─", 60))
	for k, v := range report.SystemInfo {
		fmt.Fprintf(w, "  %-20s %v\n", k+":", v)
	}

	// Results table
	fmt.Fprintln(w, "\n  BENCHMARK RESULTS")
	fmt.Fprintln(w, "  "+strings.Repeat("─", 96))
	fmt.Fprintf(w, "  %-32s %8s %8s %8s %8s %8s %8s %6s\n",
		"Test", "ops/sec", "avg", "p50", "p95", "p99", "max", "errs")
	fmt.Fprintln(w, "  "+strings.Repeat("─", 96))

	for _, r := range report.Results {
		fmt.Fprintf(w, "  %-32s %8s %8s %8s %8s %8s %8s %6d\n",
			r.Name,
			formatOps(r.OpsPerSec),
			formatDuration(r.AvgLatency),
			formatDuration(r.P50),
			formatDuration(r.P95),
			formatDuration(r.P99),
			formatDuration(r.MaxLatency),
			r.Errors)
	}

	fmt.Fprintln(w, "  "+strings.Repeat("─", 96))

	// Summary
	var totalOps int64
	var totalErrors int64
	for _, r := range report.Results {
		totalOps += r.Operations
		totalErrors += r.Errors
	}
	fmt.Fprintf(w, "\n  Total operations: %d | Total errors: %d\n", totalOps, totalErrors)
	fmt.Fprintln(w, line)
	fmt.Fprintln(w)
}

// ─── Main ───────────────────────────────────────────────────────────────────

func main() {
	cfg := Config{}
	flag.StringVar(&cfg.DirectDSN, "direct", "postgres://postgres:postgres@localhost:46432/postgres", "Direct PostgreSQL DSN")
	flag.StringVar(&cfg.PooledDSN, "pooled", "postgres://postgres:postgres@localhost:46434/postgres", "PgBouncer pooled DSN")
	flag.StringVar(&cfg.RestURL, "rest", "http://localhost:46433", "PostgREST URL")
	flag.IntVar(&cfg.Concurrency, "c", 10, "Concurrency (goroutines per test)")
	dur := flag.String("d", "5s", "Duration per benchmark")
	seed := flag.Int("seed", 10000, "Seed data row count")
	jsonOutput := flag.Bool("json", false, "Output as JSON")
	cleanup := flag.Bool("cleanup", true, "Cleanup benchmark tables after run")
	flag.BoolVar(&cfg.Verbose, "v", false, "Verbose output")
	flag.Parse()

	var err error
	cfg.Duration, err = time.ParseDuration(*dur)
	if err != nil {
		fmt.Fprintf(os.Stderr, "invalid duration: %s\n", *dur)
		os.Exit(1)
	}

	ctx := context.Background()

	// Connect direct
	fmt.Println("Connecting to PostgreSQL (direct)...")
	directPool, err := pgxpool.New(ctx, cfg.DirectDSN)
	if err != nil {
		fmt.Fprintf(os.Stderr, "direct connect failed: %v\n", err)
		os.Exit(1)
	}
	defer directPool.Close()

	// Connect pooled
	fmt.Println("Connecting to PgBouncer (pooled)...")
	pooledPool, err := pgxpool.New(ctx, cfg.PooledDSN)
	if err != nil {
		fmt.Fprintf(os.Stderr, "pooled connect failed: %v\n", err)
		os.Exit(1)
	}
	defer pooledPool.Close()

	// System info
	sysInfo := getSystemInfo(ctx, directPool)
	fmt.Printf("PostgreSQL: %s\n", sysInfo["pg_version"])

	// Setup
	fmt.Println("Setting up benchmark tables...")
	if err := setupBenchTables(ctx, directPool); err != nil {
		fmt.Fprintf(os.Stderr, "setup failed: %v\n", err)
		os.Exit(1)
	}

	// Seed
	if err := seedData(ctx, directPool, *seed); err != nil {
		fmt.Fprintf(os.Stderr, "seed failed: %v\n", err)
		os.Exit(1)
	}

	// Wait for PostgREST schema reload
	time.Sleep(2 * time.Second)

	// Run benchmarks
	fmt.Printf("\nRunning benchmarks (concurrency=%d, duration=%s)...\n\n", cfg.Concurrency, cfg.Duration)
	results := []BenchResult{}

	tests := []struct {
		name string
		fn   func() BenchResult
	}{
		{"INSERT", func() BenchResult { return benchInsert(directPool, cfg.Concurrency, cfg.Duration) }},
		{"SELECT", func() BenchResult { return benchSelect(directPool, cfg.Concurrency, cfg.Duration) }},
		{"PARTITION INSERT", func() BenchResult { return benchPartitionInsert(directPool, cfg.Concurrency, cfg.Duration) }},
		{"PARTITION QUERY", func() BenchResult { return benchPartitionQuery(directPool, cfg.Concurrency, cfg.Duration) }},
		{"VECTOR INSERT", func() BenchResult { return benchVectorInsert(directPool, cfg.Concurrency, cfg.Duration) }},
		{"VECTOR SEARCH", func() BenchResult { return benchVectorSearch(directPool, cfg.Concurrency, cfg.Duration) }},
		{"CACHE SET", func() BenchResult { return benchCacheSet(directPool, cfg.Concurrency, cfg.Duration) }},
		{"CACHE GET", func() BenchResult { return benchCacheGet(directPool, cfg.Concurrency, cfg.Duration) }},
		{"QUEUE SEND", func() BenchResult { return benchQueueSend(directPool, cfg.Concurrency, cfg.Duration) }},
		{"QUEUE SEND+READ", func() BenchResult { return benchQueueSendRead(directPool, cfg.Concurrency, cfg.Duration) }},
		{"REST GET", func() BenchResult { return benchHTTPGet(cfg.RestURL, cfg.Concurrency, cfg.Duration) }},
	}

	for _, t := range tests {
		fmt.Printf("  %-35s ", t.name+"...")
		r := t.fn()
		results = append(results, r)
		fmt.Printf("%8s ops/sec  (p50=%s, p99=%s)\n", formatOps(r.OpsPerSec), formatDuration(r.P50), formatDuration(r.P99))
	}

	// PgBouncer vs Direct: simple query
	fmt.Printf("  %-35s ", "DIRECT vs POOLED (SELECT 1)...")
	direct, pooled := benchPooledVsDirect(directPool, pooledPool, cfg.Concurrency, cfg.Duration)
	results = append(results, direct, pooled)
	fmt.Printf("direct=%s  pooled=%s ops/sec\n", formatOps(direct.OpsPerSec), formatOps(pooled.OpsPerSec))

	// PgBouncer vs Direct: real-world query (where pooling shines)
	fmt.Printf("  %-35s ", "DIRECT vs POOLED (real query)...")
	directReal, pooledReal := benchPooledVsDirectReal(directPool, pooledPool, cfg.Concurrency, cfg.Duration)
	results = append(results, directReal, pooledReal)
	fmt.Printf("direct=%s  pooled=%s ops/sec\n", formatOps(directReal.OpsPerSec), formatOps(pooledReal.OpsPerSec))

	// Connection storm: many short-lived connections (PgBouncer's killer feature)
	fmt.Printf("  %-35s ", "CONN STORM (100 concurrent)...")
	stormDirect, stormPooled := benchConnectionStorm(cfg.DirectDSN, cfg.PooledDSN, cfg.Duration)
	results = append(results, stormDirect, stormPooled)
	fmt.Printf("direct=%s  pooled=%s ops/sec\n", formatOps(stormDirect.OpsPerSec), formatOps(stormPooled.OpsPerSec))

	// Build report
	report := Report{
		Timestamp:  time.Now(),
		Config:     cfg,
		Results:    results,
		SystemInfo: sysInfo,
	}

	if *jsonOutput {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		enc.Encode(report)
	} else {
		printReport(report)
	}

	// Cleanup
	if *cleanup {
		fmt.Println("Cleaning up benchmark tables...")
		teardown(ctx, directPool)
	}
}
