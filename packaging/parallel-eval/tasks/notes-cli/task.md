Add three commands to the notes CLI (notes.js), each with tests in test/:

1. `notes search <text>`: prints the notes whose text contains <text>, case-insensitive, as `#id text`, one per line; exit 1 when none match.
2. `notes export --csv`: prints `id,text,createdAt` then one line per note, quoting a field that contains a comma or a quote (CSV rules).
3. `notes stats`: prints `notes: N`, `longest: #id (L chars)` and `average: X.X chars`; with no notes, `notes: 0` only.

Keep the existing behaviour and tests passing. The tests run with `node --test`.
