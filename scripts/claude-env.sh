#!/usr/bin/env bash
#
# claude-env — Launch Claude Code in a confined Docker environment
# with Envoy proxy whitelisting, Prometheus metrics, and Grafana dashboards.
#
# Usage:
#   ./claude-env.sh [--build] [--yolo] [--whitelist domain1,domain2,...]
#                   [--grafana-port PORT] [--cleanup]
#
set -euo pipefail

# ─── Configuration ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_DIR="${PROJECT_ROOT}/docker"

PREFIX="claude-env"

GRAFANA_PORT="${GRAFANA_PORT:-3000}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
ENVOY_ADMIN_PORT="${ENVOY_ADMIN_PORT:-9901}"

DOMAINS_FILE="${PROJECT_ROOT}/config/domains.txt"

# ─── Detect container runtime (podman or docker) ──────────────
if command -v podman &>/dev/null; then
    DOCKER=podman
elif command -v docker &>/dev/null; then
    DOCKER=docker
else
    err "Neither docker nor podman found in PATH."
    exit 1
fi
export DOCKER

MOUNT_DIR="${1:-$(pwd)}"
# If first arg is a flag, use current dir
if [[ "${MOUNT_DIR}" == --* ]]; then
    MOUNT_DIR="$(pwd)"
fi

BUILD=false
CLEANUP=false
YOLO=false
EXTRA_WHITELIST=""

# ─── Parse args ────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --build)
            BUILD=true
            shift
            ;;
        --cleanup)
            CLEANUP=true
            shift
            ;;
        --yolo)
            YOLO=true
            shift
            ;;
        --whitelist)
            EXTRA_WHITELIST="$2"
            shift 2
            ;;
        --grafana-port)
            GRAFANA_PORT="$2"
            shift 2
            ;;
        --prometheus-port)
            PROMETHEUS_PORT="$2"
            shift 2
            ;;
        *)
            MOUNT_DIR="$1"
            shift
            ;;
    esac
done

# ─── Project ID ───────────────────────────────────────────────
WORKSPACE_DIR="$(cd "${MOUNT_DIR}" && pwd -P)"
PROJECT_BASENAME="$(basename "${WORKSPACE_DIR}")"
PROJECT_HASH="$(echo -n "${WORKSPACE_DIR}" | sha256sum | cut -c1-8)"
PROJECT_ID="$(echo "${PROJECT_BASENAME}-${PROJECT_HASH}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')"

# ─── Namespaced resource names ────────────────────────────────
NETWORK_NAME="${PREFIX}-${PROJECT_ID}-net"
ENVOY_CONTAINER="${PREFIX}-${PROJECT_ID}-envoy"
PROMETHEUS_CONTAINER="${PREFIX}-${PROJECT_ID}-prometheus"
GRAFANA_CONTAINER="${PREFIX}-${PROJECT_ID}-grafana"
CLAUDE_CONTAINER="${PREFIX}-${PROJECT_ID}-claude"
PROMETHEUS_VOLUME="${PREFIX}-${PROJECT_ID}-prometheus-data"
CLAUDE_CONFIG_VOLUME="${PREFIX}-${PROJECT_ID}-claude-config"

export ENVOY_CONTAINER NETWORK_NAME

# ─── Terminal colours ──────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${BLUE}[claude-env]${NC} $*"; }
ok()    { echo -e "${GREEN}[claude-env]${NC} $*"; }
warn()  { echo -e "${YELLOW}[claude-env]${NC} $*"; }
err()   { echo -e "${RED}[claude-env]${NC} $*" >&2; }

