# Omarchy True-HDR Contribution Brief

**Author context:** Pedro Motta — Co-Founder / Creative Director, PUSH (Lisbon). VFX + colour science background (Nuke, OCIO/ACES, cinematography, GLSL, C++/Qt, Python). Daily-drives Omarchy. Also building MPT, a C++/Qt professional media viewer with an ACES/OCIO pipeline.

**Purpose of this document:** a research-backed map of the Linux HDR stack as it stands, showing exactly where the gaps are, which of them are worth attacking, and how each one would be implemented and merged. Written to be handed to Claude Code as a working brief.

**Research date:** 2 September 2026. Anything version-specific below must be re-verified before code is written — this ecosystem moves weekly. See §9 (Verification Checklist) first.

---

## 1. Executive summary

1. **The compositor-level HDR work is largely done.** Hyprland has a full colour-management implementation: `wp-color-management-v1`, PQ/HLG/BT.1886/gamma22 transfer functions in both directions, HDR metadata over DRM, CM for borders/blur/cursor, FP16 internal buffers, and (since March 2026) ICC profile loading. The umbrella tracking issue is hyprwm/Hyprland#9064.
2. **What is missing is the last mile, and it is mostly Omarchy's problem, not Hyprland's.** Omarchy ships no display configuration UI, no HDR defaults, and a screenshot pipeline that produces wrong pixels the moment the output is in a non-sRGB colour space.
3. **The remaining Hyprland gaps are precisely colour-science gaps** — inverse tone mapping quality, mastering-primaries handling, out-of-range value handling, screencopy sampling the colour-managed buffer. These are the items nobody in that community is equipped to do well, and they are exactly the author's domain.
4. **Nobody is measuring anything.** Every HDR tuning discussion in Hyprland and Omarchy is done by eye ("looks washed out", "black levels don't line up"). A probe-based validation suite would be the single highest-leverage contribution and would become the reference other work is judged against.
5. **Strategic framing for Omarchy:** DHH's stated principle is *"the default install of Omarchy is my setup… we start from the base of 'this is what I use'"* (PR basecamp/omarchy#1708). A PR adding twelve HDR knobs dies. A PR that makes an HDR display correct by default, with at most one toggle, lands.

---

## 2. The stack, layer by layer — what works, what doesn't

