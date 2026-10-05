# Candela — design specification

Draft 1 · 3 September 2026 · status: for review before any QML is written.

Companion: the visual design review (mockups in real theme tokens) is published as an artifact and its source lives in `design/`.

---

## 0. Verified environment

Everything below was checked on this machine on 3 Sep 2026, not taken from the brief.

| Item | Value |
|---|---|
| Omarchy | 4.0.2 (Quickshell 0.3.1, Qt 6.11.2). Source of 4.x: branch `quattro` of omacom/omarchy. |
| Hyprland | 0.56.2, Lua config. Monitor spec fields from `/usr/share/hypr/stubs/hl.meta.lua`. |
| Displays | DP-1 and DP-2, both Huawei MateView 3840×2560, scale 1.6, identical description, blank serial. EDID: HDR10 (ST 2084), BT.2020, 10 bpc, max 497 cd/m², P3-class primaries. |
| GPU | RTX 3090 + RTX 2060 SUPER, NVIDIA 610.57.04. Shell renders through NVIDIA EGL. |
| Existing UI | `omarchy.monitor` bar popup only (brightness, text size, scale pills, enable/disable). Setup › Monitors opens monitors.lua in an editor. |
| Upstream | #2858/#2111/#2981 closed. PR #7340 (HDR + rotation) open, conflicting, unreviewed. ~10 other display-panel PRs unreviewed. Issue #9804: shell SIGSEGV at 10-bit on a Mesa-rendered (hybrid laptop) shell. |

Test results (see §9): 10-bit on DP-2 did **not** crash this shell. Mixing an explicit position with the default "auto" rule moved DP-1 to `4800x0`.

---

## 1. Thesis

Omarchy has a *brightness* panel. It needs a *displays* product: the place where a display is arranged, driven at its real capabilities, and put into the right colour mode with the compositor telling the truth about what it is doing, in physical units, with a way back if it goes wrong.

The bar of quality is not "has the knobs". It is: a colour professional opens it, sees their panel described correctly in cd/m² and chromaticities, flips to HDR with one control that maps to the right five Hyprland fields, and never has to open a config file. And a laptop user sees only brightness, scale and rotation, and nothing else gets in their way.

## 2. Principles

1. **Keyboard first, mouse equal.** The shell's cursor model: j/k walk, h/l adjust, Enter activates, Esc closes. Every control reachable without a pointer; the pointer never produces a second highlight.
2. **Theme native.** Only `Color.*` and `Style.*` tokens. No literal colours, no custom fonts, no icons the shell would not draw. It must look right in miasma, tokyo-night, catppuccin-latte and vantablack without a single override.
3. **Physical truth.** Luminance in cd/m², primaries as chromaticities, the compositor's actual output format shown next to the requested one. Reference white is 203 cd/m² (BT.2408) and is marked on the slider.
4. **Safe by default.** Anything that can leave a display unreadable (mode, position, scale, rotation, colour mode) is previewed live and reverts itself unless confirmed. The revert runs outside the shell, so it fires even if the shell dies.
5. **Explains itself.** Every advanced control has a one-line caption in plain language stating what it does physically. No tooltip archaeology.
6. **Progressive disclosure.** Simple by default, complete on demand. The popup carries the daily controls; the studio carries everything; "Advanced" inside the studio carries the last 10 %.

## 3. Surfaces

### 3.1 Bar popup — "Candela" (kind: bar-widget)

Replaces the built-in Display widget in the bar (user moves it; the built-in stays available). Width 380 logical px, height follows the content up to what the screen allows (SDR white in HDR and the pending strip both add rows, and a scrollbar is not a substitute for room), same chrome as audio/bluetooth popups.

Sections, top to bottom:

- **Hero.** Selected display: name + connector, meta line with mode, refresh, scale and colour state, e.g. `3840×2560 · 60 Hz · 1.6× · SDR 8-bit`. Trailing: a display chip strip when more than one display is present (select which display the popup controls; defaults to the focused one).
- **Brightness.** Backlight or DDC/CI, 1–100 %, wheel on the bar icon still works. Hidden when no backlight and no DDC.
- **SDR white.** Visible only in HDR mode. Slider in cd/m² from 80 to the panel's sustained full-field luminance, with notches at 100, 203 (reference, labelled), 300. Drives `sdr_max_luminance`.
- **Text size.** The built-in popup has it and this one replaces it, so it carries it: Omarchy's `omarchy-display-text-size` on the same stops (9–20 px), labelled as applying to every display, hidden when that command is missing. *(1.2)*
- **Scale.** Existing preset pills, per selected display, clean-scale corrected.
- **Colour.** ButtonGroup `SDR · Wide · HDR`, only the options the EDID supports. Caption under it states the resulting output, e.g. `10-bit · BT.2020 PQ · SDR white 203 cd/m²` or `8-bit · sRGB`.
- **Displays.** One row per display: enabled state, mirror badge, focused dot. Clicking a row selects that display; the power control at its end switches it. Switching off arms and asks for a confirming press, because it blanks a screen the user may be reading; switching on is immediate. Last enabled display cannot be disabled.
- **Actions.** `Identify` (flashes connector name on each display for 2 s) and `Arrange…` (opens the studio).

### 3.2 Studio overlay — "Candela" (kind: overlay)

Summoned from Setup › Monitors (replacing the editor action), from the popup's Arrange…, and via `omarchy-candela open`. Centred card ~1100×720 logical px over the shell scrim, `Color.popups` surface tokens, Esc closes.

Layout: **canvas** left (~60 %), **inspector** right (~40 %), **action bar** bottom.

