const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const M = require("../Model.js")

const monitors = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "hyprctl-monitors.json"), "utf8"))

const caps = {
  available: true, manufacturer: "HWV", productCode: "28194", bitsPerPrimary: 10,
  physicalWidthMm: 596, physicalHeightMm: 397, diagonalInch: 28.2, ppi: 164,
  colorimetry: ["BT2020cYCC", "BT2020YCC", "BT2020RGB"],
  hdr: { st2084: true, maxLuminance: 496.743, maxFrameAverageLuminance: 496.743, minLuminance: 0 },
  supportsHdr: true, supportsWideColor: true,
  primaries: { red: [0.6796, 0.3203], green: [0.2646, 0.6796], blue: [0.1503, 0.0595], white: [0.3134, 0.3291] }
}

function display(overrides) {
  const base = Object.assign({}, monitors[1], { live: { bitdepth: 8, cm: "srgb", sdrMaxLuminance: 80 }, capabilities: caps, kept: {}, pendingConfig: null })
  return Object.assign(base, overrides || {})
}

test("clean scale follows Hyprland's 1/120 rule", () => {
  assert.equal(M.cleanScale(1.6, 3840, 2560), 1.6)
  assert.equal(M.cleanScale(1.25, 3840, 2560), 1.25)
  // 1.3 is not on the grid for this panel; the nearest step above it is 4/3,
  // which must keep its 1/120 precision. 1.33 would be corrected by Hyprland
  // with a warning, because 3840/1.33 is not a whole number of pixels.
  assert.equal(M.cleanScale(1.3, 3840, 2560), 1.33333)
  assert.equal(M.cleanScale(4 / 3, 2880, 1800), 1.33333)
  for (const [s, w, h] of [[1.3, 3840, 2560], [4 / 3, 2880, 1800], [1.5, 2560, 1440], [1.75, 2560, 1600]]) {
    const e = M.cleanScale(s, w, h)
    const units = Math.round(e * 120)
    assert.equal(Math.abs(e - units / 120) < 1e-5, true, `${e} sits on the 1/120 grid`)
    assert.equal((w * 120) % units, 0, `${w} divides at ${e}`)
    assert.equal((h * 120) % units, 0, `${h} divides at ${e}`)
  }
  const scales = M.availableScales(3840, 2560)
  assert.deepEqual(scales.map(s => s.label), ["1", "1.25", "1.6", "2", "3", "4"])
  assert.equal(M.scaleIndex(scales, 1.6), 2)
  // hyprctl reports two decimals: 1.33 must still find the 1.33333 entry.
  const grid = [{ label: "4/3", effective: 1.33333 }]
  assert.equal(M.scaleIndex(grid, 1.33), 0)
  assert.equal(M.sameScale(1.33333, 1.33), true)
  assert.equal(M.sameScale(1.6, 1.5), false)
})

test("scale labels round for people, values keep the grid", () => {
  assert.equal(M.formatScale(1.33333), "1.33")
  assert.equal(M.formatScale(1.6), "1.6")
  assert.equal(M.formatScale(1.25), "1.25")
  assert.equal(M.formatScale(2), "2")
  assert.equal(M.formatScale(3.2), "3.2")
  assert.equal(M.formatScale(undefined), "1")
  assert.equal(M.round5(4 / 3), 1.33333)
})

test("bit depth is derived from the framebuffer format", () => {
  assert.equal(M.bitdepthFromFormat("XRGB8888"), 8)
  assert.equal(M.bitdepthFromFormat("XBGR2101010"), 10)
  assert.equal(M.bitdepthFromFormat("XBGR16161616F"), 16)
})

test("modes parse and format consistently", () => {
  assert.deepEqual(M.parseMode("3840x2560@59.98Hz"), { width: 3840, height: 2560, refresh: 59.98, value: "3840x2560@59.98" })
  assert.equal(M.formatMode(3840, 2560, 59.984), "3840x2560@59.98")
  const opts = M.modeOptions(monitors[0])
  assert.equal(opts[0].value, "3840x2560@59.98")
  assert.equal(opts[0].label, "3840×2560 @ 59.98 Hz")
  assert.equal(M.currentModeValue(monitors[0]), "3840x2560@59.98")
})

test("colour mode reads the compositor, not the intent", () => {
  assert.equal(M.colourMode(display()), "sdr")
  assert.equal(M.colourMode(display({ live: { bitdepth: 10, cm: "wide" } })), "wide")
  assert.equal(M.colourMode(display({ live: { bitdepth: 10, cm: "hdr" } })), "hdr")
  assert.equal(M.colourMode(display({ live: { bitdepth: 10, cm: "srgb" } })), "sdr")
})

