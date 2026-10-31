-- Pure logic for the session tracker. No wezterm dependency, so it runs under
-- plain LuaJIT for tests.
local M = {}

local RANK = { ["needs-you"] = 3, working = 2, idle = 1 }

-- Worst state in the list: needs-you beats working beats idle. nil if none known.
function M.worst(states)
	local best, best_rank = nil, 0
	for _, s in ipairs(states or {}) do
		local r = RANK[s]
		if r and r > best_rank then
			best, best_rank = s, r
		end
	end
	return best
end

-- Reading-order number (top to bottom, then left to right) for each pane of
-- one tab. `infos` is a list of {id=, left=, top=}; returns {[id] = 1..n}.
function M.positions(infos)
	local sorted = {}
	for i, info in ipairs(infos or {}) do
		sorted[i] = info
	end
	table.sort(sorted, function(a, b)
		if a.top ~= b.top then
			return a.top < b.top
		end
		return a.left < b.left
	end)
	local out = {}
	for rank, info in ipairs(sorted) do
		out[info.id] = rank
	end
	return out
end

-- Next inactive-pane hsb for the dim toggle. `current` is the window's override
-- (nil means the config default, which is dimmed): normal flips to dim, anything
-- else flips to normal.
function M.toggle_hsb(current, dim, normal)
	if current and current.saturation == normal.saturation and current.brightness == normal.brightness then
		return dim
	end
	return normal
end

function M.counts(states)
	local c = { ["needs-you"] = 0, working = 0, idle = 0 }
	for _, s in ipairs(states or {}) do
		if c[s] then
			c[s] = c[s] + 1
		end
	end
	return c
end