# ─── Cleanup persistent volumes ─────────────────────────────────
if [[ "${CLEANUP}" == true ]]; then
    log "Cleaning up persistent volumes for project '${PROJECT_BASENAME}' (${PROJECT_ID})..."

    # Stop any running containers for this project first
    for ctn in "${CLAUDE_CONTAINER}" "${GRAFANA_CONTAINER}" "${PROMETHEUS_CONTAINER}" "${ENVOY_CONTAINER}"; do
        if ${DOCKER} inspect "${ctn}" &>/dev/null; then
            log "  Stopping ${ctn}..."
            ${DOCKER} rm -f "${ctn}" &>/dev/null || true
        fi
    done

    if ${DOCKER} network inspect "${NETWORK_NAME}" &>/dev/null; then
        log "  Removing network ${NETWORK_NAME}..."
        ${DOCKER} network rm "${NETWORK_NAME}" &>/dev/null || true
    fi

    removed=0
    for vol in "${PROMETHEUS_VOLUME}" "${CLAUDE_CONFIG_VOLUME}"; do
        if ${DOCKER} volume inspect "${vol}" &>/dev/null; then
            log "  Removing volume ${vol}..."
            ${DOCKER} volume rm "${vol}"
            removed=$((removed + 1))
        else
            warn "  Volume ${vol} does not exist, skipping."
        fi
    done

    if [[ ${removed} -gt 0 ]]; then
        ok "Removed ${removed} persistent volume(s) for project '${PROJECT_BASENAME}'."
    else
        warn "No persistent volumes found for project '${PROJECT_BASENAME}'."
    fi
    exit 0
fi

# ─── Cleanup on exit ──────────────────────────────────────────
cleanup() {
    echo ""
    log "Shutting down Claude Code environment..."

    for ctn in "${CLAUDE_CONTAINER}" "${GRAFANA_CONTAINER}" "${PROMETHEUS_CONTAINER}" "${ENVOY_CONTAINER}"; do
        if ${DOCKER} inspect "${ctn}" &>/dev/null; then
            log "  Stopping ${ctn}..."
            ${DOCKER} rm -f "${ctn}" &>/dev/null || true
        fi
    done

    if ${DOCKER} network inspect "${NETWORK_NAME}" &>/dev/null; then
        log "  Removing network ${NETWORK_NAME}..."
        ${DOCKER} network rm "${NETWORK_NAME}" &>/dev/null || true
    fi

    if [[ -n "${ENVOY_CONFIG_DIR:-}" && -d "${ENVOY_CONFIG_DIR}" ]]; then
        log "  Removing temp config dir: ${ENVOY_CONFIG_DIR}"
        rm -rf "${ENVOY_CONFIG_DIR}"
    fi

    ok "Cleanup complete. Persistent volumes retained for project '${PROJECT_BASENAME}'."
    echo -e "  Prometheus data: ${CYAN}${DOCKER} volume rm ${PROMETHEUS_VOLUME}${NC}"
    echo -e "  Claude auth:    ${CYAN}${DOCKER} volume rm ${CLAUDE_CONFIG_VOLUME}${NC}"
    echo -e "  List all:        ${CYAN}docker volume ls --filter name=claude-env${NC}"
}

trap cleanup EXIT INT TERM

# ─── Pre-flight checks ────────────────────────────────────────
if ! ${DOCKER} info &>/dev/null; then
    err "${DOCKER} daemon is not running."
    exit 1
fi

# ─── Build images ──────────────────────────────────────────────
build_images() {
    log "Building Envoy proxy image..."
    ${DOCKER} build -t "${PREFIX}-envoy-img" "${DOCKER_DIR}/envoy"

    log "Building Claude Code image..."
    ${DOCKER} build -t "${PREFIX}-claude-img" "${DOCKER_DIR}/claude"
}

if [[ "${BUILD}" == true ]]; then
    build_images
else
    # Build if images don't exist
    if ! ${DOCKER} image inspect "${PREFIX}-envoy-img" &>/dev/null || \
       ! ${DOCKER} image inspect "${PREFIX}-claude-img" &>/dev/null; then
        warn "Images not found. Building..."
        build_images
    fi
fi

