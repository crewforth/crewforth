# A CLI an agent calls

Not every tool needs a server. A command-line tool the agent runs through its shell is cheaper to build and to
debug, and the same design rules apply: the output is read by a model, so its shape is the interface.

1. **stdout is always valid JSON** in the machine mode (`--json`, or by default when stdout is not a terminal),
   on success and on failure alike. Human text, progress and warnings go to stderr. One stray line on stdout and the
   caller's parse fails.
2. **Too much output drops whole results, never half of one.** Cut at a fixed size, keep complete items, and end
   with a truncation object: `{"truncated": true, "shown": 50, "total": 1240, "full_response_path": "/tmp/x.json"}`.
   The agent reads the file in a second call when it needs the rest.
3. **Typed exit codes, documented in `--help`**:

   | Code | Means |
   |---|---|
   | 0 | Success (an empty result is still success) |
   | 1 | The operation failed; the JSON says why |
   | 2 | Bad usage: a flag or argument was wrong |
   | 3 | Not found |
   | 4 | Not allowed (auth, permission) |

   Pick codes once and never reuse one for a second meaning; the agent branches on them.
4. **Search writes to a file, parsing is a separate call.** A broad search returns a count and a path, and the agent
   then reads or filters that file. Streaming thousands of hits through the context costs more than the answer.
5. **A "Do not use when" section in `--help`** names the cases another tool handles better ("for a single file, read
   it directly"). The model reads help text the way it reads a tool description.
