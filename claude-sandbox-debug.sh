#!/bin/bash
# Claude Code Sandbox debug launcher
# Opens a root shell inside the sandbox container

IMAGE_NAME="claude-code-sandbox"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse optional --name argument
CONTAINER_NAME=""
if [ "$1" = "--name" ] && [ -n "$2" ]; then
  CONTAINER_NAME="$2"
  shift 2
fi

# Build the image if it doesn't exist yet
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
  echo "Building sandbox image (one-time setup)..."
  docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
fi

# Derive container name from current working directory if not provided
if [ -z "$CONTAINER_NAME" ]; then
  CONTAINER_NAME="claude-sandbox-$(pwd | sed 's/[^a-zA-Z0-9]/-/g' | sed 's/^-//;s/-$//' | tr '[:upper:]' '[:lower:]')"
fi

# Check if container is running, exists but stopped, or doesn't exist
if docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q "true"; then
  echo "Attaching debug shell to running container..."
  docker exec -it -u 0 "$CONTAINER_NAME" /bin/bash "$@"
elif docker container inspect "$CONTAINER_NAME" &>/dev/null; then
  echo "Starting stopped container and attaching debug shell..."
  docker start "$CONTAINER_NAME"
  docker exec -it -u 0 "$CONTAINER_NAME" /bin/bash "$@"
else
  echo "Creating new sandbox container in debug mode..."
  docker run -it \
    --name "$CONTAINER_NAME" \
    -v "$(pwd):/workspace" \
    -w /workspace \
    -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
    -u 0 \
    "$IMAGE_NAME" \
    /bin/bash "$@"
fi
