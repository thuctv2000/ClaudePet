#!/usr/bin/env bash
#
# e2e_pet_state.sh — automated end-to-end tests for the "Pet macOS" desktop pet.
#
# The pet is an LSUIElement accessory app with a borderless window, so it cannot
# be driven or inspected via computer-use. Instead these tests exercise the HTTP
# loopback hook server and assert on the debug-only endpoint:
#
#     GET /debug/state   (header: X-Pet-Token: <token>)
#
# which returns the exact in-memory pet state as JSON:
#   { mood, runningTasks[], subagentTasks[], backgroundTasks[],
#     completedNotices[], hasPendingAsk, hasPendingQuestion }
# Each card is { title, detail, kind, context }.
#
# Port + token are read fresh from ~/.petmacos/config.json every run (the port
# is OS-assigned on each app launch, so it is never hardcoded).
#
# The app must already be running. This script never starts/stops the app; if it
# is not reachable it prints restart instructions and exits non-zero.
#
# Tests are written to be robust to pre-existing pet state (leftover cards from
# earlier manual testing, or this very session's own subagent card): they assert
# on the specific cards they create (identified by unique context tags / titles),
# not on absolute list counts.

set -u

CONFIG="$HOME/.petmacos/config.json"
HOOK="$HOME/.petmacos/pet-hook.sh"
PROJECT_DIR="/Users/REDACTED/Documents/Pet macos"

PASS=0
FAIL=0
SKIP=0

# Temp files created during the run, cleaned up on exit.
TMP_TRANSCRIPT="/tmp/petmacos_e2e_transcript_$$.jsonl"
cleanup() {
    rm -f "$TMP_TRANSCRIPT"
}
trap cleanup EXIT

# ----------------------------------------------------------------------------
# Bootstrap: read port/token, confirm the app is reachable.
# ----------------------------------------------------------------------------
if [ ! -f "$CONFIG" ]; then
    echo "ERROR: $CONFIG not found. Is Pet macOS installed/running?"
    exit 1
fi

PORT=$(sed -n 's/.*"port":\([0-9]*\).*/\1/p' "$CONFIG")
TOKEN=$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "$CONFIG")

if [ -z "$PORT" ] || [ -z "$TOKEN" ]; then
    echo "ERROR: could not parse port/token from $CONFIG"
    exit 1
fi

BASE="http://127.0.0.1:$PORT"

restart_hint() {
    echo
    echo "The pet app does not seem to be running (or is not reachable on the"
    echo "port in $CONFIG). This script will not start it for you. To get a"
    echo "clean instance, run this yourself and then re-run this script:"
    echo
    echo "  pkill -x PetMacOS && sleep 1 && cd \"$PROJECT_DIR\" && nohup .build/debug/PetMacOS > /tmp/pet_stdout.log 2>&1 &"
    echo
}

# Confirm the debug endpoint answers.
PROBE=$(curl -s -m 5 -H "X-Pet-Token: $TOKEN" "$BASE/debug/state" 2>/dev/null)
if [ -z "$PROBE" ] || ! printf '%s' "$PROBE" | grep -q '"mood"'; then
    echo "ERROR: /debug/state did not return a valid snapshot on $BASE."
    restart_hint
    exit 1
fi

echo "Pet macOS reachable on $BASE"
echo "Initial state:"
printf '%s' "$PROBE" | python3 -c 'import json,sys
s=json.load(sys.stdin)
print("  mood=%s running=%d subagent=%d background=%d completed=%d pendingAsk=%s pendingQ=%s" % (
  s["mood"], len(s["runningTasks"]), len(s["subagentTasks"]), len(s["backgroundTasks"]),
  len(s["completedNotices"]), s["hasPendingAsk"], s["hasPendingQuestion"]))'
echo

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# get_state -> prints the current /debug/state JSON.
get_state() {
    curl -s -m 5 -H "X-Pet-Token: $TOKEN" "$BASE/debug/state" 2>/dev/null
}

