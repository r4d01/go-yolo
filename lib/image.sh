# shellcheck shell=bash
# The Docker image: name, content hash and build.
#
# Sets: HASH        hash of every file that goes into the image
#       IMAGE_BASE  go-yolo:<distro>-<codename>, always pointing at the newest build
#       IMAGE       IMAGE_BASE plus the hash, so editing an image file triggers a rebuild

# Hash of the files copied into the image (first 8 hex digits).
compute_hash() {
  (
    cd "$REPO_DIR"
    find Dockerfile entrypoint.sh scripts agents firewall tmux -type f -print0 \
      | LC_ALL=C sort -z | xargs -0 sha256sum
  ) | sha256sum | cut -c1-8
}

choose_image() {
  HASH="$(compute_hash)"
  IMAGE_BASE="go-yolo:${HOST_ID}-${HOST_CODENAME}"
  IMAGE="${IMAGE_BASE}-${HASH}"
}

# Build the image unless it exists already (or --rebuild was given).
ensure_image() {
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
  if ((!REBUILD)) && docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker tag "$IMAGE" "$IMAGE_BASE"
    return 0
  fi

  local build=(docker build --build-arg "BASE_IMAGE=$BASE_IMAGE" --build-arg "GOYOLO_HASH=$HASH")
  local var env_name
  # Optional version pins, e.g. GOYOLO_CLAUDE_VERSION=2.1.0 (use with --rebuild).
  for var in NODE_MAJOR UV_VERSION CLAUDE_VERSION CODEX_VERSION OPENCODE_VERSION VIBE_VERSION; do
    env_name="GOYOLO_$var"
    if [[ -n ${!env_name:-} ]]; then build+=(--build-arg "$var=${!env_name}"); fi
  done
  if ((REBUILD)); then build+=(--pull --no-cache); fi
  build+=(-t "$IMAGE" -t "$IMAGE_BASE" "$REPO_DIR")
  note "building $IMAGE from $BASE_IMAGE"
  "${build[@]}" >&2
}
