FROM node:22-bookworm

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    wget \
    iptables \
    iproute2 \
    ca-certificates \
    jq \
    vim \
    less \
    procps \
    gosu \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

# Create a non-root user for Claude Code
# No sudo access — iptables rules are set by the root entrypoint
# before dropping privileges to this user
RUN useradd -m -s /bin/bash claude

# Copy the entrypoint script
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Copy the status line metrics server and scripts
COPY metrics-server.mjs /usr/local/lib/metrics-server.mjs
COPY statusline.sh /usr/local/lib/statusline.sh
COPY hooks-metrics.sh /usr/local/lib/hooks-metrics.sh
RUN chmod +x /usr/local/lib/statusline.sh /usr/local/lib/hooks-metrics.sh

# Create workspace directory
RUN mkdir -p /workspace && chown claude:claude /workspace

# Native OpenTelemetry metrics — Claude Code exposes Prometheus
# metrics on port 9464 when OTEL_METRICS_EXPORTER=prometheus
EXPOSE 9464

# Status-line metrics endpoint (context window, cost, tokens)
EXPOSE 9465

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
