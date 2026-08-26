# Claude Code Sandbox — Go bundle
# Includes: Go 1.26, Node 22 (for Claude Code), Playwright + Chromium, common dev tools

# Build the Go tools on the build host and cross-compile them to the target
# architecture. Running the Go compiler under emulation (Rosetta, qemu)
# corrupts its garbage collector — "fatal error: found pointer to free object"
# — so the compiler must never be emulated, only its output.
FROM --platform=$BUILDPLATFORM golang:1.26-bookworm AS tools

ARG TARGETOS
ARG TARGETARCH

ENV CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH

RUN go install golang.org/x/tools/gopls@latest && \
    go install github.com/go-delve/delve/cmd/dlv@latest && \
    go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest && \
    go install golang.org/x/tools/cmd/goimports@latest

# go install writes cross-compiled binaries to $GOPATH/bin/$GOOS_$GOARCH but
# native ones straight to $GOPATH/bin. GOBIN would flatten that, except Go
# refuses the combination outright: "cannot install cross-compiled binaries
# when GOBIN is set". So normalise into /out and let the COPY below be uniform.
RUN mkdir -p /out && \
    if [ -d "/go/bin/${TARGETOS}_${TARGETARCH}" ]; then \
        cp /go/bin/${TARGETOS}_${TARGETARCH}/* /out/; \
    else \
        cp /go/bin/* /out/; \
    fi

FROM golang:1.26-bookworm

ENV COLORTERM=truecolor

# Install Node.js 22 LTS
RUN apt-get update && apt-get install -y curl && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    apt-get install -y jq && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=tools /out/ /usr/local/bin/

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

# Give sandbox user its own GOPATH so it can install/cache Go packages
ENV GOPATH=/home/sandbox/go
ENV PATH="/home/sandbox/go/bin:${PATH}"
RUN mkdir -p /home/sandbox/go && chown -R sandbox:sandbox /home/sandbox/go

USER sandbox

# Install Claude Code
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/sandbox/.local/bin:${PATH}"

WORKDIR /workspace

CMD ["bash"]
