# Claude Code Sandbox
# Includes: Go 1.26, Node 24 (for Claude Code), common dev tools

FROM golang:1.26-bookworm

# Install Node.js 24
RUN apt-get update && apt-get install -y curl && \
    curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
    apt-get install -y nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

# Install useful Go tools
RUN go install golang.org/x/tools/gopls@latest && \
    go install github.com/go-delve/delve/cmd/dlv@latest

RUN useradd -m sandbox
USER sandbox

WORKDIR /workspace

CMD ["bash"]
