# MCP: protocol, skeletons, transport, testing

Loaded on demand. SKILL.md is the design discipline; this is the concrete how.

## The three primitives

- **Tools** — actions the model invokes (side effects allowed): `create_ticket`, `search_orders`. This is what most servers are for.
- **Resources** — readable data addressed by URI the client can pull into context: `file://…`, `db://customers/42`. Read-only.
- **Prompts** — named, parameterized templates the user/client can invoke. Optional; add only if you have reusable flows.

Start with tools. Add resources when the client needs to *read* your data as context; add prompts only if there's a real reusable template.

## Transport — pick by where it runs

- **stdio** — the server is a local subprocess of the client (desktop app, CLI). Simplest; no network, no auth. Default for local/dev tools.
- **Streamable HTTP / SSE** — the server is remote (hosted, shared). You now own auth, CORS, and network errors. Use only when the tool must be remote/multi-user.

## Skeletons

**TypeScript (`@modelcontextprotocol/sdk`):**
```ts
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const server = new McpServer({ name: "orders", version: "1.0.0" });

server.tool(
  "search_orders",
  "Search orders by customer email. Returns up to 20 orders, newest first.",
  { email: z.string().email(), limit: z.number().int().min(1).max(20).default(20) },
  async ({ email, limit }) => {
    const orders = await db.findOrders(email, limit);        // your logic
    if (!orders.length) return { content: [{ type: "text", text: `No orders for ${email}.` }] };
    return { content: [{ type: "text", text: JSON.stringify(orders) }] };
  }
);
await server.connect(new StdioServerTransport());
```

**Python (FastMCP):**
```python
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("orders")

@mcp.tool()
def search_orders(email: str, limit: int = 20) -> str:
    """Search orders by customer email. Returns up to 20 orders, newest first."""
    orders = db.find_orders(email, limit)          # your logic
    return f"No orders for {email}." if not orders else json_dumps(orders)

if __name__ == "__main__":
    mcp.run()          # stdio by default
```

Both: the **docstring/description is the model's interface** — write it as the design step demands. Types drive the input schema (zod / Python type hints) — no hand-written JSON-Schema needed with these SDKs.

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
