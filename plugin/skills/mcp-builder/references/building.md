# MCP: protocol, skeletons, transport, testing

Loaded on demand. SKILL.md is the design discipline; this is the concrete how.

## The three primitives

- **Tools** — actions the model invokes (side effects allowed): `create_ticket`, `search_orders`. This is what most servers are for.
- **Resources** — readable data addressed by URI the client can pull into context: `file://…`, `db://customers/42`. Read-only.
- **Prompts** — named, parameterized templates the user/client can invoke. Optional; add only if you have reusable flows.

Start with tools. Add resources when the client needs to *read* your data as context; add prompts only if there's a real reusable template.

## Transport — pick by where it runs

- **stdio** — the server is a local subprocess of the client (desktop app, CLI). Simplest; no network, no auth. Default for local/dev tools.
  **stdout is the protocol.** Every byte the server prints there must be a protocol message: a stray `console.log`,
  `print` or a library banner corrupts the stream and the client drops the connection. Logs go to stderr.
- **Streamable HTTP** — the server is remote (hosted, shared). You now own auth, CORS, and network errors. Use only when the tool must be remote/multi-user.
  The older HTTP+SSE transport is legacy: serve it only for a client that cannot speak Streamable HTTP.
  A local HTTP server (a dev server, a desktop helper) binds `127.0.0.1`, never `0.0.0.0`, and validates the `Host`
  and `Origin` headers: without that a web page the user opens can reach it through DNS rebinding.

## Skeletons

Checked: 2026-11-07 against https://github.com/modelcontextprotocol/typescript-sdk (README, v2 on `main`,
`@modelcontextprotocol/server`) and https://github.com/modelcontextprotocol/python-sdk (README and
docs_src/run/tutorial003.py, v2). Re-check before quoting either as current after 90 days.

**TypeScript (`@modelcontextprotocol/server`, SDK v2):**
```ts
import { McpServer } from "@modelcontextprotocol/server";
import { StdioServerTransport } from "@modelcontextprotocol/server/stdio";
import * as z from "zod/v4";

const server = new McpServer({ name: "orders", version: "1.0.0" });

server.registerTool(
  "orders_search",
  {
    title: "Search orders",
    description: "Search orders by customer email. Returns up to 20 orders, newest first.",
    inputSchema: z.object({ email: z.string().email(), limit: z.number().int().min(1).max(20).default(20) }),
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  async ({ email, limit }) => {
    const orders = await db.findOrders(email, limit);        // your logic
    if (!orders.length) return { content: [{ type: "text", text: `No orders for ${email}.` }] };
    return { content: [{ type: "text", text: JSON.stringify(orders) }] };
  }
);
await server.connect(new StdioServerTransport());
```
On SDK v1 (`@modelcontextprotocol/sdk`, still maintained on its `v1.x` branch) the imports are
`@modelcontextprotocol/sdk/server/mcp.js` and `.../server/stdio.js`; follow the project's installed major.

**Python (`mcp`, SDK v2; v1 called the class `FastMCP`):**
```python
from mcp.server import MCPServer

mcp = MCPServer("orders")

@mcp.tool()
def orders_search(email: str, limit: int = 20) -> str:
    """Search orders by customer email. Returns up to 20 orders, newest first."""
    orders = db.find_orders(email, limit)          # your logic
    return f"No orders for {email}." if not orders else json_dumps(orders)

if __name__ == "__main__":
    mcp.run()          # stdio by default
```

Both: the **docstring/description is the model's interface** — write it as the design step demands. Types drive the input schema (zod / Python type hints) — no hand-written JSON-Schema needed with these SDKs.

## Names, hints and pages

- **Prefix tool names with the service**: `orders_search`, `orders_refund`. A client with several servers loaded
  shows the model one flat list, and two servers' `search` are indistinguishable.
- **Annotations are hints, never authorisation.** `readOnlyHint`, `destructiveHint`, `idempotentHint` and
  `openWorldHint` tell the client what to put in front of the user (auto-approve a read, confirm a delete). They
  change nothing about what the handler allows, and a client is free to ignore them (invariant 6 in SKILL.md).
- **A list that can grow is paged.** Return a page and an opaque `nextCursor`; accept the cursor back; keep the page
  size fixed and stated in the description. A tool that returns "all" works in the demo and floods the context in
  production.

## Error handling

- Validate at the boundary — the SDK schema rejects wrong *types*; you still check *semantics* (does the id exist? is the caller allowed?).
- Return errors as normal tool results with clear text the model can act on, or throw the SDK's error type for protocol-level failures. Never let an unhandled exception kill the process on bad input.
- Don't leak internals (stack traces, connection strings) in error text.

### Path inputs

A path that comes from the model is attacker-shaped. Accept only a path relative to one root the server owns, and
reject before touching the disk:

- absolute paths in any OS form: `/etc`, `C:\x`, `C:/x`, `\\server\share`
- a drive-relative path (`C:foo`) and a home shortcut (`~`, `~user`)
- any `..` segment, split on both `/` and `\`

Then resolve and check again: the lexical check stops the obvious forms, the resolved check stops a symlink that
points out of the root.

```ts
import path from "node:path";
import fs from "node:fs/promises";

async function safePath(root: string, input: string): Promise<string> {
  const parts = input.split(/[\\/]/);
  if (path.isAbsolute(input) || /^[A-Za-z]:/.test(input) || input.startsWith("~") || parts.includes(".."))
    throw new Error("E_PATH_REJECTED");
  const realRoot = await fs.realpath(root);
  const real = await fs.realpath(path.join(realRoot, input));      // follows symlinks
  if (real !== realRoot && !real.startsWith(realRoot + path.sep)) throw new Error("E_PATH_OUTSIDE_ROOT");
  return real;
}
```

## The test loop

1. **MCP Inspector** — `npx @modelcontextprotocol/inspector <run-command>` launches a UI that lists your tools/resources and lets you call them with arbitrary inputs. Verify each tool's schema, a happy path, and a bad-input path here first — fastest feedback.
2. **Real client** — register the server in an actual client (e.g. Claude Desktop / Claude Code `.mcp.json`) and confirm the model *discovers* it, *routes* to the right tool from a natural prompt (validates your descriptions), and handles the returned data.
3. **Edge cases** — empty results, invalid input, missing auth, large output. A tool is done when its failure modes are as clean as its happy path.

If the model picks the wrong tool or ignores yours, the bug is almost always the **description**, not the code — rewrite it and re-test in the real client.
