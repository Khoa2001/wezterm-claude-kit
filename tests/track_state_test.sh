#!/bin/sh
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
HOOK="$HERE/../hooks/track-state.sh"

# Never play real sounds from tests; sound tests opt in.
export SESSION_TRACKER_SOUND="" SESSION_TRACKER_SOUND_NEEDS=""

# fire EVENT [EXTRA_JSON_FIELDS]
# Pipes a hook payload into the hook. Uses $SD as state dir, $CWD (default $PWD),
# pane 7 unless NOPANE is set.
fire() {
  ev=$1
  extra=${2:+,$2}
  payload=$(printf '{"hook_event_name":"%s","session_id":"s1","cwd":"%s"%s}' "$ev" "${CWD:-$PWD}" "$extra")
  if [ -n "${NOPANE:-}" ]; then
    printf '%s' "$payload" | env -u WEZTERM_PANE SESSION_TRACKER_STATE_DIR="$SD" sh "$HOOK"
  else
    printf '%s' "$payload" | WEZTERM_PANE=7 SESSION_TRACKER_STATE_DIR="$SD" sh "$HOOK"
  fi
}

state() { jq -r .state "$SD/7.json" 2>/dev/null; }

test_maps_working_events() {
  SD=$(new_tmp)
  for ev in UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure; do
    fire "$ev"
    assert_eq "working: $ev" working "$(state)"
  done
}

test_maps_needs_you_events() {
  SD=$(new_tmp)
  fire PermissionRequest;  assert_eq "needs-you: PermissionRequest" needs-you "$(state)"
  fire Stop;               fire StopFailure
  assert_eq "needs-you: StopFailure" needs-you "$(state)"
  fire Stop;               fire Notification '"notification_type":"permission_prompt"'
  assert_eq "needs-you: Notification permission_prompt" needs-you "$(state)"
}

test_notification_other_type_keeps_state() {
  SD=$(new_tmp)
  fire Stop
  fire Notification '"notification_type":"auth_success"'
  assert_eq "other notification keeps idle" idle "$(state)"
}

test_stop_and_sessionstart_are_idle() {
  SD=$(new_tmp)
  fire PreToolUse; fire Stop
  assert_eq "Stop is idle" idle "$(state)"
  fire PreToolUse; fire SessionStart
  assert_eq "SessionStart is idle" idle "$(state)"
}

test_sessionend_removes_file() {
  SD=$(new_tmp)
  fire Stop
  fire SessionEnd
  assert_file_missing "SessionEnd removes file" "$SD/7.json"
}

test_subagent_event_ignored_after_stop() {
  SD=$(new_tmp)
  fire Stop
  fire PreToolUse '"agent_id":"a1"'
  assert_eq "subagent tool event does not revive" idle "$(state)"
}

test_no_wezterm_pane_is_noop() {
  SD=$(new_tmp)
  out=$(NOPANE=1 fire Stop 2>&1); rc=$?
  assert_eq "exit 0 without pane" 0 "$rc"
  assert_eq "no output without pane" "" "$out"
  assert_eq "no files without pane" 0 "$(ls -A "$SD" | wc -l | tr -d ' ')"
}

test_invalid_json_is_noop() {
  SD=$(new_tmp)
  printf 'not json' | WEZTERM_PANE=7 SESSION_TRACKER_STATE_DIR="$SD" sh "$HOOK"
  assert_eq "exit 0 on bad json" 0 "$?"
  assert_file_missing "no file on bad json" "$SD/7.json"
  printf '' | WEZTERM_PANE=7 SESSION_TRACKER_STATE_DIR="$SD" sh "$HOOK"
  assert_eq "exit 0 on empty stdin" 0 "$?"
}

test_unwritable_dir_exits_zero() {
  base=$(new_tmp)
  : > "$base/afile"
  SD="$base/afile"
  fire Stop
  assert_eq "exit 0 when dir is a file" 0 "$?"
}

test_non_git_cwd_has_empty_repo_and_branch() {
  SD=$(new_tmp)
  CWD=$(new_tmp)
  fire Stop
  assert_eq "repo empty" "" "$(jq -r .repo "$SD/7.json")"
  assert_eq "branch empty" "" "$(jq -r .branch "$SD/7.json")"
}

test_worktree_reports_main_repo_and_own_branch() {
  SD=$(new_tmp)
  root=$(new_tmp)
  git init -q -b main "$root/api"
  git -C "$root/api" commit -q --allow-empty -m init
  git -C "$root/api" worktree add -q -b feat/x "$root/wt"
  CWD="$root/wt"
  fire Stop
  assert_eq "worktree repo is main repo name" api "$(jq -r .repo "$SD/7.json")"
  assert_eq "worktree branch" feat/x "$(jq -r .branch "$SD/7.json")"
}

