#!/usr/bin/env bash
#
# lib.sh — Shared utilities for claude-coop scripts
#
# Source this file from other scripts:
#   LOG_PREFIX="my-script"
#   source "${SCRIPT_DIR}/lib.sh"
#

# ─── Terminal colours ──────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Logging ──────────────────────────────────────────────────
LOG_PREFIX="${LOG_PREFIX:-claude-coop}"

_log() { local color="$1"; shift; echo -e "${color}[${LOG_PREFIX}]${NC} $*"; }
log()  { _log "${BLUE}" "$@"; }
ok()   { _log "${GREEN}" "$@"; }
warn() { _log "${YELLOW}" "$@"; }
err()  { _log "${RED}" "$@" >&2; }

# ─── Detect container runtime (podman or docker) ──────────────
if [[ -z "${DOCKER:-}" ]]; then
    if command -v podman &>/dev/null; then
        DOCKER=podman
    elif command -v docker &>/dev/null; then
        DOCKER=docker
    else
        err "Neither docker nor podman found in PATH."
        exit 1
    fi
fi
export DOCKER
