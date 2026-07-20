# GitHub Actions Self-Hosted Runner

Custom Docker image for GitHub Actions self-hosted runners on Docker Swarm.
Supports **github.com** and **GitHub Enterprise Server (GHES)**.
Built and pushed to Artifactory via GitHub Actions.

Docker access uses a **host socket mount** — no Docker daemon inside the
container. `docker` commands in jobs talk directly to the host's Docker daemon,
meaning `docker stack deploy` from a job actually deploys to your real Swarm.

---

## Repository Structure

```
.
├── .github/
│   └── workflows/
│       ├── release-runner.yml          # Trigger — orchestrates build → scan
│       ├── build-runner-image.yml      # Reusable — build, push, smoke test
│       └── cleanup-stale-runners.yml   # Scheduled — removes offline ghost runners
│
├── docker/
│   ├── Dockerfile                      # Image (Debian 12-slim + runner binary + Docker CLI)
│   ├── docker-compose.yml              # Base compose — generic, reads from runner.env
│   ├── docker-compose.dev.yml          # DEV override — labels, replicas, placement
│   ├── docker-compose.uat.yml          # UAT override
│   └── docker-compose.prod.yml         # PROD override
│
├── scripts/
│   ├── install_runner.sh               # Downloads runner binary at build time
│   ├── token.sh                        # Exchanges PAT for registration token (with retry)
│   ├── entrypoint.sh                   # Registers runner, runs jobs, deregisters on exit
│   └── healthcheck.sh                  # Confirms Runner.Listener is alive
│
├── deploy.sh                           # Stack management CLI
├── runner.env.template                 # Template for /deployment/GitHub/runner.env
└── README.md
```

---

## How It Works

```
Container starts
      │
      └── entrypoint.sh
              │
              ├── 1. token.sh ──► POST GHES API ──► short-lived registration token
              │
              ├── 2. config.sh --url ... --token ... ──► runner registered on GHES
              │
              ├── 3. Runner.Listener ──► listens for jobs continuously
              │       docker commands in jobs ──► host Docker daemon via socket mount
              │
              └── 4. SIGTERM trap ──► token.sh (fresh token) ──► config.sh remove
```

Runners are **persistent** — they stay registered and keep picking up jobs
until the container is explicitly stopped. Swarm's `restart_policy` brings
them back up automatically after server restarts with a fresh registration token.

---

## Prerequisites

- Docker Swarm initialized on the host
- `/deployment` directory on the manager node (deployment scripts live here)
- `/deployment/GitHub/runner.env` — secrets file (see `runner.env.template`)
- Access to `registry.example.com` (Artifactory) from the host
- GitHub PAT with `admin:org` scope on `github.example.com`

---

## Secrets File

All runtime secrets live at `/deployment/GitHub/runner.env` on the server.
This file is never committed to the repo. Copy `runner.env.template` as a
reference for the required values:

```bash
cp runner.env.template /deployment/GitHub/runner.env
chmod 600 /deployment/GitHub/runner.env
# Fill in the values
```

```bash
# /deployment/GitHub/runner.env
DOCKER_REGISTRY_URL=registry.example.com
ACCESS_TOKEN=ghp_xxxx                          # PAT with admin:org scope
GITHUB_HOST=github.example.com
RUNNER_SCOPE=org
ORG_NAME=your-org
```

---

## Deploy to Docker Swarm

Use `deploy.sh` — it wraps all `docker stack deploy` commands and handles
env file loading automatically.

```bash
# Dry run first — see the resolved config and exact command without deploying
./deploy.sh dry-run \
  -s gh-runner-dev \
  -e /deployment/GitHub/runner.env \
  -c docker/docker-compose.yml \
  -o docker/docker-compose.de .yml

# Deploy
./deploy.sh deploy \
  -s gh-runner-dev \
  -e /deployment/GitHub/runner.env \
  -c docker/docker-compose.yml \
  -o docker/docker-compose.dev.yml

# UAT
./deploy.sh deploy \
  -s gh-runner-uat \
  -e /deployment/GitHub/runner.env \
  -c docker/docker-compose.yml \
  -o docker/docker-compose.uat.yml

# PROD
./deploy.sh deploy \
  -s gh-runner-prod \
  -e /deployment/GitHub/runner.env \
  -c docker/docker-compose.yml \
  -o docker/docker-compose.prod.yml
```