**Canvas.** Displays drawn to scale in logical pixels on a faint grid. Each block shows connector, model, mode and scale. Selected = selected-state chrome; focused = small dot. Arrow keys nudge 10 px, Shift+arrows 100 px, edges snap to neighbours, overlap is refused (the block turns urgent and Apply disables). Mirrors stack with a badge. A caption under the canvas prints the positions numerically, following the block while it is dragged.

*Dragging.* A block's position is always the position it had when the press
landed plus how far the pointer has travelled since — never its own last drawn
position. Measuring against the block while the block is what you are moving
feeds its displacement back in, and it oscillates instead of following the hand.
The pointer is read in canvas coordinates for the same reason: the mouse area
travels with the block. Snapping is applied to that pointer-derived position, so
a block inside a snap zone stays snapped and one outside it goes exactly where
the hand is, with no memory of either. The snap distance is **12 px measured on
screen**, converted to logical pixels through the current zoom, so the pull
feels the same whether the layout is drawn at a quarter scale or a fortieth — a
threshold fixed in logical pixels becomes hundreds of pixels wide when zoomed
out and glues every block to its neighbours. A press only becomes a drag after
4 px of travel, so clicking a display to select it does not also move it. Only
enabled, unmirrored displays are snapped to, blocked against, or counted in
overlap: the others have no independent position.

**Inspector** for the selected display, sections:

1. **Panel.** Make, model, connector, physical size and ppi, EDID capability line: `HDR10 · BT.2020 · 10-bit · peak 497 cd/m²`. A small gamut triangle: panel primaries from EDID over sRGB / P3 / BT.2020 outlines.
2. **Signal.** Mode dropdown (all `availableModes`), VRR `Off · On · Fullscreen`.
3. **Geometry.** Scale pills, rotation `0° · 90° · 180° · 270°`, position X/Y number fields, mirror-of dropdown, enabled toggle.
4. **Colour.** Mode `SDR · Wide · HDR`; SDR white slider (cd/m²); SDR saturation; SDR transfer `Default · Gamma 2.2 · sRGB`; ICC profile picker (searchable, lists `~/.local/share/icc`, `~/.color/icc`, `/usr/share/color/icc`). Caption when an ICC is set: "ICC forces the sRGB transfer and replaces the colour preset. HDR is unavailable while a profile is loaded."
5. **Workspaces** *(1.2, §11)*. Plan `Off · Split · Alternate · Custom`; "Lives on <display>": one pill per workspace 1–0, ↵ makes this display its home or clears it; "Shows when it lights up": the display's homes; "Send open workspaces home" when the kept plan and the desk disagree. The canvas blocks carry chips for the workspaces that live there, and dragging a chip to another block re-homes it.
6. **Advanced** (collapsed). Preset override (`auto · srgb · dcip3 · dp3 · adobe · wide · edid · hdr · hdredid`), luminance overrides min / max / average (blank = from EDID, shows the EDID value as placeholder), capability overrides `supports_hdr` / `supports_wide_color` (`Auto · Force on · Force off`), `sdrbrightness` multiplier, and the global switch "Auto HDR for fullscreen content" (`render:cm_auto_hdr`).

**Action bar.** `Identify`, `Revert` (to persisted), `Apply`. After Apply of a risky change the bar becomes: `Keep these settings? · Reverting in 15 s · [Keep] [Revert]`. While that strip is up the bar has exactly two keyboard targets, Revert and Keep, with the cursor on Keep; ↵ acts on the highlighted one, `r` and Esc revert. The normal three-target mapping returns when the strip goes. Keyboard hints in caption size at the far left: `j/k move · h/l adjust · ⇥ canvas/inspector · ↵ apply · esc close`.

### 3.3 Small surfaces

- **Identify overlay.** A layer-shell badge per display: connector in display-large, model beneath, 2 s.
- **Apply/revert countdown** is the same component in both the popup (compact) and the studio.
- **Pending strip.** While a change is pending, the service owns a Keep/Revert card at the top of every screen that is not already showing one in the popup or the studio. It exists so the decision is never stranded: the change can take away the very screen it was made from, and a change from the CLI has no surface at all. When no surface is open, the strip on the focused screen has the keyboard with the studio's keys (↵ on the highlighted button, esc reverts, h/l choose); the others are pointer-only. The strip is the plain countdown component on a popup-toned card, without a second frame.
- **OSD** reuse for brightness and SDR white from keys.

### 3.4 CLI

Everything the UI does is a command, so it is scriptable and bindable:

```
omarchy-candela state                  # JSON: displays, capabilities, live and persisted config
omarchy-candela apply  <json|@file>    # live apply via hyprctl eval, starts revert timer
omarchy-candela keep                   # confirm pending apply, persist
omarchy-candela revert                 # re-apply last persisted state
omarchy-candela revert --expired --token <t>   # the timer's form: a no-op unless <t> still matches pending
omarchy-candela persist                # write generated Lua from live state
omarchy-candela identify [connector]
omarchy-candela hdr <on|off|wide> [--display DP-2] [--sdr-white 203]
omarchy-candela edid <connector>       # parsed capabilities as JSON
omarchy-candela icc list
omarchy-candela workspaces home        # send open workspaces home under the kept plan
```

## 4. Colour model

### 4.1 Modes

One user-facing control, three states, mapped to Hyprland fields:

| Mode | bitdepth | cm | Other fields | Shown when |
|---|---|---|---|---|
| SDR | 8 | `srgb` | `sdr_eotf` per user | always |
| Wide | 10 | `auto` (→ wide when supported) | — | EDID has BT.2020 colorimetry or 10 bpc |
| HDR | 10 | `hdr` (`hdredid` via Advanced) | `sdr_max_luminance` = SDR white, `sdr_min_luminance` from EDID min, `max_luminance` / `max_avg_luminance` / `min_luminance` from EDID unless overridden, `sdrsaturation` | EDID HDR static metadata declares ST 2084 |

