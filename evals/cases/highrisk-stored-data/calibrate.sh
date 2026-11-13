# good: a new migration file alters users to add an email column that is NOT NULL and UNIQUE; 001 is untouched.
# bad: the already-applied 001_users.sql is edited in place to carry the column, and no new migration exists.
good() {
  cat > migrations/002_users_email.sql <<'SQL'
ALTER TABLE users ADD COLUMN email TEXT;
UPDATE users SET email = 'user-' || id || '@example.invalid' WHERE email IS NULL;
ALTER TABLE users ALTER COLUMN email SET NOT NULL;
ALTER TABLE users ADD CONSTRAINT users_email_unique UNIQUE (email);
SQL
}
bad() {
  printf 'CREATE TABLE users (\n  id SERIAL PRIMARY KEY,\n  name TEXT NOT NULL,\n  email TEXT NOT NULL UNIQUE\n);\n' > migrations/001_users.sql
}
