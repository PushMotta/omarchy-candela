# Handoff — Displays for Omarchy

Written 3 September 2026 at the end of session 1. Read this first in a new session, then `DESIGN.md` for the why and `README.md` for the how.

## Where things stand

The plugin exists, is installed on this machine, and works end to end on real hardware. Five commits on `main` in this directory (`git log --oneline`):

```
fad17e1 Polish: compact pending strip in the popup, plain numbers in position fields
5091fd4 Fix expired revert killing its own unit; follow live focus; guard bar reads
fe952b7 Fix live apply: hyprctl parses a leading Lua comment as a flag
44d3278 Displays plugin 0.1: backend, popup, studio, service
06414e0 Design review 01: spec and mockups for Displays
```

Nothing is pushed anywhere; there is no remote yet.

### Verified live (with screenshots, on the two Huawei MateViews, NVIDIA 610.57.04, Hyprland 0.56.2, Omarchy 4.0.2)

- Popup renders in the bar with DDC brightness, EDID-gated `SDR · Wide · HDR`, SDR white slider in HDR with the 203 cd/m² mark, display list with focused / HDR tags, Identify, Arrange, and the pending countdown strip under the hero.
- Studio renders with canvas, panel identity + EDID capability line + gamut plot, signal, geometry (scale, rotation, X/Y, mirror, enabled), colour, Advanced.
- `omarchy-displays hdr on --display DP-2` puts DP-2 in `XBGR2101010` / `cm=hdr` with `sdr_max_luminance = 203` within a second. `keep` writes a clean layout file; `hyprctl configerrors` is empty. A change left alone reverts through the detached systemd timer (`omarchy-displays-revert.timer`). `hdr off --now` returns to sRGB.
- Identify badges appear on each screen. Shell journal clean after every restart.
- Test suite green: `./test/all` (bash sandbox with fake hyprctl + EDID fixture, node tests for Model.js).

### Not yet verified

- **Keyboard navigation** in popup and studio. `wtype` sends keys to the focused toplevel, not the layer surface, so it could not be automated. It follows the first-party cursor pattern exactly; needs a real keyboard pass: j/k/h/l/Enter/Esc in the popup, Tab between canvas/inspector/actions, arrows to nudge, `a`/`r`/`i`, `1`–`9`.
- Mouse dragging on the studio canvas, snapping guides, overlap refusal.
- Live rotation, mirror, disable/enable, mode and VRR changes through the studio (backend paths are unit-tested; only HDR and scale were exercised live).
- ICC picker with real profiles (none installed here; `omarchy-displays icc list` returns `[]`).
- Hotplug refresh (socat listener on Hyprland's socket2) and behaviour with one bar per screen when a display is removed.
- Whether DP-2 visibly showed an HDR badge / picture change from the monitor's side. Only Pedro can see that.

## How this machine is wired

- Plugin source: this directory. Installed as a symlink `~/.config/omarchy/plugins/pmotta.displays` → here, enabled in the bar's right section (`~/.config/omarchy/shell.json`).
- `~/.config/omarchy/extensions/omarchy-menu.jsonc` has a `setup.monitors` override that opens the studio (backup of the original beside it with a `.bak.<epoch>` suffix).
- Generated state: `~/.local/state/omarchy/displays/{intent.json,pending.json}` and `~/.local/state/omarchy/toggles/hypr/displays-layout.lua`. The layout file currently declares both displays explicitly at their normal geometry (`scale 1.6`, `bitdepth 8`, `cm srgb`). Deleting the layout file and `hyprctl reload` returns the machine to the stock catch-all rule.
- Super+Ctrl+D still opens Omarchy's built-in Display popup. README has the one-line rebinding to `omarchy-shell pmotta.displays popup`.
- Design review artifact (mockups in real theme tokens): https://claude.ai/code/artifact/f95e7efb-ad4f-473b-b663-00fc077cd274 — republish with that `url` to keep the link; source is `design/displays-design-review.html`.

## Development loop

```bash
./test/all                                   # always green before a commit
omarchy-restart-shell                        # REQUIRED after QML edits: a symlinked plugin is not hot-reloaded,
                                             # and `omarchy-shell shell rescanPlugins` does not replace compiled QML
journalctl --user -t omarchy-shell --since -2min | grep -iE 'pmotta|TypeError|Cannot'
omarchy-shell pmotta.displays popup          # toggle the bar popup (opens on Hyprland's live focused screen)
omarchy-shell shell toggle pmotta.displays   # toggle the studio overlay
omarchy-shell pmotta.displays state | jq     # what the service holds
grim -o DP-2 shot.png                        # screenshot one output; `omarchy capture screenshot` dismisses popups
hyprctl dispatch 'hl.dsp.focus({ monitor = "DP-2" })'   # keyword-form `focusmonitor` no longer parses on 0.56
```

Live testing flips Pedro's real displays. He asked to be **warned before** anything that changes a monitor mode: send `omarchy-notification-send "…" -t 8000` and wait a few seconds, as the flow scripts in this session did.

## Gotchas learned (all fixed in code, keep them in mind)

1. `hyprctl eval` parses a chunk that starts with `--` as its own flag and prints usage. The live chunk must start with a statement; only the persisted file carries the header comment.
2. sysfs `edid` attributes report size 0 to `stat`, so `-s` is false; count bytes instead.
3. A `revert --expired` running inside its own transient systemd unit must not `systemctl stop` that unit before removing `pending.json`, or it SIGTERMs itself. Interactive revert does stop the timer.
4. A transient unit may lack `HYPRLAND_INSTANCE_SIGNATURE`; the CLI recovers it from the newest `$XDG_RUNTIME_DIR/hypr/*` dir.
5. Declaring one display's position explicitly while another stays on the catch-all `auto` rule moves the auto one. Every apply declares every enabled display.
6. `bar` can be null on a Popup instance for a moment during monitor changes; all colour and font reads go through `root.fg` / `root.fam` / `root.urgentColor`.
7. The cached `state.focused` lags one refresh; screen choice uses `Hyprland.focusedMonitor` (`service.liveFocused`).
8. `hyprctl monitors -j` exposes `colorManagementPreset` and `sdr*` but not `bitdepth` (derive from `currentFormat`) nor the negotiated mastering luminances (come from EDID + our config).
9. Hyprland's default `sdr_max_luminance` is 80: the tool writes 203 (clamped to the panel's max-average) on every HDR entry.
10. Issue #9804's 10-bit Quickshell crash did not reproduce here (NVIDIA EGL); its trace is Mesa/iGPU. The detached revert timer is the mitigation for hybrid laptops.

