#!/bin/bash
set -e

ENVOY_IP="${ENVOY_IP:-envoy}"
ENVOY_HTTP_PORT="${ENVOY_HTTP_PORT:-10000}"
ENVOY_HTTPS_PORT="${ENVOY_HTTPS_PORT:-10001}"

echo "============================================"
echo "  Claude Code Docker Environment"
echo "============================================"
echo "  Envoy proxy: ${ENVOY_IP}"
echo "  HTTP port:   ${ENVOY_HTTP_PORT}"
echo "  HTTPS port:  ${ENVOY_HTTPS_PORT}"
echo "============================================"

# Set up iptables to transparently redirect all outgoing traffic through Envoy.
# This requires NET_ADMIN capability on the container.
# We redirect TCP traffic on port 80 and 443 to the Envoy proxy.
echo "Setting up transparent proxy routing via iptables..."

# Resolve Envoy IP if given as hostname
RESOLVED_ENVOY_IP=$(getent hosts "${ENVOY_IP}" | awk '{print $1}' | head -1)
if [ -z "${RESOLVED_ENVOY_IP}" ]; then
    echo "WARNING: Could not resolve Envoy IP from '${ENVOY_IP}', using as-is"
    RESOLVED_ENVOY_IP="${ENVOY_IP}"
fi
echo "Resolved Envoy IP: ${RESOLVED_ENVOY_IP}"

# Ensure the claude user owns their home directory
# (first run on a fresh volume needs this)
chown claude:claude /home/claude

# ── Configure Claude Code status line for metrics ────────
CLAUDE_SETTINGS="/home/claude/.claude/settings.json"
mkdir -p /home/claude/.claude

# Build the settings patch with statusLine and hooks
SETTINGS_PATCH=$(cat <<'JSONPATCH'
{
  "statusLine": { "type": "command", "command": "/usr/local/lib/statusline.sh" },
  "hooks": {
    "PostToolUse": [{ "hooks": [{ "type": "command", "command": "/usr/local/lib/hooks-metrics.sh PostToolUse" }] }],
    "PostToolUseFailure": [{ "hooks": [{ "type": "command", "command": "/usr/local/lib/hooks-metrics.sh PostToolUseFailure" }] }],
    "PreCompact": [{ "hooks": [{ "type": "command", "command": "/usr/local/lib/hooks-metrics.sh PreCompact" }] }],
    "SubagentStart": [{ "hooks": [{ "type": "command", "command": "/usr/local/lib/hooks-metrics.sh SubagentStart" }] }],
    "SubagentStop": [{ "hooks": [{ "type": "command", "command": "/usr/local/lib/hooks-metrics.sh SubagentStop" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "/usr/local/lib/hooks-metrics.sh Stop" }] }]
  }
}
JSONPATCH
)

if [ -f "${CLAUDE_SETTINGS}" ]; then
    UPDATED=$(jq --argjson patch "$SETTINGS_PATCH" '. + $patch' "${CLAUDE_SETTINGS}")
    echo "${UPDATED}" > "${CLAUDE_SETTINGS}"
else
    echo "${SETTINGS_PATCH}" > "${CLAUDE_SETTINGS}"
fi
chown -R claude:claude /home/claude/.claude
echo "Configured status line -> /usr/local/lib/statusline.sh"
echo "Configured hooks -> /usr/local/lib/hooks-metrics.sh"

# ── NAT rules: transparently redirect HTTP/HTTPS to Envoy ─────
iptables -t nat -A OUTPUT -p tcp --dport 80 -j DNAT --to-destination "${RESOLVED_ENVOY_IP}:${ENVOY_HTTP_PORT}"
iptables -t nat -A OUTPUT -p tcp --dport 443 -j DNAT --to-destination "${RESOLVED_ENVOY_IP}:${ENVOY_HTTPS_PORT}"
iptables -t nat -A POSTROUTING -j MASQUERADE

# ── Detect Docker network subnet for inter-container traffic ──
DOCKER_SUBNET=$(ip route | grep -v default | grep 'src' | head -1 | awk '{print $1}')
echo "Docker network subnet: ${DOCKER_SUBNET}"

# ── Filter rules: lock down egress ────────────────────────────
# Allow loopback (includes Docker embedded DNS at 127.0.0.11)
iptables -A OUTPUT -o lo -j ACCEPT
# Allow already-established connections (return traffic)
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
# Allow all traffic within the Docker network (Envoy, Prometheus, etc.)
if [ -n "${DOCKER_SUBNET}" ]; then
    iptables -A OUTPUT -d "${DOCKER_SUBNET}" -j ACCEPT
else
    # Fallback: allow only Envoy
    iptables -A OUTPUT -d "${RESOLVED_ENVOY_IP}" -j ACCEPT
fi
# Drop everything else — no direct internet access
iptables -A OUTPUT -j DROP

echo "iptables rules applied:"
echo "  - HTTP  :80  → ${RESOLVED_ENVOY_IP}:${ENVOY_HTTP_PORT}"
echo "  - HTTPS :443 → ${RESOLVED_ENVOY_IP}:${ENVOY_HTTPS_PORT}"
echo "  - Docker subnet ${DOCKER_SUBNET}: ALLOWED"
echo "  - All other egress: BLOCKED"

# Drop to the claude user and start Claude Code
# gosu preserves the full environment (unlike su which can strip vars via PAM)
export HOME=/home/claude
export USER=claude

echo ""
echo "Testing connectivity to Prometheus OTLP receiver..."
if curl -sf -o /dev/null --max-time 5 "http://prometheus:9090/-/healthy" 2>/dev/null; then
    echo "  ✓ Prometheus is healthy (OTLP endpoint: http://prometheus:9090/api/v1/otlp)"
else
    echo "  ✗ WARNING: Cannot reach Prometheus"
fi

echo ""
echo "OTel environment:"
env | grep -E '^(OTEL_|CLAUDE_CODE_ENABLE)' | sort
echo ""
echo "Starting Claude Code (OTel metrics → Prometheus OTLP receiver)..."
echo "============================================"
echo ""

# ── Write static environment info metrics ─────────────────
YOLO_INT=0
if [ "${CLAUDE_YOLO:-false}" = "true" ]; then YOLO_INT=1; fi
cat > /tmp/claude-env-info.prom <<PROM
# HELP claude_env_info Environment info for this Claude Code session.
# TYPE claude_env_info gauge
claude_env_info{workspace="${WORKSPACE_NAME:-unknown}",yolo_mode="${CLAUDE_YOLO:-false}"} 1

# HELP claude_env_yolo_mode Whether YOLO mode (--dangerously-skip-permissions) is enabled (1) or not (0).
# TYPE claude_env_yolo_mode gauge
claude_env_yolo_mode ${YOLO_INT}
PROM
echo "Environment info metrics written (workspace=${WORKSPACE_NAME:-unknown}, yolo=${CLAUDE_YOLO:-false})"

# ── Start the status-line metrics HTTP server (port 9465) ─
echo "Starting status-line metrics server on :9465..."
gosu claude node /usr/local/lib/metrics-server.mjs &
echo "  Metrics server PID: $!"

CLAUDE_ARGS=""
if [ "${CLAUDE_YOLO:-false}" = "true" ]; then
    echo "⚡ YOLO mode enabled — Claude Code will run with --dangerously-skip-permissions"
    echo ""
    CLAUDE_ARGS="--dangerously-skip-permissions"
fi

exec gosu claude bash -c "cd /workspace && exec claude ${CLAUDE_ARGS}"
