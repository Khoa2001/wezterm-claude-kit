-- WezTerm glue for the session tracker: tab-title dots, and global counts plus
-- account usage on the right of the tab bar. State files are written by
-- hooks/track-state.sh as <state dir>/<pane id>.json.
--
-- API facts verified against WezTerm 20240203 in a scratch instance:
--   * wezterm.mux.get_tab(tab.tab_id):panes() works inside format-tab-title.
--   * pane:pane_id() equals the $WEZTERM_PANE value seen by hooks.
--   * wezterm.json_parse, io.open, os.getenv, os.remove and wezterm.glob work.
--   * wezterm.read_dir failed inside format-tab-title, so pane files are opened
--     directly by id instead of listing the directory.
local wezterm = require("wezterm")
local logic = require("logic")

local M = {}

-- Same red/yellow/green as the status line dot. The usage tones reuse them:
-- ok is green, warn yellow, hot rose.
local COLORS = {
	["needs-you"] = "#eb6f92",
	working = "#f6c177",
	idle = "#98c379",
	ok = "#98c379",
	warn = "#f6c177",
	hot = "#eb6f92",
}
-- Same palette as the tab bar in ~/.wezterm.lua.
local BAR_BG, BAR_FG = "#100f17", "#9492a5"

local function state_dir()
	return os.getenv("SESSION_TRACKER_STATE_DIR") or ((os.getenv("HOME") or "") .. "/.claude/state/panes")
end

local function usage_cache_path()
	return os.getenv("SESSION_TRACKER_USAGE_CACHE") or "/tmp/.claude_usage_cache"
end

local function read_state_file(pane_id)
	local ok, rec = pcall(function()
		local f = io.open(state_dir() .. "/" .. pane_id .. ".json", "r")
		if not f then
			return nil
		end
		local content = f:read("*a")
		f:close()
		local parsed = wezterm.json_parse(content)
		if type(parsed) == "table" and type(parsed.state) == "string" then
			return parsed
		end
		return nil
	end)
	if ok then
		return rec
	end
	return nil
end

-- Per-pane cache of one second, so one burst of tab redraws reads each file once.
local state_cache = {}

function M.state_of(pane_id)
	local now = os.time()
	local hit = state_cache[pane_id]
	if hit and hit.at == now then
		return hit.rec
	end
	local rec = read_state_file(pane_id)
	state_cache[pane_id] = { at = now, rec = rec }
	return rec
end

