#!/bin/sh
# UserPromptSubmit hook: every prompt, restate ultracave + basic English. If
# ultracave-check.sh flagged the last reply of this session (a rewrite also
# failed), say why once. Always exits 0.

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0
dir=${SESSION_TRACKER_ULTRACAVE_DIR:-$HOME/.claude/state/ultracave}
flag="$dir/$sid"
# New prompt restarts the tool-call counter of ultracave-nudge.sh.
rm -f "$flag.n" 2>/dev/null
base="Ultracave + basic English, every reply: short fragments or short simple sentences, common everyday words, no rare word when a common one works, no articles, no filler. Code and technical terms exact."
c="$base"
if [ -f "$flag" ]; then
  why=$(cat "$flag" 2>/dev/null)
  rm -f "$flag"
  c="Your last reply broke ultracave ($why). $base"
fi
jq -n --arg c "$c" \
  '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
exit 0
