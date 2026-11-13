#!/bin/sh
# Claude Code hook: records this WezTerm pane's session state in
# <state dir>/<WEZTERM_PANE>.json. Never fails loudly: always exits 0.

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib/git-info.sh"

# Play a sound file. Runs detached so a slow player never delays Claude; an
# empty file name disables it, SESSION_TRACKER_PLAYER swaps afplay.
play_sound() {
  sound=$1
  [ -n "$sound" ] || return 0
  player=${SESSION_TRACKER_PLAYER:-afplay}
  command -v "$player" >/dev/null 2>&1 || return 0
  ( "$player" "$sound" </dev/null >/dev/null 2>&1 & )
}

main() {
  [ -n "${WEZTERM_PANE:-}" ] || return 0
  input=$(cat) || return 0

  # Unit separator is a non-whitespace IFS, so empty fields survive `read`.
  us=$(printf '\037')
  fields=$(printf '%s' "$input" | jq -r \
    '[.hook_event_name // "", .session_id // "", .cwd // "", .notification_type // "", .agent_id // "", .tool_name // ""] | join("\u001f")' \
    2>/dev/null) || return 0
  IFS=$us read -r event sid cwd ntype agent tool <<EOF
$fields
EOF
  [ -n "$event" ] || return 0
  # Subagent tool events must not revive a stopped pane, but a subagent that is
  # blocked on the user still means this pane needs them.
  if [ -n "$agent" ]; then
    case "$event" in
      PermissionRequest|Notification) ;;
      *) return 0 ;;
    esac
  fi

  case "$event" in
    PreToolUse)
      case "$tool" in
        AskUserQuestion|ExitPlanMode) state=needs-you ;;
        *) state=working ;;
      esac ;;
    UserPromptSubmit|PostToolUse|PostToolUseFailure) state=working ;;
    PermissionRequest|StopFailure) state=needs-you ;;
    Notification)
      case "$ntype" in
        permission_prompt) state=needs-you ;;
        *) return 0 ;;
      esac ;;
    Stop|SessionStart) state=idle ;;
    SessionEnd) state=end ;;
    *) return 0 ;;
  esac

  dir=${SESSION_TRACKER_STATE_DIR:-$HOME/.claude/state/panes}
  mkdir -p "$dir" 2>/dev/null || return 0
  file="$dir/$WEZTERM_PANE.json"

  if [ "$state" = end ]; then
    rm -f "$file"
    return 0
  fi

  if [ "$event" = SessionStart ]; then
    find "$dir" -maxdepth 1 -name '*.json' -mtime +7 -delete 2>/dev/null
  fi

  # Remember when the pane entered its current state: keep the old `since`
  # while the state is unchanged. A missing or corrupt old file starts fresh.
  now=$(date +%s)
  old=$(jq -r '[.state // "", (.since // "" | tostring)] | join("\u001f")' "$file" 2>/dev/null) || old=""
  IFS=$us read -r old_state old_since <<EOF
$old
EOF
  case $old_since in ''|*[!0-9]*) old_since= ;; esac
  since=$now
  [ "$old_state" = "$state" ] && [ -n "$old_since" ] && since=$old_since

  repo=$(git_repo_name "$cwd")
  branch=$(git_branch "$cwd")
  tmp=$(mktemp "$dir/.tmp.XXXXXX" 2>/dev/null) || return 0
  if jq -n --arg state "$state" --arg repo "$repo" \
       --arg branch "$branch" --arg cwd "$cwd" --arg sid "$sid" \
       --arg ts "$now" --arg since "$since" \
       '{state:$state, repo:$repo, branch:$branch, cwd:$cwd, session_id:$sid, ts:($ts|tonumber), since:($since|tonumber)}' \
       > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi

  [ "$event" = Stop ] && play_sound "${SESSION_TRACKER_SOUND-/System/Library/Sounds/Ping.aiff}"
  # Only the move into needs-you rings: a PermissionRequest and the Notification
  # for the same prompt must not ring twice.
  if [ "$state" = needs-you ] && [ "$old_state" != needs-you ]; then
    play_sound "${SESSION_TRACKER_SOUND_NEEDS-/System/Library/Sounds/Glass.aiff}"
  fi
}

main
exit 0
