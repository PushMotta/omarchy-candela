# Handoff — Candela

Written 3 September 2026 at the end of session 1, extended after sessions 2, 3 and 4. Read **Start here** below first, then `DESIGN.md` for the why and `README.md` for the how. The sections after it are the history, kept because the gotchas and decisions in them still apply.

## Start here (state on 3 September 2026, late evening)

**The plugin is Candela.** Id `io.github.pushmotta.candela`, CLI
`omarchy-candela`, repo https://github.com/PushMotta/omarchy-candela (public,
MIT; the old `omarchy-displays` URL redirects). `main` = `origin/main`, tree
clean, CI green (`.github/workflows/test.yml`: `./test/all` + a parse-only QML
lint). The live install on this machine is migrated to the new names and was
verified after the rename with a reload, `doctor`, disable/enable, summon/hide
and a no-op apply through expiry. Nothing is pending on the displays.

**Pedro has declared the features done for now.** The next act is the
marketplace listing.

### Session 5 (3 September 2026, night) — the visual pass

Pedro asked for a look-and-motion pass before shipping: "Omarchy users
really appreciate looks and animations". The house dialect was measured
first (`/usr/share/omarchy/shell`: 13 `Easing.OutCubic` against one
`InOutCubic`, 140 ms on cards, 110-120 ms on knobs, 60 ms on cursor
chrome, 160 ms on bar text, no blur or shadow anywhere) and everything
below follows it. Five commits, tests and lint green, `plugin validate`
and `doctor` green, all seen live on the two MateViews:

- **The studio arrives and leaves.** It was `visible: root.opened`, a
  hard cut. The scrim ramps, the card rises 1.5%, and the window stays
  up while it fades, as PopupCard does.
- **The countdown is a rule on the strip's own bottom edge** that drains
  across whatever holds it, and goes urgent in colour — rule and caption
  — under five seconds. Photographed live at 9 s and at 1 s.
- **Identify never actually animated**: the windows were built with the
  flag already true (opacity starts at 1) and destroyed the moment it
  went false. Two flags now, badges animate themselves 60 ms apart, and
  an accent frame marks each screen's edge. Seen live.
- **The canvas blocks carry the desktop wallpaper**, dimmed to 0.28 and
  inset so a themed radius cannot clip it (`wallpaperOpacity` is one
  property if it wants tuning). The symlink path never changes, so the
  source is cleared before reassignment and the image uncached, or a
  theme change would never reach it. Plus a datum mark at 0,0 drawn over
  the blocks, guides that fade in, and an eased fill.
- **The canvas frame hugs the layout** (`preferredHeight`) instead of
  filling the column and stranding the displays mid-grid.
- **The gamut plot is an instrument**: CIE 1931 spectral locus, and the
  gamut *in use* filled with real chromaticity — sRGB while clamped, the
  panel's own once wide or HDR opens the container, tweened between them
  and read from the draft. Verified live by applying wide to DP-1 and
  letting it revert. The panel's corners stay outlined while sRGB is in
  use, so the headroom is visible before you take it.
- **The bar icon** takes the urgent colour while a change waits and the
  accent while any display is in HDR; the key strip wraps to two lines
  instead of ending in an ellipsis.
- **The fold.** The inspector scrolls and the shell's `AsNeeded` scrollbar
  paints nothing at rest, so everything from COLOUR down was hidden with
  no cue. A line under the inspector now names the sections below and
  scrolls to the first when clicked ("more" when what is hidden is the
  tail of a section already on screen), and the panel identity — name,
  EDID capabilities, gamut plot — moved out of the scroller into the space
  under the canvas, which brings COLOUR above the fold and puts the void
  to work. It holds no `InspectorRow`, so the keyboard's row order is
  untouched; the left column is height-bounded and clipped so a short card
  cuts it rather than drawing over the action bar.
- **The plot's axes were anisotropic.** `px` and `py` scaled x and y
  independently, which stretched the diagram and moved every primary off
  its true place. One unit for both axes now, centred in whatever box it
  is given.
- **`preview.png` retaken** from the running studio at the same crop.

**Session 5, later: the fold, the front page, 1.0.0.** `FoldHint` is a
component now (`components/FoldHint.qml`), used by both surfaces; it maps its
markers through `mapToItem` because a heading is usually nested inside the
section it titles. The popup got one for a measured reason: its surface is 596
logical px in SDR with nothing pending and 809 with a display in HDR and a
countdown running, against roughly 735 px of room on a 768-tall panel — over
that line the display list and the Identify/Arrange rows go out of reach, while
Keep and Revert stay reachable through the service's every-screen strip. It
reserves no height until the column overflows.