# post_event <json> -> fire-and-forget POST to /event.
post_event() {
    curl -s -m 5 -X POST "$BASE/event" \
        -H "X-Pet-Token: $TOKEN" -H "Content-Type: application/json" \
        --data-binary "$1" >/dev/null 2>&1
}

# report <name> <result>. result is "PASS", "SKIP: reason", or "FAIL: reason".
report() {
    local name="$1" result="$2"
    case "$result" in
        PASS)   echo "[PASS] $name"; PASS=$((PASS+1)) ;;
        SKIP:*) echo "[SKIP] $name — ${result#SKIP: }"; SKIP=$((SKIP+1)) ;;
        *)      echo "[FAIL] $name — ${result#FAIL: }"; FAIL=$((FAIL+1)) ;;
    esac
}

# assert <name> <python-body>. The current /debug/state JSON is piped to the
# python body on stdin as the variable `s` (already json.loaded). The body must
# print exactly "PASS" or "FAIL: <reason>".
# Extra state can be captured by the caller into $STATE and passed explicitly.
assert() {
    local name="$1" body="$2" state="$3"
    local out
    out=$(printf '%s' "$state" | python3 -c '
import json,sys
s=json.load(sys.stdin)
def ctx_has(cards, needle):
    return [c for c in cards if c.get("context") and needle in c["context"]]
def title_has(cards, needle):
    return [c for c in cards if c.get("title") and needle in c["title"]]
'"$body"'
' 2>&1)
    report "$name" "$out"
}

# ============================================================================
# TEST 1 — Subagents from two different sessions (same project) track distinct
# tabs: each subagent card must carry a distinct #<6-char-session-id> context,
# and both must coexist in subagentTasks.
# ============================================================================
SIDA="ta1aaa0000000000000000000000000001"
SIDB="tb2bbb0000000000000000000000000002"
TAGA="ta1aaa"
TAGB="tb2bbb"
CWD_SUB="/tmp/e2eproj"

post_event "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Agent\",\"session_id\":\"$SIDA\",\"cwd\":\"$CWD_SUB\",\"tool_input\":{\"description\":\"e2e subagent A\",\"subagent_type\":\"general-purpose\"}}"
post_event "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Agent\",\"session_id\":\"$SIDB\",\"cwd\":\"$CWD_SUB\",\"tool_input\":{\"description\":\"e2e subagent B\",\"subagent_type\":\"general-purpose\"}}"
sleep 0.6

STATE=$(get_state)
assert "1. Two subagents from distinct sessions coexist with distinct tabs" '
subs=s["subagentTasks"]
a=ctx_has(subs, "#'"$TAGA"'")
b=ctx_has(subs, "#'"$TAGB"'")
if not a:
    print("FAIL: no subagent card with context tag #'"$TAGA"' (got contexts: %s)" % [c.get("context") for c in subs])
elif not b:
    print("FAIL: no subagent card with context tag #'"$TAGB"' (got contexts: %s)" % [c.get("context") for c in subs])
elif a[0]["context"] == b[0]["context"]:
    print("FAIL: both subagents share the same context %s" % a[0]["context"])
else:
    print("PASS")
' "$STATE"

# ============================================================================
# TEST 2 — SubagentStop retires subagent cards and produces completion notices.
# NOTE: internally SubagentStop removes the OLDEST subagent (FIFO); agent_id
# only feeds the completion-notice dedupeKey. So to drain the list we send one
# SubagentStop per currently-tracked subagent, each with a distinct agent_id,
# then assert subagentTasks is empty and new completion notices were created.
# ============================================================================
N_SUB=$(printf '%s' "$(get_state)" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["subagentTasks"]))')
COMPLETED_BEFORE=$(printf '%s' "$(get_state)" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["completedNotices"]))')