### All `deploy.sh` Commands

```bash
./deploy.sh deploy    # deploy or update a stack
./deploy.sh validate  # validate compose config without deploying
./deploy.sh dry-run   # show resolved config and command, no action
./deploy.sh status    # show services and tasks
./deploy.sh logs      # follow live runner logs
./deploy.sh scale     # adjust replica count on the fly
./deploy.sh remove    # remove stack (prompts for confirmation)
./deploy.sh help      # show full usage with examples
```

### Concurrent Jobs (Scaling)

Each replica handles exactly one job at a time. Run multiple replicas on the
manager node to handle concurrent jobs:

```bash
# Scale up for heavy load periods
./deploy.sh scale -s gh-runner-dev 5

# Scale back down
./deploy.sh scale -s gh-runner-dev 2
```

All replicas are pinned to the manager node (where `/deployment` lives).
Each gets a unique name via a random suffix (`runner-dev-a1b2c3`,
`runner-dev-x9y8z7`) — so they never collide on registration.

Default replica count per environment: `docker-compose.dev.yml` → 3,
`docker-compose.uat.yml` → 2, `docker-compose.prod.yml` → 3.

### Health Checks

Each container runs a `HEALTHCHECK` every 30s confirming `Runner.Listener`
is alive. Three consecutive failures mark the container unhealthy and Swarm
restarts it automatically.

### Logs

Runner diagnostic logs persist in the `runner-logs` named Docker volume,
mounted from `/actions-runner/_diag` inside the container. Survives container
restarts.

```bash
# Follow live logs
./deploy.sh logs -s gh-runner-dev

# Inspect persisted diagnostic logs
docker run --rm \
  -v gh-runner-dev_runner-logs:/logs \
  alpine ls /logs
```

---

## Workflow Jobs

Workflows targeting these runners use the environment-specific labels:

```yaml
# DEV
jobs:
  deploy:
    runs-on: [self-hosted, dev]

# UAT
jobs:
  deploy:
    runs-on: [self-hosted, uat]

# PROD
jobs:
  deploy:
    runs-on: [self-hosted, prod]
```

GitHub matches jobs to runners by labels — runner name is irrelevant to
job scheduling. Any idle replica with matching labels picks up the job.

---

## Environment Variables

All variables are set in `/deployment/GitHub/runner.env` and loaded
automatically by `docker-compose.yml` via `env_file`. Labels and runner
name are set per-environment in the override files.

### Auth

| Variable | Description |
|---|---|
| `ACCESS_TOKEN` | GitHub PAT with `admin:org` scope — used by `token.sh` to generate registration tokens. Rotate before expiry and redeploy. |
| `RUNNER_TOKEN` | Pre-generated registration token from GitHub UI. Expires in 1 hour — not suitable for Swarm deployments. |

### Scope

| Variable | Required when | Example |
|---|---|---|
| `RUNNER_SCOPE` | Always | `org` |
| `ORG_NAME` | `RUNNER_SCOPE=org` | `your-org` |
| `REPO_URL` | `RUNNER_SCOPE=repo` | `https://github.example.com/org/repo` |
| `ENTERPRISE_NAME` | `RUNNER_SCOPE=enterprise` | enterprise slug |

### Optional

| Variable | Default | Description |
|---|---|---|
| `GITHUB_HOST` | `github.com` | GHES hostname |
| `RUNNER_NAME` | `runner-<random>` | Base name — random suffix always appended |
| `LABELS` | `self-hosted,linux,docker` | Set per environment in override files |
| `RUNNER_GROUP` | `Default` | Runner group name |
| `RUNNER_WORKDIR` | `/_work` | Job checkout directory |
| `DISABLE_AUTO_UPDATE` | *(unset)* | Set to any value to disable self-update |

