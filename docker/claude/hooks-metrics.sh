#!/usr/bin/env bash
# hooks-metrics.sh — Claude Code hook event handler
# Invoked by Claude Code hooks with event type as $1, JSON on stdin.
# Maintains counter state in a JSON file and writes Prometheus metrics.
set -euo pipefail

EVENT_TYPE="${1:-}"
STATE_FILE="/tmp/claude-hooks-state.json"
LOCK_FILE="/tmp/claude-hooks-state.lock"
METRICS_FILE="/tmp/claude-hooks-metrics.prom"
METRICS_TMP="${METRICS_FILE}.tmp"

if [ -z "$EVENT_TYPE" ]; then
    echo "Usage: hooks-metrics.sh <EventType>" >&2
    exit 1
fi

# Read JSON from stdin
INPUT=$(cat)

# ── Acquire exclusive lock for state read-modify-write ────
exec 9>"${LOCK_FILE}"
flock 9

# ── Load or initialize state ─────────────────────────────
if [ -f "${STATE_FILE}" ]; then
    STATE=$(cat "${STATE_FILE}")
else
    STATE='{
        "tool_use": {},
        "tool_errors": {},
        "compactions": 0,
        "subagent_starts": 0,
        "subagent_stops": 0,
        "turns": {}
    }'
fi

# ── Update state based on event type ─────────────────────
case "$EVENT_TYPE" in
    PostToolUse)
        TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
        STATE=$(echo "$STATE" | jq --arg t "$TOOL_NAME" '.tool_use[$t] = ((.tool_use[$t] // 0) + 1)')
        ;;
    PostToolUseFailure)
        TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
        STATE=$(echo "$STATE" | jq --arg t "$TOOL_NAME" '.tool_errors[$t] = ((.tool_errors[$t] // 0) + 1)')
        ;;
    PreCompact)
        STATE=$(echo "$STATE" | jq '.compactions += 1')
        ;;
    SubagentStart)
        STATE=$(echo "$STATE" | jq '.subagent_starts += 1')
        ;;
    SubagentStop)
        STATE=$(echo "$STATE" | jq '.subagent_stops += 1')
        ;;
    Stop)
        STOP_REASON=$(echo "$INPUT" | jq -r '.stop_reason // "unknown"')
        STATE=$(echo "$STATE" | jq --arg r "$STOP_REASON" '.turns[$r] = ((.turns[$r] // 0) + 1)')
        ;;
    *)
        # Unknown event type — ignore
        exec 9>&-
        exit 0
        ;;
esac

# ── Persist state ─────────────────────────────────────────
echo "$STATE" > "${STATE_FILE}"

# ── Generate Prometheus metrics ───────────────────────────
{
    echo "# HELP claude_hook_tool_use_total Total tool invocations by tool name."
    echo "# TYPE claude_hook_tool_use_total counter"
    echo "$STATE" | jq -r '.tool_use | to_entries[] | "claude_hook_tool_use_total{tool_name=\"\(.key)\"} \(.value)"'

    echo ""
    echo "# HELP claude_hook_tool_errors_total Total tool errors by tool name."
    echo "# TYPE claude_hook_tool_errors_total counter"
    echo "$STATE" | jq -r '.tool_errors | to_entries[] | "claude_hook_tool_errors_total{tool_name=\"\(.key)\"} \(.value)"'

    echo ""
    echo "# HELP claude_hook_compaction_total Total context compaction events."
    echo "# TYPE claude_hook_compaction_total counter"
    echo "$STATE" | jq -r '"claude_hook_compaction_total \(.compactions)"'

    echo ""
    echo "# HELP claude_hook_subagent_starts_total Total subagent start events."
    echo "# TYPE claude_hook_subagent_starts_total counter"
    echo "$STATE" | jq -r '"claude_hook_subagent_starts_total \(.subagent_starts)"'

    echo ""
    echo "# HELP claude_hook_subagent_stops_total Total subagent stop events."
    echo "# TYPE claude_hook_subagent_stops_total counter"
    echo "$STATE" | jq -r '"claude_hook_subagent_stops_total \(.subagent_stops)"'

    echo ""
    echo "# HELP claude_hook_turns_total Total turns completed by stop reason."
    echo "# TYPE claude_hook_turns_total counter"
    echo "$STATE" | jq -r '.turns | to_entries[] | "claude_hook_turns_total{stop_reason=\"\(.key)\"} \(.value)"'
} > "${METRICS_TMP}"

mv "${METRICS_TMP}" "${METRICS_FILE}"

# ── Release lock ──────────────────────────────────────────
exec 9>&-
