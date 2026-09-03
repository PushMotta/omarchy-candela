# Candela

Arrange displays, drive them at their real capabilities, and switch colour
modes (SDR, wide gamut, HDR) with a safe apply and revert. An Omarchy shell
plugin for Hyprland 0.56+ with the Lua config.

Two surfaces, one backend:

- **Popup** in the bar: brightness, SDR white while in HDR, scale, one
  `SDR · Wide · HDR` control gated by the panel's EDID, the display list,
  Identify and Arrange.
- **Studio** overlay: arrangement canvas in logical pixels with snapping, an
  inspector for signal, geometry and colour (mode, refresh, VRR, scale,
  rotation, position, mirror, enable, colour mode, SDR white, SDR transfer,
  ICC profile) and an Advanced section (colour preset, mastering luminances,
  capability overrides, auto-HDR).

Every risky change is applied live and **reverts itself in 15 seconds unless
kept**. The timer runs outside the shell, so a shell crash still reverts. The
compositor is read back after every apply, so a change Hyprland accepted but
did not land on is undone rather than shown as pending. A Keep/Revert strip
sits on every screen while a change is pending, so the decision is never
stranded on a display the change just switched off.

The design and the reasoning behind it live in [DESIGN.md](DESIGN.md).

## What it looks like

The studio: arrangement canvas on the left, inspector on the right, keyboard
hints and the apply bar along the bottom. The gamut plot draws the panel's
EDID primaries (solid) against BT.2020, P3 and sRGB (dashed).

![The Candela studio, showing two MateView panels arranged side by side with the inspector open on DP-1](docs/studio.png)

The bar popup, for what you change often. `SDR · Wide · HDR` is gated by what
the panel actually reports, and the line under it says what the compositor is
doing right now rather than what was asked for.

<img src="docs/popup.png" alt="The Candela bar popup, showing brightness, scale, colour mode and the display list" width="330">

## Install

```bash
omarchy plugin add https://github.com/PushMotta/omarchy-candela.git --enable
```

That clones the repo into `~/.config/omarchy/plugins/io.github.pushmotta.candela`, validates
the manifest, and enables the plugin over IPC. Nothing is executed from the
repo during install, no hook runs, and no sudo is needed. Without `--enable`
it asks first, so you can read the code before switching it on. To develop
against a checkout instead, symlink the checkout to that same path and run
`omarchy-shell shell rescanPlugins`.

Update with `omarchy plugin update io.github.pushmotta.candela`; it shows the diff before
applying it.

The bar widget lands in the right section. Optional keybindings, in
`~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + CTRL + D", "Candela", "omarchy-shell io.github.pushmotta.candela popup")   -- replaces the built-in Display popup
o.bind("SUPER + CTRL + SHIFT + D", "Candela studio", "omarchy-shell shell toggle io.github.pushmotta.candela")
```

To make **Setup › Monitors** open the studio instead of the config editor, add
to `~/.config/omarchy/extensions/omarchy-menu.jsonc` (it hot-reloads):

```jsonc
"setup.monitors": {"icon":"󰍹","label":"Monitors","action":"omarchy-shell shell toggle io.github.pushmotta.candela"},
```

Requirements already present on Omarchy: `hyprctl`, `jq`, `edid-decode`
(v4l-utils), `ddcutil`/`brightnessctl` through `omarchy-brightness-display`,
`socat`, `systemd-run`. Nothing else is downloaded or installed. The plugin
runs as your user and asks for no privileges; the one system service it
touches is a transient `systemd --user` timer for its own revert countdown.

## Remove

```bash
omarchy plugin disable io.github.pushmotta.candela
omarchy plugin remove io.github.pushmotta.candela
```

`remove` deletes the git checkout (or unlinks a symlink). It does not touch
what the plugin wrote for you, so that your display layout survives a
reinstall. To go back to a stock machine, also:

```bash
rm -rf ~/.local/state/omarchy/candela                           # intent and pending state
rm -f  ~/.local/state/omarchy/toggles/hypr/displays-{layout,pending}.lua   # the generated rules
hyprctl reload                                                   # back to your own monitors.lua
```

