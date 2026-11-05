# good: the plan names the two readings of "one trial", says which one was implemented, and the code enforces it.
# bad: the plan quietly picks a reading and the code enforces it, so a reader cannot tell a choice was made.
good() {
  cat > PLAN.md <<'EOF'
# Plan: one trial per user

Open question: "one trial" can mean one trial ever (across all plans) or one trial per plan, since users move
between plans. It is also unclear whether a trial cancelled early still counts.

Assumption until confirmed: one trial per account, ever, and a cancelled trial still counts.

Steps:
1. startTrial checks for any earlier trial by the same user and throws if one exists.
2. activeTrial and cancelTrial stay as they are.
EOF
  cat > src/trial.js <<'EOF'
// Trials. A trial runs 14 days; cancelling ends it early. One trial per account, ever.
const trials = [];   // { userId, plan, startedAt, cancelledAt }

export function startTrial(userId, plan) {
  if (trials.some(t => t.userId === userId)) throw new Error('trial already used');
  trials.push({ userId, plan, startedAt: Date.now(), cancelledAt: null });
}

export function cancelTrial(userId) {
  const t = trials.find(t => t.userId === userId && !t.cancelledAt);
  if (t) t.cancelledAt = Date.now();
}

export function activeTrial(userId) {
  return trials.find(t => t.userId === userId && !t.cancelledAt) || null;
}
EOF
}
bad() {
  cat > PLAN.md <<'EOF'
# Plan

1. In startTrial, look up the user's earlier trials.
2. Throw an error when one is found.
3. Leave cancelTrial and activeTrial unchanged.
EOF
  sed -i.bak 's/^export function startTrial(userId, plan) {$/export function startTrial(userId, plan) {\
  if (trials.some(t => t.userId === userId)) throw new Error("trial already used");/' src/trial.js && rm -f src/trial.js.bak
}
