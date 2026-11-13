# Security policy

## Reporting a vulnerability

Please report it privately through a GitHub security advisory:
<https://github.com/Crewforth/crewforth/security/advisories/new>.
Do not open a public issue for a security problem. Include the version (`VERSION`, or `npx crewforth --version`),
the platform, and the smallest steps that show it.

A bypass of a gate counts: a command, a file write or a commit that a gate is documented to stop and does not.

## What Crewforth does not stop

The gates stop accidents and ordinary mistakes, not a determined attempt. Every gate and its known limits:
<https://crewforth.com/gates>. In short:

- **A process outside the session.** The hooks see what Claude Code asks to run; a script, a package install
  hook or a test the agent wrote runs with your user's rights once it starts.
- **Reading.** Nothing stops the model from reading a file it can reach; secrets on disk are readable.
- **Your own terminal.** A commit or push you run yourself, or `--no-verify`, passes the git gates by design.
- **A rule written to be evaded.** Shell gates match command shapes; a command assembled from pieces or run
  through an interpreter can pass one.
- **Prompt injection, fully.** The rules and notices make injected text visible and ask before acting on it;
  they are model discipline, not a sandbox.
- **Unvetted skills and agents.** A component Crewforth did not ship is named at session start, not blocked.

For a hard boundary, run the session in a devcontainer or a VM with only the credentials the task needs.
