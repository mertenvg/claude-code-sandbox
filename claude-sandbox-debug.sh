#!/bin/bash
# Claude Code Sandbox debug launcher
# Opens a root shell inside the sandbox container

IMAGE_NAME="claude-code-sandbox"
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
  --image <name>            override the Docker image (default: claude-code-sandbox)
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

# Derive container name from current working directory if not provided
if [ -z "$CONTAINER_NAME" ]; then
  CONTAINER_NAME="claude-sandbox-$CWD_SLUG"
fi

# Handle --commit: save the container as an image and exit
if [ "$COMMIT_FLAG" = true ]; then
  if [ -z "$COMMIT_IMAGE" ]; then
    COMMIT_IMAGE="$IMAGE_NAME-$CWD_SLUG"
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
EFFECTIVE_IMAGE="${CUSTOM_IMAGE:-$IMAGE_NAME}"

# Build the default image if it doesn't exist (skip for custom images)
if ! docker image inspect "$EFFECTIVE_IMAGE" &>/dev/null; then
  if [ -n "$CUSTOM_IMAGE" ]; then
    echo "Error: image '$CUSTOM_IMAGE' not found — build or pull it first." >&2
    exit 1
  fi
  echo "Building sandbox image (one-time setup)..."
  docker build -t "$EFFECTIVE_IMAGE" "$SCRIPT_DIR"
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
