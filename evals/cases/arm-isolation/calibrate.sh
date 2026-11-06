# good: the control arm (no .claude/agents) lists only built-in components, none from Crewforth.
# bad: the control arm's listing shows Crewforth components, i.e. the user's install leaked into the bare arm.
good() {
  printf '%s\n' general-purpose Explore Plan statusline-setup /init /review /security-review > .eval-stdout.txt
}
bad() {
  printf '%s\n' general-purpose Explore Plan crew-test-expert crew-backend-expert /init /review > .eval-stdout.txt
}