# Distinct agent_id per stop (and unique per run via $$) so each completion
# notice gets its own dedupeKey ("subagent-<agentId>") and the suite is
# idempotent across re-runs.
i=0
while [ "$i" -lt "$N_SUB" ]; do
    post_event "{\"hook_event_name\":\"SubagentStop\",\"agent_id\":\"e2e-agent-$$-$i\",\"agent_type\":\"general-purpose\",\"session_id\":\"$SIDA\",\"cwd\":\"$CWD_SUB\",\"last_assistant_message\":\"e2e subagent $i done\"}"
    i=$((i+1))
    sleep 0.2
done
sleep 0.5

STATE=$(get_state)
assert "2. SubagentStop empties subagentTasks and adds completion notices" '
subs=s["subagentTasks"]
comp=s["completedNotices"]
n_sub_before='"$N_SUB"'
comp_before='"$COMPLETED_BEFORE"'
done_notices=title_has(comp, "hoàn thành")
if subs:
    print("FAIL: subagentTasks not empty after SubagentStop drain: %s" % [c.get("context") for c in subs])
elif n_sub_before>0 and len(comp) <= comp_before:
    print("FAIL: no new completion notice created (before=%d now=%d)" % (comp_before, len(comp)))
elif n_sub_before>0 and not done_notices:
    print("FAIL: no subagent completion notice ('"'"'hoàn thành'"'"') present")
else:
    print("PASS")
' "$STATE"

# ============================================================================
# TEST 3 — Background Bash task: a PostToolUse for a run_in_background Bash call
# shows a background card; appending a <task-notification>completed block to the
# transcript retires it and creates a "Chạy nền xong" completion notice.
# ============================================================================
BG_ID="E2EBG$$"
BG_SID="bgsess0000000000000000000000000003"
BG_TAG="bgsess"
BG_CWD="/tmp/e2eproj"
BG_DESC="e2e-bg-$$"

# Seed the transcript with pre-existing content so the app records a starting
# offset and only reads the completion block we append afterwards.
printf '{"type":"user","message":"seed"}\n' > "$TMP_TRANSCRIPT"

TOOL_RESPONSE="Command running in background with ID: $BG_ID. Output is being written to: $TMP_TRANSCRIPT."
post_event "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"session_id\":\"$BG_SID\",\"cwd\":\"$BG_CWD\",\"transcript_path\":\"$TMP_TRANSCRIPT\",\"tool_input\":{\"description\":\"$BG_DESC\",\"command\":\"sleep 100\",\"run_in_background\":true},\"tool_response\":\"$TOOL_RESPONSE\"}"
sleep 0.6

STATE=$(get_state)
assert "3a. Background Bash task creates a background card" '
bg=s["backgroundTasks"]
mine=[c for c in bg if c.get("detail")=="'"$BG_DESC"'" or (c.get("title") and "'"$BG_DESC"'" in c["title"])]
if not mine:
    print("FAIL: no background card for '"$BG_DESC"' (got: %s)" % [(c.get("title"),c.get("context")) for c in bg])
elif "#'"$BG_TAG"'" not in (mine[0].get("context") or ""):
    print("FAIL: background card missing expected context tag #'"$BG_TAG"' (got %s)" % mine[0].get("context"))
else:
    print("PASS")
' "$STATE"

# Append the completion signal; the app polls the transcript every ~2s.
printf '<task-notification><task-id>%s</task-id><status>completed</status></task-notification>\n' "$BG_ID" >> "$TMP_TRANSCRIPT"
sleep 5

STATE=$(get_state)
assert "3b. Completion signal retires background card + adds 'Chạy nền xong' notice" '
bg=s["backgroundTasks"]
comp=s["completedNotices"]
still=[c for c in bg if c.get("detail")=="'"$BG_DESC"'" or (c.get("title") and "'"$BG_DESC"'" in c["title"])]
done=[c for c in comp if c.get("title")=="Chạy nền xong" and c.get("detail") and "'"$BG_DESC"'" in c["detail"]]
if still:
    print("FAIL: background card still present after completion signal")
