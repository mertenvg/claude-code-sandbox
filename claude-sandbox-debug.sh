#!/bin/bash
# Claude Code Sandbox debug launcher
# Opens a root shell inside the sandbox container

IMAGE_REPO="ghcr.io/mertenvg/claude-code-sandbox"
COMMIT_PREFIX="claude-code-sandbox"
DEFAULT_BUNDLE="go"
BUNDLE="$DEFAULT_BUNDLE"
PULL_FLAG=false
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse arguments
CONTAINER_NAME=""
CUSTOM_IMAGE=""
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      cat <<'EOF'
Usage: claude-sandbox-debug.sh [flags]

Open a root shell inside the sandbox container.

Flags:
  --name <name>             override the container name
  --image <name>            override the Docker image (default: ghcr.io/mertenvg/claude-code-sandbox:go)
  --bundle <name>           image bundle to pull or build (default: go)
  --pull                    pull the latest bundle image before running
  --commit [name]           commit the current container as a new image
  --rm                      remove the container and exit
  --help                    show this help text
EOF
      exit 0
      ;;
    --name)
      CONTAINER_NAME="$2"
      shift 2
      ;;
    --image)
      CUSTOM_IMAGE="$2"
      shift 2
      ;;
    --bundle)
      BUNDLE="$2"
      shift 2
      ;;
    --pull)
      PULL_FLAG=true
      shift
      ;;
    --rm)
      REMOVE_FLAG=true
      shift
      ;;
    --commit)
      COMMIT_FLAG=true
      if [[ -n "$2" && "$2" != --* ]]; then
        COMMIT_IMAGE="$2"
        shift 2
      else
        COMMIT_IMAGE=""
        shift
      fi
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

CWD_SLUG="$(pwd | sed 's/[^a-zA-Z0-9]/-/g' | sed 's/^-//;s/-$//' | tr '[:upper:]' '[:lower:]')"

# Qualify per-directory names so bundles don't collide. The default bundle
# contributes nothing, so containers created before bundles existed keep
# their names.
BUNDLE_SUFFIX=""
if [ "$BUNDLE" != "$DEFAULT_BUNDLE" ]; then
  BUNDLE_SUFFIX="-$BUNDLE"
fi

# Derive container name from current working directory if not provided
if [ -z "$CONTAINER_NAME" ]; then
  CONTAINER_NAME="claude-sandbox-$CWD_SLUG$BUNDLE_SUFFIX"
fi

# Handle --commit: save the container as an image and exit
if [ "$COMMIT_FLAG" = true ]; then
  if [ -z "$COMMIT_IMAGE" ]; then
    COMMIT_IMAGE="$COMMIT_PREFIX-$CWD_SLUG$BUNDLE_SUFFIX"
  fi
  if ! docker container inspect "$CONTAINER_NAME" &>/dev/null; then
    echo "Error: container '$CONTAINER_NAME' does not exist." >&2
    exit 1
  fi
  echo "Committing container '$CONTAINER_NAME' as image '$COMMIT_IMAGE'..."
  docker commit "$CONTAINER_NAME" "$COMMIT_IMAGE"
  echo "Done. Use --image $COMMIT_IMAGE to start a new container from this image." >&2
  exit 0
fi

# Handle --rm: stop and remove the container, then exit
if [ "$REMOVE_FLAG" = true ]; then
  if ! docker container inspect "$CONTAINER_NAME" &>/dev/null; then
    echo "Error: container '$CONTAINER_NAME' does not exist." >&2
    exit 1
  fi
  if docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q "true"; then
    echo "Stopping container '$CONTAINER_NAME'..." >&2
    docker stop "$CONTAINER_NAME"
  fi
  echo "Removing container '$CONTAINER_NAME'..." >&2
  docker rm "$CONTAINER_NAME"
  echo "Done." >&2
  exit 0
fi

