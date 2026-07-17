#!/usr/bin/env bash
#
# channel_smoke.sh — REAL end-to-end test of the Channels transport (Reply
# v1.1) against an actual `claude` process, complementing the pure-HTTP checks
# in tests/e2e_pet_state.sh (TEST 23).
#
# It spawns a real Claude Code session with the development-channel flag so
# Claude Code itself launches our channel server (channels/claudepet-channel.mjs),
# then pushes a message from the pet and proves it travels the whole path:
#
#   pet card --/debug/sendReply--> pet channel queue
#            --GET /channel/poll--> claudepet-channel.mjs  (spawned by claude)
#            --notifications/claude/channel--> the running session
#
# WHAT THIS PROVES (reproducible, asserted below):
#   1. `claude --dangerously-load-development-channels server:claudepet` starts
#      and spawns the mjs (NOT blocked by the research-preview allowlist — the
#      dev flag is gated only by a one-time consent dialog).
#   2. The mjs registers with the pet (POST /channel/hello) and the pet routes a
#      card reply over the CHANNEL transport (sendReply -> {"transport":"channel"}).
#   3. The mjs receives that message on its long-poll and EMITS the channel
#      notification back toward the session (grep of the mjs stderr).
#
# KNOWN-OPEN HOP (reported, not asserted): whether Claude Code then *injects*
# the emitted notification into the transcript. Channels are designed for
# INTERACTIVE sessions; in non-interactive modes (-p / stream-json, the only
# modes drivable without a controlling TTY) the async event is queued but not
# processed, so the transcript injection can't be positively confirmed from a
# script. A human running the interactive command (see bottom of this file)
# sees it inline. This script therefore asserts steps 1-3 and prints the
# transcript check as informational.
#
# Requirements: pet app running; `claude` >= 2.1.205; Node. Uses a throwaway
# project dir with its own .mcp.json + project-local settings (auto-approving
# the MCP server) — does NOT touch ~/.claude/settings.json. No `expect`/TTY.

set -u

NODE="${NODE:-/Users/tranvanthuc/.nvm/versions/node/v20.18.1/bin/node}"
MJS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/channels/claudepet-channel.mjs"
CONFIG="$HOME/.petmacos/config.json"
TD="/tmp/claudepet_channel_smoke_$$"
MJSLOG="$TD/mjs_stderr.log"
NONCE="CHANSMOKE${$}Z"

PASS=0; FAIL=0
ok()  { echo "[PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

CLAUDE_PID=""
cleanup() {
    [ -n "$CLAUDE_PID" ] && kill "$CLAUDE_PID" 2>/dev/null
    pkill -f "$TD/run.sh" 2>/dev/null
    pkill -f "$MJS" 2>/dev/null
    rm -rf "$TD"
}
trap cleanup EXIT

command -v claude >/dev/null || { echo "ERROR: claude not on PATH"; exit 1; }
[ -x "$NODE" ] || { echo "ERROR: node not found at $NODE"; exit 1; }
[ -f "$CONFIG" ] || { echo "ERROR: $CONFIG missing — is the pet running?"; exit 1; }

PORT=$(sed -n 's/.*"port":\([0-9]*\).*/\1/p' "$CONFIG")
TOKEN=$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "$CONFIG")
BASE="http://127.0.0.1:$PORT"
curl -s -m 5 -H "X-Pet-Token: $TOKEN" "$BASE/debug/state" | grep -q '"mood"' \
    || { echo "ERROR: pet /debug/state unreachable on $BASE"; exit 1; }
echo "Pet reachable on $BASE ; nonce=$NONCE"

# ---- throwaway project: .mcp.json + project-local MCP auto-approval ---------
mkdir -p "$TD/.claude"
: > "$MJSLOG"
cat > "$TD/run.sh" <<EOF
#!/bin/sh
exec "$NODE" "$MJS" 2>>"$MJSLOG"
EOF
chmod +x "$TD/run.sh"
echo "{ \"mcpServers\": { \"claudepet\": { \"command\": \"$TD/run.sh\", \"args\": [] } } }" > "$TD/.mcp.json"
echo '{ "enableAllProjectMcpServers": true, "enabledMcpjsonServers": ["claudepet"] }' > "$TD/.claude/settings.local.json"
REALCWD="$(cd "$TD" && pwd -P)"
SID="chansmokesess$$0000000000000000000"