---

## CI: Build and Push

Three workflows handle the build pipeline:

```
release-runner.yml  ──► build-runner-image.yml  (build + push + smoke test)
```

### Required Vars (Settings → Variables → Actions)

| Var | Value |
|---|---|
| `DOCKER_REGISTRY_URL` | `registry.example.com` |
| `DOCKER_REGISTRY_PU_USER` | Artifactory username |

### Required Secrets (Settings → Secrets → Actions)

| Secret | Description |
|---|---|
| `DOCKER_REGISTRY_PU_TOKEN` | Artifactory API token |
| `GH_PAT_V1` | GitHub PAT — downloads runner binary from GHES during build |

### Manual Trigger

**Actions → Release Runner Image → Run workflow**

Options available from the UI:
- `runner_version` — version to build (e.g. `2.324.0`)
- `github_host` — GHES hostname
- `org_name` — GHES org name

---

## Stale Runner Cleanup

`cleanup-stale-runners.yml` runs daily at 03:00 UTC and removes any runner
showing `offline` status from the GHES org. Since runners are persistent and
only deregister on clean shutdown, offline entries accumulate only when
containers are killed abruptly (host crash, `SIGKILL`, power loss).

Run manually: **Actions → Cleanup Stale Runners → Run workflow**

---

## Building the Image Manually

### GHES (standard)

```bash
docker build --no-cache -f docker/Dockerfile \
  --build-arg GH_RUNNER_VERSION=2.324.0 \
  --build-arg GITHUB_HOST=github.example.com \
  --build-arg ORG_NAME=your-org \
  --build-arg GITHUB_PAT=$ACCESS_TOKEN \
  -t registry.example.com/my-org/github-runner:2.324.0 \
  -t registry.example.com/my-org/github-runner:latest \
  .

docker push registry.example.com/my-org/github-runner:2.324.0
docker push registry.example.com/my-org/github-runner:latest
```

### github.com

```bash
docker build --no-cache -f docker/Dockerfile \
  --build-arg GH_RUNNER_VERSION=2.324.0 \
  -t docker-github-runner:2.324.0 .
```

---

## Notes

**Why socket mount instead of Docker-in-Docker (DinD)?**
The container runs `docker-ce-cli` only — no daemon. The host's
`/var/run/docker.sock` is mounted in, so `docker stack deploy` from a job
deploys to the real host Swarm. DinD would isolate those commands inside
the container where they'd disappear on exit.
Tradeoff: any job on this runner has root-equivalent access to the host.
Acceptable for internal trusted repos — avoid for public repos.

**Why `dumb-init`?**
Bash as PID 1 ignores `SIGTERM` by default. `dumb-init` sits as PID 1,
forwards signals properly, and triggers the deregister trap in `entrypoint.sh`
so runners clean up from GHES before the container dies.

**Why is `RUNNER_NAME` always given a random suffix?**
Multiple replicas of the same service on the same Swarm node would otherwise
try to register under the identical name, causing a "session already exists"
collision on GHES. The random suffix (`runner-dev-a1b2c3`) makes every
container instance unique. Job routing uses labels, not names — so this has
no effect on which runner picks up which job.

**Why does `token.sh` retry?**
Transient network blips or GHES 5xx responses shouldn't kill the container
on the first failure. It retries 3 times with backoff. 401 (bad PAT) and
404 (wrong org/repo) fail immediately since retrying those never helps.

**PAT expiry**
`ACCESS_TOKEN` will eventually expire. When it does, Swarm will keep
restarting the container but every start will fail with 401. Set a calendar
reminder before the expiry date. To rotate: update `/deployment/GitHub/runner.env`
with the new PAT and redeploy with `./deploy.sh deploy ...` — no rebuild needed.