-- "1 waiting · 2 working · 1 idle", zero counts omitted.
function M.summary(counts)
	local parts = {}
	if counts["needs-you"] > 0 then
		parts[#parts + 1] = counts["needs-you"] .. " waiting"
	end
	if counts.working > 0 then
		parts[#parts + 1] = counts.working .. " working"
	end
	if counts.idle > 0 then
		parts[#parts + 1] = counts.idle .. " idle"
	end
	return table.concat(parts, " · ")
end

-- Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
local function days_from_civil(y, m, d)
	if m <= 2 then
		y = y - 1
	end
	local era = math.floor(y / 400)
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = math.floor((153 * mp + 2) / 5) + d - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

-- Epoch seconds for an ISO-8601 string like 2026-02-26T12:59:59.997656+00:00, or nil.
local function parse_iso(s)
	if type(s) ~= "string" then
		return nil
	end
	local y, mo, d, h, mi, se = s:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not y then
		return nil
	end
	local epoch = days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
		+ tonumber(h) * 3600
		+ tonumber(mi) * 60
		+ tonumber(se)
	local sign, oh, om = s:match("([+-])(%d%d):(%d%d)$")
	if sign then
		local offset = tonumber(oh) * 3600 + tonumber(om) * 60
		epoch = epoch - (sign == "+" and offset or -offset)
	end
	return epoch
end

local function countdown(reset_iso, now)
	local at = parse_iso(reset_iso)
	if not at then
		return nil
	end
	local diff = at - now
	if diff <= 0 then
		return "now"
	end
	local days = math.floor(diff / 86400)
	local hours = math.floor((diff % 86400) / 3600)
	local minutes = math.floor((diff % 3600) / 60)
	if days > 0 then
		return ("%dd %dh"):format(days, hours)
	elseif hours > 0 then
		return ("%dh %dm"):format(hours, minutes)
	end
	return ("%dm"):format(minutes)
end

local MAX_CACHE_AGE = 900

M.PULSE_SECONDS = 8
-- Windows narrower than this many columns get the compact right status.
M.COMPACT_COLS = 100

-- True while a needs-you tab should blink: the first PULSE_SECONDS after it
-- entered the state, on every other second. After that it holds steady. A nil
-- or future `since` (clock change) never blinks.
function M.pulse_on(since, now)
	if type(since) ~= "number" or now < since then
		return false
	end
	local age = now - since
	return age < M.PULSE_SECONDS and age % 2 == 0
end

-- True while the tab bar still needs a per-second repaint for the pulse: the
-- blink window plus one second, so the last repaint lands on the steady shade.
function M.pulse_active(since, now)
	return type(since) == "number" and now >= since and now - since <= M.PULSE_SECONDS
end

local SID_PATTERN = "^" .. ("%x"):rep(8) .. "%-" .. ("%x"):rep(4) .. "%-" .. ("%x"):rep(4) .. "%-" .. ("%x"):rep(4) .. "%-" .. ("%x"):rep(12) .. "$"

-- True for a Claude session id (uuid). Ids are typed into a shell on restore,
-- so anything else must never get through.
function M.valid_sid(sid)
	return type(sid) == "string" and sid:match(SID_PATTERN) ~= nil
end

-- Text that resumes a session in a shell, or nil for an invalid id.
function M.resume_text(sid)
	if not M.valid_sid(sid) then
		return nil
	end
	return "claude --resume " .. sid .. "\n"
end

-- True when a layout snapshot ({windows -> {tabs -> {panes}}}) holds at least
-- one Claude session worth restoring.
function M.has_claude(snapshot)
	for _, window in ipairs(type(snapshot) == "table" and snapshot or {}) do
		for _, tab in ipairs(window.tabs or {}) do
			for _, pane in ipairs(tab.panes or {}) do
				if M.valid_sid(pane.sid) then
					return true
				end
			end
		end
	end
	return false
end

-- How to rebuild one tab's panes by splitting. `panes` is a list of
-- {left=, top=}; returns steps in reading order: {index=, from=, dir=}. The
-- first step has no from/dir (it is the tab's first pane). Later panes split
-- the nearest pane above them in the same column ("Bottom"), else the nearest
-- pane to their left in the same row ("Right"), else the previous pane. Split
-- sizes come out even, so this restores the shape and not the exact sizes.
function M.split_plan(panes)
	local order = {}
	for i, p in ipairs(panes or {}) do
		order[i] = { index = i, left = p.left or 0, top = p.top or 0 }
	end
	table.sort(order, function(a, b)
		if a.top ~= b.top then
			return a.top < b.top
		end
		if a.left ~= b.left then
			return a.left < b.left
		end
		return a.index < b.index
	end)
	local steps = {}
	for n, p in ipairs(order) do
		local step = { index = p.index }
		if n > 1 then
			local above, left
			for k = 1, n - 1 do
				local q = order[k]
				if q.left == p.left and q.top < p.top and (not above or q.top > above.top) then
					above = q
				end
				if q.top == p.top and q.left < p.left and (not left or q.left > left.left) then
					left = q
				end
			end
			if above then
				step.from, step.dir = above.index, "Bottom"
			elseif left then
				step.from, step.dir = left.index, "Right"
			else
				step.from, step.dir = order[n - 1].index, "Right"
			end
		end
		steps[#steps + 1] = step
	end
	return steps
end

-- Layout presets for a new tab. Each step after the first splits an earlier
-- pane (`from`, 1-based) toward `dir`; `size` is the share the new pane takes.
local PRESETS = {
	["2x2"] = {
		{},
		{ from = 1, dir = "Right", size = 0.5 },
		{ from = 1, dir = "Bottom", size = 0.5 },
		{ from = 2, dir = "Bottom", size = 0.5 },
	},
}

M.PRESET_NAMES = { "2x2" }

-- Steps for a preset (a fresh copy), or nil for an unknown name.
function M.preset_steps(name)
	local preset = type(name) == "string" and PRESETS[name] or nil
	if not preset then
		return nil
	end
	local out = {}
	for i, step in ipairs(preset) do
		out[i] = { from = step.from, dir = step.dir, size = step.size }
	end
	return out
end

-- How full a usage window is: ok under 70, warn 70-89, hot from 90. nil when
-- the value is not a number.
function M.usage_level(pct)
	local n = tonumber(pct)
	if not n then
		return nil
	end
	if n >= 90 then
		return "hot"
	elseif n >= 70 then
		return "warn"
	end
	return "ok"
end

local USAGE_NA = { { text = "usage n/a" } }

-- Usage as colorable pieces: { text =, tone = } with tone from usage_level.
-- lines: the 4 lines of the usage cache (5h pct, 7d pct, 5h reset ISO, 7d reset ISO).
-- compact drops the reset countdowns and keeps the percents.
function M.usage_segments(lines, age_seconds, now_epoch, compact)
	if
		type(lines) ~= "table"
		or #lines < 4
		or not age_seconds
		or age_seconds > MAX_CACHE_AGE
		or lines[1] == ""
		or lines[2] == ""
	then
		return USAGE_NA
	end
	local out = {}
	local function window(pct, reset_iso, label)
		if not compact then
			out[#out + 1] = { text = (countdown(reset_iso, now_epoch) or label) .. " " }
		end
		out[#out + 1] = { text = pct .. "%", tone = M.usage_level(pct) }
	end
	window(lines[1], lines[3], "5h")
	out[#out + 1] = { text = " │ " }
	window(lines[2], lines[4], "7d")
	return out
end

function M.usage_text(lines, age_seconds, now_epoch)
	local parts = {}
	for _, seg in ipairs(M.usage_segments(lines, age_seconds, now_epoch, false)) do
		parts[#parts + 1] = seg.text
	end
	return table.concat(parts)
end

local STATE_ORDER = { "needs-you", "working", "idle" }

-- Counts as colorable pieces. Wide: the plain summary. Compact: one colored
-- "● N" per state that has sessions.
function M.count_segments(counts, compact)
	if not compact then
		local text = M.summary(counts)
		if text == "" then
			return {}
		end
		return { { text = text } }
	end
	local out = {}
	for _, state in ipairs(STATE_ORDER) do
		if counts[state] > 0 then
			if #out > 0 then
				out[#out + 1] = { text = "  " }
			end
			out[#out + 1] = { text = "● " .. counts[state], tone = state }
		end
	end
	return out
end

-- Usage pieces, then counts pieces, joined by " │ " when both exist.
function M.right_segments(usage, counts)
	local out = {}
	for _, seg in ipairs(usage) do
		out[#out + 1] = seg
	end
	if #usage > 0 and #counts > 0 then
		out[#out + 1] = { text = " │ " }
	end
	for _, seg in ipairs(counts) do
		out[#out + 1] = seg
	end
	return out
end

-- Tab title for a pane's state record: "repo:branch", or just "repo" when the
-- branch is unknown. Anything else (no record, no repo) gives the fallback.
function M.tab_label(rec, fallback)
	if type(rec) == "table" then
		local repo = type(rec.repo) == "string" and rec.repo or ""
		local branch = type(rec.branch) == "string" and rec.branch or ""
		if repo ~= "" and branch ~= "" then
			return repo .. ":" .. branch
		elseif repo ~= "" then
			return repo
		end
	end
	return fallback
end

-- Right side of the tab bar. WezTerm clips it from the left when the window is
-- narrow, so the counts go last and survive longest.
function M.right_status(summary, usage)
	local parts = {}
	if usage ~= "" then
		parts[#parts + 1] = usage
	end
	if summary ~= "" then
		parts[#parts + 1] = summary
	end
	return table.concat(parts, " │ ")
end

return M