### 2.1 Kernel / DRM
- Hyprland currently drives HDR output through the `HDR_OUTPUT_METADATA` connector property only. `CTM` is used (landed via PR #11503 for direct-scanout and SDR passthrough). `GAMMA_LUT` and `DEGAMMA_LUT` exist as DRM properties but are **not yet wired up** in Hyprland. The newer DRM *colour pipeline* API (per-plane colour ops) is **not used at all**.
- Caveat noted by the Hyprland maintainer of this subsystem (UjinT34) in #9064: not every driver supports every property, and drivers accept different value ranges for the same property. Any work here needs per-vendor testing (amdgpu / i915-xe / nvidia).
- NVIDIA proprietary: drivers before **595.58.03** require the `vk-hdr-layer` shim and `ENABLE_HDR_WSI=1` per-application. From 595.58.03 onward this is no longer needed. Confirm the installed driver version before drawing conclusions from any test.

### 2.2 Wayland protocol
- `wp-color-management-v1` was **merged into wayland-protocols on 13 February 2025**, shipping in wayland-protocols 1.41, after five years and 800+ review comments. Design goals explicitly include supporting *professional colour-managed applications* and *bringing adequate colour management to apps that are colour-aware but not colour-managed*.
- Legacy/parallel protocols still in play: `frog-color-management-v1` (Valve — what gamescope actually speaks) and the deprecated experimental `xx-color-management-v4`. Hyprland implements all three lineages; gamescope needs scRGB + frog or xx, and will **not** work through the `vk-hdr-layer` shim.
- `wp-color-representation-v1` exists in staging (YCbCr matrix/range signalling) — relevant to the unchecked "Handle YCC" item in #9064.

### 2.3 Hyprland — status against its own tracking issue (#9064)

**Done:**
- Primaries conversion; luminance handling; output image-description settings.
- Decode-to-linear and encode-from-linear for: sRGB, gamma2.2, gamma2.8, ST2084 PQ, HLG, BT.1886, ST240, LOG100, LOG316, xvYCC, ST428 (PR #11084).
- CM for decorations, blur, software cursor, hardware cursor (PR #15905).
- Auto-HDR / fullscreen passthrough logic (PR #9785, #11503, #12127).
- FP16 internal buffer (issue #10558, PR #11000).
- **ICC profile loading** (vaxry's `icc` branch, merged ~March 2026). Usage: `icc = /full/path` in the v2/Lua monitor block. It also changed the general CM architecture: the intermediate offload buffer is now sRGB and colour management happens at the end of the chain. VCGT ramps are loaded into KMS.
- CM shader optimisation with precomputed primaries matrices (PR #9814).

**Still open — this is the contribution surface:**

| # | Open item | Why it matters | Skill needed |
|---|---|---|---|
| 1 | **Better inverse tone mapping** (discussion #11341, PR #12204) | SDR content on an HDR desktop looks washed out; black levels never line up. The requester explicitly asked for a BT.2446a port and gave up because it operates in YCbCr. | Colour science + GLSL |
| 2 | **Handle mastering primaries** | Content mastered to DCI-P3 inside a BT.2020 container is currently treated as full BT.2020 → oversaturation | Colour science |
| 3 | **Correctly handle values outside 0.0–1.0** | Negative/over-range values after primaries conversion clip instead of being gamut-mapped | Colour science + GLSL |
| 4 | **GAMMA_LUT + DRM colour pipeline** | Offload transforms to fixed-function hardware; also the correct home for calibration curves | Kernel/DRM + C++ |
| 5 | **Direct scanout: SDR luminances, HDR scRGB** | Power/latency on fullscreen video and games | C++ |
| 6 | **Handle YCC** | Video planes and some HDMI modes | C++ |
| 7 | **Hardware cursor with CPU buffer copy** | Cursor colour on some drivers | C++ |
| 8 | **Wiki page for CM** — *still unchecked* | Everything above is undocumented, which is why every forum thread is cargo-culted config | Writing |

**Two known live bugs worth owning:**
- `render:cm_auto_hdr` state tracking breaks when the monitor's `cm` is not the default `srgb` — HDR is enabled on fullscreen but never reset on exit (issue #12971 / discussion #12958).
- ICC profile stops applying after a DPMS off/on cycle or reboot on Hyprland 0.56; re-applying by hand fixes it, `hyprctl reload` does not. Suspected AMD kernel colour-state interaction (Hyprland forum thread "icm profile turns off after DPMS off and on cycle of hypridle").
- Related: `cm_auto_hdr = 1` switches an HDR monitor *to SDR* when a non-HDR game goes fullscreen, which users experience as regression (discussion #15185).

**Critical, under-appreciated detail:** the colour-management shader is **user-overridable** at `~/.config/hypr/shaders/CM.glsl`. This means a better tone mapper can be prototyped and A/B tested with zero build cycle before it is ever proposed upstream. This is the fastest path from idea to evidence in the whole document.

### 2.4 Hyprland configuration surface (0.55+)

Since 0.55, hyprlang is deprecated in favour of **Lua**. Monitor colour fields:

- `bitdepth` — 8 or 10. Caveats from the wiki: Hyprland's own registered colours (border gradients) are **not** 10-bit, and some applications cannot screen-capture with 10-bit enabled.
- `cm` — `auto` (srgb at 8bpc, wide at 10bpc — the recommended setting), `srgb` (default), `dcip3`, `dp3` (Apple P3), `adobe`, `wide` (BT.2020), `hdr` (BT.2020 + PQ, experimental), `hdredid` (same, EDID primaries).
- `sdrbrightness`, `sdrsaturation` — SDR content appearance while the output is in HDR.
- `sdr_min_luminance`, `sdr_max_luminance`, `min_luminance`, `max_luminance`, `max_avg_luminance` — the luminance knobs.
- `icc` — path to an ICC/ICM profile.
- Renderer-level: `render:cm_auto_hdr`, `render:cm_fs_passthrough`, `render:cm_sdr_eotf`.

`cm_sdr_eotf` default changed to **gamma 2.2** (value 2), with value 3 restoring the previous piecewise-sRGB behaviour. This is the root of the "my terminal got lighter after 0.53" class of reports (discussion #12788) and is a genuine, defensible colour decision: most SDR content is authored on displays tracking pure 2.2, not the piecewise sRGB EOTF.

### 2.5 Capture — the weakest link

- **Screenshots.** Omarchy's `omarchy-cmd-screenshot` uses `grim -g "$SELECTION"` piped to `wl-copy`, with `satty` for annotation. `grim` speaks `wlr-screencopy`, writes PNG/JPEG/PPM, and has **no concept of colour space, transfer function or tone mapping**. Under a PQ/BT.2020 output it captures encoded PQ code values and writes them into a file tagged (implicitly) as sRGB. Result: the blown-out, washed screenshots reported in omacom/omarchy#2981, plus a grey/black selection overlay at `bitdepth 10`.
- The ICC PR's own TODO list contains the unchecked item **"Screencopy must not sample CM'd buffer"**, and vaxry noted the new sRGB offload buffer "should make it possible to have actual, proper pixel-perfect screencopy in a follow-up MR". **That follow-up MR does not appear to exist yet.** It is the correct upstream fix and it is currently unclaimed.
- **Recording.** `gpu-screen-recorder` *does* support HDR recording (HEVC HDR and AV1 HDR). Omarchy's recorder has two paths: a default KMS path via `omarchy-capture-region`/slurp, and a portal path (`OMARCHY_SCREENRECORD_USE_PORTAL`) documented as the one to use for HDR, external GPUs, and window capture. So recording is closer to correct than screenshots — but HDR is not the default path, and there is a hard 4K cap on the recording resolution.

### 2.6 Toolkits and applications
- **Qt** ships `color-management-v1.xml` in `qtwayland/src/3rdparty/wayland/protocols/color-management/`. This matters enormously because **Omarchy 4.0 rebuilds the entire desktop shell in Quickshell (Qt6/QML)**. Whether the shell declares an image description, and what happens to its gradients and blur at 10-bit in an HDR session, is untested territory.
- **GTK4 / Mutter / KWin** all have `wp_color_management_v1` support (Mutter since GNOME 48).
- **mpv** is the reference working client. Known-good HDR config from discussion #11341: `vo=gpu-next`, `gpu-api=vulkan`, `gpu-context=waylandvk`, `target-colorspace-hint`, `target-trc=pq`, `target-prim=bt.2020`, `inverse-tone-mapping`, `target-peak=400`, `tonemapping=bt.2446a`. **Use this as the quality bar**: the same user found mpv's inverse tone mapping visibly better than Hyprland's, which is the entire premise of contribution #1 above.
- **Chromium / Electron on Wayland HDR** — state unverified; treat as an open research item, not an assumption. Omarchy ships Chromium as the default browser, so this matters for perceived "HDR works" quality.

### 2.7 Omarchy specifics
- Repository has moved: **`omacom/omarchy`** (was `basecamp/omarchy`). Related repos: `omacom-io/omarchy-iso`, `omacom/ttfx`.
- **4.0** (RC as of August 2026) headline changes: shell reimagined in **Quickshell**; internals moved **from git to system packages** to separate user modifications; all Hyprland configs converted to **Lua** for 0.56 compatibility; dual-boot install; factory reset.
- Config lives at `~/.config/hypr/` with defaults sourced from `~/.local/share/omarchy/default/hypr/`. Scripts live in `~/.local/share/omarchy/bin/` (`omarchy-cmd-*`, `omarchy-capture-*`).
- There is an extension mechanism: `~/.config/omarchy/extensions/` (menu.sh precedent, PR #4012) — a legitimate place to prototype without touching defaults.
- Open, explicitly help-wanted: **issue #2858 "Add a better display configuration tool"**, tagged `enhancement`, `good first issue`, `help wanted`, with the maintainer noting neither he nor DHH uses multiple displays so it needs someone with the hardware. Also **#2111** requesting a display settings panel. This is an open door with a welcome mat on it.

---

## 3. Gap analysis: what "true HDR on Omarchy" actually requires

| Capability | Status | Owner layer |
|---|---|---|
| HDR output signalling (PQ, BT.2020, metadata) | Works | Hyprland ✅ |
| 10-bit output | Works | Hyprland ✅ |
| Per-surface colour management | Works | Hyprland ✅ |
| ICC profile loading | Works (with a DPMS bug) | Hyprland ⚠️ |
| SDR content in HDR looking correct | Poor — the #1 complaint | **Hyprland tonemapper** ❌ |
| HDR enabled by default on capable hardware | Not attempted | **Omarchy** ❌ |
| Any UI to configure displays | Does not exist | **Omarchy** ❌ |
| Screenshots that are colorimetrically correct | Broken | **Omarchy + grim + Hyprland screencopy** ❌ |
| HDR screen recording | Works via non-default path | **Omarchy defaults** ⚠️ |
| Shell/theme rendering correct at 10-bit HDR | Unknown | **Omarchy 4.0 / Quickshell** ❓ |
| Calibration workflow (probe → profile → applied) | Fragmented, undocumented | **Ecosystem** ❌ |
| Documentation | Wiki page unchecked in #9064 | **Both** ❌ |
| Verified, measured correctness | Nobody is doing this | **Nobody** ❌ |

---

## 4. Proposed workstreams

Ordered by leverage-per-effort. Each is independently shippable.

---

### WS-0 — Measurement harness and baseline report
**Deliverable:** a public repository, `hyprland-hdr-validation`, containing test patterns, a measurement script, and a results table across hardware.

**Why first:** every other workstream needs it, it is uniquely enabled by the author's background, and it costs nothing politically. It also converts subjective forum arguments into numbers, which is how you earn standing in a project you have not contributed to before.

**Contents:**
1. **Test pattern generator** (Python + OpenImageIO or numpy → 16-bit PNG / EXR):
   - PQ luminance staircase: patches at 0.005, 0.1, 1, 5, 10, 50, 100, **203**, 400, 600, 1000, 4000, 10000 cd/m². 203 is the BT.2408 reference/diffuse white — the anchor everything else should be judged against.
   - Near-black ramp, PQ code values 0–64, to expose black crush and the OLED black-level issue (#9716).
   - BT.2020 and DCI-P3 primary/secondary patches at 75% and 100%.
   - Grey ramp 0–100% in 1% steps for banding at 8 vs 10 bit.
   - SDR sRGB reference chart to be displayed *while the output is in HDR mode*, for evaluating `sdrbrightness` / `sdrsaturation` / `cm_sdr_eotf`.
   - A gradient/blur panel replicating Omarchy's shell aesthetics, to catch banding in the compositor's own decorations (which are not 10-bit).
2. **Measurement script** wrapping ArgyllCMS (`dispread`, `spotread`) to capture measured cd/m² and xy for each patch.
3. **Analysis**: measured vs requested nits (EOTF tracking error), ΔE2000 against target primaries, black floor, SDR-white anchor position in HDR mode.
4. **Matrix**: run per {GPU vendor × driver version × Hyprland version × `cm` setting × `bitdepth`}.

**Acceptance criteria:** a README table showing, per configuration, EOTF tracking error at each stimulus level and ΔE for the primaries — with the raw CSVs committed.

**Where it lands:** own repo first; then link it from Hyprland issue #9064 and the relevant forum threads. Expect it to be cited immediately.

---

### WS-1 — Screenshots that are colorimetrically correct
**Fixes:** omacom/omarchy#2981. **Highest user-visible value per line of code.**

**Three tiers; do them in order.**

**Tier 1 — Omarchy-side post-process (ships in days).**
Modify `omarchy-cmd-screenshot` to detect the target monitor's colour state via `hyprctl monitors -j` and, when it is not plain sRGB, run the captured buffer through a proper HDR→SDR conversion instead of writing raw PQ code values into an sRGB-tagged PNG.

The crude, known-working version uses ffmpeg's zscale:
```
ffmpeg -i in.png -vf "zscale=transfer=linear:npl=100,tonemap=bt2390,zscale=transfer=bt709:primaries=bt709:matrix=bt709,format=rgb24" out.png
```
The correct version uses BT.2390 EETF with the actual display peak (from EDID/config) as the source peak and 100 cd/m² as the target, with diffuse white mapped from 203 → 100. This is where domain knowledge visibly beats the default `tonemap=mobius` folklore.

Also offer an **HDR-preserving** mode: PNG (3rd edition) can carry a `cICP` chunk describing BT.2020/PQ, and AVIF/JXL carry it natively. A screenshot of HDR content that stays HDR is a genuinely new capability on this desktop.

**Tier 2 — teach `grim` about colour.**
`grim` upstream (emersion) gains: read the output's image description via `wp-color-management-v1`, and either tag the output file correctly or tone map with a `--tonemap` flag. Small, well-scoped C patch to a maintained project.

**Tier 3 — the correct upstream fix in Hyprland.**
Implement the follow-up the ICC PR promised: **screencopy must sample the pre-CM sRGB offload buffer, not the colour-managed output buffer.** This makes every existing screenshot tool correct with no changes to any of them. Explicitly named as possible-but-not-done by the maintainer. High value, moderate C++ effort, and it also fixes the grey-overlay-at-10-bit half of #2981.

**Acceptance criteria:** capture the WS-0 test chart at `cm = hdr, bitdepth = 10`; the resulting PNG, measured back through a known viewer, reproduces the source patch relationships within a stated ΔE; the selection overlay renders normally.

---

### WS-2 — Display & HDR settings panel for Omarchy
**Fixes:** #2858 (help wanted), #2111.

**Design constraints from Omarchy's culture:**
- It must feel like Omarchy — keyboard-driven, themed, no heavyweight GUI (`nwg-displays` was explicitly rejected as "too heavy, doesn't fit the vibe").
- It must keep the config files as source of truth, not replace them.
- Minimum viable surface: resolution, refresh, scale, position, and **one HDR toggle** that sets `bitdepth` + `cm` together, plus SDR brightness. Not eleven luminance fields.

**Two implementation targets — pick based on where 4.0 has landed at the time:**
- **On 3.x:** a TUI in the `omarchy-cmd-*` style writing to `~/.config/hypr/monitors.lua`, invoked from the Omarchy menu.
- **On 4.0+:** a Quickshell/QML panel inside the new shell. This is the better long-term home and plays directly to Qt experience.

**Non-obvious requirement:** the writer must handle the Lua config format, and Hyprland changed config syntax twice (0.53 rules, 0.55 Lua). Write it against Lua only and generate rather than parse-and-patch where possible.

**Acceptance criteria:** plug in an HDR monitor, open the panel, toggle HDR, verify `hyprctl monitors -j` reports the expected colour space and format, and no restart is required.

---

### WS-3 — Correct-by-default HDR detection in Omarchy
**The DHH-shaped PR.** No new UI, no new options: on first run and on hotplug, if the display's EDID advertises HDR static metadata (SMPTE ST 2084 support) and the GPU/driver combination is known-good, write a sane monitor block; otherwise leave it alone.

**Defaults to propose, with measurements from WS-0 backing each number:**
- `bitdepth = 10`, `cm = "auto"` for wide-gamut non-HDR panels — `auto` is the wiki-recommended setting and is the safe default.
- `cm = "hdr"` only where the panel's measured peak and black floor justify it. Many "HDR400" panels are worse in HDR mode than in SDR mode, and saying so with data is a real contribution.
- SDR diffuse white anchored per BT.2408 (203 cd/m² reference white), expressed through `sdrbrightness` relative to the panel's measured SDR white.
- `render:cm_auto_hdr` — **recommend leaving it off by default until #12971 and #15185 are fixed**, since it currently switches HDR *off* under SDR fullscreen content and fails to restore state when `cm` is non-default. Document the reasoning in the PR.

**Watch item:** monitors lie in EDID. #9064 says this outright. Ship a small override list keyed on EDID manufacturer/model for panels known to misreport, in the same spirit as the existing hardware quirk handling.

---

### WS-4 — A proper inverse tone mapper for Hyprland
**Addresses:** #9064 open items 1–3; discussion #11341; PR #12204.

**Prototype path (no build required):** edit `~/.config/hypr/shaders/CM.glsl` directly, A/B against mpv's `gpu-next` with `tonemapping=bt.2446a` and `inverse-tone-mapping` as the reference. Capture both with the screen recorder and compare frames numerically, which is exactly the methodology the original requester used but without measurement.

**What to implement:**
1. **SDR→HDR (inverse) path:** BT.2446 Method A is what the community asked for; it is specified in YCbCr, which the requester correctly identified as awkward in a linear-RGB compositor shader. Options: derive an RGB-domain approximation, or do the YCbCr round-trip with precomputed matrices (the CM shader already uses precomputed primaries matrices per PR #9814, so the machinery exists). Document the deviation from the spec honestly — reviewers respect that more than a silent approximation.
2. **HDR→SDR path:** BT.2390 EETF with correct source/target peak and black, driven by the actual `min_luminance`/`max_luminance` values rather than hardcoded constants.
3. **Mastering primaries:** honour the content's mastering display primaries where signalled instead of assuming container primaries — this alone removes a large class of oversaturation complaints.
4. **Out-of-range handling:** gamut-map rather than clip after primaries conversion.
5. **Black level:** a correct black-floor lift/anchor addressing #9716 (OLED blacks not perfectly black), verified with a probe rather than by eye.

**Why this is defensible:** the maintainer labelled #9064 low priority and the tonemapping items are unassigned. An outsider arriving with measurements, a working shader, and references to BT.2390/BT.2446/BT.2408 is not a nuisance — they are the person the issue was waiting for.

---

### WS-5 — Calibration and ICC workflow
1. **Fix the ICC-after-DPMS bug** (ICC stops applying after monitor power cycle; suspected AMD kernel colour-state interaction). Reproduce, bisect, file with a proper trace, and fix or hand off with a diagnosis.
2. **Document the working calibration path end-to-end**: ArgyllCMS/DisplayCAL → profile → `icc = /path` in the monitor block → verification measurement. Right now users find only conflicting forum answers and `colord` not seeing displays under Hyprland.
3. **Investigate `colord` integration** so profile management works with the standard Linux colour daemon rather than a bespoke config line — this is what "professional colour-managed applications" in the protocol's own design goals actually requires.
4. **VCGT into KMS** is already handled by the ICC PR; verify it survives mode switches and DPMS.

---

### WS-6 — HDR recording as a first-class path
- Make the portal/PipeWire path (which supports HDR) the default when the output is in HDR, rather than an env-var opt-in.
- Verify `gpu-screen-recorder`'s HEVC-HDR and AV1-HDR output actually carries correct mastering-display and MaxCLL/MaxFALL metadata; if not, that is a small upstream patch to a receptive project.
- Revisit the hard 4K recording cap for HDR sessions.
- Deliverable that will get attention: a recorded HDR clip from Omarchy that plays back correctly in mpv and in a browser, with a measurement showing the round-trip preserved luminance.

---

### WS-7 — Documentation
- **The Hyprland CM wiki page is an explicitly unchecked box in #9064.** Writing it is a fast, high-gratitude contribution that also establishes credibility before proposing renderer changes. It should cover: what each `cm` value does, what the luminance knobs mean in physical units, when to use ICC vs `cm`, why `cm_sdr_eotf` defaults to gamma 2.2, and the known limitations (10-bit borders, screen capture).
- **An Omarchy manual chapter** on displays and HDR, matching the existing manual's tone.

---

### WS-8 — MPT as the reference HDR client (adjacent, compounding)
Implementing `wp-color-management-v1` surface support in MPT produces something the Linux desktop conspicuously lacks: a **non-game, colour-managed, HDR-native professional application** to test compositors against. Concretely:
- It gives the author a legitimate, self-interested reason to be in these codebases.
- Qt/Wayland colour-management lessons transfer directly to the Quickshell shell work in WS-2.
- "The reference HDR viewer on Linux" is a defensible market position for MPT against OpenRV / xSTUDIO / DJV, none of which have solved desktop HDR presentation on Linux either.

---

## 5. Suggested sequencing

**Phase 1 (weeks 1–3) — establish standing.**
WS-0 baseline measurements on own hardware → publish repo → post findings into Hyprland #9064 and the relevant Omarchy issue. Simultaneously WS-7 wiki page draft. Cost: low. Payoff: known quantity in both projects.

**Phase 2 (weeks 3–8) — ship user-visible fixes.**
WS-1 Tier 1 (Omarchy screenshot PR) and WS-3 (HDR defaults PR). Both are small, both fix reported bugs, both are in Omarchy where the maintainers have said out loud they need someone with the hardware.

**Phase 3 (months 2–4) — the substantial work.**
WS-4 tonemapper (prototype in CM.glsl → measurements → upstream PR) and WS-2 display panel. In parallel, WS-1 Tier 3 (screencopy from the pre-CM buffer) as the "real" fix.

**Phase 4 (ongoing).** WS-5 calibration, WS-6 recording, WS-8 MPT.

---

## 6. Ready-to-use artefacts

### 6.1 `~/.config/hypr/monitors.lua` — HDR test configuration

> ⚠️ **Verify syntax against the current wiki before use.** Hyprland moved to Lua in 0.55 and 0.56 is current; the `hl.monitor({...})` table form below matches the wiki as of this research, but the setter form for renderer variables was not verified and may differ. Check `hyprctl getoption render:cm_auto_hdr` and the Monitors + Variables wiki pages first.

```lua
-- ~/.config/hypr/monitors.lua
-- HDR validation configuration for Hyprland >= 0.55 (Lua config format)
-- Purpose: A/B an HDR-capable display against an SDR reference display.

-- ── Display A: HDR under test ───────────────────────────────────────────────
-- cm = "hdr"      → BT.2020 primaries + ST.2084 PQ transfer function
-- cm = "hdredid"  → same, but primaries taken from EDID (often inaccurate)
-- cm = "auto"     → srgb at 8bpc, wide (BT.2020) at 10bpc — safe default
hl.monitor({
  output        = "DP-1",
  mode          = "3840x2160@120",
  position      = "0x0",
  scale         = 1,
  bitdepth      = 10,
  cm            = "hdr",
  sdrbrightness = 1.15,   -- SDR diffuse-white multiplier while output is HDR
  sdrsaturation = 1.00,   -- 1.00 = no saturation boost; tune only with measurements
  vrr           = 1,
})

-- ── Display B: SDR reference, deliberately untouched ────────────────────────
hl.monitor({
  output   = "HDMI-A-1",
  mode     = "2560x1440@60",
  position = "-2560x0",
  scale    = 1,
})

-- ── Renderer-level colour management ────────────────────────────────────────
-- cm_auto_hdr: auto-switch to HDR for fullscreen HDR content.
--   Leave DISABLED while validating: see Hyprland #12971 (state not restored
--   when cm != srgb) and #15185 (switches HDR *off* for SDR fullscreen apps).
-- cm_sdr_eotf: 2 = gamma 2.2 (default since 0.55), 3 = piecewise sRGB (old).
-- cm_fs_passthrough: fullscreen passthrough behaviour.
--
-- Set these via your config's variable syntax for the version you are on, e.g.:
--   hl.set("render:cm_auto_hdr", 0)
--   hl.set("render:cm_sdr_eotf", 2)
--   hl.set("render:cm_fs_passthrough", 0)
-- Confirm the setter name against the current wiki before relying on it.

-- ── ICC profile (optional; only after a real calibration) ───────────────────
-- Add `icc = "/home/USER/.local/share/icc/DP-1.icm"` to the monitor table above.
-- Known bug: profile may stop applying after a DPMS off/on cycle.
```

### 6.2 Verification commands

```bash
# What does Hyprland think the output is doing?
hyprctl monitors -j | jq '.[] | {name, description, currentFormat, activeWorkspace, vrr}'

# Full monitor state including colour management fields
hyprctl monitors all

# Does the Vulkan/WSI side see colour management?
vulkaninfo | grep -i -A5 hdr
# On NVIDIA drivers older than 595.58.03 you additionally need:
#   ENABLE_HDR_WSI=1 vulkaninfo | grep -i hdr
# (Do NOT set ENABLE_HDR_WSI globally, and never with gamescope.)

# Which colour-management protocols are advertised?
wayland-info | grep -i -E 'color|hdr'

# Read the panel's own claims (they are often wrong — that is the point)
sudo get-edid | parse-edid 2>/dev/null || edid-decode /sys/class/drm/card*-DP-1/edid

# Kernel-side connector properties actually in use
sudo cat /sys/kernel/debug/dri/0/*/hdr_output_metadata 2>/dev/null
```

### 6.3 mpv reference profile — the quality bar to beat

```ini
# ~/.config/mpv/mpv.conf  — [HDRify] profile from Hyprland discussion #11341
[HDRify]
vo=gpu-next
gpu-api=vulkan
gpu-context=waylandvk
target-colorspace-hint
target-trc=pq
target-prim=bt.2020
inverse-tone-mapping
target-peak=400
tonemapping=bt.2446a
```

Play the WS-0 test patterns through this, then through the compositor's own path, and compare. The delta between them **is** the deliverable for WS-4.

### 6.4 Screenshot tone-mapping prototype (WS-1 Tier 1)

```bash
#!/usr/bin/env bash
# omarchy-screenshot-hdr — prototype: colour-correct screenshots under HDR output.
# Drop in ~/.local/bin and bind it, or fold into omarchy-cmd-screenshot.
set -euo pipefail

OUTDIR="${XDG_PICTURES_DIR:-$HOME/Pictures}/Screenshots"
mkdir -p "$OUTDIR"
FILE="$OUTDIR/$(date +%Y%m%d_%H%M%S).png"

SELECTION="$(slurp -d)" || exit 1

# Determine the colour state of the monitor under the selection.
# NOTE: field name for the colour-management state must be confirmed against
# `hyprctl monitors -j` on the running version — it has changed between releases.
CM="$(hyprctl monitors -j | jq -r '.[] | select(.focused==true) | .currentFormat')"

grim -g "$SELECTION" -t ppm - > /tmp/shot.ppm

case "$CM" in
  *2101010*|*XBGR2101010*|*ARGB2101010*)
    # Output is 10-bit / likely PQ: convert rather than reinterpret.
    # npl = nominal peak luminance of the source; set from the panel's measured peak.
    ffmpeg -y -loglevel error -i /tmp/shot.ppm \
      -vf "zscale=transfer=linear:npl=400,\
tonemap=tonemap=bt2390:desat=0,\
zscale=primaries=bt709:transfer=bt709:matrix=bt709:range=pc,\
format=rgb24" \
      "$FILE"
    ;;
  *)
    ffmpeg -y -loglevel error -i /tmp/shot.ppm "$FILE"
    ;;
esac

wl-copy < "$FILE"
notify-send "Screenshot saved" "$FILE"
```

**Known limitations to state honestly in the PR:** `npl` should come from the display's real peak rather than a constant; `tonemap=bt2390` in ffmpeg is not a full BT.2390 EETF implementation; and the right long-term fix is Tier 3 (screencopy sampling the pre-CM buffer), which makes all of this unnecessary.

---

## 7. Contribution mechanics

**Omarchy:**
- Repo: `omacom/omarchy`. PRs target **`dev`**, not `master`; releases are cut as a `dev → master` PR by DHH.
- Test a fresh install with the ISO dev flow: `./bin/omarchy-iso-make-dev` from `omacom-io/omarchy-iso`. Proxmox is known to work; some QEMU flows have issues.
- Cultural rules that decide whether a PR merges:
  - "The default install of Omarchy is my setup" — argue from *this makes the default correct*, never from *this adds an option*.
  - Fixes must address root cause; DHH has rejected migration-shaped workarounds with "we need to get to the bottom of why it's actually failing."
  - Migrations matter: config-affecting changes need a migration, and 4.0 already shipped one bug from a missing one (#5879).

**Hyprland:**
- Repo: `hyprwm/Hyprland`. Renderer/CM work is effectively owned by **UjinT34**, with vaxry doing the ICC work. Comment on #9064 before starting anything in that checklist — it is the coordination point.
- Related repo: `hyprwm/aquamarine` (the backend; HDR/CM changes often need matching commits there).
- Discussions are used heavily for feature requests; issues for bugs. #11341 sat with 15 upvotes and **zero replies** for a year — there is no queue to wait in.

**Positioning statement to reuse:** *"I do commercial VFX colour work — Nuke, ACES, on-set supervision. I have a probe and HDR reference displays. I measured Hyprland's colour output; here are the numbers; here is a patch."* That sentence is worth more than any amount of enthusiasm, in both projects.

---

## 8. Risks and honest caveats

- **Fast-moving target.** Hyprland went 0.53 → 0.56 and Omarchy 3.x → 4.0 within months, with two config-syntax breaks. Any patch must be written against current `main`/`dev`, and this document's version-specific claims decay quickly.
- **Hardware dependence.** HDR behaviour differs sharply between amdgpu, Intel and NVIDIA proprietary, and between panels. A fix validated on one setup may regress another; the WS-0 matrix is the mitigation.
- **`cm = hdr` is still marked experimental** in the Hyprland wiki. Proposing it as an Omarchy default before the tonemapper improves would be premature and would likely be rejected — hence the sequencing in §5 (fix appearance first, then defaults).
- **Community friction.** Hyprland has a documented reputation for a difficult community. Keep contributions technical, measured, and unemotional; walk away from anything else.
- **Scope discipline.** Every one of these workstreams could expand indefinitely. Ship WS-0 and WS-1 Tier 1 before touching WS-4.

---

## 9. Verification checklist — do this before writing any code

Claude Code: treat everything below as unverified until checked on the actual machine and against current upstream sources. Do not assume this document is current.

1. `hyprctl version` — actual Hyprland version and its config format.
2. `omarchy-version` (or the About menu) — Omarchy version; 3.x or 4.x changes the target for WS-2 entirely.
3. `hyprctl monitors -j` — the **exact field names** reporting colour space / format. The script in §6.4 guesses at these.
4. Fetch the current Hyprland Monitors and Variables wiki pages and confirm every option name in §2.4 and §6.1, including the Lua setter form for `render:*`.
5. Re-read hyprwm/Hyprland#9064 for checklist items closed since this research.
6. Check whether a screencopy-from-offload-buffer MR now exists (WS-1 Tier 3 may already be claimed).
7. Check omacom/omarchy issues #2858, #2111, #2981 for status and for anyone who has picked them up.
8. Confirm GPU driver version — for NVIDIA, whether it is ≥ 595.58.03.
9. `pacman -Q hyprland aquamarine grim slurp satty gpu-screen-recorder quickshell` — actual installed versions.
10. Verify whether Omarchy 4.0's Quickshell shell declares a colour image description at all, and what its gradients look like at `bitdepth 10`.

---

## 10. Sources

**Hyprland**
- Colour management tracking issue: https://github.com/hyprwm/Hyprland/issues/9064
- Original CM protocol PR: https://github.com/hyprwm/Hyprland/pull/8715
- Earlier CM request: https://github.com/hyprwm/Hyprland/issues/4377
- Inverse tonemapping request: https://github.com/hyprwm/Hyprland/discussions/11341
- `cm_auto_hdr` state bug: https://github.com/hyprwm/Hyprland/issues/12971 · https://github.com/hyprwm/Hyprland/discussions/12958
- `cm_auto_hdr` SDR-fullscreen regression: https://github.com/hyprwm/Hyprland/discussions/15185
- sRGB EOTF change / terminal colours: https://github.com/hyprwm/Hyprland/discussions/12788
- ICC support thread: https://forum.hypr.land/t/colour-management-support/1448
- Monitors wiki: https://wiki.hypr.land/Configuring/Basics/Monitors/
- Screenshots & recording wiki: https://wiki.hypr.land/Useful-Utilities/Screenshots-and-Recording/

**Omarchy**
- Screenshot/10-bit bug: https://github.com/omacom/omarchy/issues/2981
- Display configuration tool (help wanted): https://github.com/omacom/omarchy/issues/2858
- Display settings panel request: https://github.com/basecamp/omarchy/issues/2111
- Lua config migration PR: https://github.com/basecamp/omarchy/pull/5723
- 4.0 release PR: https://github.com/basecamp/omarchy/pull/6231
- Lua migration bug (missing migration): https://github.com/omacom/omarchy/issues/5879
- Maintainer philosophy statement: https://github.com/basecamp/omarchy/pull/1708
- Screen recording internals: https://deepwiki.com/basecamp/omarchy/5.2-interactive-package-tools

**Ecosystem**
- Wayland CM protocol merged: https://www.phoronix.com/news/Wayland-CM-HDR-Merged
- Protocol MR: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/merge_requests/14
- Hyprland CM landing: https://www.phoronix.com/news/Hyprland-HDR-Color-Management
- Arch HDR wiki: https://wiki.archlinux.org/title/HDR
- Colour & HDR reference documentation (Pekka Paalanen): https://gitlab.freedesktop.org/pq/color-and-hdr
- Qt's copy of the CM protocol: https://doc.qt.io/qt-6/qtwaylandcompositor-attribution-wayland-color-management-protocol.html

**Standards to cite in PRs**
- ITU-R BT.2100 — HDR TV parameter values (PQ / HLG)
- ITU-R BT.2408 — operational practices for HDR; **reference white at 203 cd/m²**
- ITU-R BT.2390 — HDR conversion, EETF
- ITU-R BT.2446 — HDR↔SDR conversion, Methods A/B/C
- ITU-R BT.1886 — reference EOTF for SDR displays
- SMPTE ST 2084 (PQ), ST 2086 (mastering display metadata), CTA-861 (MaxCLL/MaxFALL)
