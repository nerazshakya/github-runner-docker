# GitHub Actions Self-Hosted Runner

Custom Docker image for GitHub Actions self-hosted runners on Docker Swarm.
Supports **github.com** and **GitHub Enterprise Server (GHES)**.
Built and pushed to Artifactory via GitHub Actions.

Docker access uses a **host socket mount**: no Docker daemon inside the
container. `docker` commands in jobs talk directly to the host's Docker daemon,
meaning `docker stack deploy` from a job actually deploys to your real Swarm.

Runners can run in two modes, chosen per environment (see
[Runner Modes](#runner-modes)): **persistent** (one container handles many
jobs) or **ephemeral** (one container handles one job, then is replaced).

---

## Repository Structure

```
.
├── .github/
│   └── workflows/
│       ├── release-runner.yml          # Manual trigger: calls the build workflow
│       ├── build-runner-image.yml      # Reusable: build, token-leak check, smoke test, push
│       └── cleanup-stale-runners.yml   # Scheduled: removes offline ghost runners
│
├── docker/
│   ├── Dockerfile                      # Image (Debian 12-slim + runner binary + Docker CLI)
│   ├── docker-compose.yml              # Base compose: generic, values come from runner.env
│   ├── docker-compose.dev.yml          # DEV override: labels, replicas, placement, EPHEMERAL
│   ├── docker-compose.uat.yml          # UAT override
│   └── docker-compose.prod.yml         # PROD override
│
├── scripts/
│   ├── install_runner.sh               # Downloads runner binary at build time
│   ├── token.sh                        # GitHub App or PAT -> registration token (with retry)
│   ├── entrypoint.sh                   # Registers runner, runs jobs, deregisters on exit
│   ├── cleanup-offline-runners.sh      # Persistent mode only: removes offline ghost runners at startup
│   └── healthcheck.sh                  # Confirms Runner.Listener is alive
│
├── deploy.sh                           # Stack management CLI
├── runner.env.template                 # Template for the runner.env secrets file
└── README.md
```

---

## How It Works

```
Container starts
      │
      └── entrypoint.sh
              │
              ├── 1. cleanup-offline-runners.sh   (persistent mode only)
              │
              ├── 2. token.sh ──► GitHub App (or PAT) ──► short-lived registration token
              │
              ├── 3. config.sh --url ... --token ... [--ephemeral] ──► runner registered
              │
              ├── 4. Runner.Listener ──► picks up jobs
              │       docker commands in jobs ──► host Docker daemon via socket mount
              │
              └── 5. Exit
                      persistent: SIGTERM trap ──► config.sh remove
                      ephemeral:  exits after one job; Swarm starts a fresh container
```

---

## Runner Modes

| | Persistent | Ephemeral |
| --- | --- | --- |
| Setting | `EPHEMERAL` unset or not `true` | `EPHEMERAL: "true"` in the environment override file |
| Jobs per container | Many | Exactly one |
| Clean state per job | No (workspace and processes carry over) | Yes (fresh container every job) |
| Deregistration | SIGTERM trap on shutdown | Automatic after the job |
| Startup cleanup of offline runners | Yes | Skipped |
| Pool refill | n/a | Swarm `restart_policy: any` starts a replacement |

Current state: **DEV is ephemeral. UAT and PROD are persistent** until you
uncomment `EPHEMERAL: "true"` in their override files.

How ephemeral works on Swarm: the pool is a fixed number of replicas, each
registered and idle. When a job arrives, one replica takes it, runs it, and
exits. Swarm starts a replacement, which registers and waits. Concurrency is
capped at the replica count. This is a self-refilling pool, not true
scale-to-zero.

**Ephemeral requires `restart_policy: condition: any`** (already set in
`docker-compose.yml`). An ephemeral runner exits with code 0 after its job, so
`on-failure` would not replace it and the pool would drain to zero. Do not add
`max_attempts` either: it would stop the pool after N jobs.

---

## Prerequisites

- Docker Swarm initialized on the host
- `/deployment` directory on the manager node (deployment scripts live here)
- A secrets file **outside `/deployment`** (see [Secrets File](#secrets-file))
- Access to `registry.example.com` (Artifactory) from the host
- One GitHub credential for registering runners:
  - **GitHub App** (recommended), or
  - a PAT: fine-grained with only the "Self-hosted runners" org permission, or
    classic `admin:org`, preferably from a dedicated bot account

---

## Secrets File

All runtime secrets live in `runner.env` on the server. This file is never
committed to the repo. Use `runner.env.template` as a reference.

**Do not keep it under `/deployment`.** The compose file mounts `/deployment`
into every runner container, so a `runner.env` there is readable by every job
on every environment. Use a directory that is not mounted, for example:

```
mkdir -p /etc/gh-runner
cp runner.env.template /etc/gh-runner/runner.env
chmod 600 /etc/gh-runner/runner.env
# Fill in the values, then delete any old copy under /deployment
```

Format: plain `KEY=VALUE`, one per line, no inline comments.

```
# /etc/gh-runner/runner.env
DOCKER_REGISTRY_URL=registry.example.com
ACCESS_TOKEN=ghp_xxxx
GITHUB_HOST=github.example.com
RUNNER_SCOPE=org
ORG_NAME=your-org
DISABLE_AUTO_UPDATE=true
```

When you switch to a GitHub App, remove `ACCESS_TOKEN` and add the App
variables (see below).

---

## GitHub App Authentication (recommended)

A GitHub App replaces the PAT. It is not tied to a person, never expires on a
calendar, and can only manage self-hosted runners.

1. In the org: **Settings > Developer settings > GitHub Apps > New GitHub App**.
   Untick webhook "Active". Set one permission: **Organization permissions >
   Self-hosted runners: Read and write**. Verify this permission set against
   your GHES version.
2. Generate a private key (`.pem`) and note the **App ID**.
3. Install the App on the org. The **installation ID** is the number at the end
   of the installation settings URL.
4. Store the key as a Swarm secret, then store the `.pem` somewhere safe and
   delete the loose copy:

   ```
   docker secret create gh_app_key ./app-private-key.pem
   ```

5. In `docker/docker-compose.yml`, uncomment both `secrets` pieces (the
   `secrets: - gh_app_key` lines inside the runner service and the top-level
   `secrets:` block at the bottom). The stack will not deploy if the secret
   does not exist, so do this only after step 4.
6. In `runner.env`, set `APP_ID` and `APP_INSTALLATION_ID`, and remove
   `ACCESS_TOKEN`.

When `APP_ID` is set it takes priority over `ACCESS_TOKEN`.

Limits: startup cleanup of offline runners (persistent mode) still needs a PAT
and is skipped with App-only auth. Ephemeral mode does not need it. The image
build still needs a token to download the runner from GHES (see
[CI: Build and Push](#ci-build-and-push)).

Be aware that a job can read the key from `/run/secrets/gh_app_key` because it
runs as root in the same container. The App reduces what a stolen credential
can do; it does not hide it from jobs.

---

## Deploy to Docker Swarm

Use `deploy.sh`. It wraps all `docker stack deploy` commands and handles env
file loading automatically.

```
# Dry run first: see the resolved config and exact command without deploying
./deploy.sh dry-run \
  -s gh-runner-dev \
  -e /etc/gh-runner/runner.env \
  -c docker/docker-compose.yml \
  -o docker/docker-compose.dev.yml

# Deploy
./deploy.sh deploy \
  -s gh-runner-dev \
  -e /etc/gh-runner/runner.env \
  -c docker/docker-compose.yml \
  -o docker/docker-compose.dev.yml

# UAT
./deploy.sh deploy \
  -s gh-runner-uat \
  -e /etc/gh-runner/runner.env \
  -c docker/docker-compose.yml \
  -o docker/docker-compose.uat.yml

# PROD
./deploy.sh deploy \
  -s gh-runner-prod \
  -e /etc/gh-runner/runner.env \
  -c docker/docker-compose.yml \
  -o docker/docker-compose.prod.yml
```

Updating a stack restarts its containers. A job that is running at that moment
is cut off once the 30 second grace period ends, so deploy when the runners are
idle. Roll out DEV first, then UAT, then PROD.

### All `deploy.sh` Commands

```
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

Each replica handles one job at a time, so the replica count is your maximum
number of concurrent jobs:

```
# Scale up for heavy load periods
./deploy.sh scale -s gh-runner-dev 5

# Scale back down
./deploy.sh scale -s gh-runner-dev 2
```

All replicas are pinned to the manager node (where `/deployment` lives). Each
gets a unique name via a random suffix (`dev-runner-a1b2c3`,
`dev-runner-x9y8z7`), so they never collide on registration.

Default replica count: 2 for each of DEV, UAT and PROD. PROD keeps 2 so a hung
job cannot block the next deploy.

### Health Checks

Each container runs a `HEALTHCHECK` every 30s confirming `Runner.Listener` is
alive. Three consecutive failures mark the container unhealthy and Swarm
restarts it.

### Monitoring

With ephemeral runners, a bad or expired credential only shows up when a
replacement container tries to register, which can be days after the
credential broke on a low-traffic environment. The pool then drains quietly.
Check replica counts on a schedule and alert when they are below target:

```
docker service ls --filter name=gh-runner --format '{{.Name}} {{.Replicas}}'
```

### Logs

Runner diagnostic logs go to the `runner-logs` named Docker volume, mounted
from `/actions-runner/_diag`. They survive container restarts. Ephemeral mode
creates new log files for every container, so prune old files occasionally.

```
# Follow live logs
./deploy.sh logs -s gh-runner-dev

# Inspect persisted diagnostic logs
docker run --rm \
  -v gh-runner-dev_runner-logs:/logs \
  alpine ls /logs
```

There is deliberately no `/_work` volume. A named volume is shared by all
replicas of a service and would carry one job's files into the next. `/_work`
lives in each container's own filesystem.

---

## Workflow Jobs

Workflows targeting these runners use the environment-specific labels:

```
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

GitHub matches jobs to runners by labels. Runner name is irrelevant to
scheduling. Any idle replica with matching labels picks up the job.

Labels route jobs; they are **not** a security boundary. Anyone who can write a
workflow in a repo that can use these runners can put `prod` in `runs-on`. To
restrict who can use PROD runners, put them in a **runner group** limited to
specific repositories (Org settings > Actions > Runner groups) and set
`RUNNER_GROUP` for that environment.

---

## Environment Variables

Values are set in `runner.env`. `deploy.sh` sources that file, and Compose
substitutes `${VAR}` into `docker-compose.yml`. A variable only reaches the
container if it is listed under `environment:` in the compose file, so adding a
line to `runner.env` alone does nothing. Labels, runner name and `EPHEMERAL`
are set per environment in the override files.

### Auth

| Variable | Description |
| --- | --- |
| `APP_ID` | GitHub App ID. When set, App auth is used and `ACCESS_TOKEN` is ignored. |
| `APP_INSTALLATION_ID` | Installation ID of the App on your org. Required with `APP_ID`. |
| `APP_KEY_FILE` | Path to the App private key. Default `/run/secrets/gh_app_key` (Swarm secret). |
| `ACCESS_TOKEN` | GitHub PAT used by `token.sh` to get registration tokens. Rotate before expiry and redeploy. |
| `RUNNER_TOKEN` | Pre-generated registration token from the GitHub UI. Expires in 1 hour, not suitable for Swarm. |

### Scope

| Variable | Required when | Example |
| --- | --- | --- |
| `RUNNER_SCOPE` | Always | `org` |
| `ORG_NAME` | `RUNNER_SCOPE=org` | `your-org` |
| `REPO_URL` | `RUNNER_SCOPE=repo` | `https://github.example.com/org/repo` |
| `ENTERPRISE_NAME` | `RUNNER_SCOPE=enterprise` | enterprise slug |

### Optional

| Variable | Default | Description |
| --- | --- | --- |
| `GITHUB_HOST` | `github.com` | GHES hostname |
| `RUNNER_NAME` | `runner` | Base name. A random suffix is always appended. |
| `LABELS` | `self-hosted,linux,docker` | Set per environment in override files |
| `RUNNER_GROUP` | `Default` | Runner group name |
| `RUNNER_WORKDIR` | `/_work` | Job checkout directory |
| `EPHEMERAL` | `false` | `true` = one job per container. Set in the override files, not `runner.env`. |
| `DISABLE_AUTO_UPDATE` | `false` | Must be exactly `true` to disable self-update. Any other value leaves it on. |

With auto-update disabled, upgrading the runner means rebuilding the image.

---

## CI: Build and Push

Workflows handle the build pipeline:

```
release-runner.yml  ──► build-runner-image.yml  (build, token-leak check, smoke test, push)
```

### Required Vars (Settings > Variables > Actions)

| Var | Value |
| --- | --- |
| `DOCKER_REGISTRY_URL` | `registry.example.com` |
| `DOCKER_REGISTRY_PU_USER` | Artifactory username |
| `CI_RUNNER_LABELS` | Optional. JSON array of labels for the runners that execute CI jobs. Default `["self-hosted","linux"]`. |

### Required Secrets (Settings > Secrets > Actions)

| Secret | Description |
| --- | --- |
| `DOCKER_REGISTRY_PU_TOKEN` | Artifactory API token |
| `GH_PAT_V1` | GitHub token used to download the runner binary from GHES during build, and by the cleanup workflow to delete offline runners. It needs permission to manage org runners. |

`build-runner-image.yml` passes `GH_PAT_V1` to the build as a **BuildKit
secret**, never as a build arg. Build args are recorded in the image history
and the image is pushed to the registry, so anyone who can pull it could read
the token with `docker history --no-trunc`. The workflow also inspects the
history after the build and **fails before the push** if it finds the token
value or anything shaped like a GitHub token.

The workflow uses plain `docker` commands and only `actions/checkout`, so it
does not depend on marketplace actions being available on your GHES server.

### Manual Trigger

**Actions > Release Runner Image > Run workflow**

Options available from the UI:

- `runner_version` - version to build (e.g. `2.324.0`)
- `github_host` - GHES hostname
- `org_name` - GHES org name

On GHES the server decides which runner version it serves, so `runner_version`
is not used for the download. `install_runner.sh` prints a warning when the
served version differs from the requested one. Tag the image with the version
that was actually installed.

---

## Stale Runner Cleanup

`cleanup-stale-runners.yml` runs daily at 03:00 UTC and removes any runner
showing `offline` status from the GHES org.

- Persistent runners only deregister on a clean shutdown, so offline entries
  accumulate after abrupt kills (host crash, `SIGKILL`, power loss). This
  workflow and the startup cleanup in `entrypoint.sh` handle that.
- Ephemeral runners deregister themselves after their job, and GitHub removes
  ephemeral runners that stop connecting. Once every environment is ephemeral
  you can retire this workflow, and the admin credential it needs.

The startup cleanup is skipped in ephemeral mode on purpose: a sibling replica
that has registered but not yet connected looks "offline", so cleanup could
delete a healthy runner.

The workflow only touches runners whose name starts with `dev-runner-`,
`uat-runner-` or `prod-runner-` (edit `RUNNER_NAME_PREFIXES` in the workflow if
you rename them), so offline runners owned by other teams are left alone. It
reads the org from the repository owner and the API URL from the server it
runs on.

Run manually: **Actions > Cleanup Stale Runners > Run workflow**. Tick
`dry_run` first to see what would be removed without deleting anything.

Limits: the job runs on a runner, so it cannot run if every runner is down.
Set `CI_RUNNER_LABELS` to a runner outside the pools being cleaned. Also check
that 03:00 UTC does not collide with your nightly server shutdown.

---

## Building the Image Manually

Requires Docker 23+ (BuildKit) for `--secret`.

### GHES (standard)

```
export GITHUB_PAT=ghp_xxxx   # token that can list runner downloads for the org

docker build --no-cache -f docker/Dockerfile \
  --build-arg GH_RUNNER_VERSION=2.324.0 \
  --build-arg GITHUB_HOST=github.example.com \
  --build-arg ORG_NAME=your-org \
  --secret id=gh_pat,env=GITHUB_PAT \
  -t registry.example.com/my-org/github-runner:2.324.0 \
  -t registry.example.com/my-org/github-runner:latest \
  .

docker push registry.example.com/my-org/github-runner:2.324.0
docker push registry.example.com/my-org/github-runner:latest
```

### github.com

```
docker build --no-cache -f docker/Dockerfile \
  --build-arg GH_RUNNER_VERSION=2.324.0 \
  -t docker-github-runner:2.324.0 .
```

---

## Security Model

Read this before giving these runners to more teams.

- **Socket mount means root on the host.** Any job can run any Docker command,
  including against the whole Swarm, because the runners sit on a manager node.
  Acceptable for trusted internal repos. Avoid for public repos.
- **DEV, UAT and PROD share one host and one Docker socket.** The environment
  split is routing only. A DEV job can deploy to PROD stacks. For a real
  boundary, use separate hosts and runner groups restricted to specific repos.
- **`/deployment` is mounted into every runner.** Anything stored there is
  readable by every job. Keep `runner.env` and other secrets elsewhere.
- **Credentials are readable by jobs.** Jobs run as root in the same container,
  so they can read `/proc/1/environ`, mounted secrets, and
  `docker service inspect` output. Hiding variables from child processes does
  not change that. The practical defence is a narrow credential (GitHub App or
  a PAT with only the Self-hosted runners permission) and ephemeral runners.
- **Build secrets stay out of the image.** See
  [CI: Build and Push](#ci-build-and-push).

---

## Notes

**Why socket mount instead of Docker-in-Docker (DinD)?** The container runs
`docker-ce-cli` only, with no daemon. The host's `/var/run/docker.sock` is
mounted in, so `docker stack deploy` from a job deploys to the real host Swarm.
DinD would isolate those commands inside the container where they would
disappear on exit. Tradeoff: see [Security Model](#security-model).

**Why `dumb-init`?** Bash as PID 1 ignores `SIGTERM` by default. `dumb-init`
sits as PID 1, forwards signals properly, and lets the deregister trap in
`entrypoint.sh` run so persistent runners clean up from GHES before the
container dies. The stack uses a 30 second `stop_grace_period` to give it time.

**Why is `RUNNER_NAME` always given a random suffix?** Multiple replicas of the
same service on the same Swarm node would otherwise try to register under the
identical name, causing a "session already exists" collision on GHES. The
random suffix (`dev-runner-a1b2c3`) makes every container instance unique. Job
routing uses labels, not names, so this has no effect on which runner picks up
which job.

**Why does `token.sh` retry?** Transient network blips or GHES 5xx responses
should not kill the container on the first failure. It retries 3 times with
backoff, with connection timeouts so a hung server cannot block startup
forever. 401 (bad credential), 403 (not allowed) and 404 (wrong org or repo)
fail immediately, and the error includes GitHub's own message.

**Credential expiry.** A PAT will eventually expire. Swarm keeps restarting the
container (every 15 seconds) and every start fails with 401. In ephemeral mode
this only surfaces after jobs finish and replacements fail to register, so use
the monitoring check above. To rotate a PAT: update `runner.env` with the new
value and redeploy with `./deploy.sh deploy ...`. No rebuild needed. A GitHub
App avoids calendar-based expiry entirely.