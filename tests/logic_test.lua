-- Tests for wezterm/logic.lua. Run with: luajit tests/logic_test.lua
local here = arg[0]:match("^(.*)/tests/[^/]+$") or "."
package.path = here .. "/wezterm/?.lua;" .. package.path
local logic = require("logic")

local fails, passes = 0, 0
local function eq(name, got, want)
	if got == want then
		passes = passes + 1
		print("PASS " .. name)
	else
		fails = fails + 1
		print(("FAIL %s\n  expected [%s] got [%s]"):format(name, tostring(want), tostring(got)))
	end
end

-- worst
eq("worst working over idle", logic.worst({ "idle", "working" }), "working")
eq("worst needs-you over all", logic.worst({ "idle", "needs-you", "working" }), "needs-you")
eq("worst empty", logic.worst({}), nil)
eq("worst unknown only", logic.worst({ "bogus" }), nil)
eq("worst ignores unknown", logic.worst({ "bogus", "idle" }), "idle")

-- toggle_hsb
local dim_hsb = { saturation = 0.9, brightness = 0.75 }
local normal_hsb = { saturation = 1.0, brightness = 1.0 }
eq("toggle_hsb nil to normal", logic.toggle_hsb(nil, dim_hsb, normal_hsb), normal_hsb)
eq("toggle_hsb dim to normal", logic.toggle_hsb(dim_hsb, dim_hsb, normal_hsb), normal_hsb)
eq("toggle_hsb normal to dim", logic.toggle_hsb(normal_hsb, dim_hsb, normal_hsb), dim_hsb)
eq(
	"toggle_hsb equal copy to dim",
	logic.toggle_hsb({ saturation = 1.0, brightness = 1.0 }, dim_hsb, normal_hsb),
	dim_hsb
)

-- counts
local c =logic.counts({ "working", "working", "idle", "needs-you", "bogus" })
eq("counts needs-you", c["needs-you"], 1)
eq("counts working", c.working, 2)
eq("counts idle", c.idle, 1)

-- summary
eq("summary full", logic.summary(c), "1 waiting · 2 working · 1 idle")
eq("summary omits zeros", logic.summary({ ["needs-you"] = 0, working = 3, idle = 0 }), "3 working")
eq("summary all zero", logic.summary({ ["needs-you"] = 0, working = 0, idle = 0 }), "")

-- usage_text
local now = 1792368000 -- 2026-10-19T00:00:00Z
local lines = { "2", "51", "2026-10-19T04:37:00+00:00", "2026-10-23T12:00:00+00:00" }
eq("usage ok", logic.usage_text(lines, 60, now), "4h 37m 2% │ 4d 12h 51%")
eq("usage stale", logic.usage_text(lines, 901, now), "usage n/a")
eq("usage nil lines", logic.usage_text(nil, 60, now), "usage n/a")
eq("usage nil age", logic.usage_text(lines, nil, now), "usage n/a")
eq("usage short lines", logic.usage_text({ "2", "51", "x" }, 60, now), "usage n/a")
eq(
	"usage garbage reset falls back to label",
	logic.usage_text({ "2", "51", "garbage", "2026-10-23T12:00:00+00:00" }, 60, now),
	"5h 2% │ 4d 12h 51%"
)
eq(
	"usage past reset is now",
	logic.usage_text({ "2", "51", "2026-10-18T00:00:00+00:00", "2026-10-23T12:00:00+00:00" }, 60, now),
	"now 2% │ 4d 12h 51%"
)
eq(
	"usage minutes only",
	logic.usage_text({ "2", "51", "2026-10-19T00:12:00+00:00", "2026-10-23T12:00:00+00:00" }, 60, now),
	"12m 2% │ 4d 12h 51%"
)
eq(
	"usage fractional seconds and offset",
	logic.usage_text({ "2", "51", "2026-10-19T04:37:00.997656+00:00", "2026-10-23T12:00:00+00:00" }, 60, now),
	"4h 37m 2% │ 4d 12h 51%"
)

-- tab_label
eq("tab_label repo:branch", logic.tab_label({ repo = "web", branch = "dark-mode" }, "fb"), "web:dark-mode")
eq("tab_label repo only", logic.tab_label({ repo = "web", branch = "" }, "fb"), "web")
eq("tab_label empty repo falls back", logic.tab_label({ repo = "", branch = "main" }, "fb"), "fb")
eq("tab_label branch only falls back", logic.tab_label({ branch = "main" }, "fb"), "fb")
eq("tab_label nil record falls back", logic.tab_label(nil, "fb"), "fb")
eq("tab_label non-string fields fall back", logic.tab_label({ repo = 5, branch = {} }, "fb"), "fb")
eq("tab_label nil fallback", logic.tab_label(nil, nil), nil)

-- right_status: usage first, counts last, so a narrow tab bar clips usage first
eq("right_status both", logic.right_status("1 waiting · 1 idle", "4h 37m 2% │ 4d 12h 51%"), "4h 37m 2% │ 4d 12h 51% │ 1 waiting · 1 idle")
eq("right_status no counts", logic.right_status("", "usage n/a"), "usage n/a")
eq("right_status no usage", logic.right_status("2 working", ""), "2 working")
eq("right_status neither", logic.right_status("", ""), "")

