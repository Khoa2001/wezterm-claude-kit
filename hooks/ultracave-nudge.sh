#!/bin/sh
# PostToolUse hook: long tool-heavy turns drift out of ultracave because the
# UserPromptSubmit reminder is far behind. Every Nth tool call of a session,
# inject one short reminder. Counter resets on each prompt (ultracave-remind.sh).
# Always exits 0.

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0
every=${SESSION_TRACKER_ULTRACAVE_EVERY:-8}
dir=${SESSION_TRACKER_ULTRACAVE_DIR:-$HOME/.claude/state/ultracave}
mkdir -p "$dir" 2>/dev/null || exit 0
counter="$dir/$sid.n"

n=$(cat "$counter" 2>/dev/null)
n=$(( ${n:-0} + 1 ))
if [ "$n" -lt "$every" ]; then
  printf '%s' "$n" > "$counter" 2>/dev/null
  exit 0
fi
printf '0' > "$counter" 2>/dev/null
jq -n --arg c "Reminder: ultracave still on. Text between tool calls and final report: fragments, no articles, no filler, no pleasantries. Code, commits, docs stay normal." \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
exit 0
