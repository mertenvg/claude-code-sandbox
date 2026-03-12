#!/bin/bash
# Claude Code Sandbox launcher
# Run this from your project root

IMAGE_NAME="claude-go-sandbox"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Build the image if it doesn't exist yet
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
  echo "Building sandbox image (one-time setup)..."
  docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
fi

# Launch the sandbox
docker run -it --rm \
  -v "$(pwd):/workspace" \
  -w /workspace \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  "$IMAGE_NAME" \
  claude --dangerously-skip-permissions