# ─── Create network ───────────────────────────────────────────
if ${DOCKER} network inspect "${NETWORK_NAME}" &>/dev/null; then
    warn "Network ${NETWORK_NAME} already exists, removing..."
    # Remove any orphaned containers first
    for ctn in "${CLAUDE_CONTAINER}" "${GRAFANA_CONTAINER}" "${PROMETHEUS_CONTAINER}" "${ENVOY_CONTAINER}"; do
        ${DOCKER} rm -f "${ctn}" &>/dev/null || true
    done
    ${DOCKER} network rm "${NETWORK_NAME}" &>/dev/null || true
fi

log "Creating container network: ${NETWORK_NAME}"
${DOCKER} network create \
    --driver bridge \
    "${NETWORK_NAME}"

# ─── Create persistent volumes ───────────────────────────────
if ! ${DOCKER} volume inspect "${PROMETHEUS_VOLUME}" &>/dev/null; then
    log "Creating Prometheus data volume: ${PROMETHEUS_VOLUME}"
    ${DOCKER} volume create "${PROMETHEUS_VOLUME}"
else
    log "Using existing Prometheus data volume: ${PROMETHEUS_VOLUME}"
fi

if ! ${DOCKER} volume inspect "${CLAUDE_CONFIG_VOLUME}" &>/dev/null; then
    log "Creating Claude config volume: ${CLAUDE_CONFIG_VOLUME}"
    ${DOCKER} volume create "${CLAUDE_CONFIG_VOLUME}"
else
    log "Using existing Claude config volume: ${CLAUDE_CONFIG_VOLUME} (auth persisted)"
fi

# ─── Generate Envoy config ────────────────────────────────────
ENVOY_CONFIG_DIR="${PROJECT_ROOT}/.cache/envoy-config"
mkdir -p "${ENVOY_CONFIG_DIR}"

# If --whitelist was passed, temporarily append extra domains
if [[ -n "${EXTRA_WHITELIST}" ]]; then
    log "Adding extra whitelist domains: ${EXTRA_WHITELIST}"
    IFS=',' read -ra EXTRA_DOMAINS <<< "${EXTRA_WHITELIST}"
    for domain in "${EXTRA_DOMAINS[@]}"; do
        domain=$(echo "${domain}" | xargs)  # trim whitespace
        if ! grep -qxF "${domain}" "${DOMAINS_FILE}"; then
            echo "${domain}" >> "${DOMAINS_FILE}"
        fi
    done
fi

log "Generating Envoy config from template..."
"${SCRIPT_DIR}/whitelist.sh" generate --config-dir "${ENVOY_CONFIG_DIR}"

# ─── Start Envoy ──────────────────────────────────────────────
log "Starting Envoy proxy..."
${DOCKER} run -d \
    --name "${ENVOY_CONTAINER}" \
    --network "${NETWORK_NAME}" \
    --network-alias envoy \
    --restart unless-stopped \
    -v "${ENVOY_CONFIG_DIR}/envoy.yaml:/etc/envoy/envoy.yaml:ro" \
    -p "${ENVOY_ADMIN_PORT}:9901" \
    "${PREFIX}-envoy-img"

ok "Envoy proxy running (admin: http://localhost:${ENVOY_ADMIN_PORT})"

# ─── Start Prometheus ──────────────────────────────────────────
log "Starting Prometheus..."
${DOCKER} run -d \
    --name "${PROMETHEUS_CONTAINER}" \
    --network "${NETWORK_NAME}" \
    --network-alias prometheus \
    --restart unless-stopped \
    -v "${DOCKER_DIR}/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
    -v "${PROMETHEUS_VOLUME}:/prometheus" \
    -p "${PROMETHEUS_PORT}:9090" \
    prom/prometheus:latest \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/prometheus \
    --storage.tsdb.retention.time=30d \
    --web.enable-lifecycle

ok "Prometheus running (UI: http://localhost:${PROMETHEUS_PORT})"

