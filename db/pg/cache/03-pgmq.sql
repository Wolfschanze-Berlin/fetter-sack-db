-- 03-pgmq.sql
-- pgmq message queue infrastructure setup.
-- Creates default application queues and helper functions.

\echo '=== Configuring pgmq ==='

-- ---------------------------------------------------------------------------
-- Default application queues
-- These are common patterns; add/remove based on your actual needs.
-- ---------------------------------------------------------------------------

-- General task processing queue
SELECT pgmq.create('tasks');
\echo '  tasks queue created'

-- Dead letter queue for failed messages
SELECT pgmq.create('dead_letters');
\echo '  dead_letters queue created'

-- Event notification queue (for webhooks, alerts, etc.)
SELECT pgmq.create('events');
\echo '  events queue created'

-- ---------------------------------------------------------------------------
-- Helper: send a JSON message with automatic timestamp wrapping
-- Usage: SELECT mq_send('tasks', '{"action": "process", "id": 123}');
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mq_send(
    p_queue TEXT,
    p_payload JSONB,
    p_delay INTEGER DEFAULT 0
)
RETURNS BIGINT
LANGUAGE sql
AS $$
    SELECT pgmq.send(
        p_queue,
        jsonb_build_object(
            'payload', p_payload,
            'enqueued_at', now()
        ),
        p_delay
    );
$$;

COMMENT ON FUNCTION public.mq_send IS
'Send a JSON message to a pgmq queue. Wraps payload with enqueued_at timestamp.
Optional delay in seconds before message becomes visible.';

\echo '  mq_send() helper function created'

-- ---------------------------------------------------------------------------
-- Helper: send to dead letter queue with error context
-- Usage: SELECT mq_dead_letter('tasks', 42, 'parsing failed', msg_body);
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mq_dead_letter(
    p_source_queue TEXT,
    p_original_msg_id BIGINT,
    p_error TEXT,
    p_original_payload JSONB DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE sql
AS $$
    SELECT pgmq.send(
        'dead_letters',
        jsonb_build_object(
            'source_queue', p_source_queue,
            'original_msg_id', p_original_msg_id,
            'error', p_error,
            'original_payload', p_original_payload,
            'failed_at', now()
        )
    );
$$;

COMMENT ON FUNCTION public.mq_dead_letter IS
'Move a failed message to the dead_letters queue with error context for debugging.';

\echo '  mq_dead_letter() helper function created'

-- ---------------------------------------------------------------------------
-- View: queue overview
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.queue_status AS
SELECT
    queue_name,
    is_partitioned,
    is_unlogged,
    created_at
FROM pgmq.list_queues()
ORDER BY queue_name;

COMMENT ON VIEW public.queue_status IS
'Overview of all pgmq queues and their configuration.';

\echo '  queue_status view created'

\echo '=== pgmq configured ==='
