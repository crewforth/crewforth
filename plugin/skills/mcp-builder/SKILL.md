---
name: mcp-builder
description: |
  Build a Model Context Protocol (MCP) server so an AI client can call your tools/resources: design tool schemas,
  pick a transport, handle errors, and test it. For exposing an API, database, or service to Claude and other clients.
---

# MCP Builder

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "MCP server", "build an MCP", "model context protocol", "expose tools to Claude", "MCP tool"

An MCP server exposes **tools** (actions the model can call), **resources** (data it can read), and **prompts**
(reusable templates) to any MCP client over a standard protocol. The whole job is: **design a small set of clear,
well-described tools, validate their inputs, return useful errors, and prove it works with a real client.** The
protocol is easy; the design of the tools is what makes the server good or useless.

> **Crewforth adaptation (local, .claude/):** Stack-agnostic — TypeScript (`@modelcontextprotocol/sdk`) or Python
> (`mcp` / FastMCP) are the maintained SDKs; match the project's language. §4 Prohibitions apply (no AI trace in
> generated code/strings). Secrets (API keys the server needs) go via env, never hardcoded — Crewforth's secret gates apply.

## Design first (the tools ARE the product)
- **Few, purposeful tools** — expose *tasks*, not a 1:1 mirror of every API endpoint. "create_invoice" beats "post_v2_billing_documents".
- **The description is the interface** — the model routes on it. Say what it does, when to use it, and what it returns, in plain language. A vague description = an unused or misused tool.
- **Typed, validated inputs** — a JSON-Schema for each tool; required vs optional explicit; enums over free strings where possible. Reject bad input with a clear message, don't guess.
- **Useful returns & errors** — return structured, model-readable results; on failure return an actionable error ("no invoice with id X") not a stack trace. Never crash the server on bad input.
- **Least privilege** — a tool does one scoped thing; destructive actions are explicit and, where possible, confirmable. Don't expose raw SQL / shell unless that is genuinely the product.

## Checklist
- [ ] Tools chosen by task, not by mirroring endpoints
- [ ] Each tool has a clear description (what · when · returns) and a JSON-Schema input
- [ ] Inputs validated; bad input → clear error, not a crash
- [ ] Returns are structured and model-readable; errors are actionable
- [ ] Transport chosen (stdio for local, HTTP/SSE for remote) — see references
- [ ] Secrets via env; no hardcoded keys
- [ ] Path inputs are relative and contained: the reject list and the two-step check are in `references/building.md`
- [ ] Error text to the model is built from codes and safe fields; the raw exception goes to stderr
- [ ] Every tool declares its behaviour hints (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`)
- [ ] A tool whose reach you cannot bound (any path, any URL, any query) is not registered
- [ ] Large output returns a handle plus a read-range and a search tool, not the whole blob
- [ ] Shelling out: options first, then `--`, then untrusted values; admin verbs only behind an explicit mode the
      operator turns on
- [ ] Tested against a real client (Inspector + a live client)

**Consuming a server someone else wrote** (adding one to an agent, not building one): pin the server's version;
keep a fixture of the tool names you rely on and check it on upgrade; give the consuming agent only that server's
tools (`mcp__<server>__*`), not a wildcard; when the tools are absent, stop and say so, never fall back to
calling the API another way (curl, a script).

---

## Protocol, SDK skeletons, transport, and testing
Concrete server skeletons (TypeScript + Python), stdio vs. HTTP transport choice, resources/prompts (not just
tools), and the test loop (MCP Inspector → real client): **`references/building.md`**.

## Invariant rules
1. **Design the tools before writing them** — task-shaped, few, clearly described.
2. **Validate every input** — schema-checked; bad input returns an error, never crashes.
3. **Errors are for the model** — actionable text it can recover from, not raw traces.
4. **Secrets via env only** — never hardcode credentials the server needs.
5. **Prove it with a real client** — a server that only "looks right" is untested.
6. **Descriptions guide; they never authorize** — a tool's description, schema or metadata shapes what the model
   tries. Whether a call is allowed is decided in the handler, per requester and per resource, every time. A schema
   narrows shape; it does not make a path, URL or id safe.
7. **Bind identity to the connection, not to a name** — never route a call or accept a result by a tool name,
   server name or alias the other side can choose. How these fail is in `security-scan/references/ai-agents.md`.
