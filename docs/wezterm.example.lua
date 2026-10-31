-- Example ~/.wezterm.lua for wezterm-claude-kit. Copy it, or merge the parts you
-- need into your own config. If you already have a format-tab-title handler,
-- merge the idea into it instead of adding a second one.
local wezterm = require("wezterm")
local config = wezterm.config_builder()
config.tab_max_width = 32 -- room for repo:branch

-- Change this to where you cloned the repo.
package.path = package.path .. ";/path/to/wezterm-claude-kit/wezterm/?.lua"
local tracker = require("tracker")

-- Tab: dot for the busiest state, rose when a session needs you.
wezterm.on("format-tab-title", function(tab, _, _, _, _, max_width)
  local view = tracker.tab_view(tab)
  local needs_you = view.state == "needs-you"
  local bg, fg = "#312f3d", "#9492a5"
  if tab.is_active then bg, fg = "#c4a7e7", "#111111" end
  if needs_you then bg, fg = "#eb6f92", "#111111" end

  local title = view.title or tab.active_pane.title
  local label = string.format("[%d] %s", tab.tab_index + 1, title)
  local items = { { Background = { Color = bg } }, { Foreground = { Color = fg } }, { Text = " " } }
  for _, item in ipairs(tracker.dot(view.state, needs_you and fg or nil)) do
    table.insert(items, item)
  end
  table.insert(items, { Foreground = { Color = fg } })
  table.insert(items, { Text = wezterm.truncate_right(label, max_width - 4) .. " " })
  return items
end)

-- Hotkeys. Each one emits an event the kit handles.
local function emit(name)
  return wezterm.action.EmitEvent(name)
end
config.keys = {
  { key = "d", mods = "CMD|SHIFT", action = emit("toggle-dim-panes") },
  { key = "r", mods = "CMD|SHIFT", action = emit("restore-layout") },
  -- Shifted digits can arrive as the digit or as the symbol, so bind both.
  { key = "1", mods = "CMD|SHIFT", action = emit("layout-preset-2x2") },
  { key = "!", mods = "CMD|SHIFT", action = emit("layout-preset-2x2") },
  { key = "2", mods = "CMD|SHIFT", action = emit("layout-preset-4x2") },
  { key = "@", mods = "CMD|SHIFT", action = emit("layout-preset-4x2") },
}

tracker.setup(config) -- counts, usage, dimming, layouts, restore

return config
