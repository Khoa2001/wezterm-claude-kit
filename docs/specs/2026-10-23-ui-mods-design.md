# UI mods: pulse, usage colors, compact status, sounds

Four small changes to how the kit looks and sounds. Each one fits the existing design: hooks write per-pane state files, `tracker.lua` and the status line read them. No daemon.

Illustrations: https://claude.ai/artifact/EVjmvVzYTFVYhkXUtNuc42 (ideas 2, 5, 6, 9).

## Goals

- A pane that needs the user is noticed fast, from across the screen.
- Account usage shows how close the limit is without reading digits.
- The counts stay readable in a narrow window.
- A permission prompt and a finished task sound different. (Desktop notice removed 2026-11-13.)

## Non-goals

- No change to the status line script, the tab dot colors, or the done sound.
- No new files outside `hooks/`, `wezterm/`, `tests/`, `docs/`.
- No continuous animation. WezTerm repaints at the 1 s `status_update_interval`, so the pulse is a 1 Hz blink, not the smooth fade drawn in the illustration.

## Anti-goals

- A hook that prints, blocks or exits non-zero.
- A Lua error inside `format-tab-title` or `update-right-status` (wrap new code in `pcall`).
- A pulse that never stops.

## 2. Needs-you pulse

State file gains `since` (epoch seconds): when the pane entered its current state. `track-state.sh` reads the old file once; if the old `state` equals the new one it keeps the old `since`, otherwise it writes `now`. A missing or unreadable old file gives `now`. `ts` keeps its current meaning.

`logic.lua` gets a pure `pulse_on(since, now)`: true for the first 8 s after `since` on alternating seconds (`(now - since) % 2 == 0`), false afterwards and when `since` is nil. The needs-you tab background alternates between the existing rose and a brighter rose while `pulse_on` can still be true, then holds the steady rose. Callers pass `os.time()`.

`tab_view` returns `since` of the worst pane when that pane is needs-you. `~/.wezterm.lua` (hand-edited, not in this repo) picks the background from it, so the install notes in the plan must say what to change there.

Open check for the builder: confirm in a scratch WezTerm 20240203 that `format-tab-title` re-runs each second because `set_right_status` repaints the bar. If it does not, the pulse needs `window:set_config_overrides` or a different trigger, and the builder should stop and report.

## 5. Usage color ramp

The usage text already includes the reset countdown (`2h 10m 38% │ 4d 3h 74%`), so only color is new.

`logic.lua` gets `usage_level(pct)`: `ok` under 70, `warn` 70 to 89, `hot` 90 and above, `nil` for a non-number. Boundaries are inclusive on the upper band.

`usage_text` stays as is for tests that exist. A new function returns the two parts as segments `{ text =, level = }` so `tracker.lua` can emit one FormatItem per segment. Colors reuse `COLORS`: idle green for `ok`, working yellow for `warn`, needs-you rose for `hot`. `usage n/a` stays plain `BAR_FG`.

## 6. Compact right status

`update-right-status` reads the window width in columns (`window:active_tab():get_size().cols`, builder to verify it works in this WezTerm build). Below 100 columns (my call, a named constant):

- Counts: `1 waiting · 2 working · 1 idle` becomes colored dots with numbers, `● 1 ● 2 ● 1`, zero counts omitted, same state colors as the tab dots.
- Usage: the countdown drops and the percents remain, `38% │ 74%`, still colored by section 5.

Order stays usage first, counts last, because WezTerm clips from the left. Pure formatting lives in `logic.lua` (`right_status` gets a `compact` argument) so luajit tests cover it.

## 9. Sounds

In `track-state.sh`, when the new state is needs-you and the old state was not:

- Play the needs-you sound, detached like the done sound. Default `/System/Library/Sounds/Glass.aiff` (my call). Env `SESSION_TRACKER_SOUND_NEEDS`, empty disables.

Transition only, so a `PermissionRequest` followed by a `Notification` for the same prompt rings once.

The done sound on `Stop` is unchanged.

`tests/track_state_test.sh` must export `SESSION_TRACKER_SOUND_NEEDS=""` next to the existing `SESSION_TRACKER_SOUND=""`, then enable it per test with stub players that record their arguments.

## Tests

- `luajit tests/logic_test.lua`: `pulse_on` (before, during, after the window, nil), `usage_level` (69, 70, 89, 90, nil, string), compact and wide `right_status`.
- `sh tests/track_state_test.sh`: `since` kept on same state, reset on change, reset on a corrupt old file; needs-you sound once for the double event; no sound when state stays needs-you.
- `sh tests/run.sh` passes before and after.

## Left to the builder

Brighter-rose hex value, exact segment data shape.

## Calls I made (check these)

Pulse window 8 s and 1 Hz blink; compact threshold 100 columns; ok/warn/hot cutoffs 70 and 90; Glass.aiff for needs-you; needs-you sound fires even when WezTerm is frontmost; ideas 1, 3, 4, 7, 8 are out of scope here.
