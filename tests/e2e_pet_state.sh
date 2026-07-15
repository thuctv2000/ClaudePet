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
#     completedNotices[], hasPendingAsk, hasPendingQuestion, pendingAskCount,
#     pendingAskSessionId, sessions[] }
# Each card is { title, detail, kind, context, sessionId }.
# Each sessions[] entry is { id, mood, lastEventAt } -- one per currently-live
# Claude Code session, tracked independently (see PetState.SessionActivity).
# "mood" at the top level is the AGGREGATE across all live sessions (priority:
# asking > error > working > thinking > talking > sleep > idle) -- since
# several sessions can be live at once (including this very dev machine's own
# real Claude Code sessions, running concurrently with this suite), tests
# below assert on a *specific* session's entry in sessions[] wherever possible
# rather than the aggregate, so they aren't fragile to unrelated concurrent
# activity.
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
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# drain_all_asks -> resolves (denies) every ask currently in the FIFO queue,
# via the test-only /debug/resolveAsk route, so a leftover ask from an earlier
# test/run can never sit at the head of the queue and swallow/misorder the
# asks a later test posts. Capped at 10 iterations as a safety net against an
# infinite loop if something is continuously re-queuing asks.
drain_all_asks() {
    local n i=0
    n=$(get_state | python3 -c 'import json,sys;print(json.load(sys.stdin).get("pendingAskCount",0))' 2>/dev/null)
    while [ "${n:-0}" -gt 0 ] && [ "$i" -lt 10 ]; do
        curl -s -m 5 -X POST "$BASE/debug/resolveAsk" -H "X-Pet-Token: $TOKEN" -H "Content-Type: application/json" \
            --data-binary '{"decision":"deny"}' >/dev/null 2>&1
        sleep 0.2
        n=$(get_state | python3 -c 'import json,sys;print(json.load(sys.stdin).get("pendingAskCount",0))' 2>/dev/null)
        i=$((i+1))
    done
}

# post_event <json> -> fire-and-forget POST to /event.
post_event() {
    curl -s -m 5 -X POST "$BASE/event" \
        -H "X-Pet-Token: $TOKEN" -H "Content-Type: application/json" \
        --data-binary "$1" >/dev/null 2>&1
}

# wait_for_mood <mood> <max-seconds> -> polls /debug/state until the mood
# matches or the deadline passes. Events are applied asynchronously after the
# POST returns, so fixed sleeps race with slow machines; polling doesn't.
wait_for_mood() {
    local want="$1" deadline_s="$2" waited=0
    while [ "$(printf '%s' "$(get_state)" | python3 -c 'import json,sys;print(json.load(sys.stdin)["mood"])' 2>/dev/null)" != "$want" ]; do
        waited=$((waited + 1))
        [ "$waited" -ge $((deadline_s * 5)) ] && return 1
        sleep 0.2
    done
    return 0
}