`internal-monitor-disable.lua` and `internal-monitor-scale` in that directory
are Omarchy's own files; this plugin writes them on Omarchy's behalf and
Omarchy's tools keep understanding them after it is gone.

and drop the optional `setup.monitors` override and keybindings above if you
added them. No file outside those paths is ever written.

## Keys

| Key | Popup | Studio |
|---|---|---|
| j / k, ↓ / ↑ | next / previous row | next / previous inspector row |
| h / l, ← / → | adjust slider, walk pills | adjust the current row; on the canvas nudge 10 px (⇧ 100) |
| Tab | switch bar panel | canvas ⇄ inspector ⇄ actions |
| 1–9 | — | select display |
| [ / ] | — | previous / next display |
| ⌥ + arrows | — | on the canvas: flush against the nearest display on that side, centred |
| 0 | — | on the canvas: move to the origin |
| Enter | select the display under the cursor; on the display already selected, its power | activate row / open dropdown / focus a number field |
| a / r / i | — | Apply / Revert or Discard / Identify |
| Esc | close | cancel a pending countdown, then close |

Mouse hover moves the same cursor; there is never a second highlight.

While a change is pending, a Keep/Revert strip sits at the top of every screen
that is not already showing one in the popup or the studio. When neither is
open, the strip on the focused screen has the keyboard: ↵ acts on the
highlighted button (Keep by default), esc reverts, h/l choose. The strip
belongs to the service rather than to a window, so it survives the change
taking away the screen it was made from, and it appears for changes made from
the command line too.

On the canvas, a display dropped on top of another lands flush against the
nearest clear edge instead of overlapping. Changing a display's mode, scale or
rotation moves the displays that sat flush against its old right or bottom
edge by the difference, so a flush layout stays flush.

Clicking a display in the popup's list selects it. Switching one **off** is the
one action that will not happen on a single press: the power control at the end
of the row arms first and says `turn off?`, and a second press within four
seconds carries it out. Moving off the row, or letting the window lapse, puts
the safety back on. Switching a display on is immediate, and the last enabled
display cannot be switched off at all. In the studio, `Enabled` stages the
change like every other field and needs `a` to apply.

## Command line

Everything the UI does is a subcommand of `bin/omarchy-candela`. It is not
on your PATH by itself; the popup, the studio and the revert timer call it by
its full path. To use it from a terminal, link it once:

```bash
ln -s ~/.config/omarchy/plugins/io.github.pushmotta.candela/bin/omarchy-candela ~/.local/bin/
```

```
omarchy-candela state                          # JSON: displays, EDID capabilities, live + kept config, pending
omarchy-candela hdr on|off|wide [--display DP-2] [--sdr-white 203] [--now]
omarchy-candela apply [--now] '{"displays":[{"name":"DP-2","scale":2}]}'
omarchy-candela keep | revert | persist
omarchy-candela revert --expired --token <t>   # the timer's form; does nothing unless <t> still matches pending
omarchy-candela brightness DP-2 [+5%|5%-|40%]
omarchy-candela identify | open
omarchy-candela edid DP-2
omarchy-candela icc list
omarchy-candela recover                        # every display off? switch the built-in (or first) one back on
omarchy-candela doctor                         # is the layout loaded, does the compositor agree, what could fight it
```

Change JSON accepts, per display: `mode`, `position`, `scale`, `transform`,
`vrr`, `enabled`, `mirror`, `bitdepth`, `cm`, `sdr_eotf`, `sdrbrightness`,
`sdrsaturation`, `sdr_min_luminance`, `sdr_max_luminance`, `min_luminance`,
`max_luminance`, `max_avg_luminance`, `icc`, `supports_hdr`,
`supports_wide_color`; and `global.cm_auto_hdr`. Everything is validated
against what `hl.monitor` accepts before anything is written, unknown keys are
rejected at every level, and two rules hold on the merged result rather than
just the change: an ICC profile and an HDR preset cannot coexist, and an HDR
preset is refused while `supports_hdr` is forced off (`-1`).