test_sessionstart_prunes_files_older_than_7_days() {
  SD=$(new_tmp)
  echo '{}' > "$SD/99.json"
  touch -t "$(date -v-10d +%Y%m%d%H%M)" "$SD/99.json"
  echo '{}' > "$SD/98.json"
  fire SessionStart
  assert_file_missing "old file pruned" "$SD/99.json"
  assert_file_exists "fresh other file kept" "$SD/98.json"
}

test_output_is_always_valid_json() {
  SD=$(new_tmp)
  for ev in UserPromptSubmit PermissionRequest Stop SessionStart; do
    fire "$ev"
    jq empty "$SD/7.json" 2>/dev/null
    assert_eq "valid json after $ev" 0 "$?"
  done
}

test_state_file_has_expected_fields() {
  SD=$(new_tmp)
  fire Stop
  assert_eq "state file keys" "branch,cwd,repo,session_id,since,state,ts" "$(jq -r 'keys | join(",")' "$SD/7.json")"
  assert_eq "ts is a number" number "$(jq -r '.ts | type' "$SD/7.json")"
}

test_idle_prompt_keeps_idle() {
  SD=$(new_tmp)
  fire Stop
  fire Notification '"notification_type":"idle_prompt"'
  assert_eq "idle_prompt does not turn a finished pane red" idle "$(state)"
}

test_subagent_permission_request_needs_you() {
  SD=$(new_tmp)
  fire PreToolUse
  fire PermissionRequest '"agent_id":"a1"'
  assert_eq "subagent permission prompt is needs-you" needs-you "$(state)"
}

test_subagent_notification_needs_you() {
  SD=$(new_tmp)
  fire PreToolUse
  fire Notification '"agent_id":"a1","notification_type":"permission_prompt"'
  assert_eq "subagent notification is needs-you" needs-you "$(state)"
}

test_question_tools_are_needs_you() {
  SD=$(new_tmp)
  for tool in AskUserQuestion ExitPlanMode; do
    fire PreToolUse "\"tool_name\":\"$tool\""
    assert_eq "PreToolUse $tool is needs-you" needs-you "$(state)"
    fire PostToolUse "\"tool_name\":\"$tool\""
    assert_eq "PostToolUse $tool is working again" working "$(state)"
  done
  fire PreToolUse '"tool_name":"Bash"'
  assert_eq "ordinary tool is working" working "$(state)"
}

# fake_player DIR -> writes DIR/player (logs its args to DIR/played) and prints its path
fake_player() {
  printf '#!/bin/sh\necho "$@" >> "%s/played"\n' "$1" > "$1/player"
  chmod +x "$1/player"
  echo "$1/player"
}