# Determine which image to use
EFFECTIVE_IMAGE="${CUSTOM_IMAGE:-$IMAGE_REPO:$BUNDLE}"

# Prefer the prebuilt image. Building locally is the fallback: it compiles the
# Go toolchain, which is where emulated builds tend to fall over.
if [ -n "$CUSTOM_IMAGE" ]; then
  if ! docker image inspect "$EFFECTIVE_IMAGE" &>/dev/null; then
    echo "Error: image '$CUSTOM_IMAGE' not found — build or pull it first." >&2
    exit 1
  fi
elif [ "$PULL_FLAG" = true ] || ! docker image inspect "$EFFECTIVE_IMAGE" &>/dev/null; then
  echo "Pulling sandbox image $EFFECTIVE_IMAGE..." >&2
  if ! docker pull "$EFFECTIVE_IMAGE"; then
    if [ "$PULL_FLAG" = true ]; then
      echo "Error: could not pull '$EFFECTIVE_IMAGE'." >&2
      exit 1
    fi
    DOCKERFILE_DIR="$SCRIPT_DIR/dockerfiles/$BUNDLE"
    if [ ! -f "$DOCKERFILE_DIR/Dockerfile" ]; then
      echo "Error: could not pull '$EFFECTIVE_IMAGE', and there is no $DOCKERFILE_DIR/Dockerfile to build from." >&2
      exit 1
    fi
    echo "Falling back to a local build (one-time setup)..." >&2
    docker build -t "$EFFECTIVE_IMAGE" "$DOCKERFILE_DIR"
  fi
fi

# Emulating amd64 on arm64 (Rosetta, qemu) corrupts Go's garbage collector,
# so warn when the image architecture doesn't match the host.
IMAGE_ARCH="$(docker image inspect -f '{{.Architecture}}' "$EFFECTIVE_IMAGE" 2>/dev/null)"
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  x86_64) HOST_ARCH="amd64" ;;
  aarch64|arm64) HOST_ARCH="arm64" ;;
esac
if [ -n "$IMAGE_ARCH" ] && [ "$IMAGE_ARCH" != "$HOST_ARCH" ]; then
  echo "Warning: image $EFFECTIVE_IMAGE is $IMAGE_ARCH but this host is $HOST_ARCH — it will run under emulation." >&2
  echo "Go tooling is unreliable under emulation. Unset DOCKER_DEFAULT_PLATFORM (or disable Rosetta" >&2
  echo "emulation in Docker Desktop) and re-run with --pull to get the native $HOST_ARCH image." >&2
fi

# Check if container is running, exists but stopped, or doesn't exist
if docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q "true"; then
  echo "Attaching debug shell to running container..."
  docker exec -it -u 0 "$CONTAINER_NAME" /bin/bash "${POSITIONAL_ARGS[@]}"
elif docker container inspect "$CONTAINER_NAME" &>/dev/null; then
  echo "Starting stopped container and attaching debug shell..."
  docker start "$CONTAINER_NAME"

  # Check if it stayed running (old containers may exit immediately)
  if ! docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q "true"; then
    echo "Recreating container in new format..." >&2
    docker rm "$CONTAINER_NAME"
    docker run -d \
      --name "$CONTAINER_NAME" \
      -v "$(pwd):/workspace" \
      -w /workspace \
      -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
      -u 0 \
      "$EFFECTIVE_IMAGE" \
      sleep infinity
  fi

  docker exec -it -u 0 "$CONTAINER_NAME" /bin/bash "${POSITIONAL_ARGS[@]}"
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1
else
  echo "Creating new sandbox container in debug mode..."
  docker run -d \
    --name "$CONTAINER_NAME" \
    -v "$(pwd):/workspace" \
    -w /workspace \
    -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
    -u 0 \
    "$EFFECTIVE_IMAGE" \
    sleep infinity

  docker exec -it -u 0 "$CONTAINER_NAME" /bin/bash "${POSITIONAL_ARGS[@]}"
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1
fi