elif not done:
    print("FAIL: no '"'"'Chạy nền xong'"'"' notice for '"$BG_DESC"' (got: %s)" % [(c.get("title"),c.get("detail")) for c in comp])
else:
    print("PASS")
' "$STATE"

# ============================================================================
# TEST 4 — Fleeting auxiliary sessions are filtered. A SessionStart+SessionEnd
# pair within the 1.5s debounce window must produce NO card; a lone SessionStart
# left >1.5s must produce a "Bắt đầu phiên mới" card.
# ============================================================================
FLEET_SID="fleet10000000000000000000000000004"
FLEET_TAG="fleet1"
START_SID="start20000000000000000000000000005"
START_TAG="start2"
SESS_CWD="/tmp/e2eproj"

# Part A: back-to-back start/end (well inside the 1.5s debounce window). A short
# 0.1s gap enforces start-before-end ordering while staying under the window.
post_event "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$FLEET_SID\",\"cwd\":\"$SESS_CWD\"}"
sleep 0.1
post_event "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$FLEET_SID\",\"cwd\":\"$SESS_CWD\"}"
sleep 2.0

STATE=$(get_state)
assert "4a. Fleeting SessionStart+End pair produces no session card" '
run=s["runningTasks"]
leaked=ctx_has(run, "#'"$FLEET_TAG"'")
if leaked:
    print("FAIL: fleeting session leaked a card: %s" % [(c.get("title"),c.get("context")) for c in leaked])
else:
    print("PASS")
' "$STATE"

# Part B: a lone SessionStart, given >1.5s, must surface a card.
post_event "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$START_SID\",\"cwd\":\"$SESS_CWD\"}"
sleep 2.0

STATE=$(get_state)
assert "4b. Lone SessionStart (>1.5s) surfaces a 'Bắt đầu phiên mới' card" '
run=s["runningTasks"]
mine=[c for c in run if c.get("title")=="Bắt đầu phiên mới" and c.get("context") and "#'"$START_TAG"'" in c["context"]]
if not mine:
    print("FAIL: expected '"'"'Bắt đầu phiên mới'"'"' card with tag #'"$START_TAG"' (got: %s)" % [(c.get("title"),c.get("context")) for c in run])
else:
    print("PASS")
' "$STATE"

# ============================================================================
# TEST 5 — Permission-mode gating via the REAL installed hook script.
# We invoke ~/.petmacos/pet-hook.sh directly (not the /ask endpoint) so the
# script's own permission_mode logic is exercised:
#   - permission_mode "default"  -> script BLOCKS on /ask (pendingAsk=true).
#   - plan / acceptEdits / dontAsk -> script does NOT block; it POSTs /event,
#     producing an ordinary running card (kind "tool"). No pendingAsk.
# (bypassPermissions is intentionally NOT tested.)
# ============================================================================
PERM_CWD="/tmp/e2eperm"

run_nonblocking_mode() {
    local mode="$1" tag="$2"
    local sid="${tag}00000000000000000000000000pm"
    local desc="perm-$mode"
    local payload="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"permission_mode\":\"$mode\",\"session_id\":\"$sid\",\"cwd\":\"$PERM_CWD\",\"tool_input\":{\"description\":\"$desc\",\"command\":\"echo hi\"}}"
    # Compare pendingAsk before/after: a non-blocking mode must not NEWLY set it.
    # (A pre-existing pendingAsk from an earlier 'default' run may linger — that
    # is the documented limitation, so we check for a false->true transition,
    # not the absolute value.)
    local pending_before
    pending_before=$(printf '%s' "$(get_state)" | python3 -c 'import json,sys;print(json.load(sys.stdin)["hasPendingAsk"])')
    printf '%s' "$payload" | "$HOOK" ask >/dev/null 2>&1
    sleep 0.6
    STATE=$(get_state)
    assert "5. permission_mode=$mode does NOT block, creates a tool card" '
run=s["runningTasks"]
mine=[c for c in run if c.get("title")=="'"$desc"'" and c.get("kind")=="tool"]
pending_before = ('"$pending_before"' == True)
if s["hasPendingAsk"] and not pending_before:
    print("FAIL: hasPendingAsk newly became true for non-default mode '"$mode"'")
elif not mine:
    print("FAIL: no tool card '"$desc"' created (got: %s)" % [(c.get("title"),c.get("kind")) for c in run])
else:
    print("PASS")
' "$STATE"
}

