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
2. Create an isolated Docker network
3. Start Envoy, Prometheus, and Grafana
4. Launch an interactive Claude Code session with your current directory mounted

### Options

```bash
# Force rebuild of images
./scripts/claude-env.sh --build

# Mount a specific directory
./scripts/claude-env.sh /path/to/project

# Custom ports
./scripts/claude-env.sh --grafana-port 8080 --prometheus-port 9999
```

### Cleanup

Everything is cleaned up automatically when you exit the Claude Code session (Ctrl+C or `/exit`). The trap handler removes all containers and the Docker network.

Prometheus data is persisted in the `claude-env-prometheus-data` Docker volume. To remove it:

```bash
docker volume rm claude-env-prometheus-data
```

## Domain Whitelist

The Envoy proxy allows traffic only to these domains:

| Domain | Purpose |
|--------|---------|
| `api.anthropic.com` | Claude API |
| `statsig.anthropic.com` | Feature flags |
| `sentry.io` / `*.sentry.io` | Error reporting |
| `registry.npmjs.org` | npm packages |
| `github.com` / `api.github.com` | GitHub access |

### Modifying the Whitelist

Edit `docker/envoy/envoy.yaml`:

- **HTTPS (SNI-based):** Update the `server_names` list in the `https_listener` → `filter_chain_match` section
- **HTTP (Lua-based):** Update the `allowed` table and `wildcard_suffixes` list in the Lua filter

After changes, rebuild with `--build`:

```bash
./scripts/claude-env.sh --build
```

## Monitoring

Claude Code's [native OpenTelemetry support](https://code.claude.com/docs/en/monitoring-usage) is used for metrics. The launcher script enables the built-in Prometheus exporter (`OTEL_METRICS_EXPORTER=prometheus`), which serves metrics on port 9464 inside the container. Prometheus scrapes this directly — no custom exporter needed.

### Native Metrics Available

| Metric | Description | Unit |
|--------|-------------|------|
| `claude_code.token.usage` | Tokens consumed (by type: input/output/cache) | tokens |
| `claude_code.cost.usage` | Session cost (by model) | USD |
| `claude_code.session.count` | Sessions started | count |
| `claude_code.lines_of_code.count` | Lines added/removed | count |
| `claude_code.commit.count` | Git commits created | count |
| `claude_code.pull_request.count` | PRs created | count |
| `claude_code.active_time.total` | Active time (user interaction / CLI processing) | seconds |
| `claude_code.code_edit_tool.decision` | Edit/Write/NotebookEdit accept/reject counts | count |

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

# Lines of code added
rate(claude_code_lines_of_code_count_total{type="added"}[5m])

# HTTPS connections blocked in last 5 minutes
increase(envoy_tcp_https_blocked_cx_total[5m])

# Envoy upstream connection rate
rate(envoy_cluster_upstream_cx_total{envoy_cluster_name=~"dynamic_forward_proxy.*"}[1m])
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
├── docker/
│   ├── claude/
│   │   ├── Dockerfile            # Claude Code container image
│   │   └── entrypoint.sh         # iptables setup + launch
│   ├── envoy/
│   │   ├── Dockerfile            # Envoy proxy image
│   │   └── envoy.yaml            # Envoy config (whitelist + routing)
│   ├── grafana/
│   │   ├── dashboards/
│   │   │   └── claude-env.json   # Pre-built Grafana dashboard
│   │   └── provisioning/
│   │       ├── dashboards/
│   │       │   └── dashboards.yml
│   │       └── datasources/
│   │           └── prometheus.yml
│   └── prometheus/
│       └── prometheus.yml        # Scrape targets config
├── scripts/
│   └── claude-env.sh             # Main launcher script
└── README.md
```
