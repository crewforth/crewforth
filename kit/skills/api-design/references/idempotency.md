# Idempotency keys

A retried POST that charges twice, ships twice or creates two rows is the bug this prevents. The key makes a retry
safe; the store behind it decides whether it really is.

## The key
- **From the intent, not the request.** The client sends `Idempotency-Key` (a UUID made once per user action, kept
  across its retries), or the server derives one from what the action means (order id + operation). A key made per
  HTTP attempt protects nothing: every retry is new.
- **Scoped to the caller.** Store it per account or API client, so two callers cannot collide or read each other's
  result.

## Claiming it
- **Atomically.** Insert the key under a unique constraint (or an equivalent conditional write) before the side
  effect runs. "Look it up, then insert" leaves a window where two retries both find nothing and both charge.
- **With a fingerprint of the payload.** Store a hash of the normalised body with the key.

## Answers
| The request | The answer |
|---|---|
| New key | Run it; store the outcome with the key |
| Same key, same payload, finished | The stored response, status code included, without running it again |
| Same key, different payload | `422` (or `409`): a client bug, never a silent replay of the first result |
| Same key, first attempt still running | `409` with `Retry-After`, or wait briefly, or `202` with a status URL; never a second run |

Three outcomes are stored: **succeeded** (replay it), **failed in a way the client can fix** (replay the 4xx), and
**failed before or during the side effect** (5xx, timeout): release the key, or mark it retryable, so the next
retry can run. Storing a 5xx as final turns a passing outage into a permanent failure for that action.

## Retention
Keep a key longer than the longest retry chain any client runs (its backoff schedule and the queue's redelivery
window), and say how long in the API docs. A key dropped after one hour is useless to a client that retries for a
day.

## Review checks
- The side effect and the key claim are in one transaction, or the key is claimed first and the effect is
  conditional on it.
- A downstream call (payment provider, email) gets its own idempotency key, derived from ours.
- A test sends the same key twice in parallel and finds one effect.