-- What a tab should show: `state` is the worst state among its Claude panes
-- (nil when none), `title` is "repo:branch" of the focused pane (nil when that
-- pane has no state record), `since` is when the newest needs-you pane started
-- waiting (nil unless the tab needs you). Never raises.
function M.tab_view(tab)
	local ok, view = pcall(function()
		local states = {}
		local since
		for _, pane in ipairs(wezterm.mux.get_tab(tab.tab_id):panes()) do
			local rec = M.state_of(pane:pane_id())
			if rec then
				states[#states + 1] = rec.state
				if rec.state == "needs-you" and type(rec.since) == "number" and (not since or rec.since > since) then
					since = rec.since
				end
			end
		end
		local focused = M.state_of(tab.active_pane.pane_id)
		local state = logic.worst(states)
		return {
			state = state,
			title = logic.tab_label(focused, nil),
			since = state == "needs-you" and since or nil,
		}
	end)
	if ok then
		return view
	end
	return {}
end

-- FormatItems for the state dot plus a space, or {} when there is no state.
-- `color` overrides the state color (used where the state color would vanish
-- into the tab background).
function M.dot(state, color)
	local c = color or COLORS[state]
	if not c then
		return {}
	end
	return { { Foreground = { Color = c } }, { Text = "● " } }
end

-- True while a needs-you tab (see tab_view's `since`) should show its brighter
-- shade. Never raises.
function M.pulse_on(since)
	local ok, on = pcall(logic.pulse_on, since, os.time())
	return ok and on
end

-- Usage cache mtime is looked up with stat at most every 30 seconds.
local mtime_cache = { checked = 0, mtime = nil }

local function usage_segments(compact)
	local ok, segs = pcall(function()
		local path = usage_cache_path()
		local now = os.time()
		if now - mtime_cache.checked >= 30 then
			mtime_cache.checked = now
			local _, stdout = wezterm.run_child_process({ "/usr/bin/stat", "-f", "%m", path })
			mtime_cache.mtime = tonumber(stdout)
		end
		local lines = {}
		for line in io.lines(path) do
			lines[#lines + 1] = line
		end
		local age = mtime_cache.mtime and (now - mtime_cache.mtime) or nil
		return logic.usage_segments(lines, age, now, compact)
	end)
	if ok then
		return segs
	end
	return { { text = "usage n/a" } }
end

-- Pieces of the right status: usage first, counts last. compact swaps words
-- for colored dots and drops the reset countdowns. The second result is true
-- while a needs-you pane is still inside its pulse window.
local function right_status_segments(compact)
	local states = {}
	local pulsing = false
	local now = os.time()
	for _, window in ipairs(wezterm.mux.all_windows()) do
		for _, tab in ipairs(window:tabs()) do
			for _, pane in ipairs(tab:panes()) do
				local rec = M.state_of(pane:pane_id())
				if rec then
					states[#states + 1] = rec.state
					if rec.state == "needs-you" and logic.pulse_active(rec.since, now) then
						pulsing = true
					end
				end
			end
		end
	end
	return logic.right_segments(usage_segments(compact), logic.count_segments(logic.counts(states), compact)), pulsing
end

-- Pane number within its tab, for the status line badge. Written next to the
-- state files as <pane id>.pos only while the tab has several panes, and only
-- when the number changed.
local written_pos = {}

local function write_positions()
	local dir = state_dir()
	local seen = {}
	for _, window in ipairs(wezterm.mux.all_windows()) do
		for _, tab in ipairs(window:tabs()) do
			local infos = tab:panes_with_info()
			local pos = {}
			if #infos > 1 then
				local list = {}
				for _, info in ipairs(infos) do
					list[#list + 1] = { id = info.pane:pane_id(), left = info.left, top = info.top }
				end
				pos = logic.positions(list)
			end
			for _, info in ipairs(infos) do
				local id = info.pane:pane_id()
				seen[id] = true
				if written_pos[id] ~= pos[id] then
					local path = dir .. "/" .. id .. ".pos"
					if pos[id] then
						local f = io.open(path, "w")
						if f then
							f:write(pos[id], "\n")
							f:close()
						end
					else
						os.remove(path)
					end
					written_pos[id] = pos[id]
				end
			end
		end
	end
	for id in pairs(written_pos) do
		if not seen[id] then
			os.remove(dir .. "/" .. id .. ".pos")
			written_pos[id] = nil
		end
	end
end

-- Layout snapshot for session restore. layout.json follows the live windows;
-- at startup it moves to layout.prev.json, which the "restore-layout" event
-- reads. Both sit outside the pane state dir, so the startup wipe leaves them.
local function layout_path(name)
	local dir = os.getenv("SESSION_TRACKER_LAYOUT_DIR") or ((os.getenv("HOME") or "") .. "/.claude/state")
	return dir .. "/" .. name
end

local function pane_cwd(pane, rec)
	if rec and type(rec.cwd) == "string" and rec.cwd ~= "" then
		return rec.cwd
	end
	local ok, url = pcall(function()
		return pane:get_current_working_dir()
	end)
	if ok and url then
		if type(url) == "string" then
			return (url:gsub("^file://[^/]*", ""))
		end
		if type(url.file_path) == "string" then
			return url.file_path
		end
	end
	return nil
end

-- {windows -> {tabs -> {panes -> {cwd=, sid=, left=, top=}}}} of everything open.
local function snapshot_layout()
	local snap = {}
	for _, window in ipairs(wezterm.mux.all_windows()) do
		local tabs = {}
		for _, tab in ipairs(window:tabs()) do
			local panes = {}
			for _, info in ipairs(tab:panes_with_info()) do
				local rec = M.state_of(info.pane:pane_id())
				local sid = rec and logic.valid_sid(rec.session_id) and rec.session_id or nil
				panes[#panes + 1] = { cwd = pane_cwd(info.pane, rec), sid = sid, left = info.left, top = info.top }
			end
			tabs[#tabs + 1] = { panes = panes }
		end
		snap[#snap + 1] = { tabs = tabs }
	end
	return snap
end

local function read_layout(name)
	local ok, snap = pcall(function()
		local f = io.open(layout_path(name), "r")
		if not f then
			return nil
		end
		local content = f:read("*a")
		f:close()
		return wezterm.json_parse(content)
	end)
	if ok and type(snap) == "table" then
		return snap
	end
	return nil
end

-- Writes layout.json when it changed and holds a Claude session. An empty or
-- Claude-less snapshot never replaces a good one.
local last_layout_json, last_layout_at = nil, 0

local function write_layout()
	local now = os.time()
	if now - last_layout_at < 10 then
		return
	end
	last_layout_at = now
	local snap = snapshot_layout()
	if not logic.has_claude(snap) then
		return
	end
	local json = wezterm.json_encode(snap)
	if json == last_layout_json then
		return
	end
	local path = layout_path("layout.json")
	local tmp = path .. ".tmp"
	local f = io.open(tmp, "w")
	if not f then
		return
	end
	f:write(json)
	f:close()
	if os.rename(tmp, path) then
		last_layout_json = json
	else
		os.remove(tmp)
	end
end

-- At startup: keep the last good snapshot as layout.prev.json, unless it has no
-- Claude session (a quick second restart must not lose the earlier one).
local function archive_layout()
	if logic.has_claude(read_layout("layout.json")) then
		os.rename(layout_path("layout.json"), layout_path("layout.prev.json"))
	end
end

-- Opens the saved windows, tabs and panes, and resumes each Claude session.
-- Returns true when nothing failed.
local function restore_layout()
	local snap = read_layout("layout.prev.json")
	if not logic.has_claude(snap) then
		return nil
	end
	local all_ok = true
	for _, saved_window in ipairs(snap or {}) do
		local mux_window
		for _, saved_tab in ipairs(saved_window.tabs or {}) do
			local panes = saved_tab.panes or {}
			local ok = pcall(function()
				local function spawn_args(p)
					return (type(p.cwd) == "string" and p.cwd ~= "") and { cwd = p.cwd } or {}
				end
				local first = panes[1] or {}
				local pane
				if not mux_window then
					_, pane, mux_window = wezterm.mux.spawn_window(spawn_args(first))
				else
					_, pane = mux_window:spawn_tab(spawn_args(first))
				end
				local made = {}
				for _, step in ipairs(logic.split_plan(panes)) do
					local saved = panes[step.index]
					if step.from then
						local args = spawn_args(saved)
						args.direction = step.dir
						made[step.index] = made[step.from]:split(args)
					else
						made[step.index] = pane
					end
					local text = logic.resume_text(saved.sid)
					if text then
						made[step.index]:send_text(text)
					end
				end
			end)
			all_ok = all_ok and ok
		end
	end
	if all_ok then
		os.remove(layout_path("layout.prev.json"))
	end
	return all_ok
end

-- Opens a new tab in the window, shaped by a preset (see logic.preset_steps),
-- every pane in the focused pane's directory running claude. Live panes cannot
-- be moved into a new shape, so a preset always builds a fresh tab.
local function open_preset(window, pane, name)
	local steps = logic.preset_steps(name)
	if not steps then
		return false
	end
	local cwd = pane_cwd(pane, M.state_of(pane:pane_id()))
	local has_cwd = type(cwd) == "string" and cwd ~= ""
	local tab, first = window:mux_window():spawn_tab(has_cwd and { cwd = cwd } or {})
	local made = { first }
	for i = 2, #steps do
		local args = { direction = steps[i].dir, size = steps[i].size }
		if has_cwd then
			args.cwd = cwd
		end
		made[i] = made[steps[i].from]:split(args)
	end
	for _, p in ipairs(made) do
		p:send_text("claude\n")
	end
	tab:activate()
	return true
end

local function wipe_state_files()
	pcall(function()
		for _, path in ipairs(wezterm.glob(state_dir() .. "/*.json")) do
			os.remove(path)
		end
		for _, path in ipairs(wezterm.glob(state_dir() .. "/*.pos")) do
			os.remove(path)
		end
	end)
end

-- Per window id: the second of its last pulse repaint, and which way it flipped.
local last_redraw, pulse_flip = {}, {}

-- Inactive panes: slightly dimmed by default, toggled per window by the
-- "toggle-dim-panes" event.
local DIM_HSB = { saturation = 0.8, brightness = 0.6 }
local NORMAL_HSB = { saturation = 1.0, brightness = 1.0 }

-- set_config_overrides replaces the whole override table, so merge one key into
-- what the window already has or the pulse and the dim toggle wipe each other.
local function set_override(window, key, value)
	local overrides = window:get_config_overrides() or {}
	overrides[key] = value
	window:set_config_overrides(overrides)
end

function M.setup(config)
	config.status_update_interval = 1000
	config.inactive_pane_hsb = DIM_HSB

	wezterm.on("toggle-dim-panes", function(window, _)
		pcall(function()
			local current = window:get_config_overrides() or {}
			set_override(window, "inactive_pane_hsb", logic.toggle_hsb(current.inactive_pane_hsb, DIM_HSB, NORMAL_HSB))
		end)
	end)
	-- The right status carries the session counts, so the bar must stay visible
	-- with a single tab.
	config.hide_tab_bar_if_only_one_tab = false

	wezterm.on("update-right-status", function(window, _)
		pcall(write_positions)
		pcall(write_layout)
		-- No width (API change, odd window) counts as wide.
		local cols_ok, cols = pcall(function()
			return window:active_tab():get_size().cols
		end)
		local compact = cols_ok and type(cols) == "number" and cols < logic.COMPACT_COLS
		local ok, segs, pulsing = pcall(right_status_segments, compact)
		if not ok then
			segs = {}
		end
		-- WezTerm re-runs format-tab-title only when the tab bar changes, not on
		-- the status tick. Flipping an inert option once per second while a tab
		-- pulses makes it redraw; more often than that loops (each override
		-- re-fires this handler).
		local now = os.time()
		local wid = window:window_id()
		if pulsing and now ~= last_redraw[wid] then
			last_redraw[wid] = now
			pulse_flip[wid] = not pulse_flip[wid]
			pcall(set_override, window, "status_update_interval", pulse_flip[wid] and 1000 or 1001)
		end
		local items = { { Background = { Color = BAR_BG } }, { Foreground = { Color = BAR_FG } }, { Text = " " } }
		for _, seg in ipairs(segs) do
			items[#items + 1] = { Foreground = { Color = COLORS[seg.tone] or BAR_FG } }
			items[#items + 1] = { Text = seg.text }
		end
		items[#items + 1] = { Foreground = { Color = BAR_FG } }
		items[#items + 1] = { Text = " " }
		window:set_right_status(wezterm.format(items))
	end)

	-- Pane ids restart with the mux, so files left by a previous run could paint
	-- a dot on an unrelated pane. The handler only wipes; WezTerm still spawns
	-- the default window (and honors `start --workspace` and `-- cmd`) itself.
	wezterm.on("gui-startup", function()
		pcall(archive_layout)
		wipe_state_files()
	end)

	-- "layout-preset-<name>" opens a new tab with that preset. The hotkeys are
	-- bound by hand in ~/.wezterm.lua: EmitEvent("layout-preset-2x2") and so on.
	for _, name in ipairs(logic.PRESET_NAMES) do
		wezterm.on("layout-preset-" .. name, function(window, pane)
			local ok = pcall(open_preset, window, pane, name)
			if not ok then
				pcall(function()
					window:toast_notification("WezTerm", "Layout preset failed", nil, 4000)
				end)
			end
		end)
	end

	-- Reopens the layout saved before the last restart. The hotkey is bound by
	-- hand in ~/.wezterm.lua: EmitEvent("restore-layout").
	wezterm.on("restore-layout", function(window, _)
		local ok, result = pcall(restore_layout)
		local msg
		if not ok or result == false then
			msg = "Restore hit an error; saved layout kept"
		elseif result == nil then
			msg = "No saved Claude layout to restore"
		else
			msg = "Layout restored"
		end
		pcall(function()
			window:toast_notification("WezTerm", msg, nil, 4000)
		end)
	end)
end

return M
