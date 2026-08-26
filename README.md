# claude-code-sandbox ![GitHub tag (latest by date)](https://img.shields.io/github/v/tag/mertenvg/claude-code-sandbox)

A Docker-based sandbox for running Claude Code with `--dangerously-skip-permissions` safely. The container provides filesystem and process isolation so Claude can operate autonomously on your project without risking your host system.

## What it does

Claude Code's `--dangerously-skip-permissions` flag lets it run commands and edit files without asking for approval at every step — useful for long autonomous tasks. The risk is that it can also run arbitrary shell commands on your machine. This sandbox runs Claude inside a Docker container with only your project directory mounted, so any risky operations are contained.

Every container includes Node.js 22, Claude Code, and Playwright with Chromium, plus a
language toolchain chosen by [bundle](#bundles):

| Bundle | Toolchain |
| --- | --- |
| `go` (default) | Go 1.26, gopls, Delve, golangci-lint, goimports |
| `rust` | Rust stable, rust-analyzer, clippy, rustfmt, lldb |

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

It pulls the same prebuilt image as the binary, so it works standalone. It only needs the
`dockerfiles/` directory alongside it if you want the local-build fallback.

### What happens on first run

1. The prebuilt image is pulled from `ghcr.io/mertenvg/claude-code-sandbox:go`. If the pull
   fails (offline, registry unreachable), the image is built locally from the embedded
   Dockerfile instead — that takes a few minutes.
2. Your current directory is mounted into the container as `/workspace`
3. Claude Code launches with `--dangerously-skip-permissions`

Images are published for `linux/amd64` and `linux/arm64`, so Apple Silicon and Intel
machines both get a native image. Playwright's Chromium adds roughly 400MB, so the first
pull is not instant, but it is a one-time cost and far faster than building locally.

To refresh an already-pulled image:

```bash
claude-code-sandbox -pull
```

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

### Bundles

The image is built from `dockerfiles/<bundle>/Dockerfile` and published to GHCR under a
bundle-prefixed tag. `go` is the default:

```bash
claude-code-sandbox                # ghcr.io/mertenvg/claude-code-sandbox:go
claude-code-sandbox -bundle rust   # ghcr.io/mertenvg/claude-code-sandbox:rust
```

Non-default bundles get their own container name (`claude-sandbox-<dir>-<bundle>`), so a
Go and a Rust sandbox can coexist in the same project. Containers created before bundles
existed keep working, since the default bundle leaves the name unchanged.

Tags published per bundle:

| Tag | Meaning |
| --- | --- |
| `<bundle>` | latest build from `main` |
| `<bundle>-v1.2.3` | build from release `v1.2.3` |
| `<bundle>-<sha>` | build from a specific commit |

To add a bundle, drop a `dockerfiles/<name>/Dockerfile` into the repo. The publish
workflow discovers bundles from that directory, and the binary embeds them all as
local-build fallbacks — no code changes needed.

### Custom image

By default, the sandbox uses the `ghcr.io/mertenvg/claude-code-sandbox:go` image. You can override this with the `-image` flag:

```bash
claude-code-sandbox -image my-custom-sandbox
```

The custom image must already exist — the sandbox will not auto-build or pull it. See [Saving container state](#saving-container-state) for how to create one from an existing container.

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

## Troubleshooting

### Build crashes with "fatal error: found pointer to free object"

If a local build dies inside the Go tools layer with something like:

```
runtime: marked free object in span 0x40474c78c0 ...
fatal error: found pointer to free object
runtime.(*mspan).reportZombies
```

…Docker is running an `amd64` image on an `arm64` host under emulation (Rosetta or qemu),
which corrupts Go's garbage collector. The sandbox warns when it detects this mismatch.

Fixes, in order of preference:

1. Let the sandbox pull the native image — `claude-code-sandbox -pull`.
2. Unset `DOCKER_DEFAULT_PLATFORM` if it is pinned to `linux/amd64`.
3. In Docker Desktop, turn off **Settings → General → Use Rosetta for x86_64/amd64 emulation**.

The `go` bundle also cross-compiles its Go tools rather than emulating the compiler, so
local builds on Apple Silicon no longer hit this even when targeting `amd64`.

### Playwright

`@playwright/test` and Chromium are preinstalled. Browsers live in the shared
`PLAYWRIGHT_BROWSERS_PATH=/ms-playwright` so they work for any user in the container:

```bash
playwright --version
```

Only Chromium is baked in — Firefox and WebKit would roughly triple the download for
something most projects don't need. Adding one needs its OS dependencies installed as root,
so do it from a shell in the container:

```bash
claude-code-sandbox -shell
playwright install --with-deps firefox   # or webkit
```

Commit the container afterwards (see [Saving container state](#saving-container-state)) if
you want to keep it.

If a project pins a different `@playwright/test` version than the one baked in, its browser
revisions won't match and Playwright will report a missing executable. The browser directory
is world-writable, so fetching matching revisions needs no root:

```bash
npx playwright install chromium
```

## Notes

- Changes Claude makes inside the container are written directly to your mounted project directory — they persist on your host.
- The container is reused across runs. If a container with the same name already exists, it is restarted rather than recreated. Anything outside `/workspace` (e.g. installed packages, auth state) is preserved between sessions.
- To start fresh, remove the container with `claude-code-sandbox -rm`.
- Network access is not restricted by default. If you want to limit outbound connections, add Docker network flags to the `docker run` command in `claude-sandbox.sh`.
