# Claude Code Sandbox — Rust bundle
# Includes: Rust (stable 1.x), Node 22 (for Claude Code), Playwright + Chromium, common dev tools

# Tracks the latest stable 1.x. Pin to a specific minor (e.g. rust:1.90-bookworm)
# if you need reproducible image builds.
FROM rust:1-bookworm

ENV COLORTERM=truecolor

# Install Node.js 22 LTS
RUN apt-get update && apt-get install -y curl && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    apt-get install -y jq lldb && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Rust tooling ships as prebuilt rustup components, so nothing is compiled here.
# That is why this bundle needs no cross-compiling builder stage — unlike the
# Go bundle, where emulating the compiler corrupts its garbage collector.
# Installed before the CARGO_HOME switch below so the shims land on the shared PATH.
RUN rustup component add rustfmt clippy rust-analyzer rust-src

# Playwright with Chromium only, to keep the image pullable. Firefox and WebKit
# can be added at runtime — see the README; each needs its OS deps installed as
# root first. Browsers go to a shared, world-writable path so the sandbox user
# can drive the ones installed here as root, and can install matching revisions
# itself when a project pins a different @playwright/test version.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN apt-get update && \
    npm install -g @playwright/test && \
    playwright install --with-deps chromium && \
    chmod -R a+rwX /ms-playwright && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# add sandbox user for claude
RUN useradd -m sandbox

# Give sandbox user its own CARGO_HOME so it can cargo install without root.
# The cargo/rustc shims stay on PATH via the base image's /usr/local/cargo/bin.
ENV CARGO_HOME=/home/sandbox/.cargo
ENV PATH="/home/sandbox/.cargo/bin:${PATH}"
RUN mkdir -p /home/sandbox/.cargo && chown -R sandbox:sandbox /home/sandbox/.cargo

USER sandbox

# Install Claude Code
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/sandbox/.local/bin:${PATH}"

WORKDIR /workspace

CMD ["bash"]