That exposed a bug worth remembering: **testing overflow against the view the
hint has already shortened is self-fulfilling** — the column then overflows by
exactly the height of the line reporting it, so once the line appears it never
leaves. The unreduced height comes in from outside now (`available`).

README: three GIFs under `docs/media/` (gamut morph, countdown, Identify) built
from timed `grim` frame sequences, since there is no screen recorder on this
machine and no sudo to install one. `grim -g` takes **logical** coordinates and
scales by the output's factor; `-s` is slower than cropping at native
resolution and downscaling in ffmpeg afterwards. The recorder is
`record.py` in the session scratchpad, not in the repo. Crops are exact to each
surface's own border so no desktop leaks into the media.

**Tested small, twice.** A temporary headless output
(`hyprctl output create headless`, then `hl.monitor` through `hyprctl eval`
— `hyprctl keyword` no longer works on 0.56) at 1366x768 showed the card
sizing itself correctly with nothing overlapping; the studio always selects
the *focused* display, though, and a headless output has no EDID, so that
run could not exercise the colour section. Pinning the card's own size to
1366x768 while DP-1 stayed selected did: the layout holds, the left column
fits, the plot shrinks into what is left — and the fold comes back, with
COLOUR sliced in half. That is what the hint is for, and it was wrong until
it counted a section's end rather than its header.

Where this lands for real laptops: the card caps at 1120x880 logical, so
any screen at or above ~1140x900 logical gets exactly the card on this
desk — 1920x1080 at scale 1, 2880x1800 at 2, 1512x982, all identical. Only
768-tall panels at scale 1 shrink it, and there COLOUR falls below the fold
and the hint names it. Untested: the popup on a short screen. Its content
measured ~611 logical px here in SDR with nothing pending; HDR adds the SDR
white section and a countdown adds the strip, which would put it over a
768-tall screen's ~738 px and make it scroll, with no cue of its own. The
fold hint is a studio component today; the popup would need its own.

One judgement call left deliberately for Pedro: the popup's eased
`contentHeight` resizes a Wayland surface every frame it runs — if that
ever looks steppy, deleting that one Behavior is the fix. (The canvas
frame's alignment settled itself: it is top-aligned again now that the
identity block fills the column beneath it.)

### Marketplace submission — drafted, not sent

- Route (verified against the manual, plugins.omarchy.org and the marketplace
  repo): open ONE issue on `omacom/omarchy-plugin-marketplace` with the
  `submit-plugin.yml` template. Bots validate the exact HEAD commit and run a
  static Security Baseline; a maintainer applies `approved-and-verified`.
- The body is ready in **`docs/marketplace-submission.md`** (six headings in
  the required order; category Hardware; tags hyprland, quickshell, system;
  maintainer notes pre-empting the two review capabilities). Send it with:
  `gh issue create --repo omacom/omarchy-plugin-marketplace --title "[Plugin]: Candela" --body-file docs/marketplace-submission.md`