## How it persists

- `~/.local/state/omarchy/candela/intent.json` — what you chose, per connector.
- `~/.local/state/omarchy/candela/pending.json` — an applied-but-not-kept change with its expiry and transaction token.
- `~/.local/state/omarchy/toggles/hypr/candela-pending.lua` — the pending
  change in the same form as the layout, loaded after it, for as long as the
  change is pending.
- `~/.local/state/omarchy/toggles/hypr/candela-layout.lua` — generated from
  intent plus live geometry. Omarchy loads every file in that directory after
  your own `~/.config/hypr/monitors.lua`, so these rules win, and your file is
  never parsed or edited. Every connected display gets a full rule: mixing an
  explicit position with Hyprland's auto placement moves displays.

`hyprctl reload` restores the kept configuration; that is the revert primitive.
Because the pending change is on disk too, loaded after the layout, a reload
from anywhere else during the window (a theme change, Omarchy's clamshell
script reacting to a lid or monitor event) re-applies the preview instead of
silently undoing it. Revert deletes that file and reloads.

`apply` is ordered so that a change is never live without a revert already
armed: it takes a lock, writes the pending file with a transaction token, arms
the timer bound to that token, and only then applies through `hyprctl eval`.
If Hyprland rejects any part of the chunk, apply unwinds on the spot and reports
the rejection. A timer whose token no longer matches the pending file does
nothing, so a stale one can never revert a newer change. After the chunk is
accepted, apply reads the compositor back for up to three seconds and undoes
a change Hyprland did not land on, naming the field. `keep` and `apply --now`
reload, check `hyprctl configerrors`, ask Hyprland whether the layout file
actually ran (the file sets a global for exactly this question; `doctor` asks
it too), and read the displays back once more.

A display that is switched off keeps its mode, position and scale in intent,
so it comes back where it was. Should every display ever be off, for instance
a kept layout with one display off booted without the other attached, the
service runs `recover`, which switches the built-in panel, or the first
display, back on.

## The built-in panel

A laptop's built-in panel is switched off through Omarchy's own toggle, the
`internal-monitor-disable.lua` file that its clamshell script honours and its
recovery service clears at boot when nothing else is connected, never through
a rule of ours: that script would re-enable a plainly disabled panel within
seconds of any lid or monitor event. Reverting a change that touched the panel
puts the toggle back as it was. The panel's kept scale is also written to
`internal-monitor-scale`, which the same script reads when it brings the
panel back. With the stock `monitors.lua` (scale `"auto"`) the two never
disagree; `doctor` warns when yours sets a number there.

## Colour model

| Mode | bitdepth | cm | also written |
|---|---|---|---|
| SDR | 8 | `srgb` | — |
| Wide | 10 | `auto` (→ wide when supported) | — |
| HDR | 10 | `hdr` (`hdredid` via Advanced) | `sdr_max_luminance` = SDR white, default 203 cd/m² (BT.2408) clamped to the panel's max-average luminance; `sdr_min_luminance` from EDID or 0.2 |

Hyprland's own default for SDR white in HDR mode is 80 cd/m², which is why
HDR desktops look washed out. This tool always writes it on HDR entry.

## Development

```bash
./test/all               # bash tests (sandboxed fake compositor + EDID fixture) and node tests for Model.js
omarchy-restart-shell    # after editing QML; a symlinked plugin is not hot-reloaded
journalctl --user -t omarchy-shell -f   # QML warnings and errors
```

Layout:

```
manifest.json      kinds: bar-widget (Popup.qml), overlay (Studio.qml), service (Service.qml)
Model.js           pure logic shared by QML and tests
components/        ApplyBar, DisplayCanvas, GamutPlot
bin/               omarchy-candela, omarchy-candela-edid
test/              all, *-test.sh, fake-hyprctl.sh (a compositor that keeps state), model.test.js, fixtures/
design/            the visual design review (HTML, real theme tokens)
```

## Licence

MIT, the same as Omarchy itself, so the code can move upstream without a
licensing question if it ever earns a place there.
