# claude-coop

A sandboxed Docker environment for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with network confinement, traffic control, and full observability.

## Why claude-coop?

### Isolation

Claude Code runs inside a Docker container on an internal-only network with no direct internet access. All outbound traffic on ports 80/443 is transparently redirected through an Envoy proxy via iptables DNAT rules. The container runs as a non-root user — `NET_ADMIN` is granted solely for iptables setup during entrypoint, then privileges are dropped via `gosu`. The agent cannot bypass the proxy, reach arbitrary hosts, or escalate privileges.

### Dynamic Domain Whitelisting

Envoy inspects every outbound connection — SNI for HTTPS, `Host` header for HTTP — and only forwards traffic to domains listed in `config/domains.txt`. Everything else hits a blackhole cluster or gets a 403. The whitelist is fully manageable at runtime:

```bash
./scripts/whitelist.sh add example.com *.example.com   # add domains
./scripts/whitelist.sh apply                            # regenerate config + restart Envoy
./scripts/claude-coop.sh --whitelist extra.com           # or pass temporary domains at launch
```

### Persistent Session and Memory per Workspace

Each workspace gets its own namespaced Docker volumes (keyed by directory path hash), so Claude Code's `~/.claude/` directory — including session history, project memory, and authentication tokens — survives across container restarts. Prometheus data is also retained per-workspace with 30-day TSDB retention. Launch the same project directory again and everything picks up where you left off.

### Observability

