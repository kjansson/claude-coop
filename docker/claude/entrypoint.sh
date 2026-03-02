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

# ── NAT rules: transparently redirect HTTP/HTTPS to Envoy ─────
iptables -t nat -A OUTPUT -p tcp --dport 80 -j DNAT --to-destination "${RESOLVED_ENVOY_IP}:${ENVOY_HTTP_PORT}"
iptables -t nat -A OUTPUT -p tcp --dport 443 -j DNAT --to-destination "${RESOLVED_ENVOY_IP}:${ENVOY_HTTPS_PORT}"
iptables -t nat -A POSTROUTING -j MASQUERADE

# ── Filter rules: lock down egress to only Envoy + DNS ────────
# Allow loopback (includes Docker embedded DNS at 127.0.0.11)
iptables -A OUTPUT -o lo -j ACCEPT
# Allow already-established connections (return traffic)
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
# Allow all traffic to the Envoy proxy (covers DNAT'd packets)
iptables -A OUTPUT -d "${RESOLVED_ENVOY_IP}" -j ACCEPT
# Drop everything else — no direct internet access
iptables -A OUTPUT -j DROP

echo "iptables rules applied:"
echo "  - HTTP  :80  → ${RESOLVED_ENVOY_IP}:${ENVOY_HTTP_PORT}"
echo "  - HTTPS :443 → ${RESOLVED_ENVOY_IP}:${ENVOY_HTTPS_PORT}"
echo "  - All other egress: BLOCKED"

# Drop to the claude user and start Claude Code
# Native OTel Prometheus exporter is configured via environment variables
# passed in by the launcher script (CLAUDE_CODE_ENABLE_TELEMETRY, etc.)
echo ""
echo "Starting Claude Code (OTel metrics on :9464)..."
echo "============================================"
echo ""

exec su - claude -c "cd /workspace && claude"
