# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Docker-based sandbox for running Claude Code with `--dangerously-skip-permissions` safely. The Go binary (`main.go`) wraps Docker commands to pull (or build) an image, create/reuse containers, and launch Claude Code inside them with the project directory mounted at `/workspace`.

## Build and Run

```bash
# Build the Go binary
go build -o claude-code-sandbox .

# Install globally
go install .

# Run (builds Docker image on first use, then creates/reuses a container)
claude-code-sandbox

# Shell mode (root shell instead of Claude)
claude-code-sandbox -shell    # or -debug (deprecated alias)

# Custom container name
claude-code-sandbox -name my-container

# Save container state as a new image
claude-code-sandbox -commit                   # auto-names: claude-code-sandbox-{dirname}
claude-code-sandbox -commit my-custom-sandbox # custom name

# Use a custom image (e.g., from -commit)
claude-code-sandbox -image my-custom-sandbox

# Image bundles (dockerfiles/<bundle>/Dockerfile)
claude-code-sandbox -bundle go     # default
claude-code-sandbox -bundle rust
claude-code-sandbox -pull           # refresh the bundle image from GHCR

# Session management
claude-code-sandbox -continue              # resume most recent session
claude-code-sandbox -resume                # open session picker
claude-code-sandbox -resume-session "name" # resume specific session
claude-code-sandbox -session "name"        # name the current session
```

There are no tests, no linter config, and no Makefile. The module requires Go 1.26.

## Architecture

This is a single-file Go program (`main.go`) with the `dockerfiles/` tree embedded via `//go:embed`. Key flow:

1. `ensureImage()` — checks if the Docker image exists (default or custom via `-image`); if the default is missing, pulls `ghcr.io/mertenvg/claude-code-sandbox:<bundle>` and falls back to writing the embedded Dockerfile to a temp dir and building it. Custom images must already exist. `warnArchMismatch()` flags an image whose architecture differs from the host, since emulating amd64 on arm64 corrupts Go's GC.
2. `run()` — determines container state (running/stopped/absent) and either reattaches, restarts, or creates a new container. Shell mode (`-shell` / `-debug`) opens a root bash shell instead of launching Claude.
3. `createContainer()` — runs `docker run -d` with `sleep infinity` as CMD, then uses `docker exec` to launch claude (or bash in debug mode) with session flags. Stops the container after claude exits.
4. `startContainer()` — for existing containers: starts detached, then `docker exec` claude. Detects old-format containers (pre-session-support) and prompts for migration with a `docker commit` tip. Falls back to legacy `docker start -a -i` if the user declines.
5. `claudeArgs()` — assembles claude CLI arguments including session flags (`-continue`, `-resume`, `-resume-session`, `-session-id`, `-session`).

Container naming is derived from the cwd (slugified), suffixed with the bundle for non-default bundles (`bundleSuffix()`), or overridden with `-name`. Containers are reused across runs; state outside `/workspace` persists between sessions.

### Image bundles

Each bundle is a `dockerfiles/<bundle>/Dockerfile`; `-bundle` selects one (default `go`). Current bundles: `go`, `rust`. `.github/workflows/publish-images.yml` discovers bundles from that directory and pushes multi-arch (`linux/amd64`, `linux/arm64`) images to GHCR tagged `<bundle>`, `<bundle>-v<version>`, and `<bundle>-<sha>`. `flavor: latest=false` is required on `docker/metadata-action`: its `latest=auto` default tags whichever matrix job finishes last as `latest`, which is a race between bundles. Adding a bundle requires no Go or workflow changes — drop in the Dockerfile and both the `//go:embed dockerfiles` fallback and the CI matrix pick it up.

Every bundle installs Node 22, Claude Code, and Playwright with Chromium only (browsers in the shared world-writable `PLAYWRIGHT_BROWSERS_PATH=/ms-playwright` so the `sandbox` user can use them and add engines at runtime; other engines are omitted to keep the pull small). Bundle Dockerfiles must never run the Go compiler under emulation — cross-compile Go tools from a `FROM --platform=$BUILDPLATFORM` stage instead. Emulated Go builds crash with `fatal error: found pointer to free object`. Prefer prebuilt toolchain components generally (the `rust` bundle uses `rustup component add`, which downloads rather than compiles, so it needs no builder stage).

The shell scripts (`claude-sandbox.sh`, `claude-sandbox-debug.sh`) are standalone alternatives to the Go binary with equivalent functionality.

## Engineering Guidelines

Refer to the AI engineering guidelines at https://github.com/mertenvg/my-ai-guidelines/guidelines/ for the full set of rules. They apply to all work in this repository. Key points summarized below.

### Code Style (Go)

- `gofmt` and `go vet` are mandatory before committing.
- Import order: standard library, third-party, local packages.
- Short, descriptive names following Go conventions. Method names must not repeat type/package name.
- Prefix SQL query constants with `q` (e.g., `qGetByID`).
- Early returns over deep nesting. Named constants over magic values.
- Comments explain **why**, not what.

### Error Handling

- Always wrap errors with context: `fmt.Errorf("module: operation: %w", err)`.
- Use `%w` when callers may need `errors.Is()`/`errors.As()`.
- Do not panic for expected failures — return errors. Panic only for programmer errors.
- Use sentinel errors for common conditions.

### Architecture

- **Module-based package structure is mandatory.** Group by domain (types, store, handler together), never by classification (`models/`, `handlers/`, `repositories/`).
- Inject dependencies via constructor functions. No package-level globals for mutable state.
- Define interfaces at the consumption boundary, not alongside the implementation. Keep them small (1-3 methods) and unexported.
- Handlers use constructor functions returning closures with injected dependencies.

### Security (Non-Negotiable)

- Never log secrets, credentials, tokens, or private keys.
- Never construct SQL via string concatenation — use parameterized queries.
- Never disable TLS verification or commit secrets to version control.
- Validate all user input at system boundaries. Prefer allow-lists over deny-lists.

### Testing

- Test behavior, not implementation details. Prefer table-driven tests.
- Use `require` for preconditions/errors (aborts on failure), `assert` for value checks (continues on failure).
- Name tests: `TestThing_Scenario_Expectation`.
- Use fakes/stubs over mocks when possible.
- Verify before committing: `go test ./...` and `go vet ./...`.

### Performance

- Bound concurrency — use worker pools, never unbounded goroutines.
- Timeouts on all network calls. Propagate `context.Context` and respect cancellation.
- Avoid N+1 queries — batch or join instead.
- Every goroutine must have a clear shutdown path. Code must be race-detector safe (`go test -race`).

### Dependencies

- Standard library first. Avoid trivial dependencies.
- Check if existing dependencies already solve the problem before adding new ones.
- Pin dependency versions.

### Git Workflow

- Conventional Commits: `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`. Imperative mood, ≤72 char first line.
- Short-lived feature branches: `feat/<name>`, `fix/<name>`, `chore/<name>`.
- One logical change per PR, aim for <300 lines of diff.
- Rebase on latest `main` before review. Semantic versioning for releases.

### AI Behavior

- Changes must be minimal, localized, and backwards compatible.
- No drive-by refactors, style-only rewrites, or features beyond what was requested.
- Do not add comments, docstrings, or type annotations to unchanged code.
- If uncertain, ask for clarification before writing code.
- A change is done only when it compiles, tests pass, linting passes, and errors are handled.
