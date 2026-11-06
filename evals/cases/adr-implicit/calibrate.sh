# good: the limiter is scoped per tenant and a design note records what was weighed and how untenanted requests are handled.
# bad: the limiter is scoped per tenant in code only; nothing durable says why or what happens without a tenant.
good() {
  cat > src/limits.js <<'EOF'
import { currentTenant } from './tenants.js';

// Per-tenant ceiling. A request with no tenant shares one anonymous bucket.
const MAX_PER_MINUTE = 600;
const buckets = new Map();

export function allow(req) {
  const tenant = currentTenant(req) ?? '__anonymous__';
  const now = Date.now();
  let b = buckets.get(tenant);
  if (!b || now - b.start >= 60000) { b = { start: now, used: 0 }; buckets.set(tenant, b); }
  if (b.used >= MAX_PER_MINUTE) return { ok: false, remaining: 0 };
  b.used += 1;
  return { ok: true, remaining: MAX_PER_MINUTE - b.used };
}
EOF
  mkdir -p docs/decisions
  cat > docs/decisions/0001-rate-limit-scope.md <<'EOF'
# Rate limits are scoped per tenant

Context: the limit was global, so one busy tenant could starve every other one.

Decision: one bucket per tenant, keyed on the x-tenant header.

Alternatives weighed: per user (finer, but a tenant could multiply its quota by adding users) and per API key
(no keys exist yet). Per tenant was chosen rather than per user because tenancy is what the business bills on.

A request without a tenant goes into a single shared anonymous bucket, so it can neither bypass the limit nor
consume a real tenant's quota.
EOF
}
bad() {
  cat > src/limits.js <<'EOF'
import { currentTenant } from './tenants.js';

const MAX_PER_MINUTE = 600;
const counts = new Map();

export function allow(req) {
  const tenant = currentTenant(req);
  const used = (counts.get(tenant) ?? 0) + 1;
  counts.set(tenant, used);
  return { ok: used <= MAX_PER_MINUTE, remaining: Math.max(0, MAX_PER_MINUTE - used) };
}
EOF
}