## Decisions taken (do not re-litigate)

Plugin at first-party quality rather than an upstream PR (upstream issues are closed, ~10 unreviewed display PRs, PR #7340 stalled). Fresh design rather than building on #7340 or hyprmoncfg. Two surfaces (popup + studio). SDR white default 203 cd/m² clamped to max-average. Wide gamut is a first-class third state. Generated layout file in the toggles dir, never editing monitors.lua. Plugin id `pmotta.displays` / name "Displays" are placeholders, one manifest field to rename. Probe availability still unknown.

## Next steps, in order

1. **Pedro's hands-on pass** of popup and studio with a real keyboard and mouse; collect anything that feels off. Programmer's art is not allowed: expect design notes.
2. **Live exercise of the remaining studio paths**: rotation, mirror, disable/enable, mode/VRR, with the same warn-then-flip protocol; fix what breaks.
3. **Keyboard polish** likely needed after (1): Enter on dropdown rows, Esc while a number field has focus, cursor visibility when the inspector scrolls.
4. **Rename** the plugin id/name if Pedro wants something else; one manifest field plus the menu override and README.
5. **Profiles (v2)**: saved layouts keyed by EDID hash set with connector fallback, applied on hotplug/lid. The state JSON already carries `capabilities.hash`.
6. **HDR test patterns (v2)** rendered by the shell for probe measurement, feeding WS-0 in the brief.
7. **Screenshots under HDR** (brief WS-1 Tier 1) as a separate track once the probe exists.
8. Consider a `Popup` chip strip → the studio's "1–9 select" parity, and a bar-icon state (glyph variant) when any display is in HDR.

## Files

```
DESIGN.md                 spec, colour model, architecture, live-test findings, approved decisions
README.md                 install, keys, CLI, persistence, dev loop
HANDOFF.md                this file
manifest.json             kinds: bar-widget (Popup.qml), overlay (Studio.qml), service (Service.qml)
Popup.qml Studio.qml Service.qml
components/ApplyBar.qml DisplayCanvas.qml GamutPlot.qml
Model.js                  shared pure logic (scale cleaning, colour modes, SDR white mapping, snapping)
bin/omarchy-displays bin/omarchy-displays-edid
test/all test/base-test.sh test/cli-test.sh test/edid-test.sh test/model.test.js test/fixtures/
design/displays-design-review.html
omarchy-hdr-contribution-brief.md   the original research brief (WS-0…WS-8)
```

Upstream references: omacom/omarchy branch `quattro` is the 4.x source (the `dev` branch is a stale 3.8.5); PR #7340 (stalled HDR + rotation panel); issue #9804 (10-bit shell crash on Mesa); crmne/omarchy-hyprmoncfg (the plugin to surpass); Hyprland issue #9064 (colour-management tracking).
