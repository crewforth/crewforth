# good: the comparison becomes strict, nothing else changes.
# bad: the operator is fixed but the change sprawls: a new clock helper file and a changed isValid signature.
good() {
  sed -i.bak 's/token\.exp >= nowSeconds/token.exp > nowSeconds/' src/auth.js && rm -f src/auth.js.bak
}
bad() {
  cat > src/clock.js <<'EOF'
export const nowInSeconds = () => Math.floor(Date.now() / 1000);
EOF
  cat > src/auth.js <<'EOF'
import { nowInSeconds } from './clock.js';

// A token is valid until its expiry instant, exclusive.
export function isValid(token, nowSeconds = nowInSeconds()) {
  return token.exp > nowSeconds;
}
EOF
}
