# claude-code-sandbox

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

## Notes

- Changes Claude makes inside the container are written directly to your mounted project directory — they persist on your host.
- The container is ephemeral (`--rm`): anything outside `/workspace` is discarded when Claude exits.
- Network access is not restricted by default. If you want to limit outbound connections, add Docker network flags to the `docker run` command in `claude-sandbox.sh`.
