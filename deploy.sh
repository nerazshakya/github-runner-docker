#!/usr/bin/env bash
# GitHub Actions runner - configure, register and start containers.
#
# Works on Docker Swarm (docker stack deploy) or plain Docker (docker compose);
# the mode is auto-detected. Runner registration itself happens inside each
# container at startup (scripts/entrypoint.sh + scripts/token.sh), using a
# GitHub App or a PAT from the env file. This script prepares and verifies
# everything that has to be right before that point, then starts the containers
# and waits until they are healthy (= registered and listening).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROG="$(basename "$0")"
DEFAULT_ENV_FILE="${RUNNER_ENV_FILE:-/etc/gh-runner/runner.env}"

usage() { cat <<EOF2
GitHub Actions Runner - deployment

Usage:
  $PROG <command> [options]

Commands:
  init        Create the runner.env file (interactive, or from exported variables with -y)
  check       Verify the GitHub credentials can create runner tokens (no deploy)
  deploy      Pre-flight checks, then deploy/update the runners and wait until healthy
  validate    Validate env file and compose config without deploying
  dry-run     Show the resolved config (secrets redacted) and the command, no action
  status      Show services/containers for the stack
  logs        Follow live runner logs
  scale N     Change the number of runner replicas (concurrent job capacity)
  remove      Remove the stack (prompts unless -y)
  version     Show the runner version inside the configured image
  help        Show this help

Options:
  -s, --stack NAME      Stack / compose project name (default: gh-runner)
  -e, --env-file FILE   Env file (default: $DEFAULT_ENV_FILE)
  -c, --compose FILE    Base compose file (default: docker/docker-compose.yml)
  -o, --override FILE   Environment override file, e.g. docker/docker-compose.dev.yml
      --env dev|uat|prod  Shortcut for -o docker/docker-compose.<env>.yml
      --mode MODE       swarm | standalone | auto (default: auto)
      --skip-check      Skip the credential pre-flight check on deploy
      --timeout SECS    How long deploy waits for healthy runners (default: 120)
  -y, --yes             No prompts (init: take values from exported variables)
  -h, --help            Show this help

Values already exported in your shell win over values in the env file.

Examples:
  $PROG init                                   # create /etc/gh-runner/runner.env
  $PROG check                                  # are the credentials good?
  $PROG deploy -s gh-runner-dev --env dev      # deploy DEV runners (ephemeral)
  $PROG deploy                                 # one generic stack, defaults
  $PROG scale -s gh-runner-dev 5
  $PROG logs -s gh-runner-dev
  $PROG remove -s gh-runner-dev -y
EOF2
}

die()  { echo "Error: $*" >&2; exit 1; }
warn() { echo "Warning: $*" >&2; }
info() { echo "==> $*"; }

