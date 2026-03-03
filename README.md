# Claude Code Docker Environment

A confined Docker environment for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with network-level security controls, traffic monitoring, and observability.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                    Docker Internal Network                        │
│  ┌──────────────┐   iptables DNAT   ┌──────────────────┐        │
│  │  Claude Code  │ ──────────────── │   Envoy Proxy     │        │
│  │  Container    │  :80  → :10000   │   (whitelist)     │ ──┐    │
│  │              │  :443 → :10001   │                    │   │    │
│  │  OTel :9464  │                   │  admin:9901       │   │    │
│  │  Metrics:9465│                   │                    │   │    │
│  └──────┬───────┘                   └────────┬─────────┘   │    │
│         │                                     │             │    │
│  ┌──────┴────────────────────────────┐       │             │    │
│  │          Prometheus               │◄──────┘             │    │
│  │          :9090                     │    scrape metrics    │    │
│  │          (persistent volume)      │                     │    │
│  └──────────────┬────────────────────┘                     │    │
│                 │                                           │    │
│  ┌──────────────┴────────────────────┐                     │    │
│  │          Grafana                  │                     │    │
│  │          :3000                     │                     │    │
│  │          (dashboards)             │                     │    │
│  └───────────────────────────────────┘                     │    │
└────────────────────────────────────────────────────────────┼────┘
                                                              │
                                              ┌───────────────┴────┐
                                              │  External Network   │
                                              │  (internet access)  │
                                              └────────────────────┘
```

**Key security property:** The Claude Code container is on an internal-only Docker network. It cannot reach the internet directly. All TCP traffic on ports 80/443 is redirected via iptables DNAT rules to the Envoy proxy, which enforces a domain whitelist. Only the Envoy container has external network access.

## Components

| Component | Purpose | Image |
|-----------|---------|-------|
| **Claude Code** | Claude Code CLI in a confined container | Custom (Node 22 + `@anthropic-ai/claude-code`) |
| **Envoy Proxy** | Domain-whitelisting egress proxy | Custom (envoyproxy/envoy v1.31) |
| **Prometheus** | Metrics collection and storage | `prom/prometheus:latest` |
| **Grafana** | Metrics visualization dashboards | `grafana/grafana:latest` |

## Quick Start

### Prerequisites

- Docker installed and running
- `ANTHROPIC_API_KEY` environment variable set

### Launch

```bash
# From any directory you want to use as workspace:
export ANTHROPIC_API_KEY="sk-ant-..."
./scripts/claude-env.sh
```

This will:
1. Build the custom Docker images (first run only)
2. Generate the Envoy config from the domain whitelist
3. Create an isolated Docker network
4. Start Envoy, Prometheus, and Grafana
5. Launch an interactive Claude Code session with your current directory mounted

### Options

```bash
# Force rebuild of images
./scripts/claude-env.sh --build

# Add extra domains for this session (comma-separated)
./scripts/claude-env.sh --whitelist example.com,*.example.org

# Mount a specific directory
./scripts/claude-env.sh /path/to/project

# Custom ports
./scripts/claude-env.sh --grafana-port 8080 --prometheus-port 9999
```

### Cleanup

Everything is cleaned up automatically when you exit the Claude Code session (Ctrl+C or `/exit`). The trap handler removes all containers and the Docker network.

Persistent volumes are preserved across sessions. To remove them:

```bash
docker volume rm claude-env-prometheus-data
docker volume rm claude-env-claude-config
```

## Domain Whitelist

Allowed domains are defined in `config/domains.txt` — one domain per line, with `*.` prefix for wildcard subdomains.

**Default whitelist:**

| Domain | Purpose |
|--------|---------|
| `anthropic.com` / `*.anthropic.com` | Claude API, feature flags |
| `claude.com` / `*.claude.com` | Claude documentation |
| `sentry.io` / `*.sentry.io` | Error reporting |
| `registry.npmjs.org` | npm packages |
| `github.com` / `api.github.com` | GitHub access |
| `envoyproxy.io` / `*.envoyproxy.io` | Envoy documentation |
| `*.golang.org` | Go documentation |
| `*.prometheus.io` | Prometheus documentation |

### Managing the Whitelist

Use the `whitelist.sh` helper:

```bash
# List current domains
./scripts/whitelist.sh list

# Add domains
./scripts/whitelist.sh add example.com *.example.com

# Remove a domain
./scripts/whitelist.sh remove example.com

# Regenerate Envoy config from domains.txt
./scripts/whitelist.sh generate

