# Topology A — self-managed host (phases 1-5)

## Contents
- Phase 1 (A) — Surface: method and runtime
- Phase 2 (A) — Preparation: config, SSH, proxy, SSL
- Phase 3 (A) — Swap: keep the old, put the new
- Phase 4 (A) — Health gate
- Phase 5 (A) — Rollback

Read this only when Phase 0 answered **A**: you have SSH to a machine you own or rent, a release is a directory on
that host, and rollback means moving a pointer back. On topology B read `references/topology-b.md` instead — never
both, because mixing them is where deploys go wrong.

The invariant rules in SKILL.md hold over everything here: no deploy without approval, back up before the swap,
health-gate after it, keep the last three versions, the app binds to `127.0.0.1` only.

## Phase 1 (A) — Surface: method and runtime

```bash
if   [ -f Dockerfile ] || [ -f docker-compose.yml ]; then METHOD=docker
elif [ -f package.json ];                                then METHOD=bare RUNTIME=node
elif [ -f requirements.txt ] || [ -f pyproject.toml ];   then METHOD=bare RUNTIME=python
elif [ -f go.mod ];                                      then METHOD=bare RUNTIME=go
elif ls ./*.csproj ./*.sln >/dev/null 2>&1;              then METHOD=bare RUNTIME=dotnet
elif [ -f pom.xml ] || [ -f build.gradle ];              then METHOD=bare RUNTIME=java
elif [ -f Cargo.toml ];                                  then METHOD=bare RUNTIME=rust
elif [ -f Gemfile ];                                     then METHOD=bare RUNTIME=ruby
elif [ -f composer.json ];                               then METHOD=bare RUNTIME=php
else METHOD=unknown; fi
```
If `method: docker` and there's no Dockerfile, generate one. `method: bare` → a process manager suited to the runtime; build the release artefact with the runtime's own command (`dotnet publish -c Release`, `mvn package`, `cargo build --release`, …) and run it under systemd. Prefer Docker for any runtime whose bare setup needs a toolchain on the box. If detection is ambiguous, ask the user — never guess a runtime.

---

## Phase 2 (A) — Preparation: config, SSH, proxy, SSL

**Config** — read `.deploy.yml` from the root, and if it's missing ask for each field:
```yaml
host: 192.168.1.100        # VPS IP/hostname (required)
user: deploy               # SSH user (required)
ssh_key: ~/.ssh/id_rsa     # private key
app_port: 3000             # application port (required)
health_check: /api/health  # HTTP path (default /)
deploy_path: /var/www/app  # server path (required)
method: auto               # auto | docker | bare
domain: app.example.com    # for proxy/SSL (optional)
ssl: true                  # default true if there is a domain
reverse_proxy: auto        # auto | nginx | caddy
```
**Verify SSH first** — if you can't connect, stop immediately:
```bash
ssh -i $SSH_KEY -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new $USER@$HOST "echo OK"
```

**Reverse proxy** — detect the one installed on the server (`auto` → Caddy if present, otherwise Nginx). The application binds only to `127.0.0.1`; it is exposed outward **only** through the proxy.

**SSL** — skip if `ssl: false` or there's no domain, and never on a bare IP. On the Nginx path, verify DNS resolves to the host (`dig +short $DOMAIN` = `$HOST`) *before* running Certbot; on the Caddy path the certificate and its renewal are automatic and there is no separate step.

Config file contents for both proxies, the Certbot commands and the renewal timer: **`references/proxy-ssl.md`** — read the half for the proxy you found, not both.

---

## Phase 3 (A) — Swap: keep the old, put the new

**First back up the running version** (timestamped `releases/`, last 3 kept):
```bash
ssh -i $SSH_KEY $USER@$HOST "
  mkdir -p $DEPLOY_PATH/releases
  [ -d $DEPLOY_PATH/current ] && cp -a $DEPLOY_PATH/current $DEPLOY_PATH/releases/$(date +%Y%m%d_%H%M%S)
  cd $DEPLOY_PATH/releases && ls -dt */ | tail -n +4 | xargs -r rm -rf
"
```

**Docker** — build the image locally, transfer it, replace the container:
```bash
docker build -t $APP:latest .
docker save $APP:latest | gzip | ssh -i $SSH_KEY $USER@$HOST "gunzip | docker load"
ssh -i $SSH_KEY $USER@$HOST "
  docker rm -f $APP 2>/dev/null || true
  docker run -d --name $APP --restart unless-stopped -p 127.0.0.1:$APP_PORT:$APP_PORT $APP:latest
"
```

**Bare-metal** — `rsync` the source, install dependencies, start with the process manager:
```bash
rsync -avz --delete --exclude .git --exclude node_modules --exclude .venv \
  -e "ssh -i $SSH_KEY" ./ $USER@$HOST:$DEPLOY_PATH/current/
```

| Runtime | Dependencies + startup |
|---|---|
| Node | `npm ci --production` → PM2: `pm2 start ecosystem.config.js --name $APP || pm2 start npm --name $APP -- start` → `pm2 save` |
| Python | `python3 -m venv venv && venv/bin/pip install -r requirements.txt` → systemd (gunicorn/uvicorn or `python main.py`) |
| Go | build locally `GOOS=linux GOARCH=amd64 go build -o $APP` → `scp` → systemd |

systemd unit (for Python/Go, fill in ExecStart per the runtime):
```ini
[Unit]
After=network.target
[Service]
Type=simple
User=$USER
WorkingDirectory=$DEPLOY_PATH/current
ExecStart=<runtime command>
Restart=always
Environment=PORT=$APP_PORT
[Install]
WantedBy=multi-user.target
```
`systemctl daemon-reload && systemctl enable --now $APP`.

---

## Phase 4 (A) — Health gate

Right after the swap; retry for ~30 s until a 200 comes back. **If it doesn't pass, trigger Phase 5 automatically.**
```bash
ssh -i $SSH_KEY $USER@$HOST '
  for i in $(seq 1 6); do
    [ "$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:'"$APP_PORT$HEALTH_CHECK"')" = 200 ] \
      && { echo "Health gate PASSED"; exit 0; }
    sleep 5
  done
  echo "Health gate FAILED"; exit 1
'
```
Also verify the process is up: `docker ps` on Docker, otherwise `systemctl is-active $APP` / `pm2 show $APP`.

---

## Phase 5 (A) — Rollback

On health-gate failure: put the most recent `releases/` version back into `current`, restart the service, and
re-run the health gate (Phase 4). Guard-safe rollback script (uses `rsync --delete`, not `rm -rf`) + the
approval-gate note: **`references/rollback.md`**.