test("offered modes are gated by EDID", () => {
  assert.deepEqual(M.offeredModes(caps), ["sdr", "wide", "hdr"])
  assert.deepEqual(M.offeredModes({ available: true, supportsHdr: false, supportsWideColor: false }), ["sdr"])
  assert.deepEqual(M.offeredModes({ available: true, supportsHdr: false, supportsWideColor: true }), ["sdr", "wide"])
})

test("offeredModes with no intent (or {}) reproduces the EDID-only behaviour", () => {
  assert.deepEqual(M.offeredModes(caps), M.offeredModes(caps, {}))
  assert.deepEqual(M.offeredModes(caps, {}), ["sdr", "wide", "hdr"])
  const sdrOnly = { supportsHdr: false, supportsWideColor: false }
  assert.deepEqual(M.offeredModes(sdrOnly), M.offeredModes(sdrOnly, undefined))
  assert.deepEqual(M.offeredModes(sdrOnly, {}), ["sdr"])
})

test("supports_hdr override forces HDR on or off regardless of what the EDID says", () => {
  // Hyprland's convention: 1 forces on, -1 forces off, 0 (the default) trusts
  // the EDID. EDID reports HDR: 1 and 0/absent leave it offered, -1 removes it.
  assert.deepEqual(M.offeredModes(caps, { supports_hdr: 1 }), ["sdr", "wide", "hdr"])
  assert.deepEqual(M.offeredModes(caps, { supports_hdr: 0 }), ["sdr", "wide", "hdr"])
  assert.deepEqual(M.offeredModes(caps, { supports_hdr: -1 }), ["sdr", "wide"])
  // EDID does not report HDR: 1 forces it on (and wide along with it);
  // 0, -1 and absent all leave it off.
  const noHdr = { supportsHdr: false, supportsWideColor: false }
  assert.deepEqual(M.offeredModes(noHdr, { supports_hdr: 1 }), ["sdr", "wide", "hdr"])
  assert.deepEqual(M.offeredModes(noHdr, { supports_hdr: 0 }), ["sdr"])
  assert.deepEqual(M.offeredModes(noHdr, { supports_hdr: -1 }), ["sdr"])
  assert.deepEqual(M.offeredModes(noHdr, {}), ["sdr"])
})

test("supports_wide_color override behaves the same way, independent of HDR", () => {
  const noHdr = { supportsHdr: false, supportsWideColor: false }
  assert.deepEqual(M.offeredModes(noHdr, { supports_wide_color: 1 }), ["sdr", "wide"])
  assert.deepEqual(M.offeredModes(noHdr, { supports_wide_color: 0 }), ["sdr"])
  assert.deepEqual(M.offeredModes(noHdr, { supports_wide_color: -1 }), ["sdr"])
  assert.deepEqual(M.offeredModes(noHdr, {}), ["sdr"])
  const wideEdid = { supportsHdr: false, supportsWideColor: true }
  assert.deepEqual(M.offeredModes(wideEdid, { supports_wide_color: 1 }), ["sdr", "wide"])
  assert.deepEqual(M.offeredModes(wideEdid, { supports_wide_color: 0 }), ["sdr", "wide"])
  assert.deepEqual(M.offeredModes(wideEdid, { supports_wide_color: -1 }), ["sdr"])
  // An HDR-capable panel is wide-capable even if wide itself is forced off.
  assert.deepEqual(M.offeredModes(caps, { supports_wide_color: -1 }), ["sdr", "wide", "hdr"])
})

test("an ICC profile removes hdr from offeredModes but leaves wide alone", () => {
  assert.deepEqual(M.offeredModes(caps, { icc: "/usr/share/color/icc/foo.icc" }), ["sdr", "wide"])
  assert.deepEqual(M.offeredModes(caps, { icc: "" }), ["sdr", "wide", "hdr"])
  assert.deepEqual(M.offeredModes(caps, { icc: "/x.icc", supports_hdr: 1 }), ["sdr", "wide"])
})

test("hdrUnavailableReason follows icc > forced-off > EDID precedence", () => {
  assert.equal(M.hdrUnavailableReason(caps, {}), "")
  assert.equal(M.hdrUnavailableReason(caps, { supports_hdr: 0 }), "")
  assert.equal(M.hdrUnavailableReason(caps, { supports_hdr: 1 }), "")
  assert.equal(M.hdrUnavailableReason(caps, { icc: "/x.icc" }), "an ICC profile is loaded")
  assert.equal(M.hdrUnavailableReason(caps, { supports_hdr: -1 }), "the HDR capability is forced off")
  // Both apply at once: ICC wins.
  assert.equal(M.hdrUnavailableReason(caps, { supports_hdr: -1, icc: "/x.icc" }), "an ICC profile is loaded")
  const noHdr = { supportsHdr: false, supportsWideColor: false }
  assert.equal(M.hdrUnavailableReason(noHdr, {}), "the panel does not report HDR")
  assert.equal(M.hdrUnavailableReason(noHdr, { supports_hdr: 0 }), "the panel does not report HDR")
  assert.equal(M.hdrUnavailableReason(noHdr, { supports_hdr: 1 }), "")
})

