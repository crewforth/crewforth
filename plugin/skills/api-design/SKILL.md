---
name: api-design
description: |
  Use when an API contract is designed or changed: a new endpoint or resource, how its errors and pages
  are returned, a field to add or remove, or a version to cut without breaking a consumer.
---

# API Design

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "api design", "api contract", "api versioning", "openapi", "swagger", "rest contract", "breaking api change", "response shape", "response format", "endpoint returns", "error format"

Goal: a contract the consumer can **predict** and that can **evolve** without breaking. Once published, a
public API is a commitment; a breaking change is expensive. Stack-agnostic (REST as the baseline; GraphQL/gRPC follow similar principles).

## Checklist
- [ ] Resource names are **consistent** (plural nouns, a single `kebab`/`camel` style), resources not verbs
- [ ] Correct HTTP semantics: GET (side-effect free) · POST · PUT/PATCH · DELETE; correct **status code**
- [ ] A uniform **error model**: machine-readable code + human message + (if any) field details
- [ ] A clear **versioning** strategy (URL `/v1` or header); a breaking change means a new version
- [ ] **Pagination/filtering/sorting** defined and consistent on large collections
- [ ] **Backward compatibility**: adding a field is additive; removing a field or changing its meaning is breaking → version
- [ ] **Idempotency** (for POST/payment-like cases) supported via a key when needed: the key, its atomic claim and
  the answers to a replay are in **`references/idempotency.md`**
- [ ] The contract is documented in **OpenAPI**; example request/response present (coordinate with `docs-writer`)

## How
1. **Model the resource** — a noun not a verb: `POST /orders` (✓), `POST /createOrder` (✗).
2. **Status codes**: 200/201/204 · 400 validation · 401/403 authorization · 404 · 409 conflict · 422 · 429 · 5xx. Use them meaningfully.
3. **Error contract** — every error has the same shape:
   ```json
   { "code": "ORDER_NOT_FOUND", "message": "Order not found", "details": [] }
   ```
   No stack trace / internal detail leakage (overlaps with `security-scan`).
4. **Versioning**: additive changes in the same version; breaking (remove/rename a field / add a required field) → `/v2`.
5. **Collection**: pagination (cursor or offset), filter/sort parameters; a consistent envelope.
6. **Write the contract** — OpenAPI/schema; with examples. Wire the change to `docs-writer`, and if breaking to `release`/CHANGELOG.

## Breaking vs additive
| Additive (safe) | Breaking (needs a version) |
|---|---|
| Add an optional field/endpoint | Remove / rename a field |
| A new optional parameter | Add a required parameter |
| A new enum value (if the consumer is tolerant) | Change a type/meaning, change a status code |

**Observable behaviour is the contract,** not only the documented fields: someone depends on the error text, the
order of a list, the default page size and how long a call takes. Changing one of those is breaking for them; say
it in the changelog like a field change.

## Invariant rules
1. **A public API is a commitment** — a breaking change is not made silently; version + announcement.
2. **Consistency > local cleverness** — a single naming/error/pagination pattern across the whole API.
3. **The error model is uniform and machine-readable.**
4. **No internal detail leakage** — a stack trace / DB error does not go to the consumer.
5. **The contract is documented** — OpenAPI + example; at design time, not after the code.