- Expect `review-required`, not `passed`: the baseline records
  `service-management` (systemd-run for the revert timer) and `privilege` (the
  CI workflow's `sudo apt-get`). Neither is a finding.
- **Version is 1.0.0** (Pedro's call, session 5). **One decision left:**
  whether he submits by hand or tells the assistant to run the command above.
  Do not open the issue without his word — it goes out under his account.
- The full readiness rescan passed again at `31661a4`: `./test/all`, the CI
  qmllint form, `omarchy plugin validate .` and `doctor` all green; a fresh
  clone validates and its tests pass; LICENSE, preview.png, manifest and
  README present; every README media link resolves in that clone; no network
  calls, no sudo or pkexec in anything executable; nothing secret in the tree
  (the only "token" is the revert nonce); repo public; ID checked against the
  live catalog — 2,186 ids, **no collision**. Re-run before sending if HEAD
  moves again.
- Two doc bugs the rescan caught and fixed: the README's removal instructions
  still named `displays-{layout,pending}.lua` from before the rename, so
  following them left the generated rules behind; and the submission's
  privilege note claimed the CI workflow held the only `sudo`, which the
  research brief's prose also contains.

### After listing: how updates work

Users install and update from mutable `main` (`omarchy plugin add` /
`plugin update`), so every push reaches them immediately. The listing is a
snapshot of one commit; later pushes make the card show "Update unverified"
until a re-verification is requested through the verify-plugin form with the
plugin ID, repo URL and the full 40-char SHA. Re-verify for releases, not every
push. The plugin ID must never change.

### Two sessions work on this project

Session 3's robustness pass came from a second interactive session
(`omarchy-monitor-options-8f`). Both sessions share this working tree; both
were told the Candela names; both agreed to stay off the tree until Pedro asks.
Check `git status` and `git log origin/main` before editing. Pedro's rule: do
not name other tools in the repo.

### Still owed (see "Not yet verified")

The live revert-fidelity test across every field is the one that underwrites
the README's promise and has never been run in full; Pedro's hands-on pass of
the session 2, 3 and 5 UI changes — the session 5 motion is best judged in
one sitting with the older changes; the laptop-only paths.

## Where things stand

### Session 3 (3 September 2026, evening) — robustness pass

Pedro asked what the other display managers for Hyprland do that we could
use; the answer was their robustness engineering rather than their UI, and he
said to move ahead. **Do not name other display managers in code, comments,
docs or commit messages** (Pedro, 3 Sep). Landed, tests green, no shell
warnings after restart:

- **Every-screen pending strip** (Service.qml): a Keep/Revert card at the
  top of each screen not already showing one in the popup or studio; the
  focused screen's strip has the keyboard when no surface is open (↵ on the
  highlighted button, esc revert, h/l choose). The studio registers its
  screen with the service and closes itself if that screen disappears;
  popups bump `surfacesChanged()` on open/close. Seen live on both
  MateViews, with and without the studio open.
- **Pending change on disk**: `candela-pending.lua` in the toggles dir,
  sorted after the layout and before Omarchy's `internal-monitor-*`, so a
  foreign reload (theme change, Omarchy's clamshell script) re-applies the
  preview instead of reverting it. Revert deletes it and reloads.
- **Readback after apply**: up to 3 s of `hyprctl monitors all -j` polling
  against the intent (`verify_live`); a change Hyprland accepted but did
  not land on is unwound, naming the field. Keep, `apply --now` and revert
  read back too; a revert that does not restore exits 1 so the shell shows
  it.
- **Load probe**: the layout ends with `omarchy_candela_layout_probe =
  "<token>"`; keep asserts it through `hyprctl eval` after the reload and
  `doctor` asks too. Verified live on 0.56.2.
- **Built-in panel through Omarchy's toggle** (DESIGN.md §6.7): off writes
  `internal-monitor-disable.lua` with Omarchy's own content, on removes it,
  pending records the flag's prior state for revert, intent never stores
  `enabled` for the panel, and the kept scale goes to
  `internal-monitor-scale`. Sandbox-tested with the laptop fixture only.
- **Switch-off remembers geometry** (mode, position, scale, rotation into
  intent at the moment it goes off), and the backend refuses to switch off
  the last enabled display.
- **`recover`** (CLI, and the service on every state refresh): every
  display off → the built-in panel or the first display comes back on, one
  attempt per dark spell.
- **`doctor`**: toggles require, probe, configerrors, pending sanity,
  writable dirs, tools, systemd user manager, Omarchy's watcher plus a
  numeric-scale warning, user rules in monitors.lua for managed
  connectors, duplicate identities.
- **Canvas**: a drop on another display lands on the nearest clear edge;
  mode, scale and rotation changes reflow flush neighbours; ⌥+arrows flush
  beside the nearest display, `0` origin, `[` `]` select.
- **Scale precision**: `cleanScale` keeps five decimals (4/3 was rounded
  to 1.33, which is off Hyprland's 1/120 grid and gets corrected with a
  warning); labels go through `formatScale`, equality through
  `sameScale` because hyprctl reports two decimals.
- **Test harness**: `test/fake-hyprctl.sh` is a compositor that keeps
  state (eval mutates the live JSON, reload rebuilds it from the fixture
  plus the toggles files in sorted order, a probe global answers the
  assert), plus a laptop fixture. Nine CLI scenarios added.

Not committed as a push: commits are local on `main`.


### Session 2 (3 September 2026, afternoon) — hardening pass

An external review of the v0.1 tree was verified claim by claim (all six
high-priority findings held) and implemented, plus two findings of our own:

- **Backend is transactional** (`76b8977`): pending.json with a token and the
  timer are armed *before* `hyprctl eval`; a rejection unwinds; a stale timer
  (`revert --expired --token`) is a no-op; flock + mktemp; `apply --now`
  validates its Lua like keep; unknown top-level JSON keys rejected; ICC+HDR
  and forced-off+HDR rejected on the merged display. 19 CLI tests.
- **Service** (`a149070`): exit codes instead of stderr; FIFO apply queue that
  merges same-flag changes instead of dropping them.
- **Surfaces** (`fd78909`): `offeredModes(caps, intent)` honours ICC and the
  capability overrides; scale sends `effective`; pending-mode Enter maps to
  Revert/Keep; brightness reads keyed by connector and available before the
  popup's first open.
- **CI** (`463b208`): `./test/all` + Qt6 qmllint on every push.

Gotcha 11: Hyprland's `supports_hdr` / `supports_wide_color` are **-1 off, 0
auto (default), 1 on** — wiki table and `CLuaConfigInt(0, -1, 1)`. A contract
written the other way round briefly inverted the studio's Force on/off
controls; the original code was right. Gotcha 12: `/usr/bin/qmllint` here is
Qt5; the real one is `/usr/lib/qt6/bin/qmllint` (exit 0 on warnings, non-zero
on errors). Gotcha 13: bar widgets are handed `bar`, `moduleName`, `settings`
— never `manifest` — so Popup.qml's id stays a literal.

The plugin exists, is installed on this machine, and works end to end on real hardware. Five commits on `main` in this directory (`git log --oneline`):

```
fad17e1 Polish: compact pending strip in the popup, plain numbers in position fields
5091fd4 Fix expired revert killing its own unit; follow live focus; guard bar reads
fe952b7 Fix live apply: hyprctl parses a leading Lua comment as a flag
44d3278 Candela plugin 0.1: backend, popup, studio, service
06414e0 Design review 01: spec and mockups for Candela
```

Pushed to https://github.com/PushMotta/omarchy-candela (MIT); `main` tracks `origin/main`.

### Verified live (with screenshots, on the two Huawei MateViews, NVIDIA 610.57.04, Hyprland 0.56.2, Omarchy 4.0.2)

- Popup renders in the bar with DDC brightness, EDID-gated `SDR · Wide · HDR`, SDR white slider in HDR with the 203 cd/m² mark, display list with focused / HDR tags, Identify, Arrange, and the pending countdown strip under the hero.
- Studio renders with canvas, panel identity + EDID capability line + gamut plot, signal, geometry (scale, rotation, X/Y, mirror, enabled), colour, Advanced.
- `omarchy-candela hdr on --display DP-2` puts DP-2 in `XBGR2101010` / `cm=hdr` with `sdr_max_luminance = 203` within a second. `keep` writes a clean layout file; `hyprctl configerrors` is empty. A change left alone reverts through the detached systemd timer (`omarchy-candela-revert.timer`). `hdr off --now` returns to sRGB.
- Identify badges appear on each screen. Shell journal clean after every restart.
- Test suite green: `./test/all` (bash sandbox with fake hyprctl + EDID fixture, node tests for Model.js).

### Not yet verified

Session 3, by hand: the strip's keyboard (↵ / esc / h / l) with no surface
open; ⌥+arrows, `0`, `[` `]`; a drop on top of another display; a scale
change reflowing the neighbour. Session 3, needs a laptop: the built-in
panel through Omarchy's toggle across a lid cycle, `recover` after a boot
with the panel off and nothing attached, the numeric-scale conflict
`doctor` warns about. Session 3, needs a real mode change: the 3 s readback
budget was only exercised on same-configuration applies, where the answer
is instant; a real mode switch on NVIDIA may need longer.

- **Keyboard navigation** in popup and studio. `wtype` sends keys to the focused toplevel, not the layer surface, so it could not be automated. It follows the first-party cursor pattern exactly; needs a real keyboard pass: j/k/h/l/Enter/Esc in the popup, Tab between canvas/inspector/actions, arrows to nudge, `a`/`r`/`i`, `1`–`9`.
- Mouse dragging on the studio canvas, snapping guides, overlap refusal.
- Live rotation, mirror, disable/enable, mode and VRR changes through the studio (backend paths are unit-tested; only HDR and scale were exercised live).
- ICC picker with real profiles (none installed here; `omarchy-candela icc list` returns `[]`).
- Hotplug refresh (socat listener on Hyprland's socket2) and behaviour with one bar per screen when a display is removed.
- Whether DP-2 visibly showed an HDR badge / picture change from the monitor's side. Only Pedro can see that.
- **Revert fidelity across every field, live.** Revert is `hyprctl reload` of the
  generated Lua; the structural test proves every accepted key is emitted, but
  whether Hyprland actually resets each one on reload (e.g. `sdrsaturation`) has
  only been seen live for HDR and scale. This is the test that underwrites the
  README's promise.
- Session 5, the fold: clicking the hint to jump to the first named
  section (needs a pointer; the logic is tested only by reading it).
- Session 5 by hand, all of it motion that a screenshot cannot judge: the
  studio's fade in and out, the popup easing its own height when HDR adds the
  SDR white section, the countdown rule between ticks, Identify's stagger
  across two screens, the guide fade during a drag, and the gamut triangle
  tweening when Wide is chosen in the draft rather than applied.
- Session 2 UI changes by hand: pending-mode Enter on Keep/Revert, the ICC row
  disabled while in HDR, an override forcing a draft out of HDR, the popup
  brightness wheel on a fresh shell, and the queued-apply merge under a burst
  of different fields.

## How this machine is wired

**Renamed 3 September 2026 (evening): the plugin is Candela.** Id
`io.github.pushmotta.candela` (permanent marketplace form), name "Candela", CLI
`omarchy-candela`, repo `PushMotta/omarchy-candela` (GitHub redirects the old
`omarchy-displays` URL). Everything below was migrated on this machine, with
`.bak.<epoch>` copies of `shell.json` and the menu override:
`~/.config/omarchy/plugins/io.github.pushmotta.candela` (symlink → here),
`~/.local/bin/omarchy-candela`, state in `~/.local/state/omarchy/candela/`,
layout rule `~/.local/state/omarchy/toggles/hypr/candela-layout.lua`
(regenerated by `persist`, probe global `omarchy_candela_layout_probe`), pending
preview `candela-pending.lua`, revert unit `omarchy-candela-revert`, env
`OMARCHY_CANDELA_*`. Verified after the reload: identical modes, no config
errors, `doctor` green, both surfaces summon by the new id. The old
`pmotta.displays` / `omarchy-displays` names exist nowhere any more.

- Plugin source: this directory. Installed as a symlink `~/.config/omarchy/plugins/io.github.pushmotta.candela` → here, enabled in the bar's right section (`~/.config/omarchy/shell.json`).
- `~/.config/omarchy/extensions/omarchy-menu.jsonc` has a `setup.monitors` override that opens the studio (backup of the original beside it with a `.bak.<epoch>` suffix).
- Generated state: `~/.local/state/omarchy/candela/{intent.json,pending.json}` and `~/.local/state/omarchy/toggles/hypr/candela-layout.lua`. The layout file currently declares both displays explicitly at their normal geometry (`scale 1.6`, `bitdepth 8`, `cm srgb`). Deleting the layout file and `hyprctl reload` returns the machine to the stock catch-all rule.
- Super+Ctrl+D still opens Omarchy's built-in Display popup. README has the one-line rebinding to `omarchy-shell io.github.pushmotta.candela popup`.
- Design review artifact (mockups in real theme tokens): https://claude.ai/code/artifact/f95e7efb-ad4f-473b-b663-00fc077cd274 — republish with that `url` to keep the link; source is `design/displays-design-review.html`.

## Development loop

```bash
./test/all                                   # always green before a commit
omarchy-restart-shell                        # REQUIRED after QML edits: a symlinked plugin is not hot-reloaded,
                                             # and `omarchy-shell shell rescanPlugins` does not replace compiled QML
journalctl --user -t omarchy-shell --since -2min | grep -iE 'pmotta|TypeError|Cannot'
omarchy-shell io.github.pushmotta.candela popup          # toggle the bar popup (opens on Hyprland's live focused screen)
omarchy-shell shell toggle io.github.pushmotta.candela   # toggle the studio overlay
omarchy-shell io.github.pushmotta.candela state | jq     # what the service holds
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
14. `hyprctl eval` prints only `ok` or an error, never a return value, and globals persist across evals and reloads: a probe is an `assert` on a global the file set.
15. A `return 1` from a command function trips the ERR trap's "aborted at line" message; intended non-zero verdicts (`doctor`, a revert that did not restore) use `exit 1`.
16. A display's live geometry once it is off is 0x0 at "preferred", so a rule generated from live state brings it back on top of the origin: geometry is remembered in intent at switch-off.
17. Omarchy's clamshell script owns the built-in panel: it re-enables it with `hyprctl eval` at `position = "auto"` (gotcha 5 again) and a scale it reads from monitors.lua or `internal-monitor-scale`, never from our layout, within seconds of any lid or monitor event. Only its own `internal-monitor-disable.lua` stops it. DESIGN.md §6.7.
18. Toggles load in `find | sort` order: `candela-layout` < `candela-pending` < `internal-monitor-*`. Name new toggles files with that in mind.

## Decisions taken (do not re-litigate)

Plugin at first-party quality rather than an upstream PR (upstream issues are closed, ~10 unreviewed display PRs, PR #7340 stalled). Fresh design rather than building on #7340 or the existing display tools. Two surfaces (popup + studio). SDR white default 203 cd/m² clamped to max-average. Wide gamut is a first-class third state. Generated layout file in the toggles dir, never editing monitors.lua. Plugin id `io.github.pushmotta.candela` / name "Displays" are placeholders; a rename touches the manifest `id`, the `~/.config/omarchy/plugins` symlink name, the `setup.monitors` menu override, and README's commands — the QML fallbacks and the backend's `OMARCHY_CANDELA_PLUGIN_ID` default are just that, defaults, not the source of truth. Probe availability still unknown.

## Next steps, in order

1. **Pedro's hands-on pass** of popup, studio and the pending strip with a
   real keyboard and mouse, including the session 2 and 3 lists above;
   collect anything that feels off. Programmer's art is not allowed: expect
   design notes.
2. **Live revert-fidelity test** with the warn-then-flip protocol: apply a
   change touching every field group, let it expire, confirm the readback
   passes (`revert` now exits 1 and says which field did not come back).
   Fix `generate_lua` for anything reload does not reset, and widen the
   readback budget if a real mode switch needs it.
3. **Live exercise of the remaining studio paths**: rotation, mirror, disable/enable, mode/VRR, with the same warn-then-flip protocol; fix what breaks.
4. **Keyboard polish** likely needed after (2): Enter on dropdown rows, Esc while a number field has focus, cursor visibility when the inspector scrolls.
5. **Rename** the plugin id/name if Pedro wants something else: manifest id, the symlink directory, the menu override, README, and the literal in Popup.qml.
6. **Profiles (v2)**: saved layouts keyed by EDID hash set with connector fallback, applied on hotplug/lid. The state JSON already carries `capabilities.hash`.
7. **HDR test patterns (v2)** rendered by the shell for probe measurement, feeding WS-0 in the brief.
8. **Screenshots under HDR** (brief WS-1 Tier 1) as a separate track once the probe exists.
9. Consider a `Popup` chip strip → the studio's "1–9 select" parity, and a bar-icon state (glyph variant) when any display is in HDR.

## Files

```
DESIGN.md                 spec, colour model, architecture, live-test findings, approved decisions
README.md                 install, keys, CLI, persistence, dev loop
HANDOFF.md                this file
manifest.json             kinds: bar-widget (Popup.qml), overlay (Studio.qml), service (Service.qml)
Popup.qml Studio.qml Service.qml
components/ApplyBar.qml DisplayCanvas.qml GamutPlot.qml
Model.js                  shared pure logic (scale cleaning, colour modes, SDR white mapping, snapping)
bin/omarchy-candela bin/omarchy-candela-edid
test/all test/base-test.sh test/fake-hyprctl.sh test/cli-test.sh test/edid-test.sh test/model.test.js
test/fixtures/            hyprctl-monitors.json (desk), hyprctl-monitors-laptop.json, mateview-dp1.edid
design/displays-design-review.html
omarchy-hdr-contribution-brief.md   the original research brief (WS-0…WS-8)
```

Upstream references: omacom/omarchy branch `quattro` is the 4.x source (the `dev` branch is a stale 3.8.5); PR #7340 (stalled HDR + rotation panel); issue #9804 (10-bit shell crash on Mesa); Hyprland issue #9064 (colour-management tracking). Omarchy's own monitor scripts live in `/usr/share/omarchy/bin/omarchy-hyprland-monitor-*` and `omarchy-hw-*`.
