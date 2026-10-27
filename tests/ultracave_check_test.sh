#!/bin/sh
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
HOOK="$HERE/../hooks/ultracave-check.sh"
REMIND="$HERE/../hooks/ultracave-remind.sh"
export SESSION_TRACKER_ULTRACAVE_DIR=$(new_tmp)

# run_hook TEXT [ACTIVE] -> hook stdout; builds a one-message transcript.
# Session s1 is flagged when the hook judges TEXT not ultracave.
run_hook() {
  d=$(new_tmp)
  jq -nc --arg t "$1" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}' > "$d/t.jsonl"
  printf '{"session_id":"s1","transcript_path":"%s/t.jsonl","stop_hook_active":%s}' "$d" "${2:-false}" | sh "$HOOK"
}

flag() { echo "$SESSION_TRACKER_ULTRACAVE_DIR/s1"; }
reset() { rm -f "$(flag)"; }

test_flags_filler_reply_without_blocking() {
  reset
  out=$(run_hook "Sure! I'd be happy to help you with that. The issue is that the token expiry check in the auth middleware uses the wrong operator, so the request is rejected before the handler ever runs.")
  assert_eq "prints nothing" "" "$out"
  assert_file_exists "flag written" "$(flag)"
  assert_contains "flag has counts" "$(cat "$(flag)")" "filler="
}

test_remind_injects_once_and_clears_flag() {
  reset
  run_hook "Sure! I'd be happy to help you with that. The issue is that the token expiry check in the auth middleware uses the wrong operator, so the request is rejected before the handler ever runs." >/dev/null
  out=$(printf '{"session_id":"s1"}' | sh "$REMIND")
  assert_contains "context injected" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)" "broke ultracave"
  assert_file_missing "flag cleared" "$(flag)"
  assert_eq "second prompt silent" "" "$(printf '{"session_id":"s1"}' | sh "$REMIND")"
}

test_remind_silent_without_flag_or_session() {
  reset
  assert_eq "no flag" "" "$(printf '{"session_id":"s1"}' | sh "$REMIND")"
  assert_eq "no session" "" "$(printf '{}' | sh "$REMIND")"
  printf 'garbage' | sh "$REMIND"; assert_eq "exit 0" 0 "$?"
}

test_passes_terse_reply() {
  reset
  assert_eq "no output" "" "$(run_hook "Bug in auth middleware. Token expiry check use < not <=. Fix: change operator, rerun tests.")"
}

test_skips_when_stop_hook_active() {
  assert_eq "no output" "" "$(run_hook "Sure! I'd be happy to help you with that. The issue is that the token expiry check uses the wrong operator." true)"
}

test_skips_questions_and_short_replies() {
  assert_eq "question" "" "$(run_hook "Which settings file should the hook go into, the user one or the project one for this repo, and why would you prefer it?")"
  assert_eq "short" "" "$(run_hook "Sure, done.")"
  assert_eq "21 words, 2 articles" "" "$(run_hook "Shipped: PR merged into main. Remote branch deleted. Local branch kept. Commits e8d3f8f and 2353352 are in the history of the repo.")"
}

test_ignores_code_blocks() {
  assert_eq "code ignored" "" "$(run_hook "Fix applied. Run:
\`\`\`
echo just the thing is really basically fine
\`\`\`
Tests pass.")"
}

test_prefers_last_assistant_message_over_stale_transcript() {
  d=$(new_tmp)
  jq -nc '{type:"assistant",message:{content:[{type:"text",text:"Sure! I would be happy to help you with that. The issue is that the token expiry check in the auth middleware uses the wrong operator, so the request is rejected before the handler ever runs."}]}}' > "$d/t.jsonl"
  out=$(printf '{"transcript_path":"%s/t.jsonl","last_assistant_message":"Fix applied. Tests pass."}' "$d" | sh "$HOOK")
  assert_eq "terse payload wins" "" "$out"
}

test_exits_zero_on_bad_input() {
  printf 'garbage' | sh "$HOOK"; assert_eq "exit 0" 0 "$?"
  printf '{"transcript_path":"/nope"}' | sh "$HOOK"; assert_eq "exit 0 missing file" 0 "$?"
}

NUDGE="$HERE/../hooks/ultracave-nudge.sh"

test_nudge_fires_every_nth_call_and_remind_resets() {
  reset; rm -f "$SESSION_TRACKER_ULTRACAVE_DIR/s1.n"
  export SESSION_TRACKER_ULTRACAVE_EVERY=3
  assert_eq "call 1 silent" "" "$(printf '{"session_id":"s1"}' | sh "$NUDGE")"
  assert_eq "call 2 silent" "" "$(printf '{"session_id":"s1"}' | sh "$NUDGE")"
  out=$(printf '{"session_id":"s1"}' | sh "$NUDGE")
  assert_contains "call 3 nudges" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)" "ultracave still on"
  assert_eq "event name" PostToolUse "$(printf '%s' "$out" | jq -r .hookSpecificOutput.hookEventName)"
  printf '{"session_id":"s1"}' | sh "$NUDGE" >/dev/null
  printf '{"session_id":"s1"}' | sh "$REMIND" >/dev/null
  assert_file_missing "prompt resets counter" "$SESSION_TRACKER_ULTRACAVE_DIR/s1.n"
  unset SESSION_TRACKER_ULTRACAVE_EVERY
}

test_nudge_silent_without_session_and_exits_zero() {
  assert_eq "no session" "" "$(printf '{}' | sh "$NUDGE")"
  printf 'garbage' | sh "$NUDGE"; assert_eq "exit 0" 0 "$?"
}

for t in test_nudge_fires_every_nth_call_and_remind_resets test_nudge_silent_without_session_and_exits_zero test_flags_filler_reply_without_blocking test_remind_injects_once_and_clears_flag test_remind_silent_without_flag_or_session test_passes_terse_reply test_skips_when_stop_hook_active \
  test_skips_questions_and_short_replies test_ignores_code_blocks test_prefers_last_assistant_message_over_stale_transcript test_exits_zero_on_bad_input; do
  ( "$t" )
done
finish
