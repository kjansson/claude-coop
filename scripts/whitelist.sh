#!/usr/bin/env bash
#
# whitelist.sh — Manage the Envoy domain whitelist
#
# Usage:
#   whitelist.sh list                         Show current whitelisted domains
#   whitelist.sh add <domain> [domain...]     Add domain(s) to the whitelist
#   whitelist.sh remove <domain>              Remove a domain from the whitelist
#   whitelist.sh generate [--config-dir DIR]  Regenerate envoy.yaml from template
#   whitelist.sh apply                        Generate config + restart Envoy
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DOMAINS_FILE="${PROJECT_ROOT}/config/domains.txt"
TEMPLATE_FILE="${PROJECT_ROOT}/docker/envoy/envoy.yaml.tpl"

PREFIX="claude-env"
ENVOY_CONTAINER="${ENVOY_CONTAINER:-${PREFIX}-envoy}"
ENVOY_CONFIG_DIR="${ENVOY_CONFIG_DIR:-${PROJECT_ROOT}/.cache/envoy-config}"
ENVOY_IMAGE="${PREFIX}-envoy-img"
NETWORK_NAME="${NETWORK_NAME:-${PREFIX}-net}"

# ─── Detect container runtime (podman or docker) ──────────────
if [[ -n "${DOCKER:-}" ]]; then
    : # inherited from parent (claude-env.sh)
elif command -v docker &>/dev/null; then
    DOCKER=docker
elif command -v podman &>/dev/null; then
    DOCKER=podman
else
    err "Neither docker nor podman found in PATH."
    exit 1
fi

# ─── Terminal colours ────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${BLUE}[whitelist]${NC} $*"; }
ok()   { echo -e "${GREEN}[whitelist]${NC} $*"; }
warn() { echo -e "${YELLOW}[whitelist]${NC} $*"; }
err()  { echo -e "${RED}[whitelist]${NC} $*" >&2; }

# ─── Helpers ────────────────────────────────────────────────

# Read domains.txt, stripping comments and blank lines.
# Output: one domain per line, trimmed.
read_domains() {
    if [[ ! -f "${DOMAINS_FILE}" ]]; then
        err "Domain file not found: ${DOMAINS_FILE}"
        exit 1
    fi
    sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' "${DOMAINS_FILE}" | grep -v '^$'
}

# ─── Commands ───────────────────────────────────────────────

