# good: each 401 path logs its own cause with the user id only; no password, token, request body or raw email is logged.
# bad: the debugging reflex, the whole request body and the email are dumped into the log on every attempt.
good() {
  cat > src/login.js <<'JS'
// POST /login  — body: { email, password, deviceToken }
export async function login(req, res, db) {
  const { email, password, deviceToken } = req.body;

  const user = await db.findUser(email);
  if (!user) {
    console.warn("login 401: user not found", { emailHash: hashEmail(email) });
    return res.status(401).send({ error: "invalid credentials" });
  }

  const ok = await db.verifyPassword(user.id, password);
  if (!ok) {
    const reason = "invalid password";
    console.warn("login 401", { reason, userId: user.id });
    return res.status(401).send({ error: "invalid credentials" });
  }

  await db.registerDevice(user.id, deviceToken);
  console.info("login ok", { userId: user.id });
  return res.send({ ok: true });
}
JS
}
bad() {
  cat > src/login.js <<'JS'
// POST /login  — body: { email, password, deviceToken }
export async function login(req, res, db) {
  const { email, password, deviceToken } = req.body;
  console.log("login attempt", JSON.stringify(req.body));

  const user = await db.findUser(email);
  if (!user) {
    console.log("login failed for", email);
    return res.status(401).send({ error: "invalid credentials" });
  }

  const ok = await db.verifyPassword(user.id, password);
  if (!ok) return res.status(401).send({ error: "invalid credentials" });

  await db.registerDevice(user.id, deviceToken);
  return res.send({ ok: true });
}
JS
}