CMD="${1:-help}"; [[ $# -gt 0 ]] && shift
STACK="gh-runner"; ENVF="$DEFAULT_ENV_FILE"; COMP="$SCRIPT_DIR/docker/docker-compose.yml"
OVR=""; YES=0; MODE="auto"; SKIP_CHECK=0; TIMEOUT=120; ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--stack)    [[ $# -ge 2 ]] || die "$1 needs a value"; STACK="$2"; shift 2 ;;
    -e|--env-file) [[ $# -ge 2 ]] || die "$1 needs a value"; ENVF="$2";  shift 2 ;;
    -c|--compose)  [[ $# -ge 2 ]] || die "$1 needs a value"; COMP="$2";  shift 2 ;;
    -o|--override) [[ $# -ge 2 ]] || die "$1 needs a value"; OVR="$2";   shift 2 ;;
    --env)         [[ $# -ge 2 ]] || die "$1 needs a value"; OVR="$SCRIPT_DIR/docker/docker-compose.$2.yml"; shift 2 ;;
    --mode)        [[ $# -ge 2 ]] || die "$1 needs a value"; MODE="$2";  shift 2 ;;
    --timeout)     [[ $# -ge 2 ]] || die "$1 needs a value"; TIMEOUT="$2"; shift 2 ;;
    --skip-check)  SKIP_CHECK=1; shift ;;
    -y|--yes)      YES=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            echo "Unknown option: $1" >&2; echo >&2; usage >&2; exit 1 ;;
    *)             ARGS+=("$1"); shift ;;
  esac
done

# ---------------------------------------------------------------------------
# Env file: parsed as plain KEY=VALUE, never executed with `source`.
# ---------------------------------------------------------------------------
load_env() {
  [[ -f "$ENVF" ]] || die "env file not found: $ENVF
  Create it with:  $PROG init -e $ENVF   (or pass -e /path/to/runner.env)"
  local mode line key val
  mode=$(stat -c '%a' "$ENVF" 2>/dev/null || stat -f '%Lp' "$ENVF" 2>/dev/null || echo 600)
  [[ "$mode" =~ ^[0-7]*00$ ]] || warn "$ENVF is accessible by group/others (mode $mode). Run: chmod 600 $ENVF"
  case "$(cd "$(dirname "$ENVF")" && pwd)/" in
    /deployment/*) warn "$ENVF is under /deployment, which is mounted into every runner. Move it (e.g. /etc/gh-runner/)." ;;
  esac
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || die "bad line in $ENVF (expected KEY=VALUE): ${line%%=*}"
    key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
    [[ -n "${!key+x}" ]] && continue          # already exported: environment wins
    export "$key=$val"
  done < "$ENVF"
}

validate_env() {
  : "${RUNNER_IMAGE:?RUNNER_IMAGE is required (e.g. you/github-runner:latest)}"
  local scope="${RUNNER_SCOPE:-repo}"; scope="${scope,,}"
  case "$scope" in
    org*) [[ -n "${ORG_NAME:-}" ]]        || die "RUNNER_SCOPE=org needs ORG_NAME" ;;
    ent*) [[ -n "${ENTERPRISE_NAME:-}" ]] || die "RUNNER_SCOPE=enterprise needs ENTERPRISE_NAME" ;;
    repo) [[ -n "${REPO_URL:-}" ]]        || die "RUNNER_SCOPE=repo needs REPO_URL (https://host/owner/repo)" ;;
    *)    die "RUNNER_SCOPE must be repo, org or enterprise (got '$scope')" ;;
  esac
  if [[ -n "${APP_ID:-}" ]]; then
    [[ -n "${APP_INSTALLATION_ID:-}" ]] || die "APP_ID is set but APP_INSTALLATION_ID is missing"
    [[ -n "${APP_KEY_PATH:-}" ]]        || die "GitHub App auth needs APP_KEY_PATH (path to the private key .pem)"
    [[ -r "$APP_KEY_PATH" ]]            || die "APP_KEY_PATH not readable: $APP_KEY_PATH"
    [[ -z "${ACCESS_TOKEN:-}" ]]        || warn "both APP_ID and ACCESS_TOKEN are set; the App is used, remove ACCESS_TOKEN"
  elif [[ -n "${ACCESS_TOKEN:-}" ]]; then
    :
  elif [[ -n "${RUNNER_TOKEN:-}" ]]; then
    warn "only RUNNER_TOKEN is set. It expires after 1 hour, so restarts and replacements will fail. Use a GitHub App or PAT."
  else
    die "no GitHub credential: set APP_ID + APP_INSTALLATION_ID + APP_KEY_PATH, or ACCESS_TOKEN"
  fi
}

# ---------------------------------------------------------------------------
# Docker plumbing
# ---------------------------------------------------------------------------
need_docker() { command -v docker >/dev/null 2>&1 || die "docker not found"; docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon"; }

detect_mode() {
  case "$MODE" in
    swarm|standalone) ;;
    auto) if [[ "$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null)" == "true" ]]; then MODE=swarm; else MODE=standalone; fi ;;
    *) die "--mode must be swarm, standalone or auto" ;;
  esac
  if [[ "$MODE" == swarm ]]; then
    [[ "$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null)" == "true" ]] \
      || die "swarm mode needs a Swarm manager node (use --mode standalone, or docker swarm init)"
  fi
}

dc() { # docker compose wrapper (plugin preferred, v1 fallback)
  if docker compose version >/dev/null 2>&1; then docker compose "$@"; else docker-compose "$@"; fi
}

build_files() {
  [[ -f "$COMP" ]] || die "compose file not found: $COMP"
  FILES=("$COMP")
  if [[ -n "$OVR" ]]; then [[ -f "$OVR" ]] || die "override file not found: $OVR"; FILES+=("$OVR"); fi
  if [[ -n "${APP_ID:-}" ]]; then FILES+=("$(dirname "$COMP")/docker-compose.app-$MODE.yml"); [[ -f "${FILES[-1]}" ]] || die "missing ${FILES[-1]}"; fi
}

stack_args()   { local a=(); for f in "${FILES[@]}"; do a+=(-c "$f"); done; printf '%s\n' "${a[@]}"; }
compose_args() { local a=(-p "$STACK"); for f in "${FILES[@]}"; do a+=(-f "$f"); done; printf '%s\n' "${a[@]}"; }

redact() { sed -E 's/^([[:space:]]*(ACCESS_TOKEN|RUNNER_TOKEN|REGISTRY_TOKEN):[[:space:]]*).*/\1***REDACTED***/'; }

resolved_config() {
  if [[ "$MODE" == swarm ]]; then
    local a=(); mapfile -t a < <(stack_args); docker stack config "${a[@]}" 2>/dev/null | redact || true
  else
    local a=(); mapfile -t a < <(compose_args); dc "${a[@]}" config | redact
  fi
}

registry_login() { # pull login for private images; read-only token recommended
  [[ -n "${REGISTRY_USER:-}" && -n "${REGISTRY_TOKEN:-}" ]] || return 0
  local first="${RUNNER_IMAGE%%/*}" host=""
  [[ "$RUNNER_IMAGE" == */* && ( "$first" == *.* || "$first" == *:* || "$first" == localhost ) ]] && host="$first"
  [[ "$host" == "docker.io" || "$host" == "index.docker.io" ]] && host=""
  info "Logging in to ${host:-Docker Hub} as $REGISTRY_USER (to pull the image)"
  printf '%s' "$REGISTRY_TOKEN" | docker login ${host:+"$host"} -u "$REGISTRY_USER" --password-stdin >/dev/null
}

ensure_app_secret() { # swarm only: create the key secret if missing
  [[ "$MODE" == swarm && -n "${APP_ID:-}" ]] || return 0
  local name="${APP_KEY_SECRET_NAME:-gh_app_key}"
  if docker secret inspect "$name" >/dev/null 2>&1; then
    info "Swarm secret '$name' exists (kept; see README to rotate)"
  else
    info "Creating Swarm secret '$name' from $APP_KEY_PATH"
    docker secret create "$name" "$APP_KEY_PATH" >/dev/null
  fi
}

preflight() { # run token.sh check inside the real image, with the real credentials
  info "Pulling $RUNNER_IMAGE and verifying GitHub credentials"
  docker pull "$RUNNER_IMAGE" >/dev/null || die "cannot pull $RUNNER_IMAGE (private image? set REGISTRY_USER/REGISTRY_TOKEN)"
  local a=(run --rm --entrypoint /token.sh) v
  for v in GITHUB_HOST GITHUB_API_URL RUNNER_SCOPE REPO_URL ORG_NAME ENTERPRISE_NAME ACCESS_TOKEN APP_ID APP_INSTALLATION_ID; do
    [[ -n "${!v:-}" ]] && a+=(-e "$v")
  done
  [[ -n "${APP_ID:-}" ]] && a+=(-v "$APP_KEY_PATH:/run/secrets/gh_app_key:ro")
  a+=("$RUNNER_IMAGE" check)
  docker "${a[@]}" || die "credential check failed (see message above). Nothing was deployed."
}

wait_ready() {
  info "Waiting up to ${TIMEOUT}s for runners to register and become healthy"
  local end=$((SECONDS + TIMEOUT)) want have starting label
  while (( SECONDS < end )); do
    if [[ "$MODE" == swarm ]]; then
      label="com.docker.swarm.service.name=${STACK}_runner"
      read -r have want < <(docker service ls --filter "name=${STACK}_runner" --format '{{.Replicas}}' | head -1 | tr '/' ' ' | awk '{print $1+0, $2+0}')
      starting=$(docker ps -q --filter "label=$label" --filter health=starting | wc -l)
      if (( want > 0 && have == want && starting == 0 )); then info "Healthy: $have/$want replicas"; return 0; fi
    else
      label="com.docker.compose.project=$STACK"
      want=$(docker ps -q --filter "label=$label" | wc -l)
      have=$(docker ps -q --filter "label=$label" --filter health=healthy | wc -l)
      if (( want > 0 && have == want )); then info "Healthy: $have/$want containers"; return 0; fi
    fi
    sleep 5
  done
  echo "Runners did not become healthy within ${TIMEOUT}s. Likely causes: bad credential, wrong scope/org, no network to GitHub." >&2
  echo "Inspect:  $PROG logs -s $STACK -e $ENVF" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
ask() { # ask VAR "Prompt" [default] [secret]
  local var="$1" prompt="$2" def="${3:-}" secret="${4:-}" cur="${!1:-}" val
  [[ -n "$cur" ]] && def="$cur"
  if (( YES )); then val="$def"
  elif [[ -n "$secret" ]]; then read -r -s -p "$prompt${def:+ [keep current]}: " val; echo; val="${val:-$def}"
  else read -r -p "$prompt${def:+ [$def]}: " val; val="${val:-$def}"; fi
  printf -v "$var" '%s' "$val"
}

cmd_init() {
  if [[ -e "$ENVF" ]] && (( ! YES )); then
    read -r -p "$ENVF exists. Overwrite? [y/N] " a; [[ "${a:-N}" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
  fi
  local RUNNER_IMAGE_ RUNNER_SCOPE_ GITHUB_HOST_ SCOPE_VAL="" AUTH="" pat="" aid="" iid="" kp="" ru="" rt=""
  ask RUNNER_IMAGE_ "Runner image (Docker Hub: user/github-runner:latest)" "${RUNNER_IMAGE:-}"
  ask GITHUB_HOST_  "GitHub host (empty = github.com; GHES: github.example.com)" "${GITHUB_HOST:-}"
  ask RUNNER_SCOPE_ "Runner scope (repo|org|enterprise)" "${RUNNER_SCOPE:-org}"
  case "${RUNNER_SCOPE_,,}" in
    org*) ask SCOPE_VAL "Organization name" "${ORG_NAME:-}" ;;
    ent*) ask SCOPE_VAL "Enterprise slug" "${ENTERPRISE_NAME:-}" ;;
    *)    ask SCOPE_VAL "Repository URL (https://github.com/owner/repo)" "${REPO_URL:-}" ;;
  esac
  if [[ -n "${APP_ID:-}" ]]; then AUTH=app; else AUTH=pat; fi
  ask AUTH "Authentication (app|pat)" "$AUTH"
  if [[ "$AUTH" == app ]]; then
    ask aid "GitHub App ID" "${APP_ID:-}"; ask iid "App installation ID" "${APP_INSTALLATION_ID:-}"
    ask kp "Path to App private key (.pem)" "${APP_KEY_PATH:-}"
  else
    ask pat "GitHub PAT (input hidden)" "${ACCESS_TOKEN:-}" secret
  fi
  ask ru "Registry user to PULL the image (empty if the image is public)" "${REGISTRY_USER:-}"
  [[ -n "$ru" ]] && ask rt "Registry read-only token (input hidden)" "${REGISTRY_TOKEN:-}" secret

  mkdir -p "$(dirname "$ENVF")"
  ( umask 077
    {
      echo "# Generated by $PROG init on $(date -u +%FT%TZ). Plain KEY=VALUE, no quotes needed. chmod 600."
      echo "RUNNER_IMAGE=$RUNNER_IMAGE_"
      [[ -n "$GITHUB_HOST_" ]] && echo "GITHUB_HOST=$GITHUB_HOST_"
      echo "RUNNER_SCOPE=${RUNNER_SCOPE_,,}"
      case "${RUNNER_SCOPE_,,}" in org*) echo "ORG_NAME=$SCOPE_VAL";; ent*) echo "ENTERPRISE_NAME=$SCOPE_VAL";; *) echo "REPO_URL=$SCOPE_VAL";; esac
      if [[ "$AUTH" == app ]]; then echo "APP_ID=$aid"; echo "APP_INSTALLATION_ID=$iid"; echo "APP_KEY_PATH=$kp"
      else echo "ACCESS_TOKEN=$pat"; fi
      [[ -n "$ru" ]] && { echo "REGISTRY_USER=$ru"; echo "REGISTRY_TOKEN=$rt"; }
      echo "DISABLE_AUTO_UPDATE=true"
    } > "$ENVF" )
  chmod 600 "$ENVF"
  info "Wrote $ENVF (mode 600)"
  # Re-read the file we just wrote (in a subshell, ignoring exported values)
  if ( unset RUNNER_IMAGE RUNNER_SCOPE REPO_URL ORG_NAME ENTERPRISE_NAME APP_ID APP_INSTALLATION_ID APP_KEY_PATH ACCESS_TOKEN RUNNER_TOKEN
       load_env; validate_env ); then
    echo "Config looks valid. Next: $PROG check && $PROG deploy"
  fi
}

case "$CMD" in
  help|-h|--help) usage ;;
  init) cmd_init ;;

  check)
    load_env; validate_env; need_docker; registry_login; preflight ;;

  validate)
    load_env; validate_env; need_docker; detect_mode; build_files
    resolved_config >/dev/null; echo "Validation OK (mode: $MODE, files: ${FILES[*]})" ;;

  dry-run)
    load_env; validate_env; need_docker; detect_mode; build_files
    echo "=== Mode: $MODE ==="; echo "=== Resolved config (secrets redacted) ==="; resolved_config; echo
    echo "=== Would run ==="
    if [[ "$MODE" == swarm ]]; then
      mapfile -t a < <(stack_args); echo "docker stack deploy --with-registry-auth --resolve-image always ${a[*]} $STACK"
    else
      mapfile -t a < <(compose_args); echo "docker compose ${a[*]} up -d --pull always --remove-orphans"
    fi ;;

  deploy)
    load_env; validate_env; need_docker; detect_mode; build_files
    registry_login
    ensure_app_secret
    (( SKIP_CHECK )) || preflight
    info "Deploying '$STACK' ($MODE mode)"
    if [[ "$MODE" == swarm ]]; then
      mapfile -t a < <(stack_args)
      docker stack deploy --with-registry-auth --resolve-image always "${a[@]}" "$STACK"
    else
      mapfile -t a < <(compose_args)
      dc "${a[@]}" up -d --pull always --remove-orphans
    fi
    wait_ready
    echo "Done. Status: $PROG status -s $STACK   Logs: $PROG logs -s $STACK" ;;

  status)
    load_env; need_docker; detect_mode
    if [[ "$MODE" == swarm ]]; then docker stack services "$STACK"; echo; docker stack ps "$STACK"
    else dc -p "$STACK" ps; fi ;;

  logs)
    load_env; need_docker; detect_mode
    if [[ "$MODE" == swarm ]]; then docker service logs -f "${STACK}_runner"
    else build_files; mapfile -t a < <(compose_args); dc "${a[@]}" logs -f; fi ;;

  scale)
    n="${ARGS[0]:-}"; [[ "$n" =~ ^[0-9]+$ ]] || die "usage: $PROG scale -s STACK N"
    load_env; need_docker; detect_mode
    if [[ "$MODE" == swarm ]]; then docker service scale "${STACK}_runner=$n"
    else validate_env; build_files; mapfile -t a < <(compose_args); dc "${a[@]}" up -d --no-recreate --scale "runner=$n"; fi
    echo "Scaled ${STACK} runner to $n replica(s)" ;;

  remove)
    load_env; need_docker; detect_mode
    if (( ! YES )); then read -r -p "Remove stack '$STACK'? [y/N] " a; [[ "${a:-N}" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }; fi
    if [[ "$MODE" == swarm ]]; then docker stack rm "$STACK"
    else validate_env; build_files; mapfile -t a < <(compose_args); dc "${a[@]}" down; fi
    echo "Removed. Registered runners deregister themselves on shutdown; offline leftovers: see README (Stale runner cleanup)." ;;

  version)
    load_env; : "${RUNNER_IMAGE:?RUNNER_IMAGE is required}"; need_docker
    docker run --rm --entrypoint /actions-runner/bin/Runner.Listener "$RUNNER_IMAGE" --version ;;

  *) echo "Unknown command: $CMD" >&2; echo >&2; usage >&2; exit 1 ;;
esac
