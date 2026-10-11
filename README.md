# GitHub Actions Self-Hosted Runner (Docker)

A containerized GitHub Actions self-hosted runner that **registers itself when
the container starts**, using a GitHub App or a Personal Access Token (PAT).
Works with **github.com** and **GitHub Enterprise Server (GHES)**, on **Docker
Swarm** or **plain Docker**.

- CI builds the image and publishes it to **Docker Hub** or any registry you
  can `docker login` to.
- `deploy.sh` takes you from an empty host to healthy, registered runners:
  config file, credential check, pull, start, wait.

Docker access uses a **host socket mount**: no Docker daemon inside the
container, `docker` commands in jobs talk to the host's daemon. Read the
[Security Model](#security-model) before sharing these runners.

Runners run in one of two modes, chosen per environment (see
[Runner Modes](#runner-modes)): **persistent** (one container handles many
jobs) or **ephemeral** (one container handles one job, then is replaced).

---

## Quick start

```bash
# 1. Publish the image (once): set the repo variables/secrets in "Build and publish"
#    below, then run Actions > Release Runner Image.

# 2. On the host that will run the runners:
./deploy.sh init                 # writes /etc/gh-runner/runner.env (mode 600)
./deploy.sh check                # confirms the credential can create runner tokens
./deploy.sh deploy -s gh-runner-dev --env dev
```

`deploy` pulls the image, starts the runners and waits until they are healthy,
which means each one registered with GitHub and is listening for jobs. They
then show up under **Settings > Actions > Runners**.

---

## Repository structure

```
.
├── .github/workflows/
│   ├── release-runner.yml          # Triggers: push to main, PR (build only), manual
│   ├── build-runner-image.yml      # Reusable: build, token-leak check, smoke test, push
│   └── cleanup-stale-runners.yml   # Scheduled: removes offline ghost runners
├── docker/
│   ├── Dockerfile                  # Debian 12-slim + runner binary + Docker CLI
│   ├── docker-compose.yml          # Base compose file; values come from runner.env
│   ├── docker-compose.dev.yml      # DEV override: labels, replicas, EPHEMERAL
│   ├── docker-compose.uat.yml      # UAT override
│   ├── docker-compose.prod.yml     # PROD override
│   ├── docker-compose.app-swarm.yml       # GitHub App key as a Swarm secret
│   └── docker-compose.app-standalone.yml  # GitHub App key as a mounted file
├── scripts/
│   ├── install_runner.sh           # Downloads + verifies the runner binary at build time
│   ├── token.sh                    # App/PAT -> registration / remove / API token (retry)
│   ├── entrypoint.sh               # Registers, runs jobs, deregisters on exit
│   ├── cleanup-offline-runners.sh  # Persistent mode: removes offline ghost runners
│   └── healthcheck.sh              # Confirms Runner.Listener is alive
├── deploy.sh                       # init / check / deploy / status / logs / scale / remove
├── runner.env.template             # Template for the runner.env secrets file
└── README.md
```

---

## How it works

```
deploy.sh deploy
   ├─ read runner.env, validate it
   ├─ (private image) docker login with the read-only pull credential
   ├─ (Swarm + App) create the key secret if missing
   ├─ check: run token.sh inside the image with the real credentials
   ├─ docker stack deploy  /  docker compose up -d
   └─ wait until containers are healthy

Container starts
   └─ entrypoint.sh
        1. cleanup-offline-runners.sh   (persistent mode, org scope only)
        2. token.sh registration  -> GitHub App (or PAT) -> 1-hour registration token
        3. config.sh --url ... --token ... [--ephemeral]  -> runner registered
        4. Runner.Listener (child process) -> picks up jobs
        5. exit
             persistent: SIGTERM or listener exit -> token.sh remove -> config.sh remove
             ephemeral : exits after one job; the restart policy starts a fresh container
```

---

## Runner modes

| | Persistent | Ephemeral |
| --- | --- | --- |
| Setting | `EPHEMERAL` unset or not `true` | `EPHEMERAL: "true"` in the environment override file |
| Jobs per container | Many | Exactly one |
| Clean state per job | No | Yes (fresh container every job) |
| Deregistration | On shutdown or listener exit | Automatic after the job |
| Startup cleanup of offline runners | Yes | Skipped |
| Pool refill | n/a | Restart policy starts a replacement |

Current state: **DEV is ephemeral. UAT and PROD are persistent** until you
uncomment `EPHEMERAL: "true"` in their override files.

An ephemeral pool is a fixed number of replicas, each registered and idle. A
job takes one replica, which runs it and exits; a replacement registers and
waits. Concurrency is capped at the replica count. It is a self-refilling pool,
not scale-to-zero.

Ephemeral requires restarting on exit code 0. The compose file does that
(`restart: unless-stopped` for plain Docker, `restart_policy: condition: any`
for Swarm). Do not add `max_attempts`: it would stop the pool after N jobs.

---

## Prerequisites

- A Linux host with Docker 23+ (and the Compose plugin for plain Docker mode).
  For Swarm mode, a Swarm manager node.
- Outbound HTTPS from the host and containers to GitHub (or your GHES) and to
  the container registry.
- A GitHub credential that can manage self-hosted runners at your chosen scope
  ([Authentication](#authentication)).
- For publishing: a Docker Hub account (or other registry) and an access token.

---

## Build and publish (CI/CD)

`release-runner.yml` runs `build-runner-image.yml`:

| Event | What happens |
| --- | --- |
| Push to `main` touching the Dockerfile, `scripts/` or the workflows | Build, test, **publish** |
| Pull request (same repo only) | Build and test, **nothing is pushed** |
| **Actions > Release Runner Image > Run workflow** | Build, test, publish, with optional version/host inputs |

Steps: build, check that no token leaked into the image history (fails before
the push), smoke test (runner, Docker CLI, scripts, fail-fast on missing
config), push, log out.

Runner version: the dispatch input, else the `RUNNER_VERSION` variable, else
the latest `actions/runner` release. Pin `RUNNER_VERSION` for reproducible
builds. For github.com, the download is verified against GitHub's published
SHA-256.

Published tags: `<runner-version>`, `latest`, and `sha-<commit>`.

### Docker Hub setup

1. On hub.docker.com: **Account settings > Personal access tokens > Generate**,
   with **Read & Write** access. Create the repository `github-runner` (or let
   the first push create it).
2. In this GitHub repo, **Settings > Secrets and variables > Actions**:

| Kind | Name | Value |
| --- | --- | --- |
| Variable | `DOCKER_REGISTRY_PU_USER` | Your Docker Hub username |
| Secret | `DOCKER_REGISTRY_PU_TOKEN` | The access token from step 1 |
| Variable | `DOCKER_IMAGE_NAME` | Optional, e.g. `myorg/github-runner`. Default `<user>/github-runner` |

   Leave `DOCKER_REGISTRY_URL` unset (or set it to `docker.io`).
3. Run the workflow. The image is `docker.io/<user>/github-runner:<version>`.

### Custom registry (Artifactory, GHCR, ECR-compatible login, Harbor, ...)

Same variables and secret, and also set:

| Variable | Value |
| --- | --- |
| `DOCKER_REGISTRY_URL` | Registry host, e.g. `registry.example.com` |
| `DOCKER_IMAGE_NAME` | Path in the registry, e.g. `team/github-runner` |

`DOCKER_REGISTRY_PU_USER` / `DOCKER_REGISTRY_PU_TOKEN` are whatever that
registry's `docker login` accepts (username + API token).

### All CI settings

| Name | Kind | Purpose |
| --- | --- | --- |
| `DOCKER_REGISTRY_PU_USER` | Variable | Registry username |
| `DOCKER_REGISTRY_PU_TOKEN` | Secret | Registry access token |
| `DOCKER_REGISTRY_URL` | Variable | Empty/`docker.io` = Docker Hub, else registry host |
| `DOCKER_IMAGE_NAME` | Variable | Optional image path |
| `RUNNER_VERSION` | Variable | Optional pinned runner version |
| `CI_RUNNER_LABELS` | Variable | Optional JSON array for `runs-on`. Default `["ubuntu-latest"]`. Set e.g. `["self-hosted","linux"]` on GHES. |
| `RUNNER_GITHUB_HOST`, `RUNNER_ORG_NAME` | Variables | GHES only: where to download the runner from |
| `GH_PAT_V1` | Secret | GHES only: downloads the runner binary at build time. Also used by the stale-runner cleanup workflow. |

`GH_PAT_V1` reaches the build as a **BuildKit secret**, never a build arg,
because build args are recorded in the image history. The workflow uses plain
`docker` commands and only `actions/checkout`, so it works on a GHES server
that does not mirror marketplace actions.

On GHES the server decides which runner version it serves, so the requested
version is only the tag. `install_runner.sh` warns when they differ.

### Building manually

Requires Docker 23+ (BuildKit).

```bash
# github.com
docker build -f docker/Dockerfile \
  --build-arg GH_RUNNER_VERSION=2.324.0 \
  -t youruser/github-runner:2.324.0 -t youruser/github-runner:latest .

# GHES (token that can list runner downloads for the org)
export GITHUB_PAT=ghp_xxxx
docker build -f docker/Dockerfile \
  --build-arg GH_RUNNER_VERSION=2.324.0 \
  --build-arg GITHUB_HOST=github.example.com --build-arg ORG_NAME=your-org \
  --secret id=gh_pat,env=GITHUB_PAT \
  -t registry.example.com/team/github-runner:2.324.0 .

docker login            # or: docker login registry.example.com
docker push youruser/github-runner:2.324.0
```

The image contains no org name, host or credential: all of that is supplied
when the container starts, so one image serves every org and environment.

---

## Authentication

Pick **one**. `deploy.sh check` verifies it before anything is deployed.

### Option A: GitHub App (recommended)

Not tied to a person, no calendar expiry, can only manage runners.

1. Create the App: org **Settings > Developer settings > GitHub Apps > New
   GitHub App**. Untick webhook "Active". Permissions:
   - org-scope runners: **Organization permissions > Self-hosted runners:
     Read and write**
   - repo-scope runners: **Repository permissions > Administration: Read and
     write**
   - enterprise scope: use a PAT (Apps do not manage enterprise runners).

   Check this against your GHES version.
2. Generate a private key (`.pem`), note the **App ID**.
3. Install the App on the org/repo. The **installation ID** is the number at
   the end of the installation settings URL.
4. Put the key on the deploy host (mode 600, outside `/deployment`), then in
   `runner.env`:

   ```
   APP_ID=123456
   APP_INSTALLATION_ID=78901234
   APP_KEY_PATH=/etc/gh-runner/app-private-key.pem
   ```

   `deploy.sh` adds the right override file automatically: on Swarm it creates
   the `gh_app_key` secret, on plain Docker it mounts the file read-only. In
   both cases the key appears in the container at `/run/secrets/gh_app_key`.
   It is never an environment variable.

### Option B: Personal Access Token

```
ACCESS_TOKEN=ghp_xxxx
```

Fine-grained token with only the runner permission above, or a classic token
with `admin:org` (org) / `repo` (repo), from a dedicated bot account. A PAT
sits in the container environment, so prefer the App.

If both are set, the App is used.

### Token lifecycle

Nothing long-lived is stored in the container or on disk. Every credential is
minted when needed and dies within the hour.

| Credential | Created | Lifetime | Used for |
| --- | --- | --- | --- |
| App JWT | each time a token is needed | 9 min | one call, to get an installation token |
| App installation token | each time | 1 hour | one call, to get the registration/remove token |
| Registration token | every container start | 1 hour | one `config.sh` registration, then discarded |
| Runner credential | by GitHub at registration | until deregistration | the runner's own connection (managed by the runner) |
| Remove token | at shutdown | 1 hour | deregistration |
| PAT | by you | as configured | same role as the installation token |

Consequences:

- **App**: registration keeps working indefinitely, replacements always
  register fine. Only a revoked App/key/installation breaks it.
- **PAT**: when it expires or is revoked, every start fails with
  `401 Unauthorized - credential is invalid or expired`. Rotate by editing
  `runner.env` and running `./deploy.sh deploy`. No rebuild needed. Ephemeral
  pools only notice when a replacement fails to register; see
  [Monitoring](#monitoring).
- `RUNNER_TOKEN` (pasted from the GitHub UI) expires in 1 hour and is not
  suitable for anything that restarts.
- **Rotating the App key (Swarm)**: secrets are immutable, so create a new one
  and point the stack at it:

  ```bash
  docker secret create gh_app_key_2026_10 ./new-key.pem
  # in runner.env: APP_KEY_SECRET_NAME=gh_app_key_2026_10  and  APP_KEY_PATH=./new-key.pem
  ./deploy.sh deploy -s gh-runner-dev --env dev
  docker secret rm gh_app_key     # after the rollout, then delete the old key in GitHub
  ```

  Plain Docker: replace the file at `APP_KEY_PATH` and redeploy.

---

## Configuration

All settings live in one `runner.env` on the host, never committed. Create it
with `./deploy.sh init`, or copy `runner.env.template`. Format: plain
`KEY=VALUE`, one per line. It is **parsed, not executed**; values already
exported in your shell win over the file.

**Keep it outside `/deployment`**: the compose file mounts `/deployment` into
every runner, so a `runner.env` there is readable by every job. `deploy.sh`
warns if you do, and if the file is readable by group/others.

```
# /etc/gh-runner/runner.env  (chmod 600)
RUNNER_IMAGE=youruser/github-runner:latest
RUNNER_SCOPE=org
ORG_NAME=your-org
ACCESS_TOKEN=ghp_xxxx
DISABLE_AUTO_UPDATE=true
```

A variable only reaches the container if it is listed under `environment:` in
the compose file; adding a line to `runner.env` alone does nothing for the
container. Labels, runner name and `EPHEMERAL` are set per environment in the
override files.

### Image and registry

| Variable | Description |
| --- | --- |
| `RUNNER_IMAGE` | **Required.** Full image reference, e.g. `youruser/github-runner:latest` or `registry.example.com/team/github-runner:latest` |
| `REGISTRY_USER`, `REGISTRY_TOKEN` | Only for a private image: read-only pull credential used by `deploy.sh`. Use a read-only token, not the CI push token. |

### Auth

| Variable | Description |
| --- | --- |
| `APP_ID`, `APP_INSTALLATION_ID` | GitHub App. When `APP_ID` is set, App auth is used and `ACCESS_TOKEN` is ignored. |
| `APP_KEY_PATH` | Host path to the App private key (`deploy.sh` mounts it as a secret) |
| `APP_KEY_SECRET_NAME` | Swarm secret name. Default `gh_app_key`. Change it to rotate. |
| `ACCESS_TOKEN` | PAT |
| `RUNNER_TOKEN` | Pre-generated registration token. Expires in 1 hour. Testing only. |

### Scope

| Variable | Required when | Example |
| --- | --- | --- |
| `RUNNER_SCOPE` | Always | `org`, `repo` or `enterprise` |
| `ORG_NAME` | `RUNNER_SCOPE=org` | `your-org` |
| `REPO_URL` | `RUNNER_SCOPE=repo` | `https://github.com/owner/repo` |
| `ENTERPRISE_NAME` | `RUNNER_SCOPE=enterprise` | enterprise slug |

### Optional

| Variable | Default | Description |
| --- | --- | --- |
| `GITHUB_HOST` | `github.com` | GHES hostname |
| `GITHUB_API_URL` | derived | Override the API base URL (proxies) |
| `RUNNER_NAME` | `runner` | Base name. A random suffix is always appended. |
| `LABELS` | `self-hosted,linux,docker` | Set per environment in the override files |
| `RUNNER_GROUP` | `Default` | Runner group (org/enterprise scope only) |
| `RUNNER_WORKDIR` | `/_work` | Job checkout directory |
| `EPHEMERAL` | `false` | `true` = one job per container. Set in the override files. |
| `DISABLE_AUTO_UPDATE` | `false` | Must be exactly `true` to disable self-update. With it disabled, upgrading the runner means rebuilding the image. |
| `DEPLOYMENT_DIR` | `/deployment` | Host directory mounted at `/deployment` |

---

## Deploy

`deploy.sh` picks **Swarm** (`docker stack deploy`) when the host is a Swarm
manager, otherwise **plain Docker** (`docker compose up -d`). Force it with
`--mode swarm|standalone`.

```bash
./deploy.sh init                       # create runner.env interactively
./deploy.sh check                      # verify credentials (no deploy)
./deploy.sh dry-run --env dev          # resolved config (secrets redacted) + command
./deploy.sh deploy -s gh-runner-dev  --env dev
./deploy.sh deploy -s gh-runner-uat  --env uat
./deploy.sh deploy -s gh-runner-prod --env prod
```

Without `--env`/`-o` you get one generic stack from the base compose file.
Paths and the stack name have defaults; see `./deploy.sh help`.

What `deploy` does, in order: validates `runner.env` (scope matches, exactly
one credential, key file readable), logs in for the pull if `REGISTRY_USER`
is set, creates the Swarm key secret if needed, **checks the credential
against GitHub using the real image**, deploys, and waits (default 120 s,
`--timeout`) until the runners are healthy. It exits non-zero if they are not,
and nothing is deployed if the credential check fails (`--skip-check` to
bypass).

Updating a stack restarts its containers. A job running at that moment is cut
off after the 30 second grace period, so deploy when runners are idle. Roll
out DEV, then UAT, then PROD.

### All `deploy.sh` commands

```
init       create runner.env           validate   check env + compose config
check      verify GitHub credentials   dry-run    show resolved config + command
deploy     deploy/update, wait healthy status     services/containers
logs       follow live logs            scale N    change replica count
remove     remove the stack (-y)       version    runner version in the image
```

### Scaling

Each replica handles one job at a time, so the replica count is the maximum
number of concurrent jobs.

```bash
./deploy.sh scale -s gh-runner-dev 5
```

Default is 2 replicas per environment. Every replica gets a unique name via a
random suffix (`dev-runner-a1b2c3`), so they never collide on registration.
Swarm replicas are pinned to the manager node.

### Workflow jobs

```yaml
jobs:
  deploy:
    runs-on: [self-hosted, dev]    # or uat / prod
```

GitHub matches jobs to runners by labels. Labels route jobs; they are **not a
security boundary**: anyone who can write a workflow in a repo that can use
these runners can put `prod` in `runs-on`. To restrict PROD, use a **runner
group** limited to specific repositories (Org settings > Actions > Runner
groups) and set `RUNNER_GROUP`.

---

## Operations

### Monitoring

With ephemeral runners a bad or expired credential only shows up when a
replacement tries to register, possibly days later, and the pool drains
quietly. Alert when replicas are below target:

```bash
docker service ls --filter name=gh-runner --format '{{.Name}} {{.Replicas}}'   # Swarm
docker ps --filter label=com.docker.compose.project=gh-runner --filter health=healthy -q | wc -l   # plain Docker
```

Each container has a `HEALTHCHECK` (every 30 s) confirming `Runner.Listener`
is alive; three failures mark it unhealthy and the orchestrator restarts it.

### Logs

```bash
./deploy.sh logs -s gh-runner-dev
docker run --rm -v gh-runner-dev_runner-logs:/logs alpine ls /logs   # persisted diagnostic logs
```

Runner diagnostics go to the `runner-logs` volume and survive restarts;
ephemeral mode creates new files per container, so prune occasionally. There
is deliberately no `/_work` volume: a shared volume would carry one job's files
into the next.

### Stale runner cleanup

Persistent runners deregister on clean shutdown but leave `offline` entries
after abrupt kills (host crash, `SIGKILL`). Two things handle that:

- **Startup cleanup** (`cleanup-offline-runners.sh`), persistent mode, org
  scope. Works with a PAT or a GitHub App. Skipped for ephemeral runners, where
  a sibling that has registered but not yet connected looks "offline" and could
  be deleted by mistake.
- **`cleanup-stale-runners.yml`**, daily 03:00 UTC, needs the `GH_PAT_V1`
  secret. Only touches runners named `dev-runner-`, `uat-runner-` or
  `prod-runner-` (edit `RUNNER_NAME_PREFIXES`). **Actions > Cleanup Stale
  Runners > Run workflow** with `dry_run` ticked shows what would go. It runs on
  a runner, so point `CI_RUNNER_LABELS` at one outside the pools being cleaned.
  Once every environment is ephemeral you can retire it.

---

## Security model

- **Socket mount means root on the host.** Any job can run any Docker command,
  including against the whole Swarm if runners sit on a manager. Acceptable for
  trusted internal repos. Avoid for public repos.
- **DEV, UAT and PROD share one host and one Docker socket.** The environment
  split is routing only; a DEV job can deploy to PROD stacks. For a real
  boundary use separate hosts and runner groups restricted to repos.
- **`/deployment` is mounted into every runner.** Keep `runner.env` and other
  secrets elsewhere.
- **Credentials are readable by jobs.** Jobs run as root in the same container,
  so they can read `/proc/1/environ`, mounted secrets and `docker inspect`
  output. The defence is a narrow credential (GitHub App, or a PAT with only
  the runner permission) plus ephemeral runners.
- **Secrets stay out of the image and out of `ps`.** Build secrets use BuildKit
  secrets and the history is scanned before the push. `token.sh` hands tokens
  to `curl` on stdin. `deploy.sh dry-run` redacts tokens.
- **Use separate tokens.** CI push token (read & write) for publishing; a
  read-only pull token for hosts; a runner-management credential for
  registration. No single token should do all three.

---

## Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| `deploy.sh check`: `401 Unauthorized ... credential is invalid or expired` | PAT expired/revoked, or wrong `APP_ID`/key. Regenerate and redeploy. |
| `401 ... App JWT rejected` | Wrong `APP_ID`, wrong key, or the host clock is off. Check `date`; enable NTP. |
| `403 Forbidden` | Missing permission (App: Self-hosted runners / Administration), not an org owner, or PAT not authorized for SAML SSO. |
| `404 Not Found` | Wrong `RUNNER_SCOPE`/`ORG_NAME`/`REPO_URL`/`GITHUB_HOST`, or the App is not installed on that org/repo. The error prints the URL tried. |
| `App private key not readable` | `APP_KEY_PATH` wrong, or (Swarm) the secret is missing: rerun `deploy.sh deploy`. |
| `could not sign the App JWT` | The file is not an RSA private key in PEM format. Use the `.pem` GitHub generated. |
| `cannot pull <image>` | Wrong `RUNNER_IMAGE`, or private image without `REGISTRY_USER`/`REGISTRY_TOKEN`. On Docker Hub use `user/name:tag`. |
| Runners never become healthy; `deploy.sh` times out | `./deploy.sh logs` shows the cause (credentials, scope, network to GitHub/GHES). Raise `--timeout` on slow hosts. |
| Ephemeral pool shrinks over time | Registrations failing (expired PAT). Check logs; see [Monitoring](#monitoring). Do not set `max_attempts`. |
| Runner shows offline in GitHub | Persistent runner killed without deregistering. Startup/daily cleanup removes it, or delete it in the UI. |
| `session already exists` | Duplicate runner name. Names get a random suffix; check nothing overrides it. |
| `permission denied` on `/var/run/docker.sock` in a job | The container must run as root (default) and the host socket must be mounted. |
| `error while interpolating ... RUNNER_IMAGE` | `RUNNER_IMAGE` missing from `runner.env`. |
| CI: `DOCKER_REGISTRY_PU_TOKEN secret is not set` | Set the secret (Settings > Secrets > Actions) and the `DOCKER_REGISTRY_PU_USER` variable. |
| CI: `denied: requested access to the resource is denied` | The token lacks write access, or the user/org in `DOCKER_IMAGE_NAME` is not yours. |
| CI: `Could not look up the latest runner release` | The runner cannot reach api.github.com (GHES network). Set the `RUNNER_VERSION` variable. |
| CI: `WARNING: ... download is NOT verified` | GitHub did not return a checksum for that release. Set `REQUIRE_CHECKSUM=true` to make this fatal. |
| GHES: `requested runner vX but ... serves vY` | Expected: the server picks the version. Tag with the served version. |

---

## Notes

**Why socket mount instead of Docker-in-Docker?** The container ships
`docker-ce-cli` only. The host's `/var/run/docker.sock` is mounted in, so
`docker stack deploy` from a job deploys to the real Swarm. DinD would keep
those commands inside a container that disappears on exit. Tradeoff: see
[Security Model](#security-model).

**Why `dumb-init`?** Bash as PID 1 ignores `SIGTERM`. `dumb-init` forwards
signals so the deregister logic in `entrypoint.sh` runs before the container
dies. The 30 second `stop_grace_period` gives it time.

**Why a random runner name suffix?** Replicas of the same service would
otherwise register under the same name and collide. Job routing uses labels,
not names.

**Why does `token.sh` retry?** Network blips and 5xx responses should not kill
the container on the first failure. It retries 3 times with backoff and
timeouts. 401, 403 and 404 are configuration errors and fail immediately with
GitHub's own message.