# ─── Start Grafana ─────────────────────────────────────────────
log "Starting Grafana..."
${DOCKER} run -d \
    --name "${GRAFANA_CONTAINER}" \
    --network "${NETWORK_NAME}" \
    --network-alias grafana \
    --restart unless-stopped \
    -v "${DOCKER_DIR}/grafana/provisioning:/etc/grafana/provisioning:ro" \
    -v "${DOCKER_DIR}/grafana/dashboards:/var/lib/grafana/dashboards:ro" \
    -p "${GRAFANA_PORT}:3000" \
    -e GF_SECURITY_ADMIN_USER=admin \
    -e GF_SECURITY_ADMIN_PASSWORD=admin \
    -e GF_AUTH_ANONYMOUS_ENABLED=true \
    -e GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer \
    -e GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana/dashboards/claude-env.json \
    grafana/grafana:latest

ok "Grafana running (UI: http://localhost:${GRAFANA_PORT}, user: admin/admin)"

# ─── Wait for dependencies to be healthy ──────────────────────
log "Waiting for services to initialize..."
sleep 3

# ─── Open Grafana in browser ──────────────────────────────────
GRAFANA_URL="http://localhost:${GRAFANA_PORT}"
if command -v open &>/dev/null; then
    open "${GRAFANA_URL}" 2>/dev/null && ok "Opened Grafana in browser" || true
elif command -v xdg-open &>/dev/null; then
    xdg-open "${GRAFANA_URL}" 2>/dev/null && ok "Opened Grafana in browser" || true
fi

# ─── Start Claude Code (interactive) ──────────────────────────
echo ""
echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  Claude Code Docker Environment${NC}"
echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}Project:${NC}     ${PROJECT_BASENAME} (${PROJECT_ID})"
echo -e "  ${GREEN}Workspace:${NC}   ${MOUNT_DIR}"
echo -e "  ${GREEN}Grafana:${NC}     http://localhost:${GRAFANA_PORT}"
echo -e "  ${GREEN}Prometheus:${NC}  http://localhost:${PROMETHEUS_PORT}"
echo -e "  ${GREEN}Envoy Admin:${NC} http://localhost:${ENVOY_ADMIN_PORT}"
if [[ "${YOLO}" == true ]]; then
echo -e "  ${GREEN}YOLO mode:${NC}   ${RED}ENABLED${NC} (no permission prompts)"
fi
echo -e ""
echo -e "  All outgoing traffic is filtered through the Envoy proxy."
echo -e "  Only whitelisted domains are allowed."
echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""

log "Starting Claude Code container (interactive)..."
log "Mounting workspace: ${MOUNT_DIR} → /workspace"
echo ""

# The Claude container is on the internal-only network.
# It has NET_ADMIN for iptables rules that redirect traffic to Envoy.
# It cannot directly reach the internet — only the Envoy proxy can.
${DOCKER} run -it --rm \
    --name "${CLAUDE_CONTAINER}" \
    --network "${NETWORK_NAME}" \
    --network-alias claude \
    --cap-add NET_ADMIN \
    --hostname claude-code \
    -v "${MOUNT_DIR}:/workspace" \
    -v "${CLAUDE_CONFIG_VOLUME}:/home/claude" \
    -e ENVOY_IP="${ENVOY_CONTAINER}" \
    -e ENVOY_HTTP_PORT=10000 \
    -e ENVOY_HTTPS_PORT=10001 \
    -e TERM="${TERM:-xterm-256color}" \
    -e CLAUDE_CODE_ENABLE_TELEMETRY=1 \
    -e OTEL_METRICS_EXPORTER=prometheus \
    -e CLAUDE_YOLO="${YOLO}" \
    -e WORKSPACE_NAME="${PROJECT_BASENAME}" \
    -p 9464:9464 \
    -p 9465:9465 \
    "${PREFIX}-claude-img"
