# Install count endpoint

The Cloudflare Worker that receives Crewforth's install count. `bin/cli.js` sends `GET <endpoint>/install?v=<version>`
once per project after a successful `init`; README → Telemetry says what is and is not sent and how to turn it off.
This folder is not in the npm package.

The Worker keeps one number per day and version, `"<YYYY-MM-DD>|<version>"`, in a KV namespace. It reads nothing else
from the request, and request logging is off.

## Deploy (once)

```bash
cd packaging/install-ping-worker
npx wrangler login
npx wrangler kv namespace create COUNTS          # put the printed id into wrangler.toml
npx wrangler secret put READ_KEY                 # any long random string; it guards /count
npx wrangler deploy                              # prints https://crewforth-install-count.<account>.workers.dev
```

Then set `INSTALL_COUNT_URL` in `bin/cli.js` to the printed address. Until that constant is set, nothing is sent and no
notice is printed.

## Read the counts

```bash
curl -s -H "Authorization: Bearer $READ_KEY" https://crewforth-install-count.<account>.workers.dev/count
```

## Limits

KV has no atomic increment, so two installs in the same instant can be counted once. Anyone can call `/install`, so
the count can be inflated. Read it as a weekly trend and a lower bound, not as a number of users.
