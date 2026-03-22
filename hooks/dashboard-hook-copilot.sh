#!/bin/bash
# AI Agent Session Center - GitHub Copilot CLI hook relay (macOS / Linux)
# Receives Copilot event name as $1, reads hook JSON from stdin.
# Maps Copilot events to dashboard-compatible format, enriches with env info,
# and delivers to the dashboard server via file-based MQ or HTTP.
#
# Key difference from Claude hook:
# - Copilot hooks are SYNCHRONOUS — the script must complete quickly
# - Event name comes as $1 argument (registered per-event in hooks.json)
# - Session ID extracted from JSON payload or generated from PID
# - CWD from JSON payload or pwd

COPILOT_EVENT="${1:-unknown}"
SENT_AT=$(date +%s)
INPUT=$(cat)

# --- Everything below runs in background so the hook returns instantly ---
{

# ── Map Copilot events to dashboard-compatible event names ──
case "$COPILOT_EVENT" in
  sessionStart)          MAPPED_EVENT="SessionStart" ;;
  sessionEnd)            MAPPED_EVENT="SessionEnd" ;;
  userPromptSubmitted)   MAPPED_EVENT="UserPromptSubmit" ;;
  preToolUse)            MAPPED_EVENT="PreToolUse" ;;
  postToolUse)           MAPPED_EVENT="PostToolUse" ;;
  errorOccurred)         MAPPED_EVENT="PostToolUseFailure" ;;
  *)                     MAPPED_EVENT="$COPILOT_EVENT" ;;
esac

# ── Session/CWD from payload or environment ──
SESSION_ID=$(echo "$INPUT" | jq -r '.sessionId // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && SESSION_ID="copilot-${PPID}"
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD="$(pwd)"

# ── TTY detection (cached per PID) ──
HOOK_TTY=""
if [ -n "$PPID" ] && [ "$PPID" != "0" ]; then
  TTY_CACHE="/tmp/copilot-tty-cache"
  TTY_CACHE_FILE="$TTY_CACHE/$PPID"
  if [ -f "$TTY_CACHE_FILE" ]; then
    HOOK_TTY=$(cat "$TTY_CACHE_FILE" 2>/dev/null)
  else
    RAW_TTY=$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d ' ')
    if [ -n "$RAW_TTY" ] && [ "$RAW_TTY" != "??" ] && [ "$RAW_TTY" != "?" ]; then
      HOOK_TTY="/dev/${RAW_TTY}"
      mkdir -p "$TTY_CACHE" 2>/dev/null
      echo "$HOOK_TTY" > "$TTY_CACHE_FILE" 2>/dev/null
    fi
  fi
fi

# ── Startup command capture (sessionStart only) ──
STARTUP_CMD=""
if [ "$COPILOT_EVENT" = "sessionStart" ] && [ -n "$PPID" ] && [ "$PPID" != "0" ]; then
  STARTUP_CMD=$(ps -p "$PPID" -o args= 2>/dev/null | head -1 | sed 's/^[[:space:]]*//')
fi

# ── Single jq pass: build enriched JSON ──
ENRICHED=$(echo "$INPUT" | jq -c \
  --arg event "$MAPPED_EVENT" \
  --arg session_id "$SESSION_ID" \
  --arg cwd "$CWD" \
  --arg pid "$PPID" \
  --arg tty "$HOOK_TTY" \
  --arg sent_at "$SENT_AT" \
  --arg agent_terminal_id "${AGENT_MANAGER_TERMINAL_ID:-}" \
  --arg copilot_event "$COPILOT_EVENT" \
  --arg startup_cmd "$STARTUP_CMD" \
  '
  {
    hook_event_name: $event,
    session_id: (if $session_id != "" then $session_id else null end),
    cwd: (if $cwd != "" then $cwd else null end),
    claude_pid: ($pid | tonumber),
    hook_sent_at: (($sent_at | tonumber) * 1000),
    tty_path: (if $tty != "" then $tty else null end),
    agent_terminal_id: (if $agent_terminal_id != "" then $agent_terminal_id else null end),
    tool_name: (.tool // .toolName // null),
    tool_input: (.args // .toolArgs // null),
    prompt: (.prompt // .initialPrompt // null),
    response: (.result // null),
    model: (.model // null),
    source: "copilot",
    copilot_event: $copilot_event,
    startup_command: (if $startup_cmd != "" then $startup_cmd else null end)
  }
  ' 2>/dev/null)

[ -z "$ENRICHED" ] && ENRICHED="{\"hook_event_name\":\"$MAPPED_EVENT\",\"session_id\":\"$SESSION_ID\",\"cwd\":\"$CWD\",\"source\":\"copilot\"}"

# ── Deliver to dashboard via file-based MQ (primary) or HTTP (fallback) ──
MQ_DIR="/tmp/claude-session-center"
MQ_FILE="$MQ_DIR/queue.jsonl"

if [ -d "$MQ_DIR" ]; then
  echo "$ENRICHED" >> "$MQ_FILE" 2>/dev/null
else
  echo "$ENRICHED" | curl -s --connect-timeout 1 -m 3 -X POST \
    -H "Content-Type: application/json" \
    --data-binary @- \
    http://localhost:3333/api/hooks &>/dev/null
fi

} &>/dev/null &
disown
exit 0
