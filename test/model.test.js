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
  assert.equal(M.cleanScale(1.3, 3840, 2560), 1.33)
  const scales = M.availableScales(3840, 2560)
  assert.deepEqual(scales.map(s => s.label), ["1", "1.25", "1.6", "2", "3", "4"])
  assert.equal(M.scaleIndex(scales, 1.6), 2)
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
  assert.deepEqual(M.effectiveIntent(d), { cm: "hdr", sdr_max_luminance: 250 })
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