-- positions
local pos = logic.positions({
	{ id = 9, left = 50, top = 20 },
	{ id = 4, left = 0, top = 0 },
	{ id = 7, left = 50, top = 0 },
	{ id = 5, left = 0, top = 20 },
})
eq("positions top-left", pos[4], 1)
eq("positions top-right", pos[7], 2)
eq("positions bottom-left", pos[5], 3)
eq("positions bottom-right", pos[9], 4)
eq("positions left column then right split", logic.positions({ { id = 1, left = 0, top = 0 }, { id = 2, left = 50, top = 0 }, { id = 3, left = 50, top = 20 } })[3], 3)
eq("positions nil", next(logic.positions(nil)), nil)

-- pulse_on
eq("pulse at start", logic.pulse_on(100, 100), true)
eq("pulse off beat", logic.pulse_on(100, 101), false)
eq("pulse on beat", logic.pulse_on(100, 106), true)
eq("pulse over", logic.pulse_on(100, 108), false)
eq("pulse after window on even second", logic.pulse_on(100, 110), false)
eq("pulse nil since", logic.pulse_on(nil, 100), false)
eq("pulse since in future", logic.pulse_on(200, 100), false)

-- pulse_active: true until one second past the last blink, so the tab gets a final steady repaint
eq("active at start", logic.pulse_active(100, 100), true)
eq("active at last second", logic.pulse_active(100, 108), true)
eq("active past window", logic.pulse_active(100, 109), false)
eq("active nil since", logic.pulse_active(nil, 100), false)
eq("active future since", logic.pulse_active(200, 100), false)

-- usage_level
eq("level 69", logic.usage_level(69), "ok")
eq("level 70", logic.usage_level(70), "warn")
eq("level 89", logic.usage_level(89), "warn")
eq("level 90", logic.usage_level(90), "hot")
eq("level string", logic.usage_level("92"), "hot")
eq("level junk", logic.usage_level("abc"), nil)
eq("level nil", logic.usage_level(nil), nil)

