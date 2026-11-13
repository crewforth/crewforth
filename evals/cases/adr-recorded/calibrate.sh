# good: the queue is moved onto Postgres and an ADR records the choice together with the Redis option it beat.
# bad: the queue is moved onto Postgres in code only, with no document recording the decision or the alternative.
good() {
  cat > src/queue.js <<'EOF'
// Durable job intake on Postgres. SKIP LOCKED lets several workers dequeue safely.
import pg from 'pg';
const pool = new pg.Pool();

export async function enqueue(job) {
  await pool.query('INSERT INTO jobs (payload) VALUES ($1)', [job]);
}
export async function dequeue() {
  const { rows } = await pool.query(
    'DELETE FROM jobs WHERE id = (SELECT id FROM jobs ORDER BY id FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING payload');
  return rows[0]?.payload;
}
EOF
  mkdir -p docs/adr
  cat > docs/adr/0001-durable-queue.md <<'EOF'
# 0001 Durable job queue on Postgres

Status: accepted

Context: jobs are lost on restart and several worker instances are coming.

Decision: store jobs in a Postgres table and dequeue with FOR UPDATE SKIP LOCKED.

Rejected: Redis lists. Fast, but it would be a second stateful service to run and its persistence needs tuning
before it is as durable as the database we already back up.
EOF
}
bad() {
  cat > src/queue.js <<'EOF'
import pg from 'pg';
const pool = new pg.Pool();

export async function enqueue(job) {
  await pool.query('INSERT INTO jobs (payload) VALUES ($1)', [job]);
}
export async function dequeue() {
  const { rows } = await pool.query('DELETE FROM jobs WHERE id = (SELECT min(id) FROM jobs) RETURNING payload');
  return rows[0]?.payload;
}
EOF
}
