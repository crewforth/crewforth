# Standing up SonarQube Community Build locally

Read this only on branch (b) of step 1 — the project has no SonarQube and one is being stood up. No licence, no
external account, nothing leaves the machine.

**The consent rule in SKILL.md governs every line below.** Docker, Java, a scanner — each is a proposal with its
cost stated, and the user picks. Restarting an already-approved service is not installing; a new image, a new
volume, or a tool this machine does not have is.

```bash
# b1 — with Docker (one command)
docker run -d --name sonarqube -p 9000:9000 sonarqube:community    # first boot ~1-2 min

# b2 — WITHOUT Docker: the plain server zip. Needs Java 17 or 21 on PATH (`java -version`), nothing else.
#   download SonarQube Community Build, unzip (e.g. C:\sonarqube), then start it:
#     Windows      C:\sonarqube\bin\windows-x86-64\StartSonar.bat
#     Linux/macOS  ./bin/<platform>/sonar.sh console
#   It runs on an embedded H2 database — no database to install for local use.
```

Either way: http://localhost:9000 · first login `admin`/`admin` · set a new password · then My Account → Security →
generate a token. **That token is local and yours** — it is not a company credential and nothing is sent anywhere.
Export it as `SONAR_TOKEN` in your shell; the commands in the skill read it from there.

Persist the container (`-v sonarqube_data:/opt/sonarqube/data`) so history survives, and put the key/exclusions in
`sonar-project.properties` so every later run is identical.