### 4.2 SDR white

Default on entering HDR: 203 cd/m² (BT.2408 reference white), clamped to the panel's declared max-average luminance. Slider range 80 to max-average. Sustained full-field, not peak, is the ceiling, because mapping SDR white to peak makes a white window dim under the panel's brightness limiter.

### 4.3 Transfer

Hyprland's `cm_sdr_eotf` default is gamma 2.2 since 0.55. The per-display `sdr_eotf` is exposed as `Default · Gamma 2.2 · sRGB` with the caption "Most SDR content was authored on 2.2 displays. Choose sRGB if terminals look lighter than before 0.53."

### 4.4 ICC

Mutually exclusive with HDR in practice: Hyprland forces the sRGB EOTF and overrides the preset when `icc` is set. The UI disables the HDR option while an ICC is loaded and says why, and the backend enforces the same rule: `merge_intent` rejects a merged display carrying both a profile and an HDR preset, so the CLI cannot produce the state either. The picker is gated the other way round too — while a draft is in HDR, the ICC row asks for HDR to be cleared first.

### 4.5 Auto HDR

`render:cm_auto_hdr` is on by default in 0.56.2. Two known bugs (#12971, #15185) make it unreliable when `cm ≠ srgb`. Exposed in Advanced as a global toggle, untouched by default. We do not silently change it.

### 4.6 Capabilities and overrides

Capabilities come from `edid-decode` on `/sys/class/drm/<card>-<connector>/edid`: HDR static metadata block, colorimetry block, bits per primary, desired luminances, chromaticities. Monitors lie; Hyprland's native `supports_hdr` / `supports_wide_color` (−1 / 0 / 1) are the override channel and are exposed in Advanced.

The overrides feed the mode selector, not just Hyprland: `offeredModes(caps, intent)` treats `supports_hdr = 1` as HDR-capable whatever the EDID says and `-1` as not (`0`, the default, trusts the EDID), and the backend rejects an HDR preset on a display whose HDR capability is forced off. Forcing a capability off while the draft sits in that mode moves the draft to the best mode still offered, so a draft never carries a state that cannot be applied.

## 5. Interaction model

| Key | Popup | Studio |
|---|---|---|
| j / k, ↓ / ↑ | next / previous row | next / previous inspector row |
| h / l, ← / → | adjust slider, walk pills | adjust slider, walk pills; on canvas: nudge selected display |
| Shift + arrows | — | nudge 100 px |
| Tab | switch bar panel | canvas ⇄ inspector |
| 1–9 | select display | select display |
| [ / ] | — | previous / next display |
| ⌥ + arrows | — | on canvas: flush against the nearest display on that side, centred |
| 0 | — | on canvas: move to the origin |
| Enter | activate row | activate row / Apply when in action bar |
| a / r / i | — | Apply / Revert / Identify |
| Esc | close | cancel pending countdown, then close |

Mouse hover moves the same cursor; there is never a second highlight.

*Canvas edits that resolve themselves.* A pointer drop on top of another display is a release that missed by a little, not a request for an overlap: it lands flush against the nearest clear edge. Typed positions and keyboard nudges stay exact and may overlap, which paints urgent and disables Apply as before. A mode, scale or rotation change moves the displays that sat flush against, or beyond, the display's old right and bottom edges by the difference, so a flush layout stays flush and a deliberate gap stays the same gap.

## 6. Architecture

### 6.1 Plugin layout

```
omarchy-candela/                  # git repo; symlinked to ~/.config/omarchy/plugins/io.github.pushmotta.candela
  manifest.json                    # kinds: bar-widget, overlay, service
  Popup.qml                        # bar widget + popup
  Studio.qml                       # overlay
  Identify.qml                     # per-screen badge overlay
  Service.qml                      # hotplug listener, state cache, revert-timer watcher
  components/                      # DisplayCanvas.qml, GamutTriangle.qml, NitsSlider.qml, ApplyBar.qml
  Model.js                         # pure logic: scale cleaning, snapping, nits mapping, mode mapping, Lua generation
  bin/omarchy-candela             # single bash entry with subcommands (house style: bash 5, jq)
  bin/omarchy-candela-*           # helpers
  test/                            # bash tests for bin, node tests for Model.js (same shape as upstream test/shell.d)
  README.md
```

The plugin id is provisional (`io.github.pushmotta.candela`); rename is one manifest field.

### 6.2 Backend

Bash, in the style of Omarchy's own shell scripts, reading only `hyprctl -j`, `edid-decode`, `ddcutil` via the existing `omarchy-brightness-display`, and the DRM sysfs tree. JSON out, JSON in. Live changes go through `hyprctl eval` with `hl.monitor({...})` for **every** display in one chunk, never one display alone (see §9).

### 6.3 Persistence

Generated Lua at `~/.local/state/omarchy/toggles/hypr/candela-layout.lua`, which Omarchy already loads on every reload after the user's own `monitors.lua`. One `hl.monitor` per managed display with all managed fields explicit. Header says it is generated and names the command that owns it. The user's `monitors.lua` is never parsed or edited. The file ends by setting a global to a per-keep probe token; `hyprctl eval` can assert it afterwards, which is the only proof that the toggles directory is still being loaded.

The pending change is written beside it as `candela-pending.lua`, in the same form, for as long as it is pending. Omarchy loads the directory in sorted filename order, so the pending file loads after the layout and before Omarchy's own `internal-monitor-*` toggles. A reload from anywhere else during the window, and Omarchy issues them from its clamshell script and on theme changes, therefore re-applies the preview instead of reverting it. Revert deletes the file and reloads.

A display switched off keeps its live mode, position, scale and rotation in intent at the moment it goes off, so its rule brings it back where it was rather than at "preferred" and 0x0, which is what its live geometry reads once it is off.

A display that is not connected keeps the rule the kept file last gave it, word for word, under a comment that says why. A change cannot name a display that is not there, so that rule is still what was chosen; generating rules from connected displays only would drop it on the next keep and bring the display back at Hyprland's defaults, an HDR panel in SDR. *(1.2)*

The workspace plan (§11) follows the monitor rules in the same file.

Alternative considered: a managed block inside `monitors.lua` with a Lua-aware writer (PR #7340 does this well). Rejected for v1: touching the user's file is the thing that produced #6673-class bugs, and generation is testable byte for byte.

### 6.4 Identity

Primary key: connector name. Stored alongside: make, model, serial, EDID hash. When two displays share make/model and serial is blank (this desk), connector is the only key and the UI says so in the Panel section. Profiles (v2) match on the EDID hash set with connector fallback.

### 6.5 Safety

`apply` takes a lock on the state directory, writes the pending file with a transaction token, arms a detached timer bound to that token (`systemd-run --user`, or a detached shell where there is no user manager), and only then applies live through `hyprctl eval`. The order is the guarantee: a change is never live without a revert already armed. If Hyprland rejects any part of the chunk — it is one chunk with one rule per display, so a rejection on the third display would otherwise leave the first two changed — apply unwinds on the spot (timer stopped, pending dropped, `hyprctl reload`) and reports the rejection.

The timer runs `revert --expired --token <token>`. A token that no longer matches the pending file marks a stale timer and does nothing, so the fallback timer, which cannot be cancelled, can never revert a newer change. `keep` and `apply --now` commit intent, regenerate the Lua, reload and check `hyprctl configerrors` through one shared path, so the persisted file is validated the same way whichever door it came in by. Every mutating command holds the lock, and every state write goes through a private temp file and an atomic rename.

After the chunk is accepted, apply reads the compositor back for up to three seconds, comparing every field the intent names against what hyprctl reports (position and mode are skipped on a mirror, cm only for presets Hyprland echoes verbatim, scale to hyprctl's two decimals), and unwinds a change Hyprland accepted but did not land on, naming the field. `keep` and `apply --now` do the same after their reload, after `hyprctl configerrors` and after asserting the layout probe; a revert that does not restore the kept state exits non-zero and says why.

Hyprland adds a headless output named `FALLBACK` whenever the last real display is removed or switched off (`state/FallbackState.cpp`). It is enabled, so counting it would make "every display is off" false in exactly the case below. The backend drops it from every reading of the displays, and `doctor` says when it is present. *(1.2)*

The backend refuses a change that would leave no display enabled, so the CLI is not a way round the popup's rule. Should every display ever be off anyway, most likely a kept layout with one display off booted without the other attached, the service runs `recover`, which switches the built-in panel, or the first display, back on. One attempt per dark spell, so a rescue the compositor refuses cannot loop.

The shell shows the countdown but does not own it, so a shell crash (#9804 class) still reverts. Brightness and SDR white apply immediately with no countdown.

### 6.6 Hotplug

Service listens on Hyprland's socket2 for `monitoradded` / `monitorremoved` and refreshes state. Automatic profile switching is v2.

### 6.7 The built-in panel

Omarchy already manages a laptop's built-in panel: its clamshell script runs on lid switches and on every monitor event (with retries at 1, 3 and 7 s and a 2 s poll while docked), and when the panel should be on it re-enables it with `hyprctl eval` at `position = "auto"` and a scale read from `monitors.lua`, from its own `internal-monitor-scale` state file, or 2. It never reads our layout, so a plain `disabled = true` rule of ours would be undone within seconds, and a numeric scale in `monitors.lua` would fight ours on every lid event. The only off state it respects is its own `internal-monitor-disable.lua` toggle, which its boot-time recovery unit also clears when no external display is connected.

So the panel's off state is that toggle: switching the panel off writes the same file Omarchy's own command writes, switching it on removes it, a pending change records what the file looked like before and revert puts it back, and intent never stores `enabled` for the panel. The kept scale is written to `internal-monitor-scale` on every keep. With the stock `monitors.lua` (scale `"auto"`) the script defers to the compositor's value once the panel is up, which after our reload is ours; `doctor` warns when the file sets a number. The watcher is never stopped: Omarchy's recovery depends on it, and the toggles-directory design coexists with it.

## 7. Scope

| v1 | v2 |
|---|---|
| Popup + Studio surfaces, all sections in §3 | Saved profiles (docked / undocked) with auto-switch on hotplug and lid |
| SDR / Wide / HDR mapping, SDR white, saturation, EOTF, ICC, luminance and capability overrides | HDR test patterns (WS-0 charts) rendered by the shell for probe measurement |
| Mode, VRR, scale, rotation, position with snapping, mirror, enable | ~~Workspace-to-display planner~~ moved to 1.2 (§11) |
| Identify, apply/revert countdown, CLI | Colour-correct screenshots under HDR (separate track, WS-1) |
| Hotplug refresh, every-screen pending strip, readback, load probe, `doctor`, `recover` | Chromium / Electron HDR guidance |

## 8. Decisions (approved 3 Sep 2026)

1. Two surfaces, section order as in §3. **Approved.**
2. SDR white default 203 cd/m² clamped to max-average. **Approved.**
3. Wide as a first-class third state. **Approved.**
4. Plugin id `io.github.pushmotta.candela`, name "Candela", repo `omarchy-candela`, CLI `omarchy-candela`. **Chosen 3 Sep 2026 (was the placeholder `pmotta.displays` / "Displays"): the name says light and precision, which is the differentiator, and the id follows the marketplace's permanent `io.github.<user>.<name>` form.**
5. Generated state file in the toggles directory. **Approved.**
6. Probe availability: **still unknown**; WS-0 numbers wait on it.

Earlier framing decisions: build as a plugin at first-party quality rather than an upstream PR first; start clean rather than on PR #7340; aim well past the existing display tools on design.

## 9. Findings from live tests (3 Sep 2026)

- **10-bit on NVIDIA 610 does not crash this shell.** DP-2 ran `XBGR2101010` for 12 s; Quickshell kept PID 20027, no coredump. The trace in #9804 runs through `libEGL_mesa` and `libgallium`, so that shell was rendering on an integrated GPU. Risk remains on hybrid laptops; §6.5 covers it.
- **Never mix explicit and auto positions.** Declaring DP-2 at `2400x0` while DP-1 stayed on the default `auto` rule moved DP-1 to `4800x0`. Every apply must declare all displays.
- **`hyprctl reload` restores config state**, discarding `hyprctl eval` changes. That is the revert primitive.
- **HDR entry works on this stack.** `bitdepth = 10, cm = "hdr"` on DP-2 gave `XBGR2101010` with `colorManagementPreset: hdr` within one second; shell survived 15 s, no coredump, positions held because both displays were declared in one chunk.
- **SDR white defaults to 80 cd/m² in HDR.** `sdrMaxLuminance` stayed at Hyprland's default of 80 after the flip. That is the "washed out desktop" complaint in one number: the tool must write `sdr_max_luminance` (203 by default, §4.2) on every HDR entry.
- **`hyprctl monitors -j` does not expose the negotiated HDR metadata** (min / max / max-average luminance sent to the panel), only the `sdr*` fields. The Panel section must derive those from EDID plus the config we wrote, and say so.

Later tests the same evening (3 Sep 2026):

- **A global set by a toggles file is visible to `hyprctl eval` after a reload.** The layout probe works on 0.56.2: `doctor` reports the file ran. `eval` prints only `ok` or an error, never a return value, so the probe is an `assert`.
- **The two MateViews' EDIDs differ** (manufacture week 28 against 25 of 2021) although Hyprland reports a blank serial for both and the numeric serial in the base block is identical. The EDID hash is a usable identity on this desk; make, model and serial are not.
- **Omarchy's clamshell script evals the built-in panel at `position = "auto"`** and never reads our layout (§6.7). Omarchy reloads Hyprland from that script, from its modeless-recovery loop and on theme changes, which is why the pending change is on disk (§6.3).
- **Toggles load in sorted filename order** (`find | sort` in `require_all.lua`): `candela-layout` < `candela-pending` < `internal-monitor-*`.
- **The every-screen strip and keep with the studio open were seen live** (screenshots of both screens, no shell warnings); the built-in panel paths, `recover` at boot and the strip's keyboard are covered by the sandbox only.

Found on 5 October 2026 (1.1.1), each seen on the desk and read in the 0.56.2 source:

- **`hl.monitor` starts from the earlier rule for the same output** (`LuaBindingsConfigRules.cpp`) and keeps every field a new call leaves out, until a reload clears all rules. After `disabled = true`, a rule without `disabled` left DP-2 off; `disabled = false` brought it back. A mirror stayed a mirror the same way until `mirror = ""`. So every rule for a display that is on says `disabled = false`, and says `mirror = ""` when intent has no mirror. 1.1.0 left both out: a display it switched off could not be switched on again without a reload, a mirror could not be ended, and `recover` could not light the display it chose. Revert and keep always reload first, so they were never affected. The test compositor merges rules the same way now.
- **`mirrorOf` is the mirrored output's id, as a string** (`"0"`), not its name (`HyprCtl.cpp`). The list is read through one translation to names, or every mirror would fail its own check ("DP-2 mirrors 0, wanted DP-1").
- **`FALLBACK` appears as an enabled output when every real display is off.** Counted as a display, it made "every display is off" false in the one case `recover` is for; `live_json` leaves it out. `recover` then lit DP-1 with both MateViews dark.

## 10. Prior art, read but not copied

- **PR #7340**: good ideas worth crediting — EDID-gated HDR switch, SDR white capped at sustained luminance, overlap tidy before rotation, Lua-aware writer. Different decisions here: three-state colour mode instead of a switch, generated file instead of editing monitors.lua, revert timer outside the shell.
- **Omarchy's own monitor scripts** (`omarchy-hyprland-monitor-clamshell`, `-internal`, `-watch`, `omarchy-hw-recover-internal-monitor`): the built-in panel's owner on every Omarchy machine. Read for §6.7; coexisted with, never replaced.

## 11. Workspace planner (1.2)

Design review 02 (5 October 2026, source `design/workspace-planner-review.html`) put eight decisions; all eight recommendations were approved the same day.

### 11.1 Decisions

1. **Off until the user turns it on.** No rules and no moves until a plan is chosen; a display Candela has not seen never gets one.
2. **The plan is stored, not a preset name.** `intent.workspaces = {homes: {"1".."10": display}, shows: {display: workspace}}`. Presets only fill `homes`, so nothing has to guess what a preset means for a display that appears later.
3. **Displays are named by connector**, like the monitor rules. Both MateViews report the same description, and Hyprland matches `desc:` by prefix and takes the first display that connected, so a description cannot tell them apart. `desc:` can come with saved profiles.
4. **No persistent workspaces.** Each display's lowest-numbered home (or its chosen one) gets `default = true`. With a home set, SUPER+N already opens in the right place; persistent empty workspaces would add stops to SUPER+TAB and the bar cannot show them.
5. **A workspace-only change has no countdown.** Nothing in a plan can blank a screen. It is kept at once, and `revert` undoes it once (plan and placement) until anything else is applied. A change that also touches a display keeps the countdown for everything.
6. **Applying a plan moves open workspaces home**, the inspector naming every move first.
7. **Chips on the canvas, and the plan in a strip under it** (revised 5 Oct after Pedro's first hands-on: as the last section of the inspector, after Colour, it was below the fold and easy to miss, and with the plan off the canvas showed nothing). The strip holds `Off · Split · Alternate · Custom` and a line reading the plan back; `w` goes to it, and it sits in the Tab order between canvas and inspector. With no plan, the chips show where the open workspaces are now. The inspector keeps the selected display's rows (Lives on, Shows, Send home). The popup is unchanged.
8. **1.2 = the planner + rules kept for unplugged displays (§6.3) + `FALLBACK` (§6.5) + text size (§3.1).**

### 11.2 How Hyprland 0.56.2 treats workspaces

Read in the v0.56.2 source (`src/`), and exercised against the test compositor; on hardware only as far as §11.5 says.

- `hl.workspace_rule` merges into an earlier enabled rule with the same workspace text, field by field, later wins; `monitor` is only copied when non-empty (`config/shared/workspace/WorkspaceRuleManager.cpp:25-32`). Omarchy's layout toggle writes `{ workspace = "3", layout = "scrolling" }` from `~/.local/state/omarchy/workspace-layouts/`, loaded after the toggles directory, so writing the same text (`"3"`) makes the two one rule. For the same reason Candela never calls `set_enabled(false)` on its rule: it would switch Omarchy's layout off too. Removing a plan is a reload.
- A workspace is created on its rule's monitor (`state/WorkspaceState.cpp:58-64`); `focus{workspace=N}` then moves focus there.
- A reload clears every rule and re-reads the files, and moves no open workspace (`config/lua/ConfigManager.cpp:700, 850`). Candela moves them with `hl.dsp.workspace.move`, the focused one last because its focus and pointer follow it.
- On any monitor connect, every workspace whose rule names a connected monitor is moved there (`output/Monitor.cpp:118`, `state/WorkspacePlacementController.cpp:130-149`). A workspace moved by hand goes home at the next connect.
- On disconnect, and on `disabled = true`, which takes the same path (`config/shared/monitor/MonitorRuleManager.cpp:183-187`), workspaces go to the first other monitor in connect order (`output/Monitor.cpp:421-427`).
- When a visible workspace moves away, its old monitor gets the lowest free id not bound to another monitor (`state/WorkspacePlacementController.cpp:257-291`).

### 11.3 Backend

- `merge_intent` validates the block (workspaces 1–10, display names, never `FALLBACK`), merges it like display fields (`null` removes an entry, the whole block `null` turns the plan off), drops a show whose workspace left that display, and turns an empty plan off. `apply` refuses a home that is, or is becoming, a mirror.
- `generate_lua` appends one `hl.workspace_rule({ workspace = "N", monitor = "…"[, default = true] })` per home after the monitor rules, in both the file and the live chunk.
- `apply` records the open workspaces' placement in the journal (`workspacesBefore`) before anything moves, then after the chunk lands and is read back, moves the open workspaces home and reads `workspaces -j` back. A workspace that does not move unwinds the whole change.
- `keep` and `apply --now` also compare `workspacerules -j` with the plan after the reload.
- `revert`, the watchdog, and a failed keep put workspaces back from `workspacesBefore` after the reload. Best effort: a workspace closed since, or whose display has gone, is left where it is.
- A workspace-only change is kept at once and records `workspaces-undo.json` (the plan it replaced, and the placement); a plain `revert` with nothing pending applies it back, replacing rather than merging, and restores the placement.
- `state` carries `workspaces: {kept, pendingConfig, open, undo}`; `workspaces home` moves open workspaces home under the kept (or pending) plan; `doctor` checks the live rules against the plan and lists homes on displays not connected.

### 11.4 Studio

The plan's draft is one object (`draftPlan`), not per-display fields; the strip and the inspector's workspace rows share one changed mark, and ⌫ on any of them drops the plan draft. Dragging a chip with no plan starts a custom plan from where the open workspaces are, so only the dragged one changes. Live workspace positions come from Quickshell's Hyprland module, so chips follow a workspace moved by hand while the studio is open. Choosing Custom from Off starts from where the open workspaces are; from a preset it changes nothing. Setting a mirror moves that display's homes to the display it mirrors in the same draft.

### 11.5 What is verified

Suite: the generator byte for byte, validation, merge, undo, mixed changes with revert, a move the compositor ignores, homes on an unplugged display, and the Model's presets, kinds, moves and chips. The test compositor follows the source as read in §11.2. On the desk, 5 October 2026 (two MateViews, Hyprland 0.56.2, the live shell running this branch): the Workspaces section and the chips rendered with the real workspaces; Alternate drafted from the keyboard, applied with `a` and kept at once with no countdown; `workspacerules -j` then held the ten rules with `default` on 1 and 2 and no workspace moved; with DP-1 focused, opening workspace 4 created it on DP-2; `r` in the studio undid the plan, leaving no rules and the workspaces where they were; `doctor` agreed at each step and the shell logged nothing from Candela. Not yet seen on hardware: a plan that moves open workspaces and its undo, dragging a chip, Send home, the mirror re-homing, an unplug with a plan on, the text size slider, and a real all-displays-off `FALLBACK` (the suite covers each).

Later, 5 October 2026, with 1.3 built on it: Split applied from the studio's keys moved workspace 2 from DP-2 to DP-1 (DP-2 then showed 6), and `r` moved it back and switched the plan off. `FALLBACK` was seen during the 1.1.1 recover test. Two faults were found and fixed. With virtual displays present the presets counted them as homes (Split put 7 to 0 on two virtual displays): `planOrder` now leaves virtual displays out, and a custom plan can still home a workspace there. With four displays the canvas zooms out and a second row of chips covered DP-2's name: chips now get only the room below the name, shrinking from 24 to 16 and taking the size caption's room if they must. Still for a hand: dragging a chip, Send home, an unplug with a plan on, the text size slider (it resizes text across the desktop through Omarchy's own command).

## 12. Virtual displays (1.3)

Design review 03 (5 October 2026, source `design/virtual-displays-review.html`) put ten decisions; all ten recommendations were approved the same day. Pedro's three uses: an extra screen on a tablet or laptop over VNC, a fixed-size stage to share or record, and a test bench at sizes he does not have. "Switch all screens together" desktops stay with the existing plugins.

### 12.1 Decisions

0. **SDR only, enforced.** A virtual display takes only `mode`, `position`, `scale`, `transform` and `enabled`; `merge_intent` refuses colour, VRR, mirror and ICC fields for it, with the reason: nothing that shows it carries HDR or wide colour (RFB sends RGB with no transfer function or primaries, wayvnc and RealVNC are 8 bits per channel, the preview is an SDR texture). The studio already hid those controls; the CLI now agrees. *(5 October.)*
1. **Names** `VIRTUAL-n`, with a label ("Stage") beside them. Hyprland keeps a name given to `output create headless`, so rules and screen-share pickers see a stable, plain one.
2. **Recreated when the shell starts** (`virtual restore` from the service), since Hyprland forgets them on restart.
3. **Placement per display, Beside or Apart**, the use choosing the default: an extra screen and a test bench beside, a stage apart (`VIRTUAL_GAP` = 320 logical px past the desk). Beside tries right of the rightmost real display, then below it, then left of the leftmost, taking the first free place. *Test bench revised to beside on 5 October, with the pointer rule below.*
4. **No countdown** for a change that touches only virtual displays (or only the plan); `revert` undoes the last one. Undo is one record for both (`undo.json`, the whole previous intent plus workspace placement), cleared by any later apply. *Revised 5 October:* the record lasts two minutes and names what it undoes ("adding VIRTUAL-1"); the button reads *Undo* while it lasts. An undo with no time limit let a Revert pressed an hour later remove a virtual display in use.
5. **A named workspace of its own**, the label as a slug, as each virtual display's default, so it never takes one of 1–10.
6. **The parking guard**: on `monitorremoved` the service runs `virtual guard`, which moves any workspace on a virtual display that neither is its own nor lives there by plan to the leftmost real display.
7. *(30-second login, from the iPad, 5 October:* neatvnc's `HANDSHAKE_TIMEOUT` is 30 s, compiled in, and RealVNC on the iPad asks for the password inside it; typing a 16-character mixed-case password timed out twice. Passwords became four groups of four lowercase letters and digits, and *Show* draws a QR code of the password (`qrencode`, an Omarchy base package) to scan and paste. RealVNC on iPadOS connected with RSA-AES once the password was pasted.)
   **Network viewing is Candela's own wayvnc**: RSA-AES, username `candela`, a generated 16-character password and an RSA key (`ssh-keygen -m pem`), both kept 0600; one LAN address chosen from the machine's own (never loopback, a container or VM bridge, or every interface); port 5900+n; off after each login unless asked for at login. *Revised 5 October:* wayvnc is offered with one click (`virtual install`, Omarchy's `omarchy pkg add wayvnc` in a terminal), which adds the marketplace's package-management capability; Pedro accepted that. *Pointer rule, from the desk:* Hyprland has one cursor and a viewer's input moves it; a click in a VNC window left the real pointer on the apart stage, past a gap the mouse cannot cross. So a display placed apart is served watch-only (`wayvnc -d`), one placed beside takes input, and moving a display that is on the network starts its server again under the rule.
8. **macOS Screen Sharing is refused**, with the reason shown: it only connects unencrypted.
9. **The window view is drawn by the shell**: Quickshell's `ScreencopyView`, live, in a floating window owned by the service, with no VNC and nothing installed. Watch-only; a preview asked for while a virtual display has focus first gives focus to a real display, so it never captures itself. *Revised on the desk, 5 October, twice:* the approved VNC viewers did not hold up. gvncviewer always asks the server to resize to its window, and with wayvnc's resizing off neatvnc half-accepts the request, so the next frame falls outside the size the client was told and gvncviewer disconnects; remote-viewer cannot open a Unix socket; TigerVNC worked, but was one more package, and its input moved the real cursor onto the apart stage. A prototype of the shell's own capture showed VIRTUAL-1 live at about 5 % CPU in a separate process.
10. **1.3**, after 1.2, with the desk probe first.

### 12.2 What wayvnc and Hyprland do

- `hyprctl output create headless NAME` takes our name; `output remove` refuses a real display (`src/debug/HyprCtl.cpp:1770-1810`). Monitor rules apply to it at any size; VRR is skipped (`src/output/Monitor.cpp:259`, `src/config/shared/monitor/MonitorRuleManager.cpp:211`).
- A new display takes the lowest free workspace unless a default rule names one; named workspaces have ids below −1337 (`src/output/Monitor.cpp:1276-1330`, `src/state/WorkspaceQueryCore.cpp:83`).
- A pointer outside every display snaps to the nearest one, so a display past a gap cannot be reached (`src/pointer/PointerManager.cpp:723-770`).
- wayvnc serves one output per process (`-o`), listens on 127.0.0.1:5900 by default, and when its output disappears switches to the previous one and keeps serving it (wayvnc `src/main.c:68-69, 250-278`). Every removal path here stops its servers first.
- With authentication off wayvnc offers no security at all; with it, RSA-AES with a username and password needs only a key file (neatvnc `src/server.c:302-325`, wayvnc `src/main.c:1566-1588`). The neatvnc Arch ships lacks two fixes: Apple DH aborts and a WebSocket client crashes it before authentication (neatvnc #170), so `relax_encryption` and `ws:` are never used.
- wayvnc's pointer is bound to the display it serves and Hyprland maps it there; the keyboard is shared (Hyprland `src/devices/VirtualPointer.cpp:43`).
- `--gpu` is never passed: no VAAPI encoder on the desk's NVIDIA cards, and open crash reports.
- `-d` serves a display watch-only: no virtual pointer or keyboard is made for it (wayvnc `src/main.c:390`).
- Each wayvnc gets a config of its own (`-C`), so `~/.config/wayvnc/config` never applies, and `-R` turns off client-driven resizing. Without it, wayvnc 0.10.1 resizes *any* output to the client's window and moves it to 0,0 (`src/output-management.c:366-377`); the `HEADLESS-` name check there only feeds a log line (`src/main.c:776-811`).

### 12.3 What is verified

Suite: add (apart and beside, named workspace, no countdown, undo), survival across a reload and restore after a restart, the window server on a socket with no address, network refusals (every interface, a VM bridge), the network config (authentication, address, port, key, never relaxed, 0600), a password kept between starts, state and doctor, removal stopping servers before the output, revert bringing it back, the guard, `recover` ignoring virtual displays, validation.

On the desk, 5 October 2026, before any code: with a rule and a named default workspace evaluated first, `hyprctl output create headless VIRTUAL-1` gave a 1920×1080@60 output at 5200,0 on workspace "stage" (id −1337); DP-1, DP-2 and workspaces 1 and 2 did not move; `grim -o VIRTUAL-1` showed Omarchy's bar and wallpaper on it; Candela 1.2 listed it with no EDID; removing it took the empty named workspace with it, and a reload restored everything exactly. Later the same day, with wayvnc 0.10.1 installed: network viewing listened only on 192.168.1.89:5901, a raw handshake was offered only RSA-AES-256 and RSA-AES (no None, no DES, no Apple DH), and `doctor` reported it; TigerVNC showed the stage over the private socket, and gvncviewer and remote-viewer failed as recorded under decision 9. Not yet on hardware: the built-in preview inside Candela (a stand-alone prototype of it worked), the watch-only rule, the install button, a tablet, the call picker.

Since then, all on the desk on 5 October 2026: Pedro used an extra screen from an iPad with RealVNC Viewer ("works great"); whether the QR code was the way the password got there is not recorded. Hyprland's screen-share picker (`hyprland-share-picker`, xdg-desktop-portal-hyprland 1.4.1) lists virtual displays as screens ("Screen 3 at 6400, 0 (1920x1080) (VIRTUAL-2)"); a full share through it was not run, since the picker could not be driven from a script. `wf-recorder -o VIRTUAL-2` recorded 1920×1080; `gpu-screen-recorder -w VIRTUAL-2` refused, listing only DP-1 and DP-2, because its KMS backend sees the card's outputs, and that backend is the default of Omarchy's own screen recording (`OMARCHY_SCREENRECORD_USE_PORTAL=true` switches it to the picker). TigerVNC asks to confirm an RSA-AES server key on every connection and keeps no record of it, so a resize with a viewer connected was not tested from a script.

### 12.4 After the first release candidate

Added on 5 October 2026 after Pedro's review of what to improve before 1.3:

- **Name and device.** A change may carry `"virtual": {NAME: {label, device}}`, validated (an existing virtual display; a name of 1 to 32 characters on one line; a device id or null) and kept at once like the rest of a virtual-only change. The device is the preset it was picked as: five pairs of presets share a size and scale (iPad Air 13″ and iPad Pro 12.9″, Pixel Tablet and Galaxy Tab S9 and MacBook Air M1, Framework 13 and Surface), and reading the size back named the first of them. The studio shows the remembered device while the size is still that device's, either way round. The name names the workspace (`virtual_workspace_names`); a rename renames the open workspace with `hl.dsp.workspace.rename({ workspace = "name:…" })`, by name because a named workspace's negative id would read as "back that many", and undo renames it back. Seen on the desk: "Tablet" to "Pixel Test" renamed workspace −1337 in place with its window on it, and undo renamed it back.
- **Nobody viewing.** State counts the windows on each virtual display (`hyprctl clients -j` by monitor id). With its window closed and no network client, the studio says nobody is viewing it through Candela, with the count, and *Bring them here* runs `virtual gather`: every window on it moves, silently, by address, to the workspace the focused real display shows (`hl.dsp.window.move({ workspace, follow = false, window = "address:…" })`). The popup tags it "no viewer". Switching it off when the last viewer leaves was not done: wayvnc would then serve a real display. Seen on the desk: a test window moved onto the display and back; the popup tag is not yet seen.
- **QML that compiles.** `test/qml-load-test.sh` compiles every QML file in a real Quickshell, against a config of its own whose `qs.*` modules are links to Omarchy's shell, and skips where there is no Quickshell or Wayland session (CI). It fails on the studio from before `a7a6ded` ("Duplicate method name"), which qmllint passed.