# Regenerate config and restart Envoy (live update)
./scripts/whitelist.sh apply
```

Or edit `config/domains.txt` directly and run `./scripts/whitelist.sh apply`.

You can also pass temporary extra domains at launch time:

```bash
./scripts/claude-env.sh --whitelist extra.com,*.extra.org
```

## Monitoring

Metrics are collected from three sources and scraped by Prometheus:

| Endpoint | Port | Source |
|----------|------|--------|
| Claude OTel | 9464 | Native OpenTelemetry (built into Claude Code) |
| Custom metrics | 9465 | Statusline + hooks scripts |
| Envoy admin | 9901 | Envoy's built-in stats |

### Native OTel Metrics (port 9464)

Claude Code's [native OpenTelemetry support](https://code.claude.com/docs/en/monitoring-usage) exposes these via `OTEL_METRICS_EXPORTER=prometheus`:

| Metric | Description |
|--------|-------------|
| `claude_code.token.usage` | Tokens consumed (input/output/cache) |
| `claude_code.cost.usage` | Session cost by model (USD) |
| `claude_code.session.count` | Sessions started |
| `claude_code.lines_of_code.count` | Lines added/removed |
| `claude_code.commit.count` | Git commits created |
| `claude_code.pull_request.count` | PRs created |
| `claude_code.active_time.total` | Active time (seconds) |
| `claude_code.code_edit_tool.decision` | Edit accept/reject counts |

### Custom Metrics (port 9465)

A lightweight metrics server (`metrics-server.mjs`) aggregates output from two scripts:

**Statusline metrics** (`statusline.sh`) — invoked by Claude Code's status line handler:

| Metric | Description |
|--------|-------------|
| `claude_statusline_context_window_used_percent` | Context window usage % |
| `claude_statusline_current_input_tokens` | Current input tokens |
| `claude_statusline_total_cost_usd` | Total session cost |
| `claude_statusline_exceeds_200k_tokens` | Binary flag for high usage |

**Hook metrics** (`hooks-metrics.sh`) — invoked by Claude Code hooks:

| Metric | Description |
|--------|-------------|
| `claude_hook_tool_use_total{tool_name=...}` | Tool usage by name |
| `claude_hook_tool_errors_total{tool_name=...}` | Tool errors by name |
| `claude_hook_compaction_total` | Context compaction events |
| `claude_hook_subagent_starts_total` | Subagent launches |
| `claude_hook_subagent_stops_total` | Subagent completions |
| `claude_hook_turns_total{stop_reason=...}` | Turns by stop reason |

### Grafana Dashboard

Open http://localhost:3000 (default: anonymous access, no login needed).

The pre-provisioned **Claude Code Environment** dashboard shows:

- **Claude Code Usage** — Token usage rate (input/output/cache), cost (cumulative + rate by model), lines of code modified, sessions, commits, PRs, active time, code edit decisions
- **Envoy Traffic** — HTTPS connections (allowed/blocked), HTTP requests, bytes in/out
- **Envoy Upstream & Internals** — Connection pools, latency percentiles (p50/p99), memory, uptime

### Prometheus

Direct access at http://localhost:9090 for ad-hoc queries.

Useful queries:
```promql
# Total cost this session
claude_code_cost_usage_usd_total

# Token consumption rate by type
rate(claude_code_token_usage_tokens_total[5m])

# Context window usage
claude_statusline_context_window_used_percent

# Tool usage breakdown
claude_hook_tool_use_total

# HTTPS connections blocked in last 5 minutes
increase(envoy_tcp_https_blocked_cx_total[5m])
```

### Envoy Admin

http://localhost:9901 provides direct access to Envoy's admin interface:
- `/stats` — All metrics
- `/clusters` — Upstream cluster status
- `/config_dump` — Running configuration

## How the Network Confinement Works

1. **Internal network:** The Docker network is created with `--internal`, meaning containers on it have no default route to the internet.

2. **Dual-network Envoy:** The Envoy container is connected to both the internal network and a regular (external) bridge network, making it the only container that can reach the internet.

3. **iptables DNAT:** Inside the Claude container, iptables rules transparently redirect all outgoing TCP connections on ports 80 and 443 to the Envoy proxy's listener ports (10000/10001). The `NET_ADMIN` capability is granted solely for this purpose.

4. **SNI inspection:** For HTTPS traffic, Envoy uses `tls_inspector` to read the Server Name Indication (SNI) from the TLS ClientHello. Only connections to whitelisted SNI names are forwarded via the dynamic forward proxy; everything else hits a blackhole cluster.

5. **HTTP Lua filter:** For HTTP traffic, a Lua filter checks the `Host` header against the whitelist and returns 403 for blocked domains.

## File Structure

```
claude-env/
├── config/
│   └── domains.txt                 # Domain whitelist (one per line)
├── docker/
│   ├── claude/
│   │   ├── Dockerfile              # Claude Code container image
│   │   ├── entrypoint.sh           # iptables setup + hooks config + launch
│   │   ├── hooks-metrics.sh        # Hook-based metrics (tool use, errors, compactions)
│   │   ├── metrics-server.mjs      # HTTP metrics aggregator (port 9465)
│   │   └── statusline.sh           # Statusline metrics (context window, cost, tokens)
│   ├── envoy/
│   │   ├── Dockerfile              # Envoy proxy image
│   │   └── envoy.yaml.tpl          # Envoy config template (populated by whitelist.sh)
│   ├── grafana/
│   │   ├── dashboards/
│   │   │   └── claude-env.json     # Pre-built Grafana dashboard
│   │   └── provisioning/
│   │       ├── dashboards/
│   │       │   └── dashboards.yml
│   │       └── datasources/
│   │           └── prometheus.yml
│   └── prometheus/
│       └── prometheus.yml          # Scrape targets config
├── scripts/
│   ├── claude-env.sh               # Main launcher script
│   └── whitelist.sh                # Domain whitelist management tool
└── README.md
```
