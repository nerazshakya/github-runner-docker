FROM debian:12-slim

ARG GH_RUNNER_VERSION="2.324.0"
ARG TARGETPLATFORM="linux/amd64"
# Leave empty for github.com. 
# For enterprise:
# e.g. --build-arg GITHUB_HOST=github.example.com
ARG GITHUB_HOST=""
ARG ORG_NAME
ARG GITHUB_PAT

ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_ALLOW_RUNASROOT=1 \
    AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache \
    ORG_NAME=${ORG_NAME}

# NOTE: this container runs as root. That's what lets it read/write
# /var/run/docker.sock when it's mounted in from the host (socket mount,
# see docker-compose.yml). If you ever switch to a non-root user, you
# must add that user to a group with the same GID as the host's docker
# group, or socket access will fail with "permission denied".

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Install base tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl git jq unzip zip tar ca-certificates gnupg \
    lsb-release dumb-init procps iproute2 openssh-client sudo \
    libicu72 libssl3 libc6 libgcc-s1 libstdc++6 zlib1g \
    && rm -rf /var/lib/apt/lists/*

# Install Docker CLI + plugins only (no daemon — uses host Docker via socket mount)
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg \
       | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
       https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       docker-ce-cli docker-buildx-plugin docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub Actions runner binary
WORKDIR /actions-runner
RUN mkdir -p /opt/hostedtoolcache

COPY scripts/install_runner.sh .
RUN chmod +x install_runner.sh \
    && GITHUB_PAT=${GITHUB_PAT} \
    ./install_runner.sh \
        -v "${GH_RUNNER_VERSION}" \
        -p "${TARGETPLATFORM}" \
        -g "${GITHUB_HOST}" \
        -o "${ORG_NAME}" \
    && rm -f install_runner.sh

# Copy runtime scripts
COPY scripts/token.sh scripts/entrypoint.sh scripts/healthcheck.sh scripts/cleanup-offline-runners.sh /
RUN chmod +x /token.sh /entrypoint.sh /healthcheck.sh /cleanup-offline-runners.sh

# Checks every 30s that Runner.Listener is alive. Swarm/Docker restarts
# the container automatically if this fails 3 times in a row.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD /healthcheck.sh

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["/entrypoint.sh", "./bin/Runner.Listener", "run", "--startuptype", "service"]
