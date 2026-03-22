# Claude Code Sandbox
# Includes: Go 1.26, Node 22 (for Claude Code), common dev tools

FROM golang:1.26-bookworm

ENV COLORTERM=truecolor

# Install Node.js 22 LTS
RUN apt-get update && apt-get install -y curl && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install useful Go tools (before switching user, since GOPATH=/go is root-owned)
RUN go install golang.org/x/tools/gopls@latest && \
    go install github.com/go-delve/delve/cmd/dlv@latest

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
