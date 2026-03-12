#!/bin/bash
# Claude Code Sandbox launcher
# Run this from your project root

IMAGE_NAME="claude-code-sandbox"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Build the image if it doesn't exist yet
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
  echo "Building sandbox image (one-time setup)..."
  docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
fi

CONTAINER_NAME="claude-sandbox"

# Reuse existing container if it exists, otherwise create a new one
if docker container inspect "$CONTAINER_NAME" &>/dev/null; then
  echo "Restarting existing sandbox container..."
  docker start -ai "$CONTAINER_NAME"
else
  echo "Creating new sandbox container..."
  docker run -it \
    --name "$CONTAINER_NAME" \
    -v "$(pwd):/workspace" \
    -w /workspace \
    -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
    "$IMAGE_NAME" \
    claude --dangerously-skip-permissions
fi
