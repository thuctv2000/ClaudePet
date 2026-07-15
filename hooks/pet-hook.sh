#!/bin/sh
# pet-hook.sh — bridges a Claude Code hook to the running Pet macOS app.
#
# Usage (from a Claude Code hook `command`):
#   pet-hook.sh event      # fire-and-forget notification (Stop, PostToolUse, …)
#   pet-hook.sh ask        # blocking permission request (PreToolUse) — Phase 2
#   pet-hook.sh question   # blocking AskUserQuestion answer (PreToolUse)
#
# Reads the hook JSON from stdin and forwards it to the pet's loopback server,
# whose port + token are published in ~/.petmacos/config.json on app launch.
# Always exits 0 for "event" so it never blocks Claude Code.

MODE="${1:-event}"
CONFIG="$HOME/.petmacos/config.json"

# No app running / not connected → do nothing, let Claude proceed normally.
[ -f "$CONFIG" ] || exit 0

# Whitespace-tolerant: config.json may be compact ("port":58318) or
# pretty-printed ("port": 58318) depending on how it was written.
PORT=$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$CONFIG")
TOKEN=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG")
[ -n "$PORT" ] || exit 0

PAYLOAD=$(cat)

if [ "$MODE" = "question" ]; then
    # AskUserQuestion: block for the user's answer regardless of permission mode
    # (a real question needs a human, even in auto modes). The server returns the
    # complete hookSpecificOutput JSON — print it verbatim so Claude Code applies
    # the chosen answers. Empty response (app off / timeout) → exit 0 silently so
    # Claude Code falls back to asking in the terminal. curl -m below the 600s
    # hook timeout.
    RESPONSE=$(curl -s -m 570 -X POST "http://127.0.0.1:$PORT/question" \
        -H "X-Pet-Token: $TOKEN" -H "Content-Type: application/json" \
        --data-binary "$PAYLOAD" 2>/dev/null)
    [ -n "$RESPONSE" ] && printf '%s\n' "$RESPONSE"
    exit 0
fi

if [ "$MODE" = "ask" ]; then
    # AskUserQuestion is owned by the `question` hook; if it also reaches here
    # (matcher "*"), stay out of the way.
    TOOL=$(printf '%s' "$PAYLOAD" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [ "$TOOL" = "AskUserQuestion" ] && exit 0

    # Only block for a decision in manual ("default") mode. In any auto mode
    # (acceptEdits / auto / dontAsk / bypassPermissions / plan) just notify the
    # pet and let Claude Code proceed under its own permission behaviour.
    PMODE=$(printf '%s' "$PAYLOAD" | sed -n 's/.*"permission_mode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    if [ -n "$PMODE" ] && [ "$PMODE" != "default" ]; then
        curl -s -m 3 -X POST "http://127.0.0.1:$PORT/event" \
            -H "X-Pet-Token: $TOKEN" -H "Content-Type: application/json" \
            --data-binary "$PAYLOAD" >/dev/null 2>&1
        exit 0
    fi

    # Manual mode: block until the pet returns a decision, then translate it into
    # a PreToolUse permission decision for Claude Code.
    RESPONSE=$(curl -s -m 300 -X POST "http://127.0.0.1:$PORT/ask" \
        -H "X-Pet-Token: $TOKEN" \
        -H "Content-Type: application/json" \
        --data-binary "$PAYLOAD" 2>/dev/null)

    NOTE=$(printf '%s' "$RESPONSE" | sed -n 's/.*"text"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tr -d '"\\')
    case "$RESPONSE" in
        *'"decision":"deny"'*)
            REASON="Từ chối trên Pet"
            [ -n "$NOTE" ] && REASON="$REASON: $NOTE"
            printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$REASON"
            ;;
        *'"decision":"allow"'*)
            REASON="Cho phép trên Pet"
            [ -n "$NOTE" ] && REASON="$REASON: $NOTE"
            printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"%s"}}\n' "$REASON"
            ;;
        *)
            # No response (app closed / timeout) → stay out of the way.
            exit 0
            ;;
    esac
    exit 0
fi

# Fire-and-forget notification.
curl -s -m 3 -X POST "http://127.0.0.1:$PORT/event" \
    -H "X-Pet-Token: $TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary "$PAYLOAD" >/dev/null 2>&1

exit 0
