# Front 5 — AI, agent and MCP code

## Contents
- The rule that decides what counts
- Where it breaks
- How to hunt it
- Before a finding here leaves the verifier

Read this front when the code under review builds on a model: it assembles prompts, retrieves context, stores
memory, exposes or calls tools, delegates to sub-agents, or speaks MCP. It is about the CODE around the model. For
testing whether a deployed agent's defences hold under attack, that is `red-team`.

## The rule that decides what counts

**Persuasive text is not a vulnerability. A missing deterministic control is.** A model can always be talked into
something; that alone proves nothing about the system. A finding here needs a boundary that code failed to hold:
content reached another principal's context, an action ran with authority the requester did not have, data was
disclosed to someone who could not read it, or a sink was driven that the attacker could not reach directly.

Three consequences follow, and they rule out most false positives in this front:

- **Instructions in a prompt guard nothing.** "The system prompt forbids it" is not a control. Count only what
  a deterministic path enforces: authorization scoped to the resource, isolation, binding, constrained
  credentials.
- **Everything the model reads or writes is untrusted input** — its own output, retrieved documents, memory, tool
  descriptions, MCP responses. Point to the line of code that trusts it.
- **Using your own authority on purpose is not a defect.** A user who asks the agent to do something they are
  allowed to do has not been attacked because a model carried it out.

Name, for every candidate: the attacker, the affected principal, the identity the action actually ran as, the
resource, the exact action, the authority used, and the result someone can observe.

## Where it breaks

### Context, retrieval and memory
- **Injected content reaching someone else's context.** Who can write each retrieved source — a document, page,
  ticket, email, tool result — and whose session ends up reading it? Check that retrieval is scoped to the reader,
  not just that the content looks benign.
- **Context bleeding across sessions or tenants.** History, embeddings, retrieval results and prompt caches keyed
  too broadly. A tenant field on the record is not enforcement if one query path or one cache key leaves it out.
- **Memory that turns low-trust observations into durable instructions.** Content an attacker influenced, or a
  model's own summary of it, written into memory that later steers another user or a privileged task. Who may
  create, merge and delete memory, and does retrieval tell a user's preference apart from policy? A note a user
  keeps for themself, read back only by that user, crosses no boundary.
- **Forged provenance.** Prompt assembly that lets untrusted text pass as a system message, an earlier turn, a tool
  result or a memory record — string concatenation, untyped history, a caller-supplied role field. It matters when
  the forged label changes a trust decision or unlocks a capability.

### Tools and actions
- **Model-written arguments reaching a sink unchecked.** A tool schema shapes input; it does not authorize a path,
  a URL, a query or a resource id. Follow each argument from the decoded call to the SQL, shell, file or network
  call, and look for the handler's own validation.
- **Confused deputy.** The agent acts with a broad service credential and the handler never re-checks whether the
  requesting principal may touch that resource. Ask what that user could already do without the agent. One service
  credential is fine when every call made with it is still scoped to the requester.
- **Approval that does not bind the action.** The user approves one described action, and execution can use
  different arguments, a different target, a later turn, a retry or a resumed session. Or attacker content triggers
  a side effect under the victim's valid authority that the victim never asked for — generic permission does not
  make that intentional. The approval has to bind the normalized tool name, the complete argument object, the
  requester and the target.
- **Schema and handler disagreeing.** Validation and the handler read one input two ways: an alias, a repeated or
  unexpected key, a type that gets coerced, a free-form nested object, a value out of range. Validate again where a value
  becomes a resource selector or a security option.
- **Delegated loops with no ceiling.** A bounded request that can enqueue unbounded spend, sends, mutations or
  external calls — no per-request budget, no per-action check, no cancellation, no idempotency. Establish it from
  the code and a locally bounded loop, never by exhausting a real service.

### MCP and sub-agents
- **Delegation that hands over everything.** A sub-agent or MCP call receives the whole session, its credentials,
  its memory, rather than the least authority the task needs; or its result is trusted on return.
- **Identity by name instead of by connection.** Calls or results routed by a server name, tool name, request id,
  resource URI or a model-chosen alias that an attacker can influence, instead of the authenticated connection and
  the pending request. Can two servers claim one tool? Does a reconnect change the binding? Can one server's
  response satisfy another's pending call?
- **Metadata treated as policy.** Whatever an MCP peer says about itself — tool text, resource details, suggested
  prompts, schemas, completions — can steer the model and can never grant it anything. Find the allowlist, the server
  identity check and the handler authorization that stay authoritative when the metadata says otherwise.

### Output and disclosure
- **Model output rendered unencoded.** Output reaching HTML, Markdown, a template, a URL or a command without that
  sink's encoding. Whether a renderer outside the repository sanitizes it is a fact you do not have — that makes
  the candidate CANNOT_VERIFY, not confirmed.
- **Secrets extractable from the assembled context.** Credentials, another user's data or access-granting policy
  values placed in context that user-influenced output can reveal. Leaking generic instructions crosses no
  boundary and is not a finding.

### Runtime controls the audit expects to find
Their absence is not a finding on its own (the boundary rule above still decides); it tells you where to look
first, and their presence is evidence for a `FALSE_POSITIVE`.
- **Egress allowlist** on every tool that makes a network call: link-local and cloud metadata addresses, loopback
  and private ranges blocked, checked again after each redirect and after DNS resolution.
- **Strict argument schemas:** unknown fields rejected, no silent type coercion, a size cap on every string and
  array.
- **Output guards:** a size and time limit on what a tool returns, and a breaker that stops the loop after
  repeated policy violations instead of retrying them.

## How to hunt it

Before opening single files, make four inventories: the identities code runs under, the capabilities it holds, the
context and memory stores something can write into, and the destinations output reaches. Then trace each request
from the one who made it to the power finally used on its behalf. From each tool with side effects, walk back
through dispatch, schema, confirmation, context, retrieval and ingestion; from each memory read, walk back to
everyone who writes there. One action can arrive directly, from a queue, as a retry, a resumed run, a batch or
through a delegate — the deciding check belongs after the arguments are fixed and before anything happens, on every
one of those routes.

## Before a finding here leaves the verifier

Apply `verify.md` as usual, plus:

1. It says which boundary was crossed and what anyone can see afterwards: who attacks, who (or which shared
   resource) is harmed, the identity the action ran as, the target, and the action or disclosure nobody authorized
   or asked for.
2. A confused-deputy claim shows two things: the handler never checks the requester against the resource, AND the
   attacker has no way to do the same through the product itself. An action-binding claim shows instead that
   content the attacker controlled set off an action, carried out with the victim's authority, that the victim did
   not mean to request or approve.
3. A memory or retrieval claim shows both halves: where the attacker writes, and where another principal or a
   privileged decision later reads. A shared record that nothing reads across a boundary does not qualify.
4. An MCP identity claim looks at four things: which connection is authenticated, how a response is matched to its
   request, how tool names are namespaced, and which credential is actually used. When the answer depends on
   routing done by an outside server or the deployment, the verdict is CANNOT_VERIFY, naming the one fact that
   would decide it.