test("SDR white anchors at 203 and clamps to max-average", () => {
  assert.deepEqual(M.sdrWhiteRange(caps), { min: 80, max: 497, reference: 203 })
  assert.equal(M.defaultSdrWhite(caps), 203)
  assert.equal(M.defaultSdrWhite({ hdr: { maxFrameAverageLuminance: 150 } }), 150)
  const range = M.sdrWhiteRange(caps)
  const t = M.sdrWhiteToSlider(203, range)
  assert.equal(M.sliderToSdrWhite(t, range), 203)
  assert.equal(M.sliderToSdrWhite(0, range), 80)
  assert.equal(M.sliderToSdrWhite(1, range), 497)
})

test("fields for a mode switch map to the right Hyprland keys", () => {
  assert.deepEqual(M.fieldsForMode("sdr", caps, {}), { bitdepth: 8, cm: "srgb", sdr_max_luminance: null, sdr_min_luminance: null })
  assert.deepEqual(M.fieldsForMode("wide", caps, {}), { bitdepth: 10, cm: "auto", sdr_max_luminance: null, sdr_min_luminance: null })
  assert.deepEqual(M.fieldsForMode("hdr", caps, {}), { bitdepth: 10, cm: "hdr", sdr_max_luminance: 203, sdr_min_luminance: 0.2 })
  assert.equal(M.fieldsForMode("hdr", caps, { cm: "hdredid", sdr_max_luminance: 250 }).sdr_max_luminance, 250)
  assert.equal(M.fieldsForMode("hdr", caps, { cm: "hdredid" }).cm, "hdredid")
})

test("captions describe the physical output", () => {
  assert.equal(M.outputCaption(display({ live: { bitdepth: 10, cm: "hdr", sdrMaxLuminance: 203 } })), "10-bit · BT.2020 PQ · SDR white 203 cd/m² · peak 497 cd/m²")
  assert.equal(M.outputCaption(display()), "8-bit · sRGB · transfer gamma 2.2")
  assert.equal(M.capabilityLine(caps), "HDR10 · BT.2020 · 10-bit · peak 497 cd/m²")
  assert.equal(M.luminanceLine(caps), "Peak 497 cd/m² · avg 497 · min 0.000")
  assert.equal(M.primariesLine(caps), "R .680 .320 · G .265 .680 · B .150 .060")
  assert.equal(M.panelLine(display()), "HWV 28194 · 596×397 mm · 28.2″ · 164 ppi · serial blank, identified by connector")
  assert.equal(M.displayTitle(display()), "DP-2 · MateView")
  assert.equal(M.metaLine(display()), "3840×2560 · 60 Hz · 1.6× · SDR")
})

test("effective intent lets pending override kept", () => {
  const d = display({ kept: { cm: "hdr", sdr_max_luminance: 203 }, pendingConfig: { sdr_max_luminance: 250 } })
  assert.deepEqual(M.effectiveIntent(d), { sdr_max_luminance: 250 })
  assert.deepEqual(M.effectiveIntent(display({ kept: { supports_hdr: -1 }, pendingConfig: {} })), {})
  assert.deepEqual(M.effectiveIntent(display({ kept: { supports_hdr: -1 }, pendingConfig: null })), { supports_hdr: -1 })
})

test("global pending intent is authoritative, including an empty snapshot", () => {
  assert.deepEqual(M.effectiveGlobal({ kept: { cm_auto_hdr: 1 }, pendingConfig: {} }), {})
  assert.deepEqual(M.effectiveGlobal({ kept: { cm_auto_hdr: 1 }, pendingConfig: null }), { cm_auto_hdr: 1 })
  assert.deepEqual(M.effectiveGlobal({ kept: { cm_auto_hdr: 1 }, pendingConfig: { cm_auto_hdr: 0 } }), { cm_auto_hdr: 0 })
})

test("resolution and refresh choices preserve only advertised mode pairs", () => {
  const d = display({ availableModes: ["3840x2160@60.00Hz", "3840x2160@120.00Hz", "2560x1440@144.00Hz"] })
  assert.deepEqual(M.resolutionOptions(d).map(x => x.value), ["3840x2160", "2560x1440"])
  assert.deepEqual(M.refreshOptions(d, "3840x2160").map(x => x.value), ["3840x2160@60", "3840x2160@120"])
  assert.deepEqual(M.refreshOptions(d, "2560x1440").map(x => x.value), ["2560x1440@144"])
})

test("missing numeric metadata stays unknown and luminance decimals round trip", () => {
  assert.equal(M.capabilityLine({ available: true, hdr: { maxLuminance: null } }), "SDR")
  assert.equal(M.luminanceLine({ hdr: { maxLuminance: null } }), "")
  assert.equal(M.formatLuminance(null), "Unknown")
  assert.equal(M.formatLuminance(0.2), "0.2")
  assert.equal(M.parseLuminance("0,125"), 0.125)
})

