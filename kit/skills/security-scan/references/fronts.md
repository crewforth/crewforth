# Review fronts

## Contents
- Front 0 — Discovery (map the surface)
- Front 1 — Dependencies
- Front 2 — Code (source→sink tracing)
- Front 3 — Configuration
- Front 4 — Authentication + session + authorization
- Front 5 — AI, agent and MCP code
- Front 6 — CI/CD (workflows and runners)

The scan applies the **source → gate → sink** model on these fronts. Read the fronts you're scanning.

## Front 0 — Discovery (map the surface)

The rest of the audit rests on the map produced here.

1. Scan for manifest/build files at the root and in subdirectories: `package.json`, `requirements.txt`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `Gemfile`, `pom.xml`, `build.gradle`, `composer.json`, `*.csproj`, `*.sln`, `mix.exs`. In a monorepo, note each ecosystem separately.
2. Derive the framework and runtime from the manifest.
3. **List the attack surface:** all the points where user input enters the system (the "Source" list above). These are the starting points for the following fronts.
4. Run a **web search** for the detected framework — tooling and patterns change often: `"[framework] security best practices"`, `"[framework] common vulnerabilities"`, the current `"OWASP Top 10"` list.

---

## Front 1 — Dependencies

Known vulnerabilities in third-party packages are the cheapest path to most breaches.

1. Run the audit command that suits the ecosystem (if it is not installed, suggest installing it, do not install it yourself):

   | Ecosystem | Command |
   |---|---|
   | Node | `npm audit` · `pnpm audit` · `yarn npm audit` |
   | Python | `pip-audit` |
   | .NET | `dotnet list package --vulnerable --include-transitive` |
   | Rust | `cargo audit` |
   | Go | `govulncheck ./...` |
   | Ruby | `bundle audit` |
   | Java | OWASP Dependency-Check |

2. If you are unsure of the correct/current command, verify it on the web; where possible, get machine-readable output with `--json`.
3. Extract from each finding: package · installed version · vulnerability id (CVE/GHSA) · severity · fixed version.
4. In a monorepo, audit each sub-project separately. The results go into the report (below).

---

## Front 2 — Code (source→sink tracing)

Start from every entry point on the attack surface, trace the input to where it is used, and check whether there is a gate in between. The table below is the **minimum** coverage — if you see another sink during the scan, add it.

A source is not only an HTTP request: a WebSocket, gRPC or SSE message is input too. Check authentication at the upgrade **and** per message where the channel outlives the session, the `Origin` of a WebSocket upgrade, method-level authorization on gRPC, and that gRPC reflection is off in production.

| Sink class | Vulnerability | What the "gate" should be |
|---|---|---|
| **Query** | SQL / NoSQL / LDAP / ORM raw query injection | Parameterized query; no string concatenation |
| **Command** | Shell/OS command injection | Argument array; no passing a string to the shell |
| **Render** | XSS (input in HTML without escaping), SSTI (input as template code) | Context-appropriate escaping; input as data, not code |
| **Path** | Path traversal, unrestricted file upload | Path allowlist/normalization; type-size-content validation |
| **Object** | Insecure deserialization, mass assignment | Safe format; field allowlist |
| **Expression** | Expression/eval injection, `eval`/`exec` | Never evaluate input as code |
| **Outbound request** | SSRF: the server fetches a URL or host the input chose (webhooks, URL previews, importers, PDF/image renderers) | An allowlist of hosts, or a check of the **resolved** address against private, loopback, link-local (`169.254.169.254` metadata) and RFC 1918 ranges before connecting; redirects not followed, or each hop checked again; the check and the connection use the same resolved IP (re-resolving opens DNS rebinding) |
| **Redirect** | Open redirect: a `next=` / `returnUrl` sends the user to a site the input chose | A relative path, or a host allowlist; `http(s)` only (no `javascript:`, no `//evil`) |
| **Parser** | XXE: an XML parser that resolves external entities or a DTD | External entities and DTD processing off |
| **Destructive op on a derived path** | A delete, overwrite or move whose path comes from input (`../`, a symlink, an absolute path) | Canonicalize, then require the result under an allowlisted root; ownership of the target proven from the authenticated state, not from the request |
| **State change** | A race in check-then-act on money, stock or a quota (two requests both pass the balance check) | An atomic conditional update (`UPDATE … WHERE balance >= :x`), a row lock, or an idempotency key on the request |

**On state-changing + browser-originating endpoints, additionally:**
- **CSRF** — does the state-changing endpoint have token protection?
- **CORS** — is there a wildcard origin with credentials, or an origin reflected without validation?

**Secret leakage — hardcoded credentials in the source:** search for these patterns, excluding `.env.example` and test fixtures:
```
(password|api[_-]?key|secret|token)\s*[:=]\s*["'][^"']+["']
-----BEGIN (RSA |EC |DSA )?PRIVATE KEY-----
```
Also: unmasked password/token/PII in logs; a stack trace or internal path leaked to the user.

**Tracing method:** read the route/controller files (input enters here) → grep for dangerous calls (`eval`, `exec`, string-SQL) → check whether the middleware/interceptor has auth·CSRF·rate-limit → check whether the data model has mass-assignment protection. Run a web search for language-specific dangerous functions.