# wait_for_session_mood <sessionId> <mood> <max-seconds> -> like wait_for_mood,
# but polls a specific session's own entry in sessions[] instead of the
# top-level aggregate (robust to unrelated concurrent sessions changing the
# aggregate mood while this suite runs).
wait_for_session_mood() {
    local sid="$1" want="$2" deadline_s="$3" waited=0
    while true; do
        local got
        got=$(get_state | python3 -c '
import json,sys
s=json.load(sys.stdin)
for sess in s.get("sessions", []):
    if sess.get("id") == "'"$sid"'":
        print(sess.get("mood"))
        break
else:
    print("")
' 2>/dev/null)
        [ "$got" = "$want" ] && return 0
        waited=$((waited + 1))
        [ "$waited" -ge $((deadline_s * 5)) ] && return 1
        sleep 0.2
    done
}

# wait_bg_retired <desc-substring> <timeout-seconds> -> polls /debug/state
# (every 0.1s) until no backgroundTasks card matches <desc-substring>, then
# prints how long that took. Used after appending a <task-notification> signal
# to a transcript: with file-watching (DispatchSource) instead of the old
# fixed ~2s poll, retirement should be near-instant (well under a second) —
# printing the elapsed time makes that improvement visible in the test output
# without hardcoding a tight, potentially-flaky assertion on the exact number.
# Returns 0 if retired within the timeout, 1 otherwise (caller still re-reads
# /debug/state afterwards either way, so a timeout just surfaces as the normal
# assertion failing below with full diagnostic detail).
wait_bg_retired() {
    local desc="$1" timeout_s="$2" waited=0
    local start
    start=$(python3 -c 'import time;print(time.time())')
    while true; do
        local still
        still=$(get_state | python3 -c 'import json,sys
s=json.load(sys.stdin)
bg=s["backgroundTasks"]
mine=[c for c in bg if c.get("detail")=="'"$desc"'" or (c.get("title") and "'"$desc"'" in c["title"])]
print("yes" if mine else "no")' 2>/dev/null)
        if [ "$still" = "no" ]; then
            local end elapsed
            end=$(python3 -c 'import time;print(time.time())')
            elapsed=$(python3 -c "print(f'{$end-$start:.2f}')")
            echo "      (background card retired after ${elapsed}s)"
            return 0
        fi
        waited=$((waited + 1))
        [ "$waited" -ge $((timeout_s * 10)) ] && return 1
        sleep 0.1
    done
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
def session_mood(sid):
    for sess in s.get("sessions", []):
        if sess.get("id") == sid:
            return sess.get("mood")
    return None
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
assert "1. Two subagents from distinct sessions coexist with distinct tabs, each stamped with its own sessionId" '
subs=s["subagentTasks"]
a=ctx_has(subs, "#'"$TAGA"'")
b=ctx_has(subs, "#'"$TAGB"'")
if not a:
    print("FAIL: no subagent card with context tag #'"$TAGA"' (got contexts: %s)" % [c.get("context") for c in subs])
elif not b:
    print("FAIL: no subagent card with context tag #'"$TAGB"' (got contexts: %s)" % [c.get("context") for c in subs])
elif a[0]["context"] == b[0]["context"]:
    print("FAIL: both subagents share the same context %s" % a[0]["context"])
elif a[0].get("sessionId") != "'"$SIDA"'":
    print("FAIL: subagent A card sessionId is %r, expected '"$SIDA"'" % a[0].get("sessionId"))
elif b[0].get("sessionId") != "'"$SIDB"'":
    print("FAIL: subagent B card sessionId is %r, expected '"$SIDB"'" % b[0].get("sessionId"))
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

# Hygiene: retire sessions A/B's mood entries so they don'"'"'t linger in
# sessions[] (with mood "working"/"talking") and pollute later tests that
# still check the top-level aggregate mood.
post_event "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$SIDA\",\"cwd\":\"$CWD_SUB\"}"
post_event "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$SIDB\",\"cwd\":\"$CWD_SUB\"}"

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
assert "3a. Background Bash task creates a background card (stamped with sessionId)" '
bg=s["backgroundTasks"]
mine=[c for c in bg if c.get("detail")=="'"$BG_DESC"'" or (c.get("title") and "'"$BG_DESC"'" in c["title"])]
if not mine:
    print("FAIL: no background card for '"$BG_DESC"' (got: %s)" % [(c.get("title"),c.get("context")) for c in bg])
elif "#'"$BG_TAG"'" not in (mine[0].get("context") or ""):
    print("FAIL: background card missing expected context tag #'"$BG_TAG"' (got %s)" % mine[0].get("context"))
elif mine[0].get("sessionId") != "'"$BG_SID"'":
    print("FAIL: background card sessionId is %r, expected '"$BG_SID"'" % mine[0].get("sessionId"))
else:
    print("PASS")
' "$STATE"

# Append the completion signal. Detection is now driven by a filesystem
# watcher on the transcript (see TranscriptWatcher in PetState.swift) rather
# than the old fixed ~2s poll, so this should retire in well under a second;
# the 5s bound is only a generous ceiling for a loaded/slow machine (the old
# poll-based version needed a fixed `sleep 5` here with no visibility into how
# close it was cutting it -- wait_bg_retired also prints the actual latency).
printf '<task-notification><task-id>%s</task-id><status>completed</status></task-notification>\n' "$BG_ID" >> "$TMP_TRANSCRIPT"
wait_bg_retired "$BG_DESC" 5

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
post_event "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$BG_SID\",\"cwd\":\"$BG_CWD\"}"

# ============================================================================
# TEST 3c/3d — Background Bash task status handling: "failed" and "killed"
# must ALSO retire the card (the original bug: only "completed" did), each
# with its own Vietnamese notice title and TaskKind "failed" so the UI can
# tell them apart from a normal "done" result.
# ============================================================================
run_bg_status_case() {
    local label="$1" status="$2" expect_title="$3"
    local bg_id="E2EBG${status}$$"
    local bg_sid="bg${status}00000000000000000000004"
    local bg_desc="e2e-bg-${status}-$$"
    local transcript="/tmp/petmacos_e2e_bg_${status}_$$.jsonl"

    printf '{"type":"user","message":"seed"}\n' > "$transcript"
    local tool_response="Command running in background with ID: $bg_id. Output is being written to: $transcript."
    post_event "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"session_id\":\"$bg_sid\",\"cwd\":\"$BG_CWD\",\"transcript_path\":\"$transcript\",\"tool_input\":{\"description\":\"$bg_desc\",\"command\":\"false\",\"run_in_background\":true},\"tool_response\":\"$tool_response\"}"
    sleep 0.6

    printf '<task-notification><task-id>%s</task-id><status>%s</status></task-notification>\n' "$bg_id" "$status" >> "$transcript"
    wait_bg_retired "$bg_desc" 5

    STATE=$(get_state)
    assert "$label" '
bg=s["backgroundTasks"]
comp=s["completedNotices"]
still=[c for c in bg if c.get("detail")=="'"$bg_desc"'" or (c.get("title") and "'"$bg_desc"'" in c["title"])]
done=[c for c in comp if c.get("title")=="'"$expect_title"'" and c.get("kind")=="failed" and c.get("detail") and "'"$bg_desc"'" in c["detail"]]
if still:
    print("FAIL: background card still present after '"$status"' signal")
elif not done:
    print("FAIL: no '"'"'$expect_title'"'"' (kind=failed) notice for '"$bg_desc"' (got: %s)" % [(c.get("title"),c.get("kind"),c.get("detail")) for c in comp])
else:
    print("PASS")
' "$STATE"
    rm -f "$transcript"
    post_event "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$bg_sid\",\"cwd\":\"$BG_CWD\"}"
}

run_bg_status_case "3c. Background task status=failed retires card as 'Chạy nền lỗi' (kind failed)" "failed" "Chạy nền lỗi"
run_bg_status_case "3d. Background task status=killed retires card as 'Chạy nền bị dừng' (kind failed)" "killed" "Chạy nền bị dừng"

# ============================================================================
# TEST 3e — Background task safety-net timeout: with no completion signal at
# all, the card must retire on its own once `backgroundTimeoutSeconds` (config
# override, same mechanism as talkingDecaySeconds) elapses, with a notice that
# says the outcome is simply unknown.
# ============================================================================
TIMEOUT_ID="E2EBGTMO$$"
TIMEOUT_SID="bgtimeout000000000000000000000005"
TIMEOUT_DESC="e2e-bg-timeout-$$"
TIMEOUT_TRANSCRIPT="/tmp/petmacos_e2e_bg_timeout_$$.jsonl"
printf '{"type":"user","message":"seed"}\n' > "$TIMEOUT_TRANSCRIPT"

ORIG_CONFIG_BG=$(cat "$CONFIG")
python3 - "$CONFIG" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
cfg["backgroundTimeoutSeconds"] = 3
with open(path, "w") as f:
    json.dump(cfg, f)
PYEOF

TOOL_RESPONSE_TMO="Command running in background with ID: $TIMEOUT_ID. Output is being written to: $TIMEOUT_TRANSCRIPT."
post_event "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"session_id\":\"$TIMEOUT_SID\",\"cwd\":\"$BG_CWD\",\"transcript_path\":\"$TIMEOUT_TRANSCRIPT\",\"tool_input\":{\"description\":\"$TIMEOUT_DESC\",\"command\":\"sleep 999\",\"run_in_background\":true},\"tool_response\":\"$TOOL_RESPONSE_TMO\"}"
sleep 0.6

# Never append a completion signal; just wait past the overridden 3s timeout
# (plus the ~2s poll cadence) and confirm the card retires on its own.
sleep 6

printf '%s' "$ORIG_CONFIG_BG" > "$CONFIG"
rm -f "$TIMEOUT_TRANSCRIPT"

STATE=$(get_state)
assert "3e. Background task with no signal retires after backgroundTimeoutSeconds (kind failed, 'không rõ kết quả')" '
bg=s["backgroundTasks"]
comp=s["completedNotices"]
still=[c for c in bg if c.get("detail")=="'"$TIMEOUT_DESC"'" or (c.get("title") and "'"$TIMEOUT_DESC"'" in c["title"])]
done=[c for c in comp if "không rõ kết quả" in (c.get("title") or "") and c.get("kind")=="failed" and c.get("detail") and "'"$TIMEOUT_DESC"'" in c["detail"]]
if still:
    print("FAIL: background card still present after timeout should have retired it")
elif not done:
    print("FAIL: no timeout notice for '"$TIMEOUT_DESC"' (got: %s)" % [(c.get("title"),c.get("kind"),c.get("detail")) for c in comp])
else:
    print("PASS")
' "$STATE"
post_event "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$TIMEOUT_SID\",\"cwd\":\"$BG_CWD\"}"

# ============================================================================
# TEST 3f — Background task whose transcript file does NOT exist yet at task
# start (only its containing directory does — the normal case for a project
# that's mid-session but hasn't had this particular transcript created yet).
# This exercises TranscriptWatcher's directory-watch fallback: it can't open
# a DispatchSource on a nonexistent file, so it must watch the parent
# directory instead, then promote to a direct file watch once the file
# appears, and still catch the completion signal.
# ============================================================================
NEW_DIR="/tmp/petmacos_e2e_newfile_$$"
mkdir -p "$NEW_DIR"
NEW_TRANSCRIPT="$NEW_DIR/transcript.jsonl"
rm -f "$NEW_TRANSCRIPT" # must NOT exist yet when the task starts
NEW_ID="E2EBGNEW$$"
NEW_SID="bgnewfile000000000000000000000006"
NEW_DESC="e2e-bg-newfile-$$"

TOOL_RESPONSE_NEW="Command running in background with ID: $NEW_ID. Output is being written to: $NEW_TRANSCRIPT."
post_event "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"session_id\":\"$NEW_SID\",\"cwd\":\"$BG_CWD\",\"transcript_path\":\"$NEW_TRANSCRIPT\",\"tool_input\":{\"description\":\"$NEW_DESC\",\"command\":\"sleep 100\",\"run_in_background\":true},\"tool_response\":\"$TOOL_RESPONSE_NEW\"}"
sleep 0.6

STATE=$(get_state)
assert "3f-start. Background card created even though transcript file did not exist yet" '
bg=s["backgroundTasks"]
mine=[c for c in bg if c.get("detail")=="'"$NEW_DESC"'" or (c.get("title") and "'"$NEW_DESC"'" in c["title"])]
if not mine:
    print("FAIL: no background card for '"$NEW_DESC"' (got: %s)" % [(c.get("title"),c.get("context")) for c in bg])
else:
    print("PASS")
' "$STATE"

# Now the file appears for the first time, already containing the completion
# signal (simulates Claude Code creating + writing the transcript after the
# task was already tracked with a missing-file watcher).
printf '{"type":"user","message":"seed"}\n<task-notification><task-id>%s</task-id><status>completed</status></task-notification>\n' "$NEW_ID" > "$NEW_TRANSCRIPT"
wait_bg_retired "$NEW_DESC" 5

STATE=$(get_state)
assert "3f. Directory-watch fallback catches a transcript created after task start" '
bg=s["backgroundTasks"]
comp=s["completedNotices"]
still=[c for c in bg if c.get("detail")=="'"$NEW_DESC"'" or (c.get("title") and "'"$NEW_DESC"'" in c["title"])]
done=[c for c in comp if c.get("title")=="Chạy nền xong" and c.get("detail") and "'"$NEW_DESC"'" in c["detail"]]
if still:
    print("FAIL: background card still present after transcript was created with the completion signal")
elif not done:
    print("FAIL: no '"'"'Chạy nền xong'"'"' notice for '"$NEW_DESC"' (got: %s)" % [(c.get("title"),c.get("detail")) for c in comp])
else:
    print("PASS")
' "$STATE"

rm -rf "$NEW_DIR"
post_event "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$NEW_SID\",\"cwd\":\"$BG_CWD\"}"

# ============================================================================
# TEST 4 — SessionStart/SessionEnd never surface a card. Hooks are installed
# globally (see the comment in PetState.apply()'s "SessionStart"/"SessionEnd"
# cases): these events fire for every Claude Code session on the machine, not
# just the one the user is watching a card here would just be noise from
# unrelated sessions, so the app deliberately only reacts by changing mood
# (idle / sleep), never by pushing a running card. (An earlier version of this
# test asserted the opposite — that a lone SessionStart surfaces a "Bắt đầu
# phiên mới" card after a debounce window — which no longer matches the
# intentional behaviour above; this test now asserts what the code actually,
# and correctly, does.)
# ============================================================================
FLEET_SID="fleet10000000000000000000000000004"
FLEET_TAG="fleet1"
START_SID="start20000000000000000000000000005"
START_TAG="start2"
SESS_CWD="/tmp/e2eproj"

# Part A: back-to-back start/end.
post_event "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$FLEET_SID\",\"cwd\":\"$SESS_CWD\"}"
sleep 0.1
post_event "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$FLEET_SID\",\"cwd\":\"$SESS_CWD\"}"
sleep 1.0

STATE=$(get_state)
assert "4a. SessionStart+End pair produces no session card" '
run=s["runningTasks"]
leaked=ctx_has(run, "#'"$FLEET_TAG"'")
if leaked:
    print("FAIL: session start/end leaked a card: %s" % [(c.get("title"),c.get("context")) for c in leaked])
else:
    print("PASS")
' "$STATE"

# Part B: a lone SessionStart must ALSO never surface a card (only mood reacts).
post_event "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$START_SID\",\"cwd\":\"$SESS_CWD\"}"
sleep 1.0

STATE=$(get_state)
assert "4b. Lone SessionStart surfaces no card (mood-only reaction)" '
run=s["runningTasks"]
mine=ctx_has(run, "#'"$START_TAG"'")
mood = session_mood("'"$START_SID"'")
if mine:
    print("FAIL: SessionStart unexpectedly created a card: %s" % [(c.get("title"),c.get("context")) for c in mine])
elif mood != "idle":
    print("FAIL: expected session '"$START_SID"' mood \"idle\" after SessionStart, got %r" % mood)
else:
    print("PASS")
' "$STATE"

post_event "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$START_SID\",\"cwd\":\"$SESS_CWD\"}"
sleep 0.3

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
# background and confirm pendingAsk goes true, then explicitly resolve it via
# the test-only /debug/resolveAsk route (see HookServer.handleDebugResolveAsk)
# instead of just killing the hook and leaving the ask stuck open on the
# server for its ~300s timeout. Before this pass'"'"'s FIFO queue (TASK 4), a
# stray unresolved ask here was only a cosmetic annoyance (the single pendingAsk
# slot would just show a stale dialog); now that asks QUEUE, an unresolved ask
# left behind by this test would sit at the head of the queue and silently
# swallow/misorder every ask TEST 18/19 posts afterwards -- so cleaning it up
# here is required for correctness, not just hygiene.
DEF_PAYLOAD="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"permission_mode\":\"default\",\"session_id\":\"pmdef40000000000000000000000000pm\",\"cwd\":\"$PERM_CWD\",\"tool_input\":{\"description\":\"perm-default\",\"command\":\"echo hi\"}}"

drain_all_asks # make sure nothing stray is already queued (see drain_all_asks doc)
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
# Resolve it (deny) via the debug route so it does not linger in the FIFO
# queue for later tests, then let the hook script'"'"'s own curl return and reap
# the background job cleanly.
drain_all_asks
wait "$HOOKPID" 2>/dev/null
pkill -P "$HOOKPID" 2>/dev/null
kill "$HOOKPID" 2>/dev/null
wait "$HOOKPID" 2>/dev/null

# ============================================================================
# TEST 7/8/9 — Mood decay (error, talking, and decay-cancellation-by-new-event).
#
# Both `talkingDecaySeconds` and `errorDecaySeconds` are overridden via optional
# fields in ~/.petmacos/config.json (PetState reads them fresh on every use, not
# just at launch — see PetState.talkingDecaySeconds/errorDecaySeconds) so these
# tests don't have to wait out the real 20s/6s defaults. The original
# config.json is restored on exit via the existing cleanup trap.
# ============================================================================
ORIG_CONFIG=$(cat "$CONFIG")
restore_config() { printf '%s' "$ORIG_CONFIG" > "$CONFIG"; }
cleanup() { rm -f "$TMP_TRANSCRIPT"; restore_config; }
trap cleanup EXIT

python3 - "$CONFIG" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
cfg["talkingDecaySeconds"] = 3
cfg["errorDecaySeconds"] = 3
with open(path, "w") as f:
    json.dump(cfg, f)
PYEOF

# NOTE ON MOOD ASSERTIONS BELOW: since PetState v2 (session-tabs prep), `mood`
# is an AGGREGATE across every live session (see PetState.recomputeAggregateMood),
# and this dev machine's own real Claude Code sessions may be generating hook
# events concurrently with this suite. So these tests assert on *this test's
# own session's* entry in `sessions[]` (via `session_mood`/`wait_for_session_mood`)
# instead of the top-level aggregate `s["mood"]` -- robust to unrelated
# concurrent activity, and also the more semantically correct check now that
# mood is tracked per-session.

# --- 7. PostToolUse tool_response.is_error -> mood "error", then decays. ---
ERR_SID="errtest10000000000000000000000006"
post_event "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"session_id\":\"$ERR_SID\",\"cwd\":\"/tmp/e2eerr\",\"tool_input\":{\"description\":\"e2e failing tool\",\"command\":\"false\"},\"tool_response\":{\"is_error\":true,\"stderr\":\"boom\"}}"
wait_for_session_mood "$ERR_SID" "error" 2 || true

STATE=$(get_state)
assert "7a. PostToolUse with tool_response.is_error sets mood \"error\"" '
mood = session_mood("'"$ERR_SID"'")
if mood != "error":
    print("FAIL: expected session mood \"error\", got %r" % mood)
else:
    print("PASS")
' "$STATE"

sleep 4.5 # past the overridden 3s errorDecaySeconds
STATE=$(get_state)
assert "7b. \"error\" mood decays back (working if work active GLOBALLY, else idle)" '
# hasActiveWork is deliberately global (any session'"'"'s subagent/background
# task), not scoped to this one session -- see PetState.hasActiveWork.
active = bool(s["subagentTasks"]) or bool(s["backgroundTasks"])
expected = "working" if active else "idle"
mood = session_mood("'"$ERR_SID"'")
if mood != expected:
    print("FAIL: expected session mood %r after error decay, got %r" % (expected, mood))
else:
    print("PASS")
' "$STATE"

# A tool_response WITHOUT an error signal must not flip mood to "error" (guards
# against over-eager string matching of the response text).
OK_SID="oktest200000000000000000000000009"
post_event "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"session_id\":\"$OK_SID\",\"cwd\":\"/tmp/e2eerr\",\"tool_input\":{\"description\":\"e2e ok tool\",\"command\":\"echo hi\"},\"tool_response\":\"contains the word error in its output, but no is_error flag\"}"
sleep 0.5
STATE=$(get_state)
assert "7c. PostToolUse with plain-string tool_response (no is_error flag) does not set mood \"error\"" '
mood = session_mood("'"$OK_SID"'")
if mood == "error":
    print("FAIL: session mood incorrectly became \"error\" from response text alone")
else:
    print("PASS")
' "$STATE"
post_event "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$ERR_SID\",\"cwd\":\"/tmp/e2eerr\"}"
post_event "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$OK_SID\",\"cwd\":\"/tmp/e2eerr\"}"

# --- 8. Clean Stop -> mood "talking", then decays to "idle". ---
STOP_SID="stoptest2000000000000000000000007"
post_event "{\"hook_event_name\":\"Stop\",\"session_id\":\"$STOP_SID\",\"cwd\":\"/tmp/e2estop\",\"last_assistant_message\":\"e2e stop reply\"}"
wait_for_session_mood "$STOP_SID" "talking" 2 || true

STATE=$(get_state)
assert "8a. Clean Stop sets mood \"talking\" (no active subagent/background work)" '
active = bool(s["subagentTasks"]) or bool(s["backgroundTasks"])
mood = session_mood("'"$STOP_SID"'")
if active:
    print("SKIP: subagent/background tasks still active from another test; cannot assert talking cleanly")
elif mood != "talking":
    print("FAIL: expected session mood \"talking\", got %r" % mood)
else:
    print("PASS")
' "$STATE"

sleep 4.5 # past the overridden 3s talkingDecaySeconds
STATE=$(get_state)
assert "8b. \"talking\" mood decays to \"idle\" after talkingDecaySeconds" '
mood = session_mood("'"$STOP_SID"'")
if mood != "idle":
    print("FAIL: expected session mood \"idle\" after talking decay, got %r" % mood)
else:
    print("PASS")
' "$STATE"
post_event "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$STOP_SID\",\"cwd\":\"/tmp/e2estop\"}"

# --- 9. A newer event mid-decay must win; the stale timer must not fire later. ---
CANCEL_SID="canceltest00000000000000000000010"
post_event "{\"hook_event_name\":\"Stop\",\"session_id\":\"$CANCEL_SID\",\"cwd\":\"/tmp/e2ecancel\"}"
sleep 0.3
post_event "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$CANCEL_SID\",\"cwd\":\"/tmp/e2ecancel\",\"prompt\":\"e2e new prompt mid-decay\"}"
sleep 0.3

STATE=$(get_state)
assert "9a. A new event mid-decay immediately overrides mood" '
mood = session_mood("'"$CANCEL_SID"'")
if mood != "thinking":
    print("FAIL: expected session mood \"thinking\" right after UserPromptSubmit, got %r" % mood)
else:
    print("PASS")
' "$STATE"

sleep 3   # past the original ("talking") decay deadline, which must be cancelled
STATE=$(get_state)
assert "9b. Stale decay timer does not fire after mood already moved on" '
mood = session_mood("'"$CANCEL_SID"'")
if mood != "thinking":
    print("FAIL: expected session mood still \"thinking\" (stale decay must have been cancelled), got %r" % mood)
else:
    print("PASS")
' "$STATE"
post_event "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$CANCEL_SID\",\"cwd\":\"/tmp/e2ecancel\"}"

# Restore the real config.json now (rather than only at exit) so TEST 6 below
# measures the log the app actually wrote to under normal settings.
restore_config

# ============================================================================
# TEST 10/11/12 — SubagentStart/agent_id-based matching replaces the old FIFO
# (oldest-first) SubagentStop matching. Proves: (a) claiming a PreToolUse card
# by session_id avoids a duplicate card, (b) stopping a YOUNGER subagent by its
# real agent_id retires that exact card even while an OLDER one is still
# running (impossible under pure FIFO), (c) a card with no agent_id (older
# Claude Code build, or SubagentStart never arrived) still falls back to FIFO.
# ============================================================================

# Drain whatever subagent cards already exist (leftovers from TEST 1/2, or any
# real dev-session subagent) so the FIFO fallback proof below (12) has a known,
# clean starting point. Uses fabricated agent_ids that cannot match any real
# tagged card, forcing the FIFO fallback path each time -- exactly like TEST 2.
drain_all_subagents() {
    local n
    n=$(printf '%s' "$(get_state)" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["subagentTasks"]))')
    local i=0
    while [ "$i" -lt "$n" ]; do
        post_event "{\"hook_event_name\":\"SubagentStop\",\"agent_id\":\"e2e-drain-$$-$i\",\"session_id\":\"drain\",\"cwd\":\"$CWD_SUB\"}"
        i=$((i+1))
        sleep 0.2
    done
    sleep 0.3
}
drain_all_subagents

SIDA10="tenA0000000000000000000000000010"
TAGA10="tenA00"
SIDB10="tenB0000000000000000000000000011"
TAGB10="tenB00"

# Card A: PreToolUse Task (unclaimed, no agent_id yet) then a SubagentStart
# that claims it by session_id -- must NOT produce a second card.
post_event "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Task\",\"session_id\":\"$SIDA10\",\"cwd\":\"$CWD_SUB\",\"tool_input\":{\"description\":\"e2e subagent A10\",\"subagent_type\":\"general-purpose\"}}"
sleep 0.3
post_event "{\"hook_event_name\":\"SubagentStart\",\"agent_id\":\"e2e-agentA-$$\",\"agent_type\":\"general-purpose\",\"session_id\":\"$SIDA10\",\"cwd\":\"$CWD_SUB\"}"
sleep 0.4

STATE=$(get_state)
assert "10. SubagentStart claims the PreToolUse card by session_id (no duplicate)" '
subs=s["subagentTasks"]
mine=ctx_has(subs, "#'"$TAGA10"'")
if len(mine) == 0:
    print("FAIL: no subagent card with context tag #'"$TAGA10"'")
elif len(mine) > 1:
    print("FAIL: SubagentStart created a DUPLICATE card instead of claiming the existing one (got %d)" % len(mine))
else:
    print("PASS")
' "$STATE"

# Card B: SubagentStart only (no preceding PreToolUse reaching us -- simulates
# manual/"ask" launches or an event we never saw), started AFTER card A.
post_event "{\"hook_event_name\":\"SubagentStart\",\"agent_id\":\"e2e-agentB-$$\",\"agent_type\":\"general-purpose\",\"session_id\":\"$SIDB10\",\"cwd\":\"$CWD_SUB\"}"
sleep 0.4

STATE=$(get_state)
assert "11. SubagentStart with no matching PreToolUse card creates a fresh card" '
subs=s["subagentTasks"]
mine=ctx_has(subs, "#'"$TAGB10"'")
if not mine:
    print("FAIL: no subagent card with context tag #'"$TAGB10"' (got contexts: %s)" % [c.get("context") for c in subs])
else:
    print("PASS")
' "$STATE"

# The actual regression proof: stop the YOUNGER subagent (B) first, by its
# real agent_id. Under the old FIFO-only logic this would have incorrectly
# removed the OLDER card (A) instead. With agent_id matching, B's card is
# removed and A's card -- still "running" -- must remain untouched.
post_event "{\"hook_event_name\":\"SubagentStop\",\"agent_id\":\"e2e-agentB-$$\",\"agent_type\":\"general-purpose\",\"session_id\":\"$SIDB10\",\"cwd\":\"$CWD_SUB\",\"last_assistant_message\":\"e2e B done\"}"
sleep 0.5

STATE=$(get_state)
assert "12. SubagentStop(agent_id=B) removes exactly B, NOT the older A (proves FIFO is gone)" '
subs=s["subagentTasks"]
a=ctx_has(subs, "#'"$TAGA10"'")
b=ctx_has(subs, "#'"$TAGB10"'")
if b:
    print("FAIL: card B still present after its own SubagentStop")
elif not a:
    print("FAIL: card A was wrongly removed instead of B -- FIFO fallback fired despite a valid agent_id match")
else:
    print("PASS")
' "$STATE"

# Fallback proof: a card with NO agent_id (older Claude Code build / never got
# a SubagentStart) must still be retirable via the FIFO fallback. At this
# point the only subagent card left from this test group is A; add a fresh
# unclaimed card C, then send a SubagentStop with no agent_id at all -- it
# must fall back to removing the oldest tracked card (A), leaving C.
SIDC10="tenC0000000000000000000000000012"
TAGC10="tenC00"
post_event "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Task\",\"session_id\":\"$SIDC10\",\"cwd\":\"$CWD_SUB\",\"tool_input\":{\"description\":\"e2e subagent C10\",\"subagent_type\":\"general-purpose\"}}"
sleep 0.4

post_event "{\"hook_event_name\":\"SubagentStop\",\"session_id\":\"$SIDA10\",\"cwd\":\"$CWD_SUB\",\"last_assistant_message\":\"e2e no-id stop\"}"
sleep 0.5

STATE=$(get_state)
assert "13. SubagentStop with no agent_id falls back to FIFO (removes oldest: A), C remains" '
subs=s["subagentTasks"]
a=ctx_has(subs, "#'"$TAGA10"'")
c=ctx_has(subs, "#'"$TAGC10"'")
if a:
    print("FAIL: card A still present -- fallback FIFO removal did not happen")
elif not c:
    print("FAIL: card C missing -- fallback FIFO removed the wrong card")
else:
    print("PASS")
' "$STATE"

# Clean up: drain whatever this test group left behind (card C) so it doesn't
# leak into a subsequent run of this suite.
drain_all_subagents

# ============================================================================
# TEST 14/15/16 — Session-name resolution (SessionNames.swift). `contextLabel`
# should caption cards with the conversation's first-prompt name resolved from
# `history.jsonl` instead of the raw "#tag", falling back to "#tag" when a
# session can't be resolved (never in the file, or a "[Pasted text ...]"
# placeholder that cleans to nothing). The history file path is injected via
# the optional `historyPath` field in config.json -- same override mechanism
# as talkingDecaySeconds/errorDecaySeconds -- pointed at a throwaway fixture so
# the real ~/.claude/history.jsonl is never touched.
# ============================================================================
TMP_HISTORY="/tmp/petmacos_e2e_history_$$.jsonl"
cleanup() { rm -f "$TMP_TRANSCRIPT" "$TMP_HISTORY"; restore_config; }
trap cleanup EXIT

SID_NAME="namedses0000000000000000000000014"
SID_PASTE="pastedses000000000000000000000015"
SID_UNKNOWN="unknownse00000000000000000000016"
SID_LATE="latesess0000000000000000000000017"
CWD_NAME="/tmp/e2ename"
TAGNAME6="${SID_NAME:0:6}"
TAGPASTE6="${SID_PASTE:0:6}"
TAGUNKNOWN6="${SID_UNKNOWN:0:6}"
TAGLATE6="${SID_LATE:0:6}"

python3 - "$TMP_HISTORY" "$SID_NAME" "$SID_PASTE" <<'PYEOF'
import json, sys
path, sid_name, sid_paste = sys.argv[1], sys.argv[2], sys.argv[3]
lines = [
    {"display": "Refactor the entire authentication and session management subsystem for scalability",
     "pastedContents": {}, "timestamp": 1000, "project": "/tmp/e2ename", "sessionId": sid_name},
    {"display": "[Pasted text #1 +22 lines] ",
     "pastedContents": {"1": {"id": 1, "type": "text", "content": "irrelevant"}},
     "timestamp": 1001, "project": "/tmp/e2ename", "sessionId": sid_paste},
]
with open(path, "w") as f:
    for l in lines:
        f.write(json.dumps(l) + "\n")
PYEOF

python3 - "$CONFIG" "$TMP_HISTORY" <<'PYEOF'
import json, sys
path, history_path = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)
cfg["historyPath"] = history_path
with open(path, "w") as f:
    json.dump(cfg, f)
PYEOF

# --- 14a. Resolvable session: context uses the (truncated) conversation name, not "#tag". ---
post_event "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Task\",\"session_id\":\"$SID_NAME\",\"cwd\":\"$CWD_NAME\",\"tool_input\":{\"description\":\"e2e named subagent\",\"subagent_type\":\"general-purpose\"}}"
post_event "{\"hook_event_name\":\"SubagentStart\",\"session_id\":\"$SID_NAME\",\"cwd\":\"$CWD_NAME\",\"agent_id\":\"agentname14\",\"agent_type\":\"general-purpose\"}"
sleep 0.5

STATE=$(get_state)
assert "14a. Resolvable session: card context shows the conversation name (truncated at a word boundary), not #tag" '
subs=s["subagentTasks"]
c=[c for c in subs if c.get("context") and "e2ename" in c["context"]]
if not c:
    print("FAIL: no card with e2ename context found")
else:
    ctx = c[0]["context"]
    if "#'"$TAGNAME6"'" in ctx:
        print("FAIL: context still shows the raw #tag instead of the resolved name: %r" % ctx)
    elif "Refactor the entire" not in ctx:
        print("FAIL: context does not contain the expected conversation name: %r" % ctx)
    elif len(ctx) > 60:
        print("FAIL: context looks untruncated / too long: %r" % ctx)
    else:
        print("PASS")
' "$STATE"

post_event "{\"hook_event_name\":\"SubagentStop\",\"session_id\":\"$SID_NAME\",\"cwd\":\"$CWD_NAME\",\"agent_id\":\"agentname14\",\"last_assistant_message\":\"done\"}"
sleep 0.3

# --- 14b. A "[Pasted text ...]"-only display cleans to nothing -> falls back to #tag. ---
post_event "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Task\",\"session_id\":\"$SID_PASTE\",\"cwd\":\"$CWD_NAME\",\"tool_input\":{\"description\":\"e2e pasted subagent\",\"subagent_type\":\"general-purpose\"}}"
post_event "{\"hook_event_name\":\"SubagentStart\",\"session_id\":\"$SID_PASTE\",\"cwd\":\"$CWD_NAME\",\"agent_id\":\"agentpaste14\",\"agent_type\":\"general-purpose\"}"
sleep 0.5

STATE=$(get_state)
assert "14b. Pasted-text-only display cleans to nothing -> falls back to #tag" '
subs=s["subagentTasks"]
c=[c for c in subs if c.get("context") and "#'"$TAGPASTE6"'" in c["context"]]
if not c:
    print("FAIL: expected fallback #'"$TAGPASTE6"' tag not found (contexts: %s)" % [x.get("context") for x in subs])
else:
    print("PASS")
' "$STATE"

post_event "{\"hook_event_name\":\"SubagentStop\",\"session_id\":\"$SID_PASTE\",\"cwd\":\"$CWD_NAME\",\"agent_id\":\"agentpaste14\",\"last_assistant_message\":\"done\"}"
sleep 0.3

# --- 15. Session never present in history.jsonl -> falls back to #tag. ---
post_event "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Task\",\"session_id\":\"$SID_UNKNOWN\",\"cwd\":\"$CWD_NAME\",\"tool_input\":{\"description\":\"e2e unknown subagent\",\"subagent_type\":\"general-purpose\"}}"
post_event "{\"hook_event_name\":\"SubagentStart\",\"session_id\":\"$SID_UNKNOWN\",\"cwd\":\"$CWD_NAME\",\"agent_id\":\"agentunknown15\",\"agent_type\":\"general-purpose\"}"
sleep 0.5

STATE=$(get_state)
assert "15. Session absent from history.jsonl falls back to #tag" '
subs=s["subagentTasks"]
c=[c for c in subs if c.get("context") and "#'"$TAGUNKNOWN6"'" in c["context"]]
if not c:
    print("FAIL: expected fallback #'"$TAGUNKNOWN6"' tag not found (contexts: %s)" % [x.get("context") for x in subs])
else:
    print("PASS")
' "$STATE"

post_event "{\"hook_event_name\":\"SubagentStop\",\"session_id\":\"$SID_UNKNOWN\",\"cwd\":\"$CWD_NAME\",\"agent_id\":\"agentunknown15\",\"last_assistant_message\":\"done\"}"
sleep 0.3

# --- 16. Brand-new session: history.jsonl catches up *after* the first event
# for it, so its name must appear on a later event rather than being cached as
# a permanent miss. ---
post_event "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Task\",\"session_id\":\"$SID_LATE\",\"cwd\":\"$CWD_NAME\",\"tool_input\":{\"description\":\"e2e late subagent\",\"subagent_type\":\"general-purpose\"}}"
post_event "{\"hook_event_name\":\"SubagentStart\",\"session_id\":\"$SID_LATE\",\"cwd\":\"$CWD_NAME\",\"agent_id\":\"agentlate16\",\"agent_type\":\"general-purpose\"}"
sleep 0.5

STATE=$(get_state)
assert "16a. Not-yet-in-history session initially falls back to #tag" '
subs=s["subagentTasks"]
c=[c for c in subs if c.get("context") and "#'"$TAGLATE6"'" in c["context"]]
if not c:
    print("FAIL: expected fallback #'"$TAGLATE6"' tag not found (contexts: %s)" % [x.get("context") for x in subs])
else:
    print("PASS")
' "$STATE"

# The "prompt" for this session lands in history.jsonl only now, simulating
# Claude Code's async append happening after the pet's first hook event.
python3 - "$TMP_HISTORY" "$SID_LATE" <<'PYEOF'
import json, sys
path, sid = sys.argv[1], sys.argv[2]
with open(path, "a") as f:
    f.write(json.dumps({
        "display": "Investigate the flaky network retry logic",
        "pastedContents": {}, "timestamp": 2000, "project": "/tmp/e2ename", "sessionId": sid,
    }) + "\n")
PYEOF

post_event "{\"hook_event_name\":\"SubagentStop\",\"session_id\":\"$SID_LATE\",\"cwd\":\"$CWD_NAME\",\"agent_id\":\"agentlate16\",\"last_assistant_message\":\"done\"}"
post_event "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Task\",\"session_id\":\"$SID_LATE\",\"cwd\":\"$CWD_NAME\",\"tool_input\":{\"description\":\"e2e late subagent 2\",\"subagent_type\":\"general-purpose\"}}"
post_event "{\"hook_event_name\":\"SubagentStart\",\"session_id\":\"$SID_LATE\",\"cwd\":\"$CWD_NAME\",\"agent_id\":\"agentlate16b\",\"agent_type\":\"general-purpose\"}"
sleep 0.5

STATE=$(get_state)
assert "16b. Once history.jsonl catches up, a later event resolves the real name (miss was not cached permanently)" '
subs=s["subagentTasks"]
c=[c for c in subs if c.get("context") and "Investigate the flaky" in (c["context"] or "")]
if not c:
    print("FAIL: expected resolved name not found (contexts: %s)" % [x.get("context") for x in subs])
else:
    print("PASS")
' "$STATE"

post_event "{\"hook_event_name\":\"SubagentStop\",\"session_id\":\"$SID_LATE\",\"cwd\":\"$CWD_NAME\",\"agent_id\":\"agentlate16b\",\"last_assistant_message\":\"done\"}"
sleep 0.3

restore_config

# ============================================================================
# TEST 17 — Stop/SessionEnd clear cards PER SESSION, not globally (the core
# fix in this pass: the old `clearRunning()` wiped EVERY running card
# regardless of which session's hook fired it).
# ============================================================================
SESS17_A="stopscopeA00000000000000000000018"
SESS17_B="stopscopeB00000000000000000000019"
CWD17="/tmp/e2estopscope"

post_event "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"session_id\":\"$SESS17_A\",\"cwd\":\"$CWD17\",\"tool_input\":{\"description\":\"e2e-17-cardA\",\"command\":\"echo a\"}}"
post_event "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"session_id\":\"$SESS17_B\",\"cwd\":\"$CWD17\",\"tool_input\":{\"description\":\"e2e-17-cardB\",\"command\":\"echo b\"}}"
sleep 0.4

STATE=$(get_state)
assert "17a. Both sessions' cards exist before Stop, each stamped with its own sessionId" '
run=s["runningTasks"]
a=title_has(run, "e2e-17-cardA")
b=title_has(run, "e2e-17-cardB")
if not a or not b:
    print("FAIL: expected both cards present before Stop (got titles: %s)" % [c.get("title") for c in run])
elif a[0].get("sessionId") != "'"$SESS17_A"'" or b[0].get("sessionId") != "'"$SESS17_B"'":
    print("FAIL: cards not stamped with the right sessionId (a=%r b=%r)" % (a[0].get("sessionId"), b[0].get("sessionId")))
else:
    print("PASS")
' "$STATE"

# Stop session A only. Session B'"'"'s card must survive untouched.
post_event "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SESS17_A\",\"cwd\":\"$CWD17\",\"last_assistant_message\":\"a done\"}"
sleep 0.4

STATE=$(get_state)
assert "17b. Stop(session A) clears A's card but leaves B's card untouched" '
run=s["runningTasks"]
a=title_has(run, "e2e-17-cardA")
b=title_has(run, "e2e-17-cardB")
if a:
    print("FAIL: session A'"'"'s card is still present after its own Stop: %s" % [c.get("title") for c in a])
elif not b:
    print("FAIL: session B'"'"'s card was wrongly removed by session A'"'"'s Stop (got titles: %s)" % [c.get("title") for c in run])
else:
    print("PASS")
' "$STATE"

# SessionEnd session B: its own card (a fresh one, then a rebuild) must clear;
# a sibling session C'"'"'s card must again survive.
SESS17_C="stopscopeC00000000000000000000020"
post_event "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"session_id\":\"$SESS17_B\",\"cwd\":\"$CWD17\",\"tool_input\":{\"description\":\"e2e-17-cardB2\",\"command\":\"echo b2\"}}"
post_event "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"session_id\":\"$SESS17_C\",\"cwd\":\"$CWD17\",\"tool_input\":{\"description\":\"e2e-17-cardC\",\"command\":\"echo c\"}}"
sleep 0.4
post_event "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$SESS17_B\",\"cwd\":\"$CWD17\"}"
sleep 0.4

STATE=$(get_state)
assert "17c. SessionEnd(session B) clears B's card but leaves sibling session C's card untouched" '
run=s["runningTasks"]
b=title_has(run, "e2e-17-cardB2")
c=title_has(run, "e2e-17-cardC")
if b:
    print("FAIL: session B'"'"'s card is still present after its own SessionEnd: %s" % [c.get("title") for c in b])
elif not c:
    print("FAIL: session C'"'"'s card was wrongly removed by session B'"'"'s SessionEnd (got titles: %s)" % [c.get("title") for c in run])
else:
    print("PASS")
' "$STATE"
post_event "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$SESS17_C\",\"cwd\":\"$CWD17\"}"

# ============================================================================
# TEST 18 — Mood aggregate priority (asking > working): session A working +
# session B asking (a real blocking /ask, not just a Notification) must
# aggregate to "asking" -- the single highest-priority mood wins over
# last-writer-wins. Resolving B'"'"'s ask (via the test-only /debug/resolveAsk
# route -- there is no other HTTP way to drive a real Allow/Deny, see
# HookServer.handleDebugResolveAsk) drops it back to "working" (session A'"'"'s
# mood), proving the aggregate recomputes on resolve too.
#
# "asking" is the TOP priority in `moodPriority`, so asserting the aggregate
# equals "asking" the moment B'"'"'s ask is posted is robust even if this dev
# machine has other real Claude Code sessions active concurrently -- any
# session asking forces the aggregate to "asking" regardless of what else is
# going on. The post-resolve "working" assertion is skipped (not failed) if
# some OTHER ask is still pending at that point, since that's a real
# concurrent asker this test can't control for.
# ============================================================================
drain_all_asks # ensure the queue starts empty so B's ask is the only/head one
MOOD_A_SID="moodaggA0000000000000000000000021"
MOOD_B_SID="moodaggB0000000000000000000000022"
CWD18="/tmp/e2emoodagg"

post_event "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"session_id\":\"$MOOD_A_SID\",\"cwd\":\"$CWD18\",\"tool_input\":{\"description\":\"e2e-18-A\",\"command\":\"echo a\"}}"
sleep 0.3

ASK18_PAYLOAD="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"session_id\":\"$MOOD_B_SID\",\"cwd\":\"$CWD18\",\"tool_input\":{\"description\":\"e2e-18-B\",\"command\":\"echo b\"}}"
curl -s -m 15 -X POST "$BASE/ask" -H "X-Pet-Token: $TOKEN" -H "Content-Type: application/json" \
    --data-binary "$ASK18_PAYLOAD" >/tmp/e2e_ask18_$$.out 2>&1 &
ASK18_PID=$!
sleep 0.6

STATE=$(get_state)
assert "18a. Session A working + session B asking (real /ask) aggregates to \"asking\"" '
if s["mood"] != "asking":
    print("FAIL: expected aggregate mood \"asking\" while an ask is pending, got %r" % s["mood"])
else:
    print("PASS")
' "$STATE"

curl -s -m 5 -X POST "$BASE/debug/resolveAsk" -H "X-Pet-Token: $TOKEN" -H "Content-Type: application/json" \
    --data-binary '"'"'{"decision":"allow"}'"'"' >/dev/null 2>&1
wait "$ASK18_PID" 2>/dev/null
sleep 0.4

STATE=$(get_state)
assert "18b. Resolving B's ask drops aggregate back to \"working\" (session A's mood)" '
if s["pendingAskCount"] > 0:
    print("SKIP: another ask is pending concurrently (KNOWN LIMITATION on a shared dev machine); cannot assert cleanly")
elif s["mood"] != "working":
    print("FAIL: expected aggregate mood \"working\" after B'"'"'s ask resolved, got %r" % s["mood"])
else:
    print("PASS")
' "$STATE"
post_event "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$MOOD_A_SID\",\"cwd\":\"$CWD18\"}"
post_event "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$MOOD_B_SID\",\"cwd\":\"$CWD18\"}"
rm -f /tmp/e2e_ask18_$$.out

# ============================================================================
# TEST 19 — pendingAsk is now a FIFO QUEUE: a second ask arriving while one is
# already shown must queue behind it, not replace it (the old single-slot bug:
# ask #2 silently overwrote ask #1, leaving its hook blocked until its own
# script-side timeout denied it). Verified end-to-end via the real /ask route
# plus the test-only /debug/resolveAsk route (see TEST 18'"'"'s doc comment for
# why that route exists).
# ============================================================================
drain_all_asks # ensure the queue starts empty so ordering below is unambiguous
Q_SID_1="queueask100000000000000000000023"
Q_SID_2="queueask200000000000000000000024"
CWD19="/tmp/e2easkqueue"

ASK19_1="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"session_id\":\"$Q_SID_1\",\"cwd\":\"$CWD19\",\"tool_input\":{\"file_path\":\"/tmp/e2e-queue-1.txt\"}}"
ASK19_2="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"session_id\":\"$Q_SID_2\",\"cwd\":\"$CWD19\",\"tool_input\":{\"file_path\":\"/tmp/e2e-queue-2.txt\"}}"

curl -s -m 15 -X POST "$BASE/ask" -H "X-Pet-Token: $TOKEN" -H "Content-Type: application/json" \
    --data-binary "$ASK19_1" >/tmp/e2e_ask19_1_$$.out 2>&1 &
ASK19_PID1=$!
sleep 0.5
curl -s -m 15 -X POST "$BASE/ask" -H "X-Pet-Token: $TOKEN" -H "Content-Type: application/json" \
    --data-binary "$ASK19_2" >/tmp/e2e_ask19_2_$$.out 2>&1 &
ASK19_PID2=$!
sleep 0.5

STATE=$(get_state)
assert "19a. Second ask queues behind the first instead of replacing it (pendingAskCount==2, first shown)" '
if s["pendingAskCount"] < 2:
    print("FAIL: expected pendingAskCount >= 2 with two asks pending, got %d" % s["pendingAskCount"])
elif s.get("pendingAskSessionId") != "'"$Q_SID_1"'":
    print("FAIL: expected the FIRST ask (session '"$Q_SID_1"') to be the one currently shown, got %r" % s.get("pendingAskSessionId"))
else:
    print("PASS")
' "$STATE"

# Resolve the first (currently shown) ask -> the second must become current.
curl -s -m 5 -X POST "$BASE/debug/resolveAsk" -H "X-Pet-Token: $TOKEN" -H "Content-Type: application/json" \
    --data-binary '"'"'{"decision":"allow"}'"'"' >/dev/null 2>&1
wait "$ASK19_PID1" 2>/dev/null
sleep 0.4

STATE=$(get_state)
assert "19b. Resolving the shown ask presents the queued one next, in FIFO order" '
if s.get("pendingAskSessionId") != "'"$Q_SID_2"'":
    print("FAIL: expected the SECOND ask (session '"$Q_SID_2"') to now be shown, got %r" % s.get("pendingAskSessionId"))
else:
    print("PASS")
' "$STATE"

curl -s -m 5 -X POST "$BASE/debug/resolveAsk" -H "X-Pet-Token: $TOKEN" -H "Content-Type: application/json" \
    --data-binary '"'"'{"decision":"allow"}'"'"' >/dev/null 2>&1
wait "$ASK19_PID2" 2>/dev/null
sleep 0.3

STATE=$(get_state)
assert "19c. Queue drains completely once both asks are resolved" '
mine = s.get("pendingAskSessionId") in ("'"$Q_SID_1"'", "'"$Q_SID_2"'")
if mine:
    print("FAIL: expected neither test ask to still be pending, got pendingAskSessionId=%r" % s.get("pendingAskSessionId"))
else:
    print("PASS")
' "$STATE"
rm -f /tmp/e2e_ask19_1_$$.out /tmp/e2e_ask19_2_$$.out

# ============================================================================
# TEST 20 — Session-name resolution FALLS BACK to reading the session's own
# transcript JSONL when the session is absent from history.jsonl entirely --
# the Claude Code DESKTOP APP's actual behaviour (verified: desktop sessions
# never get appended to history.jsonl, only CLI ones do). Root directory is
# injected via the optional `projectsRoot` config.json field (same mechanism
# as `historyPath`) so this never touches the real ~/.claude/projects.
# ============================================================================
TMP_PROJECTS_ROOT="/tmp/petmacos_e2e_projects_$$"
DESKTOP_SID="desktopsess0000000000000000000025"
DESKTOP_CWD="/tmp/e2edesktopapp$$"
# Slug rule verified against real folder names on this machine (see
# SessionNameResolver.slug'"'"'s doc comment): every non-alphanumeric char -> "-".
DESKTOP_SLUG=$(printf '%s' "$DESKTOP_CWD" | sed -E 's/[^A-Za-z0-9]/-/g')
mkdir -p "$TMP_PROJECTS_ROOT/$DESKTOP_SLUG"
DESKTOP_TRANSCRIPT="$TMP_PROJECTS_ROOT/$DESKTOP_SLUG/$DESKTOP_SID.jsonl"
# First line is noise (a task-notification injection), which must be SKIPPED;
# the second is the real first user prompt, wrapped in queue-operation/enqueue
# the way the desktop app'"'"'s transcripts actually look.
python3 - "$DESKTOP_TRANSCRIPT" <<'PYEOF'
import json, sys
path = sys.argv[1]
lines = [
    {"type": "queue-operation", "operation": "dequeue"},
    {"type": "task-notification", "content": "<task-notification>noise</task-notification>"},
    {"type": "queue-operation", "operation": "enqueue", "content": "Fix the flaky desktop upload retry bug"},
    {"type": "user", "message": {"role": "user", "content": "Fix the flaky desktop upload retry bug"}},
]
with open(path, "w") as f:
    for l in lines:
        f.write(json.dumps(l) + "\n")
PYEOF

python3 - "$CONFIG" "$TMP_PROJECTS_ROOT" <<'PYEOF'
import json, sys
path, root = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)
cfg["projectsRoot"] = root
with open(path, "w") as f:
    json.dump(cfg, f)
PYEOF
# historyPath is still pointed at TEST 14-16's fixture (which has no entry for
# DESKTOP_SID), simulating a session history.jsonl genuinely doesn'"'"'t know about.

post_event "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Task\",\"session_id\":\"$DESKTOP_SID\",\"cwd\":\"$DESKTOP_CWD\",\"tool_input\":{\"description\":\"e2e desktop-app subagent\",\"subagent_type\":\"general-purpose\"}}"
sleep 0.5

STATE=$(get_state)
assert "20. Session absent from history.jsonl resolves its name from the transcript fallback instead" '
subs=s["subagentTasks"]
c=[c for c in subs if c.get("context") and "Fix the flaky desktop" in c["context"]]
if not c:
    print("FAIL: expected transcript-resolved name not found (contexts: %s)" % [x.get("context") for x in subs])
else:
    print("PASS")
' "$STATE"

post_event "{\"hook_event_name\":\"SubagentStop\",\"session_id\":\"$DESKTOP_SID\",\"cwd\":\"$DESKTOP_CWD\",\"last_assistant_message\":\"done\"}"
rm -rf "$TMP_PROJECTS_ROOT"
restore_config

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
