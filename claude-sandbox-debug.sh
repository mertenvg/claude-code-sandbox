#!/bin/bash

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
  CONTAINER_NAME="claude-sandbox-$(pwd | sed 's/[^a-zA-Z0-9]/-/g' | sed 's/^-//;s/-$//' | tr '[:upper:]' '[:lower:]')-debug"
fi

# Reuse existing container if it exists, otherwise create a new one
echo "Creating new sandbox container..."
docker run -it \
  --name "$CONTAINER_NAME" \
  -v "$(pwd):/workspace" \
  -w /workspace \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  "$IMAGE_NAME" \
  bash