-- usage_segments
local function joined(segs)
	local t = {}
	for _, s in ipairs(segs) do
		t[#t + 1] = s.text
	end
	return table.concat(t)
end
local segs = logic.usage_segments(lines, 60, now, false)
eq("usage segs text", joined(segs), "4h 37m 2% │ 4d 12h 51%")
eq("usage segs tone 5h", segs[2].tone, "ok")
eq("usage segs tone 7d", segs[#segs].tone, "ok")
eq("usage segs hot", logic.usage_segments({ "95", "75", "x", "y" }, 60, now, false)[2].tone, "hot")
eq("usage segs warn", logic.usage_segments({ "95", "75", "x", "y" }, 60, now, false)[5].tone, "warn")
eq("usage compact text", joined(logic.usage_segments(lines, 60, now, true)), "2% │ 51%")
eq("usage compact first", logic.usage_segments(lines, 60, now, true)[1].text, "2%")
eq("usage stale segs", logic.usage_segments(lines, 901, now, false)[1].text, "usage n/a")
eq("usage stale tone", logic.usage_segments(lines, 901, now, false)[1].tone, nil)
eq("usage junk pct no tone", logic.usage_segments({ "x", "y", "2026-10-19T04:37:00+00:00", "2026-10-23T12:00:00+00:00" }, 60, now, false)[2].tone, nil)
eq("usage blank lines", joined(logic.usage_segments({ "", "", "", "" }, 60, now, false)), "usage n/a")

-- valid_sid, resume_text, has_claude
local SID = "8f2a1c3e-4b5d-4e6f-9a7b-0c1d2e3f4a5b"
eq("valid_sid uuid", logic.valid_sid(SID), true)
eq("valid_sid uppercase hex", logic.valid_sid(SID:upper()), true)
eq("valid_sid empty", logic.valid_sid(""), false)
eq("valid_sid nil", logic.valid_sid(nil), false)
eq("valid_sid number", logic.valid_sid(5), false)
eq("valid_sid shell injection", logic.valid_sid("8f2a1c3e-4b5d-4e6f-9a7b-0c1d2e3f4a5b; rm -rf ~"), false)
eq("valid_sid wrong length", logic.valid_sid("8f2a1c3e-4b5d"), false)
eq("valid_sid non-hex", logic.valid_sid("zf2a1c3e-4b5d-4e6f-9a7b-0c1d2e3f4a5b"), false)
eq("resume_text", logic.resume_text(SID), "claude --resume " .. SID .. "\n")
eq("resume_text invalid", logic.resume_text("x; ls"), nil)
eq("has_claude none", logic.has_claude({ { tabs = { { panes = { { cwd = "/a" } } } } } }), false)
eq("has_claude one", logic.has_claude({ { tabs = { { panes = { { cwd = "/a" }, { cwd = "/b", sid = SID } } } } } }), true)
eq("has_claude bad sid", logic.has_claude({ { tabs = { { panes = { { sid = "nope" } } } } } }), false)
eq("has_claude nil", logic.has_claude(nil), false)
eq("has_claude empty", logic.has_claude({}), false)

-- split_plan: rebuild a tab's panes by splitting, in reading order
local function plan_str(panes)
	local out = {}
	for _, step in ipairs(logic.split_plan(panes)) do
		out[#out + 1] = step.index .. (step.from and (":" .. step.dir .. "@" .. step.from) or "")
	end
	return table.concat(out, " ")
end
eq("plan single", plan_str({ { left = 0, top = 0 } }), "1")
eq("plan empty", plan_str({}), "")
eq("plan side by side", plan_str({ { left = 0, top = 0 }, { left = 80, top = 0 } }), "1 2:Right@1")
eq("plan stacked", plan_str({ { left = 0, top = 0 }, { left = 0, top = 20 } }), "1 2:Bottom@1")
eq(
	"plan 2x2",
	plan_str({ { left = 0, top = 0 }, { left = 80, top = 0 }, { left = 0, top = 20 }, { left = 80, top = 20 } }),
	"1 2:Right@1 3:Bottom@1 4:Bottom@2"
)
eq(
	"plan big left, three stacked right",
	plan_str({ { left = 0, top = 0 }, { left = 80, top = 0 }, { left = 80, top = 10 }, { left = 80, top = 20 } }),
	"1 2:Right@1 3:Bottom@2 4:Bottom@3"
)
eq(
	"plan input order does not matter, index is original",
	plan_str({ { left = 80, top = 0 }, { left = 0, top = 0 } }),
	"2 1:Right@2"
)
eq("plan nearest above wins", plan_str({ { left = 0, top = 0 }, { left = 0, top = 10 }, { left = 0, top = 20 } }), "1 2:Bottom@1 3:Bottom@2")
eq("plan odd geometry falls back to right of previous", plan_str({ { left = 0, top = 0 }, { left = 40, top = 20 } }), "1 2:Right@1")
eq("plan missing coords treated as 0", plan_str({ {}, {} }), "1 2:Right@1")

-- preset_steps: layout presets, each pane after the first splits an earlier one
local function areas(name)
	local rects = { { w = 1, h = 1 } }
	for i, step in ipairs(logic.preset_steps(name)) do
		if i > 1 then
			local src = rects[step.from]
			if step.dir == "Right" then
				rects[i] = { w = src.w * step.size, h = src.h }
				src.w = src.w * (1 - step.size)
			else
				rects[i] = { w = src.w, h = src.h * step.size }
				src.h = src.h * (1 - step.size)
			end
		end
	end
	local out = {}
	for i, r in ipairs(rects) do
		out[i] = ("%.3f"):format(r.w * r.h)
	end
	return table.concat(out, " ")
end
eq("preset names", table.concat(logic.PRESET_NAMES, ","), "2x2")
eq("preset unknown", logic.preset_steps("nope"), nil)
eq("preset nil", logic.preset_steps(nil), nil)
eq("preset 2x2 panes", #logic.preset_steps("2x2"), 4)
eq("preset big-3 is gone", logic.preset_steps("big-3"), nil)
eq("preset main-side is gone", logic.preset_steps("main-side"), nil)
eq("preset first step has no from", logic.preset_steps("2x2")[1].from, nil)
for _, name in ipairs(logic.PRESET_NAMES) do
	local ok = true
	for i, step in ipairs(logic.preset_steps(name)) do
		if i > 1 then
			ok = ok and step.from >= 1 and step.from < i and (step.dir == "Right" or step.dir == "Bottom")
				and step.size > 0 and step.size < 1
		end
	end
	eq("preset " .. name .. " steps valid", ok, true)
end
eq("preset 2x2 areas equal", areas("2x2"), "0.250 0.250 0.250 0.250")
local copy = logic.preset_steps("2x2")
copy[2].size = 0.9
eq("preset steps are copies", logic.preset_steps("2x2")[2].size, 0.5)

-- count_segments, right_segments
local cs = { ["needs-you"] = 1, working = 2, idle = 0 }
eq("count wide", logic.count_segments(cs, false)[1].text, "1 waiting · 2 working")
eq("count compact text", joined(logic.count_segments(cs, true)), "● 1  ● 2")
eq("count compact first", logic.count_segments(cs, true)[1].text, "● 1")
eq("count compact tone", logic.count_segments(cs, true)[1].tone, "needs-you")
eq("count empty", #logic.count_segments({ ["needs-you"] = 0, working = 0, idle = 0 }, false), 0)
eq("right segs both", joined(logic.right_segments({ { text = "u" } }, { { text = "c" } })), "u │ c")
eq("right segs no usage", joined(logic.right_segments({}, { { text = "c" } })), "c")
eq("right segs no counts", joined(logic.right_segments({ { text = "u" } }, {})), "u")

print(("%d passed, %d failed"):format(passes, fails))
os.exit(fails == 0 and 0 or 1)