test("the SDR white note appears only away from the colour-managed reference", () => {
  assert.equal(M.sdrWhiteClientNote(203), "")
  assert.equal(M.sdrWhiteClientNote(203.4), "")
  assert.equal(M.sdrWhiteClientNote(null), "")
  assert.match(M.sdrWhiteClientNote(250), /stay at 203 cd\/m²/)
  assert.match(M.sdrWhiteClientNote(120, true), /^Chromium and Electron apps stay at 203/)
  assert.ok(M.sdrWhiteClientNote(120, true).length < M.sdrWhiteClientNote(120).length)
})

test("inspector rows own their draft fields", () => {
  assert.deepEqual(M.rowFields("rotation"), { display: ["transform"], global: [] })
  assert.deepEqual(M.rowFields("autohdr"), { display: [], global: ["cm_auto_hdr"] })
  assert.deepEqual(M.rowFields("advanced"), { display: [], global: [] })
  assert.equal(M.rowChanged("refresh", { mode: "3840x2160@60" }, {}), true)
  assert.equal(M.rowChanged("scale", { mode: "3840x2160@60" }, {}), false)
  assert.equal(M.rowChanged("colour", { cm: "hdr", bitdepth: 10 }, {}), true)
  assert.equal(M.rowChanged("colour", { sdr_max_luminance: 250 }, {}), false)
  assert.equal(M.rowChanged("sdrwhite", { sdr_max_luminance: 250 }, {}), true)
  assert.ok(M.rowFields("colour").display.includes("sdr_min_luminance"))
  assert.equal(M.rowChanged("autohdr", undefined, { cm_auto_hdr: 2 }), true)
  assert.equal(M.rowChanged("posx", null, null), false)
})

test("layout geometry works in logical pixels", () => {
  const rects = monitors.map(m => M.rectOf(m))
  assert.deepEqual(rects[0], { name: "DP-1", x: 0, y: 0, width: 2400, height: 1600 })
  assert.deepEqual(rects[1], { name: "DP-2", x: 2400, y: 0, width: 2400, height: 1600 })
  assert.equal(M.anyOverlap(rects), null)
  assert.deepEqual(M.boundsOf(rects), { x: 0, y: 0, width: 4800, height: 1600 })
  assert.deepEqual(M.logicalSize(monitors[0], 1.6, 1), { width: 1600, height: 2400 })
  assert.equal(M.layoutCaption(rects), "DP-1 at 0, 0 · DP-2 at 2400, 0")
})

test("snapping pulls edges together and reports guides", () => {
  const rects = monitors.map(m => M.rectOf(m))
  const moving = Object.assign({}, rects[1], { x: 2430, y: 25 })
  const snapped = M.snapRect(moving, rects, 40)
  assert.equal(snapped.x, 2400)
  assert.equal(snapped.y, 0)
  assert.deepEqual(snapped.guides.map(g => g.axis), ["x", "y"])
  const far = M.snapRect(Object.assign({}, rects[1], { x: 3000, y: 900 }), rects, 40)
  assert.equal(far.x, 3000)
  assert.equal(far.guides.length, 0)
  assert.deepEqual(M.anyOverlap([rects[0], Object.assign({}, rects[1], { x: 100 })]), ["DP-1", "DP-2"])
})

test("state parsing is defensive", () => {
  assert.equal(M.parseState("not json"), null)
  assert.equal(M.parseState("{}"), null)
  assert.equal(M.parseState(JSON.stringify({ displays: [] })).displays.length, 0)
})

test("only arrangeable displays snap, block, or take part in overlap", () => {
  const rects = monitors.map(m => M.rectOf(m))
  const off = Object.assign({}, rects[0], { disabled: true })
  const mirrored = Object.assign({}, rects[0], { mirrorOf: "DP-2" })
  assert.deepEqual(M.arrangeable([off, rects[1]]).map(r => r.name), ["DP-2"])
  assert.deepEqual(M.arrangeable([mirrored, rects[1]]).map(r => r.name), ["DP-2"])
  // A dragged block never snaps to itself, and never to an output with no
  // independent position of its own.
  assert.deepEqual(M.snapTargets(rects, "DP-2").map(r => r.name), ["DP-1"])
  assert.deepEqual(M.snapTargets([off, rects[1]], "DP-2"), [])
  // An off display parked on top of a live one is not an overlap.
  assert.equal(M.anyOverlap(M.arrangeable([Object.assign({}, off, { x: 0 }), rects[0]])), null)
})

