#!/bin/sh
# pet-hook.sh — bridges a Claude Code hook to the running Pet macOS app.
#
# Usage (from a Claude Code hook `command`):
#   pet-hook.sh event       # fire-and-forget notification (PreToolUse, …)
#   pet-hook.sh permission  # blocking approval (PermissionRequest)
#   pet-hook.sh question    # blocking AskUserQuestion answer (PreToolUse)
#   pet-hook.sh stop        # Stop: notify, then maybe hold for a typed reply
#   pet-hook.sh deliver     # PostToolUse: notify + pick up a queued reply
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

if [ "$MODE" = "stop" ] || [ "$MODE" = "deliver" ]; then
    # Reply delivery. Both routes answer with either an empty body or the
    # complete hook JSON — hookSpecificOutput.additionalContext carrying what the
    # user typed — which is printed verbatim. Claude Code re-invokes the model
    # with that text instead of ending the turn, which is the entire transport:
    # no tmux, no accessibility, no extra process. Building the JSON server-side
    # keeps arbitrary user text (quotes, newlines, emoji) out of `sh`.
    #
    # `/stop` may hold while the user types, so it gets a longer budget than
    # `/deliver`, which never waits. Both -m values sit under the hook timeouts
    # in HookInstaller.plan(), so a wedged pet degrades to "turn ends normally"
    # instead of stalling the session.
    if [ "$MODE" = "stop" ]; then ROUTE=/stop; LIMIT=150; else ROUTE=/deliver; LIMIT=10; fi
    RESPONSE=$(curl -s -m "$LIMIT" -X POST "http://127.0.0.1:$PORT$ROUTE" \
        -H "X-Pet-Token: $TOKEN" -H "Content-Type: application/json" \
        --data-binary "$PAYLOAD" 2>/dev/null)
    [ -n "$RESPONSE" ] && printf '%s\n' "$RESPONSE"
    exit 0
fi

if [ "$MODE" = "permission" ]; then
    # PermissionRequest fires only when Claude Code is about to show a permission
    # dialog — after allow-rules and the permission mode have been evaluated. So
    # there is nothing to filter here: no read-only tools to skip, no
    # permission_mode to inspect. Whatever reaches this hook is exactly what the
    # terminal would have asked, which is why the pet can stand in for it.
    #
    # This must NOT be wired to PreToolUse: a PreToolUse decision suppresses the
    # dialog, and PermissionRequest would then never fire at all.

    # AskUserQuestion is owned by the `question` hook. Undocumented whether it
    # reaches here too; stay out of the way if it does.
    TOOL=$(printf '%s' "$PAYLOAD" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [ "$TOOL" = "AskUserQuestion" ] && exit 0

    # Block until the pet returns a decision. curl gives up at 300s, under the
    # hook's 600s default, so a stuck pet degrades to the terminal prompt rather
    # than killing the hook.
    RESPONSE=$(curl -s -m 300 -X POST "http://127.0.0.1:$PORT/ask" \
        -H "X-Pet-Token: $TOKEN" \
        -H "Content-Type: application/json" \
        --data-binary "$PAYLOAD" 2>/dev/null)

    case "$RESPONSE" in
        *'"decision":"deny"'*)
            printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}\n'
            ;;
        *'"decision":"allow"'*)
            printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}\n'
            ;;
        *)
            # No response (app closed / timeout) → stay out of the way, and the
            # dialog appears in the terminal as it normally would.
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