A Prometheus + Grafana stack runs alongside the Claude container. Prometheus scrapes three metric sources every 15 seconds, and a pre-provisioned Grafana dashboard (http://localhost:3000, no login required) gives you live visibility into token usage rates, session costs, context window pressure, code changes, and all Envoy traffic — including blocked connection attempts.

### Custom Metrics

Beyond Claude Code's native OpenTelemetry metrics, claude-coop instruments two additional metric sources via Claude Code's hooks and statusline systems:

- **Statusline metrics** — context window usage %, current/total tokens by type, session cost, lines added/removed
- **Hook metrics** — tool invocation counts by name, tool errors, context compaction events, subagent lifecycle, turns by stop reason

These are aggregated by a lightweight Node.js server on port 9465 and scraped by Prometheus alongside everything else.

## Quick Start

### Prerequisites

- Docker installed and running

### Launch

```bash
./scripts/claude-coop.sh # Or create a symlink for it
```

On first run, Claude Code will prompt you to authenticate interactively. Your auth token is stored in a persistent Docker volume (`/home/claude/.claude/`), so you only need to log in once per workspace.

This will:
1. Build the custom Docker images (first run only)
2. Generate the Envoy config from the domain whitelist
3. Create an isolated Docker network
4. Start Envoy, Prometheus, and Grafana
5. Launch an interactive Claude Code session with your current directory mounted

### Options

```bash
./scripts/claude-coop.sh --build                          # Force rebuild images
./scripts/claude-coop.sh --whitelist example.com,*.example.org  # Extra domains for this session
./scripts/claude-coop.sh /path/to/project                 # Mount a specific directory
./scripts/claude-coop.sh --grafana-port 8080 --prometheus-port 9999  # Custom ports
./scripts/claude-coop.sh --teams                          # Enable Agent Teams (experimental)
```

### Cleanup

Containers and the Docker network are removed automatically when you exit the Claude Code session (Ctrl+C or `/exit`).

Persistent volumes are preserved across sessions. To remove them:

```bash
docker volume rm claude-coop-<project-id>-prometheus-data
docker volume rm claude-coop-<project-id>-claude-config
```

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

## Components

| Component | Purpose | Image |
|-----------|---------|-------|
| **Claude Code** | Claude Code CLI in a confined container | Custom (Node 22 + `@anthropic-ai/claude-code`) |
| **Envoy Proxy** | Domain-whitelisting egress proxy | Custom (envoyproxy/envoy v1.31) |
| **Prometheus** | Metrics collection and storage | `prom/prometheus:latest` |
| **Grafana** | Metrics visualization dashboards | `grafana/grafana:latest` |

## Domain Whitelist

Allowed domains are defined in `config/domains.txt` — one domain per line, with `*.` prefix for wildcard subdomains.

**Default whitelist:**

| Domain | Purpose |
|--------|---------|
| `anthropic.com` / `*.anthropic.com` | Claude API, feature flags |
| `claude.com` / `*.claude.com` | Claude documentation |
| `sentry.io` / `*.sentry.io` | Error reporting |
| `registry.npmjs.org` / `*.npmjs.org` | npm registry |
| `npmjs.com` / `*.npmjs.com` | npm web / documentation |
| `github.com` / `*.github.com` | GitHub access |
| `*.githubusercontent.com` | GitHub raw content, releases, gists |
| `pypi.org` / `*.pypi.org` | Python packages |
| `envoyproxy.io` / `*.envoyproxy.io` | Envoy documentation |
| `*.golang.org` | Go documentation |
| `*.prometheus.io` | Prometheus documentation |

### Managing the Whitelist

```bash
./scripts/whitelist.sh list                      # List current domains
./scripts/whitelist.sh add example.com *.example.com  # Add domains
./scripts/whitelist.sh remove example.com        # Remove a domain
./scripts/whitelist.sh generate                  # Regenerate Envoy config
./scripts/whitelist.sh apply                     # Regenerate + restart Envoy (live update)
```

Or edit `config/domains.txt` directly and run `./scripts/whitelist.sh apply`.

## Metrics Reference

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

### Custom Statusline Metrics (port 9465)

Collected via Claude Code's statusline handler (`statusline.sh`):

| Metric | Description |
|--------|-------------|
| `claude_statusline_context_window_used_percent` | Context window usage % |
| `claude_statusline_current_input_tokens` | Current input tokens |
| `claude_statusline_total_cost_usd` | Total session cost |
| `claude_statusline_exceeds_200k_tokens` | Binary flag for high usage |

### Custom Hook Metrics (port 9465)

Collected via Claude Code hooks (`hooks-metrics.sh`):

| Metric | Description |
|--------|-------------|
| `claude_hook_tool_use_total{tool_name=...}` | Tool usage by name |
| `claude_hook_tool_errors_total{tool_name=...}` | Tool errors by name |
| `claude_hook_compaction_total` | Context compaction events |
| `claude_hook_subagent_starts_total` | Subagent launches |
| `claude_hook_subagent_stops_total` | Subagent completions |
| `claude_hook_turns_total{stop_reason=...}` | Turns by stop reason |

### Grafana Dashboard

Open http://localhost:3000 (anonymous access, no login needed).

The pre-provisioned **Claude Code Environment** dashboard shows:

- **Claude Code Usage** — Token usage rate (input/output/cache), cost (cumulative + rate by model), lines of code modified, sessions, commits, PRs, active time, code edit decisions
- **Envoy Traffic** — HTTPS connections (allowed/blocked), HTTP requests, bytes in/out
- **Envoy Upstream & Internals** — Connection pools, latency percentiles (p50/p99), memory, uptime

### Prometheus

Direct access at http://localhost:9090 for ad-hoc queries.

```promql
claude_code_cost_usage_usd_total                       # Total cost this session
rate(claude_code_token_usage_tokens_total[5m])         # Token consumption rate by type
claude_statusline_context_window_used_percent           # Context window usage
claude_hook_tool_use_total                              # Tool usage breakdown
increase(envoy_tcp_https_blocked_cx_total[5m])         # HTTPS connections blocked (5m)
```

### Envoy Admin

http://localhost:9901 provides direct access to Envoy's admin interface:
- `/stats` — All metrics
- `/clusters` — Upstream cluster status
- `/config_dump` — Running configuration

## How the Network Confinement Works

1. **Internal network:** The Docker network is created as a bridge with no default route to the internet. Only the Envoy container is dual-homed on both the internal and an external network.

2. **iptables DNAT:** Inside the Claude container, iptables rules transparently redirect all outgoing TCP on ports 80 and 443 to Envoy's listener ports (10000/10001). An egress firewall drops everything else except loopback, established connections, and internal-network traffic.

3. **SNI inspection:** For HTTPS, Envoy uses `tls_inspector` to read the SNI from the TLS ClientHello. Only whitelisted SNI names are forwarded; everything else hits a blackhole cluster.

4. **HTTP Lua filter:** For HTTP, a Lua filter checks the `Host` header against the whitelist and returns 403 for blocked domains.

## File Structure

```
claude-coop/
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
│   │   │   └── claude-coop.json     # Pre-built Grafana dashboard
│   │   └── provisioning/
│   │       ├── dashboards/
│   │       │   └── dashboards.yml
│   │       └── datasources/
│   │           └── prometheus.yml
│   └── prometheus/
│       └── prometheus.yml          # Scrape targets config
├── scripts/
│   ├── claude-coop.sh               # Main launcher script
│   └── whitelist.sh                # Domain whitelist management tool
└── README.md
```