# wait_for PATH -> true once PATH exists (up to ~3s)
wait_for() {
  i=0
  while [ "$i" -lt 30 ]; do
    [ -e "$1" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

test_stop_plays_the_configured_sound() {
  SD=$(new_tmp); P=$(new_tmp)
  export SESSION_TRACKER_PLAYER=$(fake_player "$P") SESSION_TRACKER_SOUND=/x/done.aiff
  fire Stop
  wait_for "$P/played"
  assert_eq "player got the sound file" "/x/done.aiff" "$(cat "$P/played" 2>/dev/null)"
}

test_default_sound_is_ping() {
  SD=$(new_tmp); P=$(new_tmp)
  export SESSION_TRACKER_PLAYER=$(fake_player "$P")
  unset SESSION_TRACKER_SOUND
  fire Stop
  wait_for "$P/played"
  assert_eq "default sound" "/System/Library/Sounds/Ping.aiff" "$(cat "$P/played" 2>/dev/null)"
}

test_only_stop_plays_a_sound() {
  SD=$(new_tmp); P=$(new_tmp)
  export SESSION_TRACKER_PLAYER=$(fake_player "$P") SESSION_TRACKER_SOUND=/x/done.aiff
  for ev in UserPromptSubmit PreToolUse PostToolUse PermissionRequest StopFailure SessionStart SessionEnd; do
    fire "$ev"
  done
  fire Stop '"agent_id":"a1"'
  sleep 0.5
  assert_file_missing "no sound for other events or subagents" "$P/played"
}

test_empty_sound_disables_it() {
  SD=$(new_tmp); P=$(new_tmp)
  export SESSION_TRACKER_PLAYER=$(fake_player "$P") SESSION_TRACKER_SOUND=""
  fire Stop
  sleep 0.5
  assert_file_missing "disabled" "$P/played"
}

test_missing_player_is_harmless() {
  SD=$(new_tmp)
  export SESSION_TRACKER_PLAYER=/nonexistent/player SESSION_TRACKER_SOUND=/x/done.aiff
  fire Stop
  assert_eq "exit 0" 0 "$?"
  assert_eq "state still written" idle "$(state)"
}

test_slow_player_does_not_block_the_hook() {
  SD=$(new_tmp); P=$(new_tmp)
  printf '#!/bin/sh\nsleep 3\n' > "$P/slow"; chmod +x "$P/slow"
  export SESSION_TRACKER_PLAYER="$P/slow" SESSION_TRACKER_SOUND=/x/done.aiff
  start=$(date +%s)
  fire Stop
  elapsed=$(( $(date +%s) - start ))
  assert_eq "hook returns fast" 1 "$([ "$elapsed" -lt 2 ] && echo 1 || echo 0)"
}

# since -> prints .since of pane 7 in $SD
since() { jq -r '.since' "$SD/7.json"; }

test_since_kept_when_state_unchanged() {
  SD=$(new_tmp)
  fire UserPromptSubmit
  jq '.since = 100' "$SD/7.json" > "$SD/x" && mv "$SD/x" "$SD/7.json"
  fire PostToolUse
  assert_eq "since kept while working" 100 "$(since)"
}

test_since_reset_when_state_changes() {
  SD=$(new_tmp)
  fire UserPromptSubmit
  jq '.since = 100' "$SD/7.json" > "$SD/x" && mv "$SD/x" "$SD/7.json"
  fire PermissionRequest
  assert_eq "since reset on change" 1 "$([ "$(since)" -gt 100 ] && echo 1 || echo 0)"
}

test_since_without_old_field_is_now() {
  SD=$(new_tmp)
  fire UserPromptSubmit
  jq 'del(.since)' "$SD/7.json" > "$SD/x" && mv "$SD/x" "$SD/7.json"
  fire PostToolUse
  assert_eq "since numeric" 1 "$([ "$(since)" -gt 100 ] && echo 1 || echo 0)"
}

test_since_with_corrupt_old_file() {
  SD=$(new_tmp)
  printf '{bad' > "$SD/7.json"
  fire UserPromptSubmit; rc=$?
  assert_eq "exit 0" 0 "$rc"
  assert_eq "since numeric" 1 "$([ "$(since)" -gt 100 ] && echo 1 || echo 0)"
}

test_needs_you_sound_plays_once_per_transition() {
  SD=$(new_tmp); P=$(new_tmp)
  export SESSION_TRACKER_PLAYER=$(fake_player "$P") SESSION_TRACKER_SOUND_NEEDS=/x/need.aiff
  fire PermissionRequest
  fire Notification '"notification_type":"permission_prompt"'
  wait_for "$P/played"; sleep 0.5
  assert_eq "one needs-you sound" "/x/need.aiff" "$(cat "$P/played" 2>/dev/null)"
}

test_needs_you_sound_disabled_when_empty() {
  SD=$(new_tmp); P=$(new_tmp)
  export SESSION_TRACKER_PLAYER=$(fake_player "$P") SESSION_TRACKER_SOUND_NEEDS=""
  fire PermissionRequest
  sleep 0.5
  assert_file_missing "disabled" "$P/played"
}

test_default_needs_you_sound_is_glass() {
  SD=$(new_tmp); P=$(new_tmp)
  export SESSION_TRACKER_PLAYER=$(fake_player "$P")
  unset SESSION_TRACKER_SOUND_NEEDS
  fire PermissionRequest
  wait_for "$P/played"
  assert_eq "default needs-you sound" "/System/Library/Sounds/Glass.aiff" "$(cat "$P/played" 2>/dev/null)"
}

test_done_sound_unchanged() {
  SD=$(new_tmp); P=$(new_tmp)
  export SESSION_TRACKER_PLAYER=$(fake_player "$P") SESSION_TRACKER_SOUND=/x/done.aiff SESSION_TRACKER_SOUND_NEEDS=/x/need.aiff
  fire Stop
  wait_for "$P/played"; sleep 0.3
  assert_eq "Stop still plays done" "/x/done.aiff" "$(cat "$P/played" 2>/dev/null)"
}

for t in test_maps_working_events test_maps_needs_you_events \
  test_notification_other_type_keeps_state test_stop_and_sessionstart_are_idle \
  test_sessionend_removes_file test_subagent_event_ignored_after_stop \
  test_no_wezterm_pane_is_noop test_invalid_json_is_noop \
  test_unwritable_dir_exits_zero test_non_git_cwd_has_empty_repo_and_branch \
  test_worktree_reports_main_repo_and_own_branch \
  test_sessionstart_prunes_files_older_than_7_days \
  test_output_is_always_valid_json test_state_file_has_expected_fields \
  test_idle_prompt_keeps_idle test_subagent_permission_request_needs_you \
  test_subagent_notification_needs_you test_question_tools_are_needs_you \
  test_stop_plays_the_configured_sound test_default_sound_is_ping \
  test_only_stop_plays_a_sound test_empty_sound_disables_it \
  test_missing_player_is_harmless test_slow_player_does_not_block_the_hook \
  test_since_kept_when_state_unchanged test_since_reset_when_state_changes \
  test_since_without_old_field_is_now test_since_with_corrupt_old_file \
  test_needs_you_sound_plays_once_per_transition test_needs_you_sound_disabled_when_empty \
  test_default_needs_you_sound_is_glass test_done_sound_unchanged; do
  ( "$t" )
done
finish
