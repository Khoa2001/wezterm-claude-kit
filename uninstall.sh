#!/bin/sh
# Removes the wezterm-claude-kit hooks from <home>/.claude/settings.json and
# restores the original status line command. Usage: uninstall.sh [--home DIR]
set -eu

HOME_DIR=$HOME
if [ "${1:-}" = "--home" ]; then HOME_DIR=${2:?--home needs a directory}; fi

settings="$HOME_DIR/.claude/settings.json"
if [ ! -f "$settings" ]; then
  echo "settings.json not found: $settings" >&2
  exit 1
fi
jq empty "$settings" 2>/dev/null || { echo "settings.json is not valid JSON: $settings" >&2; exit 1; }

backup="$settings.bak-$(date +%Y%m%d-%H%M%S)"
cp "$settings" "$backup"
echo "backup: $backup"

tmp=$(mktemp "$settings.tmp.XXXXXX")
trap 'rm -f "$tmp"' EXIT

# install.sh writes "$HERE/hooks/<name>.sh", so this checkout's own path matches
# even when its folder is not called wezterm-claude-kit (a git worktree).
HERE=$(cd "$(dirname "$0")" && pwd)

jq --arg here "$HERE" '
  def mine(name): contains("wezterm-claude-kit/hooks/" + name) or contains($here + "/hooks/" + name);
  def ours: any(.hooks[]?; (.command // "") | (mine("track-state.sh") or mine("ultracave-check.sh") or mine("ultracave-remind.sh") or mine("ultracave-nudge.sh")));
  (if .hooks then
     .hooks |= with_entries(
       if (.value | type) == "array" and any(.value[]?; ours)
       then .value |= map(select(ours | not))
       else . end
       | select(.value != []))
   else . end)
  | if (.statusLine.command // "" | (contains("wezterm-claude-kit/statusline") or contains($here + "/statusline")))
    then .statusLine.command = "bash ~/.claude/statusline-command.sh" | del(.statusLine.refreshInterval) else . end
' "$settings" > "$tmp"

jq empty "$tmp"
mv "$tmp" "$settings"
trap - EXIT
echo "removed wezterm-claude-kit entries from $settings"
