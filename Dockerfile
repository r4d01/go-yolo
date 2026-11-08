# go-yolo image. The launcher picks BASE_IMAGE to match the host distro and release,
# so host-mounted binaries (Go toolchain, ~/go/bin/*) run against the same glibc.
ARG BASE_IMAGE=debian:trixie
FROM ${BASE_IMAGE}

# Version build args ("latest" or an exact version) are declared right before the step that
# uses them: a declared ARG is part of the cache key of every later RUN.

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    UV_TOOL_DIR=/opt/uv/tools \
    UV_TOOL_BIN_DIR=/usr/local/bin \
    UV_PYTHON_INSTALL_DIR=/opt/uv/python \
    DISABLE_AUTOUPDATER=1 \
    OPENCODE_DISABLE_AUTOUPDATE=1

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git openssh-client less procps jq ripgrep \
      iptables ipset dnsutils iproute2 util-linux tini tmux ncurses-term \
      build-essential python3 xz-utils gpgv tzdata \
 && rm -rf /var/lib/apt/lists/*

# Node.js from nodejs.org: distro packages are too old on some bases (Claude Code needs >= 22).
# SHASUMS256.txt is checked against the release keys from github.com/nodejs/release-keys,
# a second origin, so a compromised nodejs.org alone can't swap the tarball.
ARG NODE_MAJOR=24
RUN case "$(dpkg --print-architecture)" in \
      amd64) arch=x64 ;; arm64) arch=arm64 ;; \
      *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac \
 && base="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x" \
 && tmp="$(mktemp -d)" && cd "$tmp" \
 && curl -fsSLo keys.kbx https://github.com/nodejs/release-keys/raw/HEAD/gpg-only-active-keys/pubring.kbx \
 && curl -fsSLO "$base/SHASUMS256.txt" -fsSLO "$base/SHASUMS256.txt.sig" \
 && gpgv --keyring "$tmp/keys.kbx" SHASUMS256.txt.sig SHASUMS256.txt \
 && tarball="$(awk -v a="linux-${arch}.tar.xz" '$2 ~ a"$" {print $2}' SHASUMS256.txt)" \
 && curl -fsSLO "$base/$tarball" \
 && grep " ${tarball}\$" SHASUMS256.txt | sha256sum -c - \
 && tar -xJf "$tarball" -C /usr/local --strip-components=1 --no-same-owner \
      --exclude='*/CHANGELOG.md' --exclude='*/LICENSE' --exclude='*/README.md' \
 && cd / && rm -rf "$tmp" \
 && node --version && npm --version

# uv (official installer), installed system-wide.
ARG UV_VERSION=latest
RUN if [ "$UV_VERSION" = latest ]; then url=https://astral.sh/uv/install.sh; \
    else url="https://astral.sh/uv/${UV_VERSION}/install.sh"; fi \
 && curl -LsSf "$url" | env UV_UNMANAGED_INSTALL=/usr/local/bin sh \
 && uv --version

# Agents, installed system-wide so the image works for any UID/username.
ARG CLAUDE_VERSION=latest
ARG CODEX_VERSION=latest
ARG OPENCODE_VERSION=latest
RUN npm install -g --no-fund --no-audit \
      "@anthropic-ai/claude-code@${CLAUDE_VERSION}" \
      "@openai/codex@${CODEX_VERSION}" \
      "opencode-ai@${OPENCODE_VERSION}" \
 && npm cache clean --force

ARG VIBE_VERSION=latest
RUN if [ "$VIBE_VERSION" = latest ]; then pkg=mistral-vibe; else pkg="mistral-vibe==${VIBE_VERSION}"; fi \
 && UV_CACHE_DIR=/tmp/uv-cache uv tool install "$pkg" \
 && rm -rf /tmp/uv-cache \
 && chmod -R a+rX /opt/uv

COPY entrypoint.sh /opt/go-yolo/entrypoint.sh
COPY scripts/ /opt/go-yolo/scripts/
COPY agents/ /opt/go-yolo/agents/
COPY firewall/ /opt/go-yolo/firewall/
COPY tmux/ /opt/go-yolo/tmux/
RUN chmod 0755 /opt/go-yolo/entrypoint.sh /opt/go-yolo/scripts/*.sh \
 && chmod -R a+rX /opt/go-yolo

# Last, so a new hash doesn't invalidate the cached layers above.
ARG GOYOLO_HASH=dev
LABEL go-yolo.hash="${GOYOLO_HASH}"

ENTRYPOINT ["/opt/go-yolo/entrypoint.sh"]
