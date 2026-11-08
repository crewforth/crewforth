// What each kind of agent spent, for the summary box: under "Agents", one line per agent type.
//
// The numbers are the graph's: every agent node carries its own share of the session's tokens (`usage`), counted
// once per response whichever file repeated it. This file only adds them up by type, with the same rule the
// graph's groups use (graph-plan.js `sumOf`): an agent with no usage read adds nothing, and a cost is a dash when
// any member's is, so a sum never passes for the whole.

import { sumOf } from './graph-plan.js';
import { fmtCount, fmtCost } from './usage.js';
import { typeOf, roleName } from './names.js';

/**
 * [role, "new tokens · ~cost"] pairs, the most-spent first: the shape `summaryRows` opens under a row.
 * A type that ran more than once says how many times. Empty when no agent has a usage to add.
 */
export function agentSpendRows(nodes) {
  const byType = new Map();
  for (const n of nodes ?? []) {
    if (n?.kind !== 'agent' || !n.usage) continue;
    const type = typeOf(n);
    if (!byType.has(type)) byType.set(type, []);
    byType.get(type).push(n);
  }
  return [...byType]
    .map(([type, members]) => ({ type, runs: members.length, sum: sumOf(members) }))
    .filter((g) => g.sum.fresh || g.sum.cacheRead)
    .sort((a, b) => b.sum.fresh - a.sum.fresh || (a.type < b.type ? -1 : 1))
    .map((g) => [
      g.runs > 1 ? `${roleName(g.type)} ×${g.runs}` : roleName(g.type),
      `${fmtCount(g.sum.fresh)} · ${fmtCost(g.sum.cost)}`,
    ]);
}
