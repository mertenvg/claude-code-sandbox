#!/bin/bash
# Claude Code Sandbox launcher
# Run this from your project root

IMAGE_REPO="ghcr.io/mertenvg/claude-code-sandbox"
COMMIT_PREFIX="claude-code-sandbox"
DEFAULT_BUNDLE="go"
BUNDLE="$DEFAULT_BUNDLE"
PULL_FLAG=false
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse arguments
CONTAINER_NAME=""
CUSTOM_IMAGE=""
CLAUDE_EXTRA_ARGS=()
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      cat <<'EOF'
Usage: claude-sandbox.sh [flags] [-- claude-args...]

Run Claude Code in a sandboxed Docker container.

Flags:
  --name <name>             override the container name
  --image <name>            override the Docker image (default: ghcr.io/mertenvg/claude-code-sandbox:go)
  --bundle <name>           image bundle to pull or build (default: go)
  --pull                    pull the latest bundle image before running
  --continue                resume the most recent claude session
  --resume                  open the session picker to resume a session
  --resume-session <name>   resume a specific session by name or ID
  --session-id <uuid>       resume a specific session by UUID
  --session <name>          set a display name for the claude session
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
    --continue)
      CLAUDE_EXTRA_ARGS+=("--continue")
      shift
      ;;
    --resume)
      CLAUDE_EXTRA_ARGS+=("--resume")
      shift
      ;;
    --resume-session)
      CLAUDE_EXTRA_ARGS+=("--resume" "$2")
      shift 2
      ;;
    --session-id)
      CLAUDE_EXTRA_ARGS+=("--session-id" "$2")
      shift 2
      ;;
    --session)
      CLAUDE_EXTRA_ARGS+=("--name" "$2")
      shift 2
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

# Reuse existing container if it exists, otherwise create a new one
if docker container inspect "$CONTAINER_NAME" &>/dev/null; then
  echo "Restarting existing sandbox container..."

  # Start the container if not already running
  if ! docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q "true"; then
    docker start "$CONTAINER_NAME"

    # Check if it stayed running (old containers with claude CMD may exit immediately)
    if ! docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q "true"; then
      echo "Container uses an older format and needs to be recreated for session management support." >&2
      echo "Any state outside /workspace (installed packages, auth) will be lost." >&2
      echo "Tip: run './claude-sandbox.sh --commit <image-name>' first to preserve state," >&2
      echo "then use --image <image-name> to reuse it." >&2
      read -r -p "Recreate? [y/N] " answer
      if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        echo "Using legacy mode. Session flags will be ignored." >&2
        docker start -ai "$CONTAINER_NAME"
        exit $?
      fi
      docker rm "$CONTAINER_NAME"
      echo "Creating new sandbox container..."
      docker run -d \
        --name "$CONTAINER_NAME" \
        -v "$(pwd):/workspace" \
        -w /workspace \
        -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
        "$EFFECTIVE_IMAGE" \
        sleep infinity
    fi
  fi

  docker exec -it "$CONTAINER_NAME" claude --dangerously-skip-permissions "${CLAUDE_EXTRA_ARGS[@]}" "${POSITIONAL_ARGS[@]}"
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1
else
  echo "Creating new sandbox container..."
  docker run -d \
    --name "$CONTAINER_NAME" \
    -v "$(pwd):/workspace" \
    -w /workspace \
    -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
    "$EFFECTIVE_IMAGE" \
    sleep infinity

  docker exec -it "$CONTAINER_NAME" claude --dangerously-skip-permissions "${CLAUDE_EXTRA_ARGS[@]}" "${POSITIONAL_ARGS[@]}"
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1
fi
