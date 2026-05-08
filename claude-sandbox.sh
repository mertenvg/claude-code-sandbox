#!/bin/bash
# Claude Code Sandbox launcher
# Run this from your project root

IMAGE_NAME="claude-code-sandbox"
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
  --image <name>            override the Docker image (default: claude-code-sandbox)
  --continue                resume the most recent claude session
  --resume                  open the session picker to resume a session
  --resume-session <name>   resume a specific session by name or ID
  --session-id <uuid>       resume a specific session by UUID
  --session <name>          set a display name for the claude session
  --commit [name]           commit the current container as a new image
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