test("a provisional position is substituted without touching the originals", () => {
  const rects = monitors.map(m => M.rectOf(m))
  const live = M.withRect(rects, "DP-2", 100, 40)
  assert.equal(live[1].x, 100)
  assert.equal(live[1].y, 40)
  assert.equal(rects[1].x, 2400, "the source array is left alone")
  assert.equal(live[0], rects[0], "untouched entries are passed through")
  assert.deepEqual(M.anyOverlap(live), ["DP-1", "DP-2"])
})

test("a drag follows the pointer and not its own last position", () => {
  const rects = monitors.map(m => M.rectOf(m))
  const origin = rects[1]                       // DP-2 at 2400, 0
  const targets = M.snapTargets(rects, "DP-2")
  const t = 200

  // The same pointer travel gives the same answer however the pointer got
  // there: no memory of the previous frame, so nothing can accumulate.
  const direct = M.dragPosition(origin, { x: 900, y: 500 }, targets, t)
  let last = null
  for (const step of [[120, 30], [400, 210], [900, 500]]) last = M.dragPosition(origin, { x: step[0], y: step[1] }, targets, t)
  assert.deepEqual([last.x, last.y], [direct.x, direct.y])

  // Held still inside a snap zone, the result stays put instead of alternating
  // between the snapped and the free position.
  const held = { x: 20, y: 12 }
  const first = M.dragPosition(origin, held, targets, t)
  const second = M.dragPosition(origin, held, targets, t)
  assert.deepEqual([first.x, first.y], [second.x, second.y])
  assert.deepEqual([first.x, first.y], [2400, 0], "snapped back to the shared edge")

  // Push past the snap zone on one axis and that axis goes where the hand is,
  // while the other keeps its guide: snapping is per axis, not all or nothing.
  const free = M.dragPosition(origin, { x: 900, y: 0 }, targets, t)
  assert.equal(free.x, 3300)
  assert.deepEqual(free.guides.map(g => g.axis), ["y"])
  assert.equal(free.y, 0)
})

test("resizing a display carries its flush neighbours along", () => {
  const rects = monitors.map(m => M.rectOf(m))          // DP-1 0..2400, DP-2 at 2400
  // DP-1 goes from scale 1.6 (2400 wide) to 2 (1920 wide): DP-2 slides left.
  const resized = M.withRect(rects, "DP-1", 0, 0).map(r => r.name === "DP-1" ? Object.assign({}, r, { width: 1920, height: 1280 }) : r)
  assert.deepEqual(M.reflowAfterResize(resized, "DP-1", { width: 2400, height: 1600 }), [{ name: "DP-2", x: 1920, y: 0 }])
  // A display to the left of the old right edge does not move.
  const leftOf = [Object.assign({}, rects[1], { x: 0 }), Object.assign({}, rects[0], { x: 2400, width: 1920, height: 1280 })]
  assert.deepEqual(M.reflowAfterResize(leftOf, "DP-1", { width: 2400, height: 1600 }), [])
  // A gap is preserved, not closed: a neighbour 100 px away stays 100 px away.
  const gapped = resized.map(r => r.name === "DP-2" ? Object.assign({}, r, { x: 2500 }) : r)
  assert.deepEqual(M.reflowAfterResize(gapped, "DP-1", { width: 2400, height: 1600 }), [{ name: "DP-2", x: 2020, y: 0 }])
  // Same size: nothing to do. Off or mirrored neighbours have no position to move.
  assert.deepEqual(M.reflowAfterResize(rects, "DP-1", { width: 2400, height: 1600 }), [])
  const off = resized.map(r => r.name === "DP-2" ? Object.assign({}, r, { disabled: true }) : r)
  assert.deepEqual(M.reflowAfterResize(off, "DP-1", { width: 2400, height: 1600 }), [])
})

test("a drop on top of another display lands on its nearest clear edge", () => {
  const rects = monitors.map(m => M.rectOf(m))
  // Dropped 300 px into DP-1 from the right: the nearest clear spot is flush right of DP-1.
  const dropped = Object.assign({}, rects[1], { x: 2100, y: 0 })
  assert.deepEqual(M.placeOutsideOverlaps(dropped, rects), { x: 2400, y: 0 })
  // Dropped mostly below DP-1: it goes under it, keeping its x.
  const under = Object.assign({}, rects[1], { x: 300, y: 1400 })
  assert.deepEqual(M.placeOutsideOverlaps(under, rects), { x: 300, y: 1600 })
  // A clean drop is left exactly where it is.
  assert.equal(M.placeOutsideOverlaps(Object.assign({}, rects[1], { x: 2600, y: 200 }), rects), null)
  // Landing on an off display is not an overlap.
  const off = [Object.assign({}, rects[0], { disabled: true }), rects[1]]
  assert.equal(M.placeOutsideOverlaps(Object.assign({}, rects[1], { x: 100, y: 0 }), off), null)
})

