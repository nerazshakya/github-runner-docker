#!/usr/bin/env bash
set -euo pipefail

usage() { cat <<EOF
GitHub Actions Runner � Stack Management

Usage:
  $(basename "$0") <command> [options]

Commands:
  deploy      Deploy or update the runner stack on Docker Swarm
  validate    Validate the compose config without deploying
  dry-run     Show the resolved config and deploy command without running it
  status      Show running services and tasks for the stack
  logs        Follow live logs from the runner service
  scale       Scale the number of runner replicas (concurrent job capacity)
  remove      Remove the stack from Docker Swarm (prompts for confirmation)
  version     Show the current image version
  help        Show this help message

Options:
  -s, --stack   NAME   Stack name (e.g. gh-runner-int)          [required for most commands]
  -e, --env-file FILE  Path to the env file (e.g. ../../runner.env)
  -c, --compose  FILE  Path to the base compose file
  -o, --override FILE  Path to the environment override file (e.g. docker-compose.int.yml)
  -y, --yes            Skip confirmation prompt (used with remove)
  -h, --help           Show this help message

Examples:
  # Deploy DEV runners
  $(basename "$0") deploy \\
    -s gh-runner \\
    -e /deployment/GitHub/runner.env \\
    -c docker/docker-compose.yml \\
    -o docker/docker-compose.dev.yml

  # Dry run first to verify config
  $(basename "$0") dry-run \\
    -s gh-runner \\
    -e /deployment/GitHub/runner.env \\
    -c docker/docker-compose.yml \\
    -o docker/docker-compose.dev.yml

  # Scale up to handle more concurrent jobs
  $(basename "$0") scale -s gh-runner-dev 5

  # Check stack status
  $(basename "$0") status -s gh-runner-dev

  # Follow runner logs
  $(basename "$0") logs -s gh-runner-dev

  # Remove stack without prompt
  $(basename "$0") remove -s gh-runner-dev -y
EOF
}

CMD="${1:-help}"; shift || true
STACK=""; ENVF=""; COMP=""; OVR=""; YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--stack)    STACK="$2"; shift 2 ;;
    -e|--env-file) ENVF="$2";  shift 2 ;;
    -c|--compose)  COMP="$2";  shift 2 ;;
    -o|--override) OVR="$2";   shift 2 ;;
    -y|--yes)      YES=1;      shift   ;;
    -h|--help)     usage; exit 0       ;;
    *) echo "Unknown option: $1"; echo; usage; exit 1 ;;
  esac
done

load() {
  [[ -n "$ENVF" ]] && { set -a; source "$ENVF"; set +a; }
}

compose_args() {
  A=(-c "$COMP")
  [[ -n "$OVR" ]] && A+=(-c "$OVR")
  echo "${A[@]}"
}

require_stack() {
  [[ -n "$STACK" ]] || { echo "Error: --stack is required for '$CMD'"; echo; usage; exit 1; }
}

require_compose() {
  [[ -n "$COMP" ]] || { echo "Error: --compose is required for '$CMD'"; echo; usage; exit 1; }
}

case "$CMD" in
  deploy)
    require_stack; require_compose
    load
    echo "Deploying stack: $STACK"
    docker stack deploy --with-registry-auth --resolve-image always $(compose_args) "$STACK"
    echo "Done. Check status with: $(basename "$0") status -s $STACK"
    ;;

  validate)
    require_compose
    load
    docker-compose $(compose_args) config > /dev/null && echo "Validation OK"
    ;;

  dry-run)
    require_stack; require_compose
    load
    echo "=== Resolved compose config ==="
    docker-compose $(compose_args) config
    echo
    echo "=== Would run ==="
    echo "docker stack deploy --with-registry-auth --resolve-image always $(compose_args) $STACK"
    ;;

  status)
    require_stack
    echo "=== Services ==="
    docker stack services "$STACK"
    echo
    echo "=== Tasks ==="
    docker stack ps "$STACK"
    ;;

  logs)
    require_stack
    docker service logs -f "${STACK}_runner"
    ;;

  remove)
    require_stack
    if [[ $YES -eq 1 ]]; then
      docker stack rm "$STACK"
    else
      read -p "Remove stack '$STACK'? [y/N] " a
      [[ ${a:-N} =~ ^[Yy]$ ]] && docker stack rm "$STACK" || echo "Cancelled."
    fi
    ;;

  scale)
    require_stack
    [[ -n "${2:-}" ]] || { echo "Error: specify replica count e.g. $(basename "$0") scale -s gh-runner-int 5"; exit 1; }
    docker service scale "${STACK}_runner=$2"
    echo "Scaled ${STACK}_runner to $2 replica(s)"
    ;;

  help|*)
    usage
    ;;
esac