run_nonblocking_mode "plan"        "pmpln1"
run_nonblocking_mode "acceptEdits" "pmacc2"
run_nonblocking_mode "dontAsk"     "pmdna3"

# permission_mode "default" -> the script blocks on /ask. Run it in the
# background, confirm pendingAsk goes true, then kill it (there is no HTTP way
# to resolve an ask; only the pet UI can). See the KNOWN LIMITATION note below.
PRE_PENDING=$(printf '%s' "$(get_state)" | python3 -c 'import json,sys;print(json.load(sys.stdin)["hasPendingAsk"])')
DEF_PAYLOAD="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"permission_mode\":\"default\",\"session_id\":\"pmdef40000000000000000000000000pm\",\"cwd\":\"$PERM_CWD\",\"tool_input\":{\"description\":\"perm-default\",\"command\":\"echo hi\"}}"

if [ "$PRE_PENDING" = "True" ]; then
    # An ask is already pending from an earlier run that couldn't be cleared
    # (see KNOWN LIMITATION); we cannot assert a fresh false->true transition.
    # Skip rather than fail — this is expected on any re-run without a restart.
    report "5. permission_mode=default BLOCKS (pendingAsk=true)" "SKIP: a prior pendingAsk is still set (KNOWN LIMITATION); restart the app to re-test this case"
else
    printf '%s' "$DEF_PAYLOAD" | "$HOOK" ask >/dev/null 2>&1 &
    HOOKPID=$!
    sleep 1.5
    STATE=$(get_state)
    assert "5. permission_mode=default BLOCKS (pendingAsk=true)" '
if s["hasPendingAsk"]:
    print("PASS")
else:
    print("FAIL: hasPendingAsk did not become true for default mode")
' "$STATE"
    # Kill the blocking hook + its child curl. This does NOT clear pendingAsk on
    # the app (the server keeps the ask open until its 300s timeout).
    pkill -P "$HOOKPID" 2>/dev/null
    kill "$HOOKPID" 2>/dev/null
    wait "$HOOKPID" 2>/dev/null
    echo "      KNOWN LIMITATION: the 'default' ask stays pending on the pet"
    echo "      (~300s server timeout) — there is no HTTP way to resolve it; only"
    echo "      the pet UI can. Restart the app for a fully clean state."
fi

# ============================================================================
# TEST 6 — Log rotation safety: after the whole suite, events.log stays under
# ~1.1MB (the app resets it once it passes ~1MB).
# ============================================================================
LOG="$HOME/.petmacos/events.log"
if [ -f "$LOG" ]; then
    LOG_SIZE=$(wc -c < "$LOG" | tr -d ' ')
    if [ "$LOG_SIZE" -lt 1153433 ]; then
        report "6. events.log stays under ~1.1MB (is ${LOG_SIZE} bytes)" "PASS"
    else
        report "6. events.log stays under ~1.1MB" "FAIL: events.log is ${LOG_SIZE} bytes (>= 1.1MB)"
    fi
else
    report "6. events.log stays under ~1.1MB" "FAIL: $LOG does not exist"
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
echo
echo "================================================"
echo "  RESULTS: $PASS passed, $FAIL failed, $SKIP skipped"
echo "================================================"

[ "$FAIL" -eq 0 ]
exit $?