test("snap beside puts a display flush against its nearest neighbour, centred", () => {
  const rects = monitors.map(m => M.rectOf(m))
  const small = [rects[0], { name: "DP-2", x: 5000, y: 3000, width: 1200, height: 800 }]
  assert.deepEqual(M.snapBeside(small, "DP-2", "right"), { x: 2400, y: 400 })
  assert.deepEqual(M.snapBeside(small, "DP-2", "left"), { x: -1200, y: 400 })
  assert.deepEqual(M.snapBeside(small, "DP-2", "up"), { x: 600, y: -800 })
  assert.deepEqual(M.snapBeside(small, "DP-2", "down"), { x: 600, y: 1600 })
  assert.equal(M.snapBeside(small, "DP-2", "sideways"), null)
  assert.equal(M.snapBeside([rects[0]], "DP-1", "right"), null, "nothing to snap beside")
  const off = [Object.assign({}, rects[0], { disabled: true }), small[1]]
  assert.equal(M.snapBeside(off, "DP-2", "right"), null, "an off display is not an anchor")
})

// ---------------------------------------------------------------- workspaces

const desk = [
  { name: "DP-2", x: 2400, y: 0, disabled: false, mirrorOf: "" },
  { name: "DP-1", x: 0, y: 0, disabled: false, mirrorOf: "" }
]

test("presets order displays left to right and fill workspaces 1 to 0", () => {
  const split = M.presetPlan("split", desk)
  assert.deepEqual(M.homesOn(split, "DP-1"), [1, 2, 3, 4, 5])
  assert.deepEqual(M.homesOn(split, "DP-2"), [6, 7, 8, 9, 10])
  const alternate = M.presetPlan("alternate", desk)
  assert.deepEqual(M.homesOn(alternate, "DP-1"), [1, 3, 5, 7, 9])
  assert.deepEqual(M.homesOn(alternate, "DP-2"), [2, 4, 6, 8, 10])
  const three = desk.concat([{ name: "HDMI-A-1", x: 4800, y: 0, disabled: false, mirrorOf: "" }])
  const split3 = M.presetPlan("split", three)
  assert.deepEqual(M.homesOn(split3, "DP-1"), [1, 2, 3, 4])
  assert.deepEqual(M.homesOn(split3, "DP-2"), [5, 6, 7])
  assert.deepEqual(M.homesOn(split3, "HDMI-A-1"), [8, 9, 10])
  // An off display and a mirror cannot be homes.
  const withMirror = desk.concat([{ name: "HDMI-A-1", x: 0, y: 1600, disabled: false, mirrorOf: "DP-1" }, { name: "eDP-1", x: -1000, y: 0, disabled: true, mirrorOf: "" }])
  assert.deepEqual(M.planOrder(withMirror), ["DP-1", "DP-2"])
  assert.deepEqual(M.presetPlan("off", desk), {})
})

test("the plan kind is read back from the homes", () => {
  assert.equal(M.planKind({}, desk), "off")
  assert.equal(M.planKind(M.presetPlan("split", desk), desk), "split")
  assert.equal(M.planKind(M.presetPlan("alternate", desk), desk), "alternate")
  const edited = Object.assign({}, M.presetPlan("split", desk), { "6": "DP-1" })
  assert.equal(M.planKind(edited, desk), "custom")
  assert.equal(M.planKind({ "1": "DP-1" }, desk), "custom")
})

test("each display shows its chosen workspace while it lives there, else its lowest", () => {
  const split = M.presetPlan("split", desk)
  assert.deepEqual(M.effectiveShows(split, {}), { "DP-1": "1", "DP-2": "6" })
  assert.deepEqual(M.effectiveShows(split, { "DP-2": "8" }), { "DP-1": "1", "DP-2": "8" })
  assert.deepEqual(M.effectiveShows(split, { "DP-2": "3" }), { "DP-1": "1", "DP-2": "6" })
})

test("moves, summary and chips describe this desk under Split", () => {
  const split = M.presetPlan("split", desk)
  const open = [{ id: 1, monitor: "DP-1", windows: 4 }, { id: 2, monitor: "DP-2", windows: 1 }]
  const moves = M.planMoves(split, open, ["DP-1", "DP-2"])
  assert.deepEqual(moves, [{ id: 2, from: "DP-2", to: "DP-1", windows: 1 }])
  assert.equal(M.planSummary("split", moves), "Plan Split · moves workspace 2 (1 window) from DP-2 to DP-1")
  assert.equal(M.planSummary("alternate", M.planMoves(M.presetPlan("alternate", desk), open, ["DP-1", "DP-2"])), "Plan Alternate · no open workspace moves")
  assert.deepEqual(M.planMoves(split, open, ["DP-1"]), [{ id: 2, from: "DP-2", to: "DP-1", windows: 1 }])
  assert.deepEqual(M.planMoves({ "1": "DP-2" }, open, ["DP-1"]), [], "nothing goes to a display that cannot take it")

  const dp1 = M.chipsFor("DP-1", split, open, [1, 2])
  assert.deepEqual(dp1.map(c => c.label), ["1", "2", "3", "4", "5"])
  assert.equal(dp1[0].shown, true)
  assert.equal(dp1[0].used, true)
  assert.equal(dp1[1].away, true)
  assert.equal(dp1[1].where, "DP-2")
  assert.equal(dp1[2].open, false)
  const dp2 = M.chipsFor("DP-2", split, open, [1, 2])
  assert.deepEqual(dp2.map(c => c.label), ["6", "7", "8", "9", "0", "2"])
  assert.equal(dp2[5].ghost, true)
  assert.equal(dp2[5].home, "DP-1")
  assert.equal(M.workspaceLabel(10), "0")
})

