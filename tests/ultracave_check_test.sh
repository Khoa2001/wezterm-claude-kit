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

FILLER="Sure! I'd be happy to help you with that. The issue is that the token expiry check in the auth middleware uses the wrong operator, so the request is rejected before the handler ever runs."

test_blocks_filler_reply_once() {
  reset
  out=$(run_hook "$FILLER")
  assert_eq "block decision" block "$(printf '%s' "$out" | jq -r .decision)"
  assert_contains "reason has counts" "$(printf '%s' "$out" | jq -r .reason)" "filler="
  assert_file_missing "no flag on first block" "$(flag)"
}

test_second_failure_flags_without_blocking() {
  reset
  out=$(run_hook "$FILLER" true)
  assert_eq "prints nothing" "" "$out"
  assert_file_exists "flag written" "$(flag)"
  assert_contains "flag has counts" "$(cat "$(flag)")" "filler="
}

test_remind_always_injects_and_clears_flag() {
  reset
  out=$(printf '{"session_id":"s1"}' | sh "$REMIND")
  assert_contains "base rule" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)" "basic English"
  run_hook "$FILLER" true >/dev/null
  out=$(printf '{"session_id":"s1"}' | sh "$REMIND")
  assert_contains "why injected" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)" "broke ultracave"
  assert_file_missing "flag cleared" "$(flag)"
  out=$(printf '{"session_id":"s1"}' | sh "$REMIND")
  case "$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)" in
    *"broke ultracave"*) assert_eq "second prompt has no why" ok bad ;;
    *) assert_eq "second prompt has no why" ok ok ;;
  esac
}

test_remind_silent_without_session() {
  assert_eq "no session" "" "$(printf '{}' | sh "$REMIND")"
  printf 'garbage' | sh "$REMIND"; assert_eq "exit 0" 0 "$?"
}

test_blocks_banned_word() {
  out=$(run_hook "Fix: we should utilize the existing helper here. Change operator, rerun tests, check output once more, then commit it to branch and push it. Open PR after that, then wait for review, then merge it when all checks pass.")
  assert_eq "block decision" block "$(printf '%s' "$out" | jq -r .decision)"
  assert_contains "names the word" "$(printf '%s' "$out" | jq -r .reason)" "utilize"
}

test_blocks_many_hard_words() {
  out=$(run_hook "Subsystem misconfiguration produced serialization anomalies throughout orchestration infrastructure. Reconciliation requires instrumentation. Rerun pipeline, check output once more, then commit it to branch and push it. Open PR after that, then wait for review and merge it.")
  assert_eq "block decision" block "$(printf '%s' "$out" | jq -r .decision)"
  assert_contains "lists hard words" "$(printf '%s' "$out" | jq -r .reason)" "hard words"
}

test_one_odd_name_is_fine() {
  assert_eq "no output" "" "$(run_hook "Bug in auth middleware. Token expiry check use < not <=. Run sysdiagnose first. Change operator, rerun tests, then commit fix to branch.")"
}

test_ignores_paths_and_code_words() {
  assert_eq "no output" "" "$(run_hook "Edit hooks/ultracavecheckerimplementation.sh and \`serializationconfiguration\` then rerun. Test pass, commit fix to branch, push it, open PR, done now, thanks.")"
}

test_skips_non_english() {
  assert_eq "no output" "" "$(run_hook "Đã sửa xong lỗi trong bộ lọc, chạy lại bài kiểm tra và tất cả đều đạt. Bạn có thể xem kết quả ở thư mục dự án, serializationconfiguration infrastructure orchestration.")"
}

test_passes_terse_reply() {
  reset
  assert_eq "no output" "" "$(run_hook "Bug in auth middleware. Token expiry check use < not <=. Fix: change operator, rerun tests.")"
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

for t in test_nudge_fires_every_nth_call_and_remind_resets test_nudge_silent_without_session_and_exits_zero test_blocks_filler_reply_once test_second_failure_flags_without_blocking test_remind_always_injects_and_clears_flag test_remind_silent_without_session test_blocks_banned_word test_blocks_many_hard_words test_one_odd_name_is_fine test_ignores_paths_and_code_words test_skips_non_english test_passes_terse_reply \
  test_skips_questions_and_short_replies test_ignores_code_blocks test_prefers_last_assistant_message_over_stale_transcript test_exits_zero_on_bad_input; do
  ( "$t" )
done
finish