cmd_list() {
    echo -e "${BOLD}Whitelisted domains${NC} (${DOMAINS_FILE}):"
    echo ""
    local exact=() wildcards=()
    while IFS= read -r domain; do
        if [[ "${domain}" == \*.* ]]; then
            wildcards+=("${domain}")
        else
            exact+=("${domain}")
        fi
    done < <(read_domains)

    if [[ ${#exact[@]} -gt 0 ]]; then
        echo -e "  ${BOLD}Exact:${NC}"
        for d in "${exact[@]}"; do
            echo "    ${d}"
        done
    fi
    if [[ ${#wildcards[@]} -gt 0 ]]; then
        echo -e "  ${BOLD}Wildcard:${NC}"
        for d in "${wildcards[@]}"; do
            echo "    ${d}"
        done
    fi
    echo ""
    echo "  Total: $(( ${#exact[@]} + ${#wildcards[@]} )) domains"
}

cmd_add() {
    if [[ $# -eq 0 ]]; then
        err "Usage: whitelist.sh add <domain> [domain...]"
        exit 1
    fi

    local added=0
    for domain in "$@"; do
        # Check if already present
        if read_domains | grep -qxF "${domain}"; then
            warn "Already whitelisted: ${domain}"
        else
            echo "${domain}" >> "${DOMAINS_FILE}"
            ok "Added: ${domain}"
            added=$((added + 1))
        fi
    done

    if [[ ${added} -gt 0 ]]; then
        log "Run '${BASH_SOURCE[0]} apply' to update the running Envoy proxy."
    fi
}

cmd_remove() {
    if [[ $# -eq 0 ]]; then
        err "Usage: whitelist.sh remove <domain>"
        exit 1
    fi
    local domain="$1"

    if ! read_domains | grep -qxF "${domain}"; then
        err "Domain not found in whitelist: ${domain}"
        exit 1
    fi

    # Remove exact line (preserve comments and other domains)
    local tmp
    tmp=$(mktemp)
    grep -vxF "${domain}" "${DOMAINS_FILE}" > "${tmp}"
    mv "${tmp}" "${DOMAINS_FILE}"

    ok "Removed: ${domain}"
    log "Run '${BASH_SOURCE[0]} apply' to update the running Envoy proxy."
}

cmd_generate() {
    local config_dir=""

    # Parse subcommand flags
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config-dir)
                config_dir="$2"
                shift 2
                ;;
            *)
                err "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    if [[ -z "${config_dir}" ]]; then
        config_dir="${PROJECT_ROOT}/docker/envoy"
    fi

    if [[ ! -f "${TEMPLATE_FILE}" ]]; then
        err "Template not found: ${TEMPLATE_FILE}"
        exit 1
    fi

    # ── Parse domains ──────────────────────────────────────
    local exact_domains=() wildcard_domains=()
    while IFS= read -r domain; do
        if [[ "${domain}" == \*.* ]]; then
            wildcard_domains+=("${domain}")
        else
            exact_domains+=("${domain}")
        fi
    done < <(read_domains)

    # ── Build LUA_ALLOWED_DOMAINS ──────────────────────────
    # Exact domains get a direct entry.
    # Wildcards like *.example.com also add the bare "example.com".
    local lua_allowed=""
    for d in "${exact_domains[@]}"; do
        lua_allowed+="                            [\"${d}\"] = true,\n"
    done
    for d in "${wildcard_domains[@]}"; do
        local bare="${d#\*.}"
        # Only add bare domain if not already in exact list
        local already=false
        for e in "${exact_domains[@]}"; do
            if [[ "${e}" == "${bare}" ]]; then
                already=true
                break
            fi
        done
        if [[ "${already}" == false ]]; then
            lua_allowed+="                            [\"${bare}\"] = true,\n"
        fi
    done
    # Remove trailing newline
    lua_allowed="${lua_allowed%\\n}"

    # ── Build LUA_WILDCARD_SUFFIXES ────────────────────────
    local lua_wildcards=""
    for d in "${wildcard_domains[@]}"; do
        local suffix="${d#\*}"   # *.example.com → .example.com
        lua_wildcards+="                            \"${suffix}\",\n"
    done
    lua_wildcards="${lua_wildcards%\\n}"

    # ── Build SNI_SERVER_NAMES ────────────────────────────
    # Include exact domains, wildcard domains, and bare domains
    # for wildcard entries (*.example.com also needs example.com
    # since SNI wildcard matching doesn't cover the bare domain).
    local sni_names=""
    for d in "${exact_domains[@]}"; do
        sni_names+="              - \"${d}\"\n"
    done
    for d in "${wildcard_domains[@]}"; do
        sni_names+="              - \"${d}\"\n"
        local bare="${d#\*.}"
        # Add the bare domain if not already in exact list
        local already=false
        for e in "${exact_domains[@]}"; do
            if [[ "${e}" == "${bare}" ]]; then
                already=true
                break
            fi
        done
        if [[ "${already}" == false ]]; then
            sni_names+="              - \"${bare}\"\n"
        fi
    done
    sni_names="${sni_names%\\n}"

    # ── Substitute into template ──────────────────────────
    local output="${config_dir}/envoy.yaml"
    mkdir -p "${config_dir}"

    # Use awk for reliable multi-line substitution
    awk \
        -v lua_allowed="${lua_allowed}" \
        -v lua_wildcards="${lua_wildcards}" \
        -v sni_names="${sni_names}" \
    '{
        if ($0 ~ /\{\{LUA_ALLOWED_DOMAINS\}\}/) {
            printf "%s\n", lua_allowed
        } else if ($0 ~ /\{\{LUA_WILDCARD_SUFFIXES\}\}/) {
            printf "%s\n", lua_wildcards
        } else if ($0 ~ /\{\{SNI_SERVER_NAMES\}\}/) {
            printf "%s\n", sni_names
        } else {
            print
        }
    }' "${TEMPLATE_FILE}" > "${output}"

    ok "Generated: ${output}"
    log "Domains: ${#exact_domains[@]} exact, ${#wildcard_domains[@]} wildcard"
}

cmd_apply() {
    log "Generating Envoy config..."
    cmd_generate --config-dir "${ENVOY_CONFIG_DIR}"

    if ! ${DOCKER} inspect "${ENVOY_CONTAINER}" &>/dev/null; then
        warn "Envoy container '${ENVOY_CONTAINER}' is not running. Config generated but not applied."
        log "Start the environment with: scripts/claude-env.sh"
        return 0
    fi

    # Discover the host-mapped admin port before removing the container
    local admin_port
    admin_port=$(${DOCKER} port "${ENVOY_CONTAINER}" 9901/tcp 2>/dev/null | tail -1 | cut -d: -f2)
    if [[ -z "${admin_port}" ]]; then
        admin_port="9901"
    fi

    # Recreate the container (restart alone doesn't update bind mounts)
    log "Recreating Envoy container..."
    ${DOCKER} rm -f "${ENVOY_CONTAINER}" &>/dev/null || true

    ${DOCKER} run -d \
        --name "${ENVOY_CONTAINER}" \
        --network "${NETWORK_NAME}" \
        --network-alias envoy \
        --restart unless-stopped \
        -v "${ENVOY_CONFIG_DIR}/envoy.yaml:/etc/envoy/envoy.yaml:ro" \
        -p "${admin_port}:9901" \
        "${ENVOY_IMAGE}"

    # Wait for Envoy to be ready (check from host via mapped admin port)
    log "Waiting for Envoy to be ready (admin port ${admin_port})..."
    local retries=10
    while [[ ${retries} -gt 0 ]]; do
        if curl -sf "http://localhost:${admin_port}/ready" &>/dev/null; then
            ok "Envoy restarted and ready."
            return 0
        fi
        retries=$((retries - 1))
        sleep 1
    done
    warn "Envoy may not be fully ready yet (timed out waiting for admin API)."
}

# ─── Main ─────────────────────────────────────────────────

usage() {
    echo -e "${BOLD}Usage:${NC}"
    echo "  whitelist.sh list                         Show current whitelisted domains"
    echo "  whitelist.sh add <domain> [domain...]     Add domain(s) to the whitelist"
    echo "  whitelist.sh remove <domain>              Remove a domain from the whitelist"
    echo "  whitelist.sh generate [--config-dir DIR]  Regenerate envoy.yaml from template"
    echo "  whitelist.sh apply                        Generate config + restart Envoy"
}

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

command="$1"
shift

case "${command}" in
    list)     cmd_list "$@" ;;
    add)      cmd_add "$@" ;;
    remove)   cmd_remove "$@" ;;
    generate) cmd_generate "$@" ;;
    apply)    cmd_apply "$@" ;;
    -h|--help|help)
        usage
        ;;
    *)
        err "Unknown command: ${command}"
        usage
        exit 1
        ;;
esac