test("a mirror's homes move to the display it mirrors, and the change nulls what the draft dropped", () => {
  const split = M.presetPlan("split", desk)
  assert.deepEqual(M.homesOn(M.rehomeFrom(split, "DP-2", "DP-1"), "DP-1"), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
  const kept = { homes: { "1": "DP-1", "2": "DP-2" }, shows: { "DP-2": "2" } }
  assert.deepEqual(M.workspaceChange(kept, { homes: { "1": "DP-1" } }), { homes: { "1": "DP-1", "2": null }, shows: { "DP-2": null } })
  assert.equal(M.workspaceChange(kept, { homes: {} }), null)
  assert.equal(M.workspaceChange(null, null), null)
  assert.equal(M.changeSummary({ workspaces: null }), "Workspace plan off")
  assert.equal(M.changeSummary({ workspaces: { homes: {} } }), "Workspace plan")
})

test("workspace lists read the way the keyboard numbers them", () => {
  assert.equal(M.workspaceList([1, 2, 3, 4, 5]), "1–5")
  assert.equal(M.workspaceList([6, 7, 8, 9, 10]), "6–0")
  assert.equal(M.workspaceList([1, 3, 5]), "1, 3, 5")
  assert.equal(M.workspaceList([1, 2, 4]), "1, 2, 4")
  assert.equal(M.workspaceList([]), "")
})

test("with no plan, chips show where the open workspaces are; the plan reads as one line", () => {
  const open = [{ id: 2, monitor: "DP-2", windows: 1 }, { id: 1, monitor: "DP-1", windows: 4 }, { id: 4, monitor: "DP-2", windows: 0 }, { id: -98, monitor: "DP-1", windows: 1 }]
  assert.deepEqual(M.openChipsFor("DP-2", open, [2]).map(c => [c.label, c.used, c.shown, c.away]), [["2", true, true, false], ["4", false, false, false]])
  assert.deepEqual(M.openChipsFor("DP-1", open, [2]).map(c => c.label), ["1"], "special workspaces are not chips")
  assert.equal(M.planLine(M.presetPlan("split", desk), desk), "1–5 on DP-1 · 6–0 on DP-2")
  assert.equal(M.planLine(M.presetPlan("alternate", desk), desk), "1, 3, 5, 7, 9 on DP-1 · 2, 4, 6, 8, 0 on DP-2")
  assert.equal(M.planLine({ "1": "DP-1", "6": "HDMI-A-1" }, desk), "1 on DP-1 · 6 on HDMI-A-1", "a home on a display not in the layout comes last")
  assert.equal(M.planLine({}, desk), "")
})

// ---------------------------------------------------------------- virtual displays

test("a virtual display is beside when it shares an edge with a real one, apart otherwise", () => {
  const withStage = desk.concat([{ name: "VIRTUAL-1", x: 5120, y: 0, width: 1920, height: 1080, disabled: false, mirrorOf: "", virtual: true }])
  const realDesk = [{ name: "DP-1", x: 0, y: 0, width: 2400, height: 1600, disabled: false, mirrorOf: "" }, { name: "DP-2", x: 2400, y: 0, width: 2400, height: 1600, disabled: false, mirrorOf: "" }]
  const apart = realDesk.concat([{ name: "VIRTUAL-1", x: 5120, y: 0, width: 1920, height: 1080, virtual: true }])
  assert.equal(M.virtualPlacement(apart, "VIRTUAL-1"), "apart")
  assert.deepEqual(M.virtualPositionFor(apart, "VIRTUAL-1", "beside"), { x: 4800, y: 0 })
  const beside = realDesk.concat([{ name: "VIRTUAL-1", x: 4800, y: 0, width: 1366, height: 1024, virtual: true }])
  assert.equal(M.virtualPlacement(beside, "VIRTUAL-1"), "beside")
  assert.deepEqual(M.virtualPositionFor(beside, "VIRTUAL-1", "apart"), { x: 5120, y: 0 }, "the same gap as the backend")
  // Apart clears the other virtual displays too, but beside is only ever a real one.
  const two = apart.concat([{ name: "VIRTUAL-2", x: 7360, y: 0, width: 1366, height: 768, virtual: true }])
  assert.deepEqual(M.virtualPositionFor(two, "VIRTUAL-1", "apart"), { x: 8726 + 320, y: 0 })
  assert.equal(M.virtualPlacement(realDesk.concat([{ name: "VIRTUAL-2", x: 7040, y: 0, width: 100, height: 100, virtual: true }, { name: "VIRTUAL-1", x: 7140, y: 0, width: 100, height: 100, virtual: true }]), "VIRTUAL-1"), "apart", "touching another virtual display is still apart")
  assert.deepEqual(M.rowFields("vsize").display, ["mode"])
  assert.equal(M.VIRTUAL_SIZES.length, 7)
  void withStage
})

test("device presets: every one has a source, a whole logical size, and is found again from its size", () => {
  for (const p of M.virtualPresets()) {
    assert.ok(p.width > p.height, p.label + " is listed in landscape")
    assert.ok(Number.isInteger(p.width / p.scale) && Number.isInteger(p.height / p.scale), p.label + " has a whole logical size")
    if (M.VIRTUAL_DEVICES.includes(p)) assert.match(p.source, /^https:\/\//, p.label + " cites its maker")
  }
  assert.equal(M.virtualPresetFor(2732, 2048, 2), "ipad-pro-12-9", "the first device with a size is the one found")
  assert.equal(M.virtualPresetFor(2048, 2732, 2), "ipad-pro-12-9", "in either orientation")
  assert.equal(M.virtualPresetFor(1600, 1200, 1), "custom")
  assert.equal(M.virtualPresetFor(2732, 2048, 1), "custom", "the scale is part of the preset")
  assert.equal(M.virtualModeFor(M.virtualPresetById("macbook-pro-14"), "landscape", 60), "3024x1964@60")
  assert.equal(M.virtualModeFor(M.virtualPresetById("ipad-mini"), "portrait", 60), "1488x2266@60", "portrait swaps the sides")
  assert.equal(M.virtualOrientation(1488, 2266), "portrait")
  const opts = M.virtualPresetOptions()
  assert.equal(opts[opts.length - 1].value, "custom")
  assert.match(opts.find(o => o.value === "galaxy-tab-ultra").description, /2960×1848 · 2× · Samsung/)
})


test("a picked device is shown as itself, not as the first device of its size", () => {
  assert.equal(M.virtualPresetChosen("pixel-tablet", 2560, 1600, 2), "pixel-tablet")
  assert.equal(M.virtualPresetChosen("pixel-tablet", 1600, 2560, 2), "pixel-tablet", "in portrait too")
  assert.equal(M.virtualPresetChosen("ipad-air-13", 2732, 2048, 2), "ipad-air-13")
  assert.equal(M.virtualPresetChosen(null, 2560, 1600, 2), "macbook-air-m1", "with none picked, the first of that size")
  assert.equal(M.virtualPresetChosen("pixel-tablet", 2560, 1600, 1), "1600p", "a different scale is no longer that device")
  assert.equal(M.virtualPresetChosen("pixel-tablet", 1700, 1000, 2), "custom", "nor is a different size")
  assert.equal(M.virtualPresetChosen("no-such-device", 2560, 1600, 2), "macbook-air-m1")
  for (const p of M.virtualPresets()) assert.equal(M.virtualPresetChosen(p.id, p.width, p.height, p.scale), p.id, p.label + " reads back as itself")
})

test("a virtual display's workspace is named the way the backend names it", () => {
  assert.equal(M.virtualWorkspaceSlug("iPad Pro 12.9″"), "ipad-pro-12-9")
  assert.equal(M.virtualWorkspaceSlug("  Stage!  "), "stage")
  assert.equal(M.virtualWorkspaceSlug("✨"), "", "nothing usable: the backend falls back to the output name")
})

test("the plan presets home workspaces on real displays only, never on a virtual one", () => {
  const r = [
    { name: "DP-1", x: 0, y: 0, width: 2400, height: 1600 },
    { name: "DP-2", x: 2400, y: 0, width: 2400, height: 1600 },
    { name: "VIRTUAL-1", x: 4800, y: 0, width: 1280, height: 800, virtual: true },
    { name: "VIRTUAL-2", x: 6400, y: 0, width: 1920, height: 1080, virtual: true }]
  assert.equal(M.planLine(M.presetPlan("split", r), r), "1–5 on DP-1 · 6–0 on DP-2")
  assert.equal(M.planLine(M.presetPlan("alternate", r), r), "1, 3, 5, 7, 9 on DP-1 · 2, 4, 6, 8, 0 on DP-2")
  assert.equal(M.planKind(M.presetPlan("split", r), r), "split", "and the plan still reads as Split with virtual displays present")
})
