#!/usr/bin/env bash
# statusline.sh — Claude Code status line handler
# Receives session JSON on stdin, writes Prometheus metrics, displays context bar.
set -euo pipefail

METRICS_FILE="/tmp/claude-statusline-metrics.prom"
METRICS_TMP="${METRICS_FILE}.tmp"

# Read the full JSON from stdin
INPUT=$(cat)

# Debug: dump raw JSON for field discovery
echo "$INPUT" > /tmp/claude-statusline-debug.json

# ── Extract fields with jq ─────────────────────────────────
CTX_USED_PCT=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0')
CTX_WINDOW_SIZE=$(echo "$INPUT" | jq -r '.context_window.context_window_size // 0')
INPUT_TOKENS=$(echo "$INPUT" | jq -r '.context_window.current_usage.input_tokens // 0')
OUTPUT_TOKENS=$(echo "$INPUT" | jq -r '.context_window.current_usage.output_tokens // 0')
CACHE_CREATE=$(echo "$INPUT" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
CACHE_READ=$(echo "$INPUT" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
TOTAL_INPUT=$(echo "$INPUT" | jq -r '.context_window.total_input_tokens // 0')
TOTAL_OUTPUT=$(echo "$INPUT" | jq -r '.context_window.total_output_tokens // 0')

TOTAL_COST=$(echo "$INPUT" | jq -r '.cost.total_cost_usd // 0')
TOTAL_DURATION_MS=$(echo "$INPUT" | jq -r '.cost.total_duration_ms // 0')
TOTAL_API_DURATION_MS=$(echo "$INPUT" | jq -r '.cost.total_api_duration_ms // 0')
LINES_ADDED=$(echo "$INPUT" | jq -r '.cost.total_lines_added // 0')
LINES_REMOVED=$(echo "$INPUT" | jq -r '.cost.total_lines_removed // 0')

EXCEEDS_200K=$(echo "$INPUT" | jq -r '.exceeds_200k_tokens // false')
if [ "$EXCEEDS_200K" = "true" ]; then EXCEEDS_200K_INT=1; else EXCEEDS_200K_INT=0; fi

MODEL_ID=$(echo "$INPUT" | jq -r '.model.id // "unknown"')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

# ── Write Prometheus metrics file (atomic via rename) ──────
cat > "${METRICS_TMP}" <<PROM
# HELP claude_statusline_context_window_used_percent Context window usage as a percentage (0-100).
# TYPE claude_statusline_context_window_used_percent gauge
claude_statusline_context_window_used_percent{session_id="${SESSION_ID}",model="${MODEL_ID}"} ${CTX_USED_PCT}

# HELP claude_statusline_context_window_size_tokens Total context window size in tokens.
# TYPE claude_statusline_context_window_size_tokens gauge
claude_statusline_context_window_size_tokens{session_id="${SESSION_ID}",model="${MODEL_ID}"} ${CTX_WINDOW_SIZE}

# HELP claude_statusline_current_input_tokens Current input tokens in the context window.
# TYPE claude_statusline_current_input_tokens gauge
claude_statusline_current_input_tokens{session_id="${SESSION_ID}",model="${MODEL_ID}"} ${INPUT_TOKENS}

# HELP claude_statusline_current_output_tokens Current output tokens in the context window.
# TYPE claude_statusline_current_output_tokens gauge
claude_statusline_current_output_tokens{session_id="${SESSION_ID}",model="${MODEL_ID}"} ${OUTPUT_TOKENS}

# HELP claude_statusline_current_cache_creation_tokens Current cache creation input tokens.
# TYPE claude_statusline_current_cache_creation_tokens gauge
claude_statusline_current_cache_creation_tokens{session_id="${SESSION_ID}",model="${MODEL_ID}"} ${CACHE_CREATE}

# HELP claude_statusline_current_cache_read_tokens Current cache read input tokens.
# TYPE claude_statusline_current_cache_read_tokens gauge
claude_statusline_current_cache_read_tokens{session_id="${SESSION_ID}",model="${MODEL_ID}"} ${CACHE_READ}

# HELP claude_statusline_total_input_tokens Cumulative input tokens across the session.
# TYPE claude_statusline_total_input_tokens gauge
claude_statusline_total_input_tokens{session_id="${SESSION_ID}",model="${MODEL_ID}"} ${TOTAL_INPUT}

# HELP claude_statusline_total_output_tokens Cumulative output tokens across the session.
# TYPE claude_statusline_total_output_tokens gauge
claude_statusline_total_output_tokens{session_id="${SESSION_ID}",model="${MODEL_ID}"} ${TOTAL_OUTPUT}

# HELP claude_statusline_cost_usd Cumulative session cost in USD.
# TYPE claude_statusline_cost_usd gauge
claude_statusline_cost_usd{session_id="${SESSION_ID}",model="${MODEL_ID}"} ${TOTAL_COST}

# HELP claude_statusline_duration_ms Total session duration in milliseconds.
# TYPE claude_statusline_duration_ms gauge
claude_statusline_duration_ms{session_id="${SESSION_ID}",model="${MODEL_ID}"} ${TOTAL_DURATION_MS}

# HELP claude_statusline_api_duration_ms Total API call duration in milliseconds.
# TYPE claude_statusline_api_duration_ms gauge
claude_statusline_api_duration_ms{session_id="${SESSION_ID}",model="${MODEL_ID}"} ${TOTAL_API_DURATION_MS}

# HELP claude_statusline_lines_added Cumulative lines of code added in the session.
# TYPE claude_statusline_lines_added gauge
claude_statusline_lines_added{session_id="${SESSION_ID}",model="${MODEL_ID}"} ${LINES_ADDED}

# HELP claude_statusline_lines_removed Cumulative lines of code removed in the session.
# TYPE claude_statusline_lines_removed gauge
claude_statusline_lines_removed{session_id="${SESSION_ID}",model="${MODEL_ID}"} ${LINES_REMOVED}

# HELP claude_statusline_exceeds_200k_tokens Whether the session has exceeded 200k token context (0 or 1).
# TYPE claude_statusline_exceeds_200k_tokens gauge
claude_statusline_exceeds_200k_tokens{session_id="${SESSION_ID}",model="${MODEL_ID}"} ${EXCEEDS_200K_INT}
PROM

mv "${METRICS_TMP}" "${METRICS_FILE}"
