# claude-code-sandbox ![GitHub tag (latest by date)](https://img.shields.io/github/v/tag/mertenvg/claude-code-sandbox)

A Docker-based sandbox for running Claude Code with `--dangerously-skip-permissions` safely. The container provides filesystem and process isolation so Claude can operate autonomously on your project without risking your host system.

## What it does

Claude Code's `--dangerously-skip-permissions` flag lets it run commands and edit files without asking for approval at every step — useful for long autonomous tasks. The risk is that it can also run arbitrary shell commands on your machine. This sandbox runs Claude inside a Docker container with only your project directory mounted, so any risky operations are contained.

The container includes:
- Go 1.26 + gopls + Delve (for Go development)
- Node.js 24 + Claude Code

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)

> **Note:** `ANTHROPIC_API_KEY` is not currently supported. Claude recommends against using API keys when starting the app. Instead, the app will automatically prompt for OAuth authentication on startup.

## Usage

### Install the binary (recommended)

```bash
go install github.com/mertenvg/claude-code-sandbox@latest
```

Then from any project directory:

```bash
claude-code-sandbox
```

### Updating

```bash
claude-code-sandbox -update
```

To check which version you have:

```bash
claude-code-sandbox -version
```

### Shell script (alternative)

Copy `claude-sandbox.sh` into your project and run it from your project root:

```bash
./claude-sandbox.sh
```

### What happens on first run

1. The Docker image is built automatically (one-time setup, takes a few minutes)
2. Your current directory is mounted into the container as `/workspace`
3. Claude Code launches with `--dangerously-skip-permissions`

Any extra arguments are forwarded to `claude`, e.g.:

```bash
claude-code-sandbox --model claude-opus-4-6
```

### Shell mode

Use the `-shell` flag to open an interactive root shell inside the container instead of launching Claude:

```bash
claude-code-sandbox -shell
```

The `-debug` flag is a deprecated alias for `-shell` and still works.

This is useful for inspecting the container environment, installing additional tools, or troubleshooting issues. Shell mode works in three scenarios:

- **No existing container** — creates a new container with a root bash shell
- **Container exists but is stopped** — starts the container and attaches a root shell via `docker exec`
- **Container is already running** (e.g. Claude is active in another terminal) — attaches an additional root shell via `docker exec`

The corresponding shell script is `claude-sandbox-debug.sh`.

### Session management

Claude Code saves conversations to disk. You can resume previous sessions:

```bash
# Resume the most recent session
claude-code-sandbox -continue

# Open the interactive session picker
claude-code-sandbox -resume

# Resume a specific session by name or ID
claude-code-sandbox -resume-session "my-task"

# Resume a specific session by UUID
claude-code-sandbox -session-id "550e8400-e29b-41d4-a716-446655440000"

# Start a new session with a display name (for easier resumption later)
claude-code-sandbox -session "my-new-task"
```

The corresponding shell script flags use double dashes: `--continue`, `--resume`, `--resume-session`, `--session-id`, `--session`.

### Custom image

By default, the sandbox builds and uses the `claude-code-sandbox` image. You can override this with the `-image` flag:

```bash
claude-code-sandbox -image my-custom-sandbox
```

The custom image must already exist — the sandbox will not auto-build it. See [Saving container state](#saving-container-state) for how to create one from an existing container.

### Custom container name

By default, the container name is derived from the current working directory. You can override it with the `--name` flag:

```bash
# Binary
claude-code-sandbox -name my-container

# Shell script
./claude-sandbox.sh --name my-container

# Debug script
./debug.sh --name my-debug-container
```

This is useful when you want a stable, memorable container name or need to run multiple sandboxes for the same project.

### Saving container state

If you've customized your container (installed packages, configured tools, etc.) and need to recreate it (e.g., after upgrading claude-code-sandbox), you can preserve your changes by committing the container to a new image:

1. Save the current container as a new image:

   ```bash
   # Auto-generate name based on directory (claude-code-sandbox-{dirname})
   claude-code-sandbox -commit

   # With a specific name
   claude-code-sandbox -commit my-custom-sandbox
   ```

2. Remove the old container:

   ```bash
   claude-code-sandbox -rm
   ```

3. Start the sandbox using your saved image:

   ```bash
   claude-code-sandbox -image my-custom-sandbox
   ```

   This creates a new container from your custom image, preserving all installed packages, Go tools, auth state, and other customizations.

   You only need `-image` for this first run. Once the container exists, subsequent runs reuse it by name — the image is only used at container creation time.

Note: Your project files in `/workspace` are always preserved since they are mounted from your host directory.

## Notes

- Changes Claude makes inside the container are written directly to your mounted project directory — they persist on your host.
- The container is reused across runs. If a container with the same name already exists, it is restarted rather than recreated. Anything outside `/workspace` (e.g. installed packages, auth state) is preserved between sessions.
- To start fresh, remove the container with `claude-code-sandbox -rm`.
- Network access is not restricted by default. If you want to limit outbound connections, add Docker network flags to the `docker run` command in `claude-sandbox.sh`.
