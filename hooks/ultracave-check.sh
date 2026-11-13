#!/bin/sh
# Stop hook: enforce ultracave + basic English. A reply that is padded with
# filler, full of articles or full of hard words is blocked once so Claude
# rewrites it. If the rewrite also fails (stop_hook_active), do not block again
# (no loop): write a flag file instead and hooks/ultracave-remind.sh warns on
# the next prompt. Deliberate exception to "hooks never block": this is the
# only hook that prints a block. Must always exit 0.

HERE=$(cd "$(dirname "$0")" && pwd)
input=$(cat)

active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)

# The Stop payload carries the reply itself. The transcript can lag behind at
# Stop time and still hold the previous reply, so it is only a fallback.
text=$(printf '%s' "$input" | jq -r '.last_assistant_message // empty' 2>/dev/null)
if [ -z "$text" ]; then
  transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
  [ -n "$transcript" ] && [ -f "$transcript" ] || exit 0
  text=$(jq -rs '[.[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text] | last // empty' "$transcript" 2>/dev/null)
fi
[ -n "$text" ] || exit 0

# Drop fenced code, inline code and URLs: those stay normal.
prose=$(printf '%s\n' "$text" | awk '/^```/{f=!f; next} !f' | sed -E 's/`[^`]*`//g; s#https?://[^ ]+##g' | tr 'A-Z' 'a-z')

words=$(printf '%s' "$prose" | wc -w | tr -d ' ')
[ "${words:-0}" -ge 30 ] || exit 0

# Plain prose is allowed for questions and security or irreversible warnings.
case "$prose" in
  *warning*|*irreversible*|*"security"*) exit 0 ;;
esac
printf '%s' "$prose" | tail -c 3 | grep -q '?' && exit 0

filler=$(printf '%s' "$prose" | grep -oE "\b(sure|certainly|of course|happy to|i'd be|i'll|let me know|great question|basically|actually|really|simply|just|i think|it seems|you might want|feel free|hope this helps)\b" | wc -l | tr -d ' ')
articles=$(printf '%s' "$prose" | tr -c "a-z'" '\n' | grep -cxE 'a|an|the')

# Hard words: 9+ letters and not in the common or tech list (after suffix
# stripping), or in the banned list. Paths and tokens with digits, dots, underscores or hyphens
# are skipped. Output line 1: "<checked> <hard> <banned>", line 2: hard words,
# line 3: banned words.
scan=$(printf '%s\n' "$prose" \
  | sed -E 's#[^ ]*/[^ ]*# #g; s/[.,;:!?()"]+( |$)/ /g' \
  | tr -s ' \t' '\n\n' \
  | grep -vE '[0-9_./-]' \
  | awk -v common="$HERE/words/common.txt" -v tech="$HERE/words/tech.txt" '
    BEGIN {
      while ((getline l < common) > 0) if (l !~ /^#/ && l != "") ok[l] = 1
      while ((getline l < tech) > 0) if (l !~ /^#/ && l != "") ok[l] = 1
      n = split("utilize leverage facilitate comprehensive robust idempotent heuristic subsequently furthermore moreover nevertheless consequently additionally approximately regarding methodology functionality implementation", b, " ")
      for (i = 1; i <= n; i++) ban[b[i]] = 1
    }
    function known(w,   s) {
      if (w in ok) return 1
      if (w ~ /ies$/ && ((s = substr(w, 1, length(w) - 3) "y") in ok)) return 1
      if (w ~ /(es|ed|er)$/ && (substr(w, 1, length(w) - 2) in ok)) return 1
      if (w ~ /(s|d)$/ && (substr(w, 1, length(w) - 1) in ok)) return 1
      if (w ~ /ly$/ && (substr(w, 1, length(w) - 2) in ok)) return 1
      if (w ~ /ing$/) {
        s = substr(w, 1, length(w) - 3)
        if ((s in ok) || ((s "e") in ok)) return 1
        if (length(s) > 2 && substr(s, length(s), 1) == substr(s, length(s) - 1, 1) && (substr(s, 1, length(s) - 1) in ok)) return 1
      }
      if (w ~ /ed$/) {
        s = substr(w, 1, length(w) - 2)
        if ((s "e") in ok) return 1
        if (length(s) > 2 && substr(s, length(s), 1) == substr(s, length(s) - 1, 1) && (substr(s, 1, length(s) - 1) in ok)) return 1
      }
      if (w ~ /n.t$/ || w ~ /.s$/ && w ~ /\047s$/) return 1
      return 0
    }
    {
      # Non-English tokens: skip (the check is English only).
      if ($0 ~ /[^ -~]/) { na++; next }
      gsub(/^\047+|\047+$/, "")
      gsub(/[^a-z\047]/, "")
      if ($0 == "") next
      total++
      if ($0 in ban) { nb++; if (!($0 in sb)) { sb[$0] = 1; bl = bl " " $0 } }
      # Only long words count as hard: short ones are never rare enough to matter.
      else if (length($0) >= 9 && !known($0)) { nh++; if (!($0 in sh)) { sh[$0] = 1; if (++shn <= 5) hl = hl " " $0 } }
    }
    END {
      # Mostly non-English reply: report nothing.
      if (na * 5 > total + na) { total = 0; nh = 0; nb = 0; hl = ""; bl = "" }
      printf "%d %d %d\n%s\n%s\n", total, nh, nb, hl, bl
    }')
checked=$(printf '%s\n' "$scan" | sed -n 1p | cut -d' ' -f1)
hard=$(printf '%s\n' "$scan" | sed -n 1p | cut -d' ' -f2)
banned=$(printf '%s\n' "$scan" | sed -n 1p | cut -d' ' -f3)
hardlist=$(printf '%s\n' "$scan" | sed -n 2p | sed 's/^ //')
banlist=$(printf '%s\n' "$scan" | sed -n 3p | sed 's/^ //')

why=""
# Ultracave drops articles: flag any filler, or articles above 4% of words.
if [ "$filler" -ge 1 ] || [ $((articles * 100)) -gt $((words * 4)) ]; then
  why="filler=$filler, articles=$articles/$words words"
fi
# Basic English: any banned word, or 2+ hard words above 5% of checked words
# (one odd name in a short reply is fine).
if [ "${banned:-0}" -ge 1 ] || { [ "${hard:-0}" -ge 2 ] && [ $(( ${hard:-0} * 100 )) -gt $(( ${checked:-0} * 5 )) ]; }; then
  why="${why:+$why; }hard words: ${banlist:+$banlist }$hardlist"
fi
[ -n "$why" ] || exit 0

if [ "$active" != "true" ]; then
  jq -n --arg r "Reply broke ultracave + basic English ($why). Rewrite it now: fragments or short simple sentences, no articles, no filler, common words only. Code, paths, commands exact. Do not mention this rewrite." \
    '{decision: "block", reason: $r}'
  exit 0
fi

# Second failure in a row: no loop, warn on the next prompt instead.
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0
dir=${SESSION_TRACKER_ULTRACAVE_DIR:-$HOME/.claude/state/ultracave}
mkdir -p "$dir" 2>/dev/null || exit 0
printf '%s' "$why" > "$dir/$sid" 2>/dev/null
exit 0