# ---- persistent stream-json session (no TTY, no dialogs) -------------------
INIT="{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Say READY, then wait. If you receive a message in <channel> tags, print GOTCHANNEL followed by the inner text.\"}]}}"
FIFO="$TD/in.pipe"; mkfifo "$FIFO"
( cd "$TD" && claude -p --input-format stream-json --output-format stream-json --verbose \
    --dangerously-load-development-channels server:claudepet --dangerously-skip-permissions \
    < "$FIFO" > "$TD/out.jsonl" 2>"$TD/claude_err.log" ) &
CLAUDE_PID=$!
exec 9>"$FIFO"                       # hold the pipe open so the session stays alive
printf '%s\n' "$INIT" >&9
echo "Launched claude stream session (pid $CLAUDE_PID); waiting for MCP boot + hello…"
sleep 7

# ---- push a pet message: create a matching-cwd card, then send from it ------
curl -s -m 5 -X POST "$BASE/event" -H "X-Pet-Token: $TOKEN" -H "Content-Type: application/json" \
    --data-binary "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$SID\",\"cwd\":\"$REALCWD\",\"prompt\":\"smoke\"}" >/dev/null
sleep 0.4
SENDRES=$(curl -s -m 10 -X POST "$BASE/debug/sendReply" -H "X-Pet-Token: $TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary "$(printf '{"sessionId":"%s","text":"%s xin chào từ pet"}' "$SID" "$NONCE")")
echo "sendReply -> $SENDRES"
if printf '%s' "$SENDRES" | grep -q '"transport":"channel"'; then
    ok "claude spawned the mjs; pet routed the card reply over the CHANNEL transport"
else
    bad "pet did NOT route over channel (mjs not polling / cwd mismatch): $SENDRES"
fi

echo "Waiting for the mjs to fetch + emit the channel notification…"
sleep 10
exec 9>&-                            # close pipe -> session winds down
sleep 2

# ---- assert the mjs received + emitted the channel event -------------------
echo "---- mjs stderr ----"; sed 's/^/    /' "$MJSLOG"
if grep -q "hello ok" "$MJSLOG"; then
    ok "mjs registered with the pet (POST /channel/hello) as a live channel"
else
    bad "mjs never reached the pet (no hello in stderr) — did claude start it?"
fi
if grep -q "emit channel event.*$NONCE" "$MJSLOG"; then
    ok "mjs received the pet message on its long-poll and emitted notifications/claude/channel"
else
    bad "mjs did not emit the channel event (poll never returned the message)"
fi

# ---- informational: did Claude Code inject it into the transcript? ---------
INJECT=0
for f in $(find "$HOME/.claude/projects" -path '*claudepet-channel-smoke*' -name '*.jsonl' 2>/dev/null); do
    if grep -q "$NONCE" "$f"; then INJECT=1; echo "  [info] nonce found in transcript: $f"; fi
done
if [ "$INJECT" -eq 1 ] || grep -q "GOTCHANNEL" "$TD/out.jsonl" 2>/dev/null; then
    ok "BONUS: Claude Code injected the channel event into the session (interactive-grade behaviour)"
else
    echo "[info] Channel event was emitted to Claude Code but not observed in the transcript."
    echo "[info] Expected in non-interactive (-p/stream-json) mode: channels are processed in"
    echo "[info] INTERACTIVE sessions. To confirm the final hop by hand, run in $REALCWD:"
    echo "[info]   claude --dangerously-load-development-channels server:claudepet"
    echo "[info] accept the two consent dialogs, then push from the pet and watch it appear inline."
fi

echo
echo "================================================"
echo "  CHANNEL SMOKE: $PASS passed, $FAIL failed"
echo "================================================"
[ "$FAIL" -eq 0 ]