**Record for each finding:** file:line · vulnerability · what an attacker could do (impact) · fix specific to this code.

---

## Front 3 — Configuration

**Is a secret in the repo:**
```bash
git ls-files --error-unmatch .env 2>/dev/null && echo "WARNING: .env is tracked"
```
If it's a finding, CRITICAL: `git rm --cached .env` → add to `.gitignore` → **rotate the exposed secrets**.

**Debug on in prod:** search for the framework-specific flag with `"[framework] debug mode production"`. Signs: an open debug flag, an error page showing a stack trace, a published source map, accessible development endpoints.

**Insecure transport:** hardcoded `http://` addresses (API, webhook, OAuth redirect, CDN) that should be `https`, and cookies without `Secure`. Exclude `localhost`/`127.0.0.1`/`0.0.0.0`.

**Missing security headers:** CSP, HSTS, X-Frame-Options, X-Content-Type-Options.

---

## Front 4 — Authentication + session + authorization

Access-control flaws are the class most often missed in a scan, because the code appears to "work." Mandatory if the project includes admin/dashboard or role-based access:

1. Enumerate all roles/levels (admin, moderator, user, guest…).
2. Write all routes/endpoints and the **required** permission level into a matrix.
3. Verify that each protected route actually checks — "being logged in" is not authorization.
4. Look for endpoints that should be protected but aren't; try whether there is an admin endpoint reachable by guessing the URL.
5. Verify that authorization is enforced both at the controller **and** at the data-access layer (IDOR: object reference without ownership validation).
6. Privilege escalation: can a user change their own role/permission? Does a sensitive admin action require extra protection (re-auth/2FA)?
7. **JWT:** `alg: none` / algorithm confusion, secret embedded in code, missing expiration; `aud` and `iss` checked,
   the algorithm pinned by the verifier and never read from the token; a `kid`, `jku` or `x5u` header never chooses
   a key from outside the configured set; `jti` (or a session record) lets a token be revoked before it expires.

Authentication and the session are the same front: a correct permission check on a session an attacker owns
protects nothing. Answer each with the line that does it:

8. **Account discovery:** login, signup and reset answer an unknown and a known account alike — same status, same
   message, no timing gap an attacker can measure.
9. **Guessing:** login, OTP and reset are rate-limited per account and per source, with a lockout or backoff that
   an attacker cannot turn into a denial of service against a named user.
10. **Reset token:** single use, unpredictable, short-lived, bound to the account; the reset link is built from
    configuration, never from the request's `Host` header, and the token never reaches a third party via `Referer`.
11. **Session lifecycle:** a new session id on login, logout and any privilege change (no fixation); logout
    invalidates the session on the server, not only the cookie; a remember-me token has real entropy and is
    stored hashed.
12. **Refresh tokens:** rotated on every use, and a reused old one revokes the whole family.
13. **MFA:** cannot be skipped by calling the step after it, disabled without re-authentication, or bypassed
    through enrollment of a new factor.
14. **OAuth / OIDC:** `state` checked, `redirect_uri` matched exactly (no prefix or wildcard), PKCE on public
    clients.

## Front 5 — AI, agent and MCP code

Only when the code under review builds on a model. The classes, the rule that decides what counts, and the extra
checks a finding must pass before it leaves the verifier are in **`ai-agents.md`**.

## Front 6 — CI/CD (workflows and runners)

Only when the repository carries pipeline definitions (`.github/workflows/`, `.gitlab-ci.yml`, `azure-pipelines.yml`,
a `Jenkinsfile`). A pipeline runs with the repository's secrets and its write token, so each question below is a gate:
a "no" is a finding, not a style note. Written for GitHub Actions; the same questions apply to the others.
1. **Pinned actions:** every third-party action is pinned to a full commit SHA (`uses: owner/action@<40 hex>`, with
   the version in a comment). A tag or branch can be moved under you to code that reads every secret.
2. **No untrusted text in `run:`:** no `${{ github.event.issue.title }}`, `…pull_request.body`, `…head_ref`,
   `…comment.body` or other attacker-written field interpolated into a shell line. Pass it through `env:` and quote
   the variable; interpolation is script injection with the workflow's token.
3. **`pull_request_target`:** never checks out and runs the pull request's code (`actions/checkout` with the PR head
   ref, then a build or test). That trigger runs with secrets and a write token on code a stranger wrote.
4. **Least privilege:** `permissions:` is set at the top (`{}` or `contents: read`) and widened per job only where a
   job needs it; `persist-credentials: false` on a checkout whose job does not push.
5. **Short-lived credentials:** cloud and registry access through OIDC whose trust policy is scoped to this
   repository, branch or environment, not a long-lived key in a secret. A trust policy that accepts any branch, or
   any repository of the organisation, is a finding.
6. **Forks cannot reach secrets:** a workflow a fork's pull request can trigger gets no secret and no write token;
   anything that needs them runs after a maintainer's approval or on the base repository's own events.
7. **Runners:** no self-hosted runner serves a public repository: a fork's pull request runs on that machine.
