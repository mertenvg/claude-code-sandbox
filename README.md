# claude-code-sandbox

A Docker-based sandbox for running Claude Code with `--dangerously-skip-permissions` safely. The container provides filesystem and process isolation so Claude can operate autonomously on your project without risking your host system.

## What it does

Claude Code's `--dangerously-skip-permissions` flag lets it run commands and edit files without asking for approval at every step — useful for long autonomous tasks. The risk is that it can also run arbitrary shell commands on your machine. This sandbox runs Claude inside a Docker container with only your project directory mounted, so any risky operations are contained.

The container includes:
- Go 1.23 + gopls + Delve (for Go development)
- Node.js 20 + Claude Code

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- An `ANTHROPIC_API_KEY` environment variable set in your shell

## Usage

From your project root, run:

```bash
/path/to/claude-sandbox.sh
```

Or copy `claude-sandbox.sh` into your project and run it from there:

```bash
./claude-sandbox.sh
```

The script will:
1. Build the Docker image on first run (one-time setup, takes a few minutes)
2. Mount your current directory into the container as `/workspace`
3. Launch Claude Code with `--dangerously-skip-permissions`

Your `ANTHROPIC_API_KEY` is passed through automatically from your shell environment.

## Notes

- Changes Claude makes inside the container are written directly to your mounted project directory — they persist on your host.
- The container is ephemeral (`--rm`): anything outside `/workspace` is discarded when Claude exits.
- Network access is not restricted by default. If you want to limit outbound connections, add Docker network flags to the `docker run` command in `claude-sandbox.sh`.
