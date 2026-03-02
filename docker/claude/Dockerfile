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
    sudo \
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

# Create workspace directory
RUN mkdir -p /workspace && chown claude:claude /workspace

# Native OpenTelemetry metrics — Claude Code exposes Prometheus
# metrics on port 9464 when OTEL_METRICS_EXPORTER=prometheus
EXPOSE 9464

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
