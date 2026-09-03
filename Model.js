// Pure logic shared by the QML surfaces and the node tests. No Qt here.
//
// Vocabulary:
//   display   one entry of `omarchy-candela state` .displays[]
//   caps      display.capabilities (parsed EDID)
//   intent    fields the user chose (display.kept merged with pendingConfig)

var REFERENCE_WHITE = 203      // BT.2408 reference white, cd/m²
var SDR_WHITE_FLOOR = 80       // Hyprland's default sdr_max_luminance
var SCALE_PRESETS = ["1", "1.25", "1.6", "2", "3", "4"]

// ---------------------------------------------------------------- numbers

function num(v, fallback) {
  var n = Number(v)
  return isFinite(n) ? n : fallback
}

function clamp(v, lo, hi) {
  return Math.max(lo, Math.min(hi, v))
}

function round2(v) {
  return Math.round(v * 100) / 100
}

// Scales live on Hyprland's 1/120 grid, and 1/120 is not representable in
// two decimals: 4/3 is 1.33333, and 1.33 is a scale Hyprland corrects with a
// warning. Five decimals keep every grid step distinct; labels round for
// people, values never do.
function round5(v) {
  return Math.round(v * 100000) / 100000
}

function formatScale(v) {
  var n = num(v, 1)
  var s = n.toFixed(2).replace(/0+$/, "").replace(/\.$/, "")
  return s === "" ? "1" : s
}

// hyprctl reports scale to two decimals, so equality is a tolerance, not ===.
function sameScale(a, b) {
  return Math.abs(num(a, NaN) - num(b, NaN)) < 0.006
}

// ---------------------------------------------------------------- scale

function gcd(a, b) {
  while (b) { var t = a % b; a = b; b = t }
  return a
}

// Hyprland only accepts scales where the mode divides into whole logical
// pixels in 1/120 steps: clean scales are divisors of gcd(w*120, h*120).
function cleanScale(scale, width, height) {
  var requested = Number(scale), w = Number(width), h = Number(height)
  if (!isFinite(requested) || !isFinite(w) || !isFinite(h) || requested <= 0 || w <= 0 || h <= 0) return NaN
  var divisor = gcd(Math.round(w * 120), Math.round(h * 120))
  var units = Math.round(requested * 120)
  if (units > divisor) units = divisor
  while (divisor % units !== 0) units++
  return round5(units / 120)
}

// Preset list with duplicates (presets that collapse to one clean scale)
// removed, keeping the label closest to its effective value.
function availableScales(width, height, presets) {
  var list = presets || SCALE_PRESETS
  var byEffective = {}
  for (var i = 0; i < list.length; i++) {
    var requested = Number(list[i])
    var effective = cleanScale(requested, width, height)
    if (!isFinite(effective)) continue
    var key = String(effective)
    var existing = byEffective[key]
    var distance = Math.abs(requested - effective)
    if (!existing || distance < existing.distance) byEffective[key] = { label: String(list[i]), effective: effective, index: i, distance: distance }
  }
  return Object.keys(byEffective).map(function (k) { return byEffective[k] })
    .sort(function (a, b) { return a.index - b.index })
}

function scaleIndex(scales, currentScale) {
  for (var i = 0; i < scales.length; i++) if (sameScale(scales[i].effective, currentScale)) return i
  return -1
}

// ---------------------------------------------------------------- modes

function bitdepthFromFormat(format) {
  var f = String(format || "")
  if (f.indexOf("2101010") !== -1) return 10
  if (f.indexOf("16161616") !== -1) return 16
  return 8
}

function formatMode(width, height, refresh) {
  return width + "x" + height + "@" + round2(num(refresh, 60))
}

// "3840x2560@59.98Hz" → { width, height, refresh, value: "3840x2560@59.98" }
function parseMode(text) {
  var m = String(text || "").match(/^(\d+)x(\d+)(?:@([\d.]+))?/)
  if (!m) return null
  var refresh = m[3] !== undefined ? round2(Number(m[3])) : null
  return { width: Number(m[1]), height: Number(m[2]), refresh: refresh, value: refresh === null ? m[1] + "x" + m[2] : m[1] + "x" + m[2] + "@" + refresh }
}

function modeOptions(display) {
  var seen = {}, out = []
  var modes = (display && display.availableModes) || []
  for (var i = 0; i < modes.length; i++) {
    var p = parseMode(modes[i])
    if (!p || seen[p.value]) continue
    seen[p.value] = true
    out.push({ value: p.value, label: p.width + "×" + p.height + " @ " + p.refresh + " Hz", width: p.width, height: p.height, refresh: p.refresh })
  }
  return out
}

function currentModeValue(display) {
  if (!display || !(display.width > 0)) return "preferred"
  return formatMode(display.width, display.height, display.refreshRate)
}

// ---------------------------------------------------------------- colour

// Effective intent for a display: what is pending wins over what was kept.
function effectiveIntent(display) {
  var out = {}
  var kept = (display && display.kept) || {}
  var pending = (display && display.pendingConfig) || {}
  for (var k in kept) out[k] = kept[k]
  for (var p in pending) out[p] = pending[p]
  return out
}

// One of "sdr" | "wide" | "hdr", from what the compositor reports right now.
function colourMode(display) {
  var live = (display && display.live) || {}
  var cm = String(live.cm || "srgb")
  if (cm === "hdr" || cm === "hdredid") return "hdr"
  var depth = num(live.bitdepth, 8)
  if (depth >= 10 && cm !== "srgb") return "wide"
  return "sdr"
}

// Hyprland's own override convention for supports_hdr / supports_wide_color
// (CLuaConfigInt(0, -1, 1)): 1 forces the capability on, -1 forces it off,
// and 0 — the default, or the field being absent from intent — means trust
// whatever the EDID-derived fallback says.
function override(value, fallback) {
  var n = Number(value)
  if (n === 1) return true
  if (n === -1) return false
  return fallback
}

// `intent` carries the user's overrides (supports_hdr, supports_wide_color,
// icc), on top of what the EDID (`caps`) reports. Omitting it entirely
// reproduces the old EDID-only behaviour.
function offeredModes(caps, intent) {
  var c = caps || {}
  var i = intent || {}
  var hdrCapable = override(i.supports_hdr, !!c.supportsHdr)
  // An HDR-capable panel is wide-capable too, same rule as before overrides existed.
  var wideCapable = override(i.supports_wide_color, !!c.supportsWideColor) || hdrCapable
  var iccLoaded = typeof i.icc === "string" && i.icc.length > 0
  var out = ["sdr"]
  if (wideCapable) out.push("wide")
  if (hdrCapable && !iccLoaded) out.push("hdr")   // DESIGN.md §4.4: ICC and HDR are mutually exclusive
  return out
}

// Why "hdr" is missing from offeredModes(), in the precedence the UI should
// state it: an ICC profile beats a forced-off capability beats a plain
// EDID that never claimed HDR.
function hdrUnavailableReason(caps, intent) {
  var c = caps || {}
  var i = intent || {}
  var hdrCapable = override(i.supports_hdr, !!c.supportsHdr)
  var iccLoaded = typeof i.icc === "string" && i.icc.length > 0
  if (hdrCapable && !iccLoaded) return ""
  if (iccLoaded) return "an ICC profile is loaded"
  if (Number(i.supports_hdr) === -1) return "the HDR capability is forced off"
  return "the panel does not report HDR"
}

function sdrWhiteRange(caps) {
  var c = (caps && caps.hdr) || {}
  var avg = num(c.maxFrameAverageLuminance, NaN)
  if (!isFinite(avg) || avg <= 0) avg = num(c.maxLuminance, NaN)
  if (!isFinite(avg) || avg <= 0) avg = 400
  return { min: SDR_WHITE_FLOOR, max: Math.max(SDR_WHITE_FLOOR, Math.round(avg)), reference: REFERENCE_WHITE }
}

function defaultSdrWhite(caps) {
  var r = sdrWhiteRange(caps)
  return clamp(REFERENCE_WHITE, r.min, r.max)
}

// The change to send to `omarchy-candela apply` for a colour mode switch.
function fieldsForMode(mode, caps, intent) {
  var i = intent || {}
  if (mode === "sdr") return { bitdepth: 8, cm: "srgb", sdr_max_luminance: null, sdr_min_luminance: null }
  if (mode === "wide") return { bitdepth: 10, cm: "auto", sdr_max_luminance: null, sdr_min_luminance: null }
  var minLum = num(caps && caps.hdr && caps.hdr.minLuminance, 0)
  return {
    bitdepth: 10,
    cm: i.cm === "hdredid" ? "hdredid" : "hdr",
    sdr_max_luminance: num(i.sdr_max_luminance, defaultSdrWhite(caps)),
    sdr_min_luminance: minLum > 0 ? minLum : 0.2
  }
}

// Slider position for SDR white: perceptually a log scale reads better than
// linear across 80–500 cd/m², and 203 lands near the middle.
function sdrWhiteToSlider(nits, range) {
  var lo = Math.log(range.min), hi = Math.log(range.max)
  if (hi <= lo) return 0
  return clamp((Math.log(clamp(nits, range.min, range.max)) - lo) / (hi - lo), 0, 1)
}

function sliderToSdrWhite(t, range) {
  var lo = Math.log(range.min), hi = Math.log(range.max)
  return Math.round(Math.exp(lo + clamp(t, 0, 1) * (hi - lo)))
}

function outputCaption(display) {
  var live = (display && display.live) || {}
  var caps = (display && display.capabilities) || {}
  var mode = colourMode(display)
  var depth = num(live.bitdepth, 8)
  if (mode === "hdr") {
    var peak = num(caps.hdr && caps.hdr.maxLuminance, NaN)
    var white = num(live.sdrMaxLuminance, SDR_WHITE_FLOOR)
    var s = depth + "-bit · BT.2020 PQ · SDR white " + Math.round(white) + " cd/m²"
    if (isFinite(peak)) s += " · peak " + Math.round(peak) + " cd/m²"
    return s
  }
  if (mode === "wide") return depth + "-bit · BT.2020 container, SDR transfer · no PQ metadata"
  var eotf = String(display && display.eotfLabel || "gamma 2.2")
  return depth + "-bit · sRGB · transfer " + eotf
}

function capabilityLine(caps) {
  var c = caps || {}
  if (!c.available) return "No EDID available"
  var parts = []
  if (c.supportsHdr) parts.push("HDR10")
  var col = c.colorimetry || []
  if (col.some(function (x) { return /BT2020/.test(x) })) parts.push("BT.2020")
  else if (col.some(function (x) { return /P3/.test(x) })) parts.push("P3")
  if (c.bitsPerPrimary) parts.push(c.bitsPerPrimary + "-bit")
  var peak = num(c.hdr && c.hdr.maxLuminance, NaN)
  if (isFinite(peak)) parts.push("peak " + Math.round(peak) + " cd/m²")
  if (parts.length === 0) parts.push("SDR")
  return parts.join(" · ")
}

function luminanceLine(caps) {
  var h = (caps && caps.hdr) || {}
  var peak = num(h.maxLuminance, NaN), avg = num(h.maxFrameAverageLuminance, NaN), min = num(h.minLuminance, NaN)
  if (!isFinite(peak)) return ""
  var s = "Peak " + Math.round(peak) + " cd/m²"
  if (isFinite(avg)) s += " · avg " + Math.round(avg)
  if (isFinite(min)) s += " · min " + min.toFixed(3)
  return s
}

function primariesLine(caps) {
  var p = caps && caps.primaries
  if (!p) return ""
  // Round half up in decimal before formatting: 0.0595 is stored just below
  // itself in binary and toFixed alone would print .059.
  function f(v) { return (Math.round(Number(v) * 1000 + 1e-9) / 1000).toFixed(3).replace(/^0/, "") }
  return "R " + f(p.red[0]) + " " + f(p.red[1]) + " · G " + f(p.green[0]) + " " + f(p.green[1]) + " · B " + f(p.blue[0]) + " " + f(p.blue[1])
}

// ---------------------------------------------------------------- identity

function displayTitle(display) {
  if (!display) return ""
  var model = String(display.model || "").trim()
  return model ? display.name + " · " + model : display.name
}

function panelLine(display) {
  var d = display || {}
  var caps = d.capabilities || {}
  var parts = []
  if (caps.manufacturer && caps.productCode) parts.push(caps.manufacturer + " " + caps.productCode)
  if (caps.physicalWidthMm && caps.physicalHeightMm) parts.push(caps.physicalWidthMm + "×" + caps.physicalHeightMm + " mm")
  if (caps.diagonalInch) parts.push(caps.diagonalInch + "″")
  if (caps.ppi) parts.push(caps.ppi + " ppi")
  var serial = String(d.serial || "").trim()
  if (!serial) parts.push("serial blank, identified by connector")
  return parts.join(" · ")
}

function metaLine(display) {
  var d = display || {}
  if (!(d.width > 0)) return "DISABLED"
  var parts = [d.width + "×" + d.height, Math.round(num(d.refreshRate, 0)) + " Hz", formatScale(d.scale) + "×"]
  var mode = colourMode(d)
  parts.push(mode === "hdr" ? "HDR" : (mode === "wide" ? "WIDE" : "SDR"))
  if (d.mirrorOf && d.mirrorOf !== "none") parts.push("MIRROR OF " + d.mirrorOf)
  return parts.join(" · ")
}

// ---------------------------------------------------------------- layout

function logicalSize(display, scaleOverride, transformOverride) {
  var d = display || {}
  var scale = num(scaleOverride !== undefined ? scaleOverride : d.scale, 1) || 1
  var transform = num(transformOverride !== undefined ? transformOverride : d.transform, 0)
  var w = Math.round(num(d.width, 0) / scale), h = Math.round(num(d.height, 0) / scale)
  if (transform % 2 === 1) return { width: h, height: w }
  return { width: w, height: h }
}

function rectOf(display, overrides) {
  var o = overrides || {}
  var size = logicalSize(display, o.scale, o.transform)
  return { name: display.name, x: num(o.x !== undefined ? o.x : display.x, 0), y: num(o.y !== undefined ? o.y : display.y, 0), width: size.width, height: size.height }
}

function overlaps(a, b) {
  return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
}

function boundsOf(rects) {
  if (!rects.length) return { x: 0, y: 0, width: 0, height: 0 }
  var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
  rects.forEach(function (r) {
    minX = Math.min(minX, r.x); minY = Math.min(minY, r.y)
    maxX = Math.max(maxX, r.x + r.width); maxY = Math.max(maxY, r.y + r.height)
  })
  return { x: minX, y: minY, width: maxX - minX, height: maxY - minY }
}

// Snap a moving rect's edges to the other rects' edges within `threshold`
// logical px. Returns the snapped position plus which guides fired.
function snapRect(moving, others, threshold) {
  var t = threshold === undefined ? 40 : threshold
  var best = { x: moving.x, y: moving.y, guides: [] }
  var dx = null, dy = null
  others.forEach(function (o) {
    if (o.name === moving.name) return
    var xCandidates = [
      { d: (o.x + o.width) - moving.x, guide: o.x + o.width },   // left edge to right edge
      { d: o.x - (moving.x + moving.width), guide: o.x },        // right edge to left edge
      { d: o.x - moving.x, guide: o.x },                          // left edges align
      { d: (o.x + o.width) - (moving.x + moving.width), guide: o.x + o.width }
    ]
    var yCandidates = [
      { d: (o.y + o.height) - moving.y, guide: o.y + o.height },
      { d: o.y - (moving.y + moving.height), guide: o.y },
      { d: o.y - moving.y, guide: o.y },
      { d: (o.y + o.height) - (moving.y + moving.height), guide: o.y + o.height }
    ]
    xCandidates.forEach(function (c) { if (Math.abs(c.d) <= t && (dx === null || Math.abs(c.d) < Math.abs(dx.d))) dx = c })
    yCandidates.forEach(function (c) { if (Math.abs(c.d) <= t && (dy === null || Math.abs(c.d) < Math.abs(dy.d))) dy = c })
  })
  if (dx) { best.x = moving.x + dx.d; best.guides.push({ axis: "x", at: dx.guide }) }
  if (dy) { best.y = moving.y + dy.d; best.guides.push({ axis: "y", at: dy.guide }) }
  return best
}

// Where a dragged block lands: its position when the drag started, plus how far
// the pointer has travelled since, then snapped. The travel is measured from the
// press point and nothing else — measuring it against the block's last drawn
// position feeds the block's own displacement back into the next frame and it
// oscillates instead of following the hand.
function dragPosition(origin, delta, targets, threshold) {
  return snapRect({ name: origin.name, x: origin.x + delta.x, y: origin.y + delta.y,
                    width: origin.width, height: origin.height }, targets, threshold)
}

function anyOverlap(rects) {
  for (var i = 0; i < rects.length; i++)
    for (var j = i + 1; j < rects.length; j++)
      if (overlaps(rects[i], rects[j])) return [rects[i].name, rects[j].name]
  return null
}

// Displays that take part in arrangement: enabled, and not mirroring another.
// A mirrored or disabled output has no independent position, so it neither
// snaps, nor blocks, nor counts as an overlap.
function arrangeable(rects) {
  return rects.filter(function (r) { return !r.disabled && !r.mirrorOf })
}

// Rects a dragged block may snap its edges to: arrangeable, minus itself.
function snapTargets(rects, movingName) {
  return arrangeable(rects).filter(function (r) { return r.name !== movingName })
}

// Replace the dragged rect with its provisional position, so overlap and the
// caption can report where the block is now rather than where it was dropped.
function withRect(rects, name, x, y) {
  return rects.map(function (r) {
    if (r.name !== name) return r
    var c = {}
    for (var k in r) c[k] = r[k]
    c.x = x; c.y = y
    return c
  })
}

function layoutCaption(rects) {
  return rects.map(function (r) { return r.name + " at " + r.x + ", " + r.y }).join(" · ")
}

// When a mode, scale or rotation changes a display's logical size, the
// displays that sat flush against (or beyond) its old right and bottom edges
// move by the difference, so a flush layout stays flush and a deliberate gap
// stays the same gap. `rects` already carries the new size; `oldSize` is
// what it was. Returns the moves, not a new layout: the studio stages each
// one as a draft position like any other edit.
function reflowAfterResize(rects, name, oldSize) {
  var resized = null
  for (var i = 0; i < rects.length; i++) if (rects[i].name === name) resized = rects[i]
  if (!resized || resized.disabled || resized.mirrorOf) return []
  var dx = resized.width - oldSize.width
  var dy = resized.height - oldSize.height
  if (dx === 0 && dy === 0) return []
  var oldRight = resized.x + oldSize.width
  var oldBottom = resized.y + oldSize.height
  var moves = []
  arrangeable(rects).forEach(function (r) {
    if (r.name === name) return
    var x = r.x, y = r.y
    if (dx !== 0 && r.x >= oldRight) x += dx
    if (dy !== 0 && r.y >= oldBottom) y += dy
    if (x !== r.x || y !== r.y) moves.push({ name: r.name, x: x, y: y })
  })
  return moves
}

// A pointer drop on top of another display is not a request for an overlap:
// it is a release that missed by a little. Move the dropped rect to the
// nearest position flush against an edge of the display it landed on (or of
// any other) where it overlaps nothing. Returns null when the drop is clean
// or when no clear edge exists; typed positions never come through here, so
// exact coordinates stay exact.
function placeOutsideOverlaps(rect, others) {
  var targets = arrangeable(others).filter(function (o) { return o.name !== rect.name })
  function clear(x, y) {
    var probe = { name: rect.name, x: x, y: y, width: rect.width, height: rect.height }
    for (var i = 0; i < targets.length; i++) if (overlaps(probe, targets[i])) return false
    return true
  }
  if (clear(rect.x, rect.y)) return null
  var best = null
  targets.forEach(function (o) {
    [[o.x - rect.width, rect.y], [o.x + o.width, rect.y], [rect.x, o.y - rect.height], [rect.x, o.y + o.height]].forEach(function (c) {
      if (!clear(c[0], c[1])) return
      var d = (c[0] - rect.x) * (c[0] - rect.x) + (c[1] - rect.y) * (c[1] - rect.y)
      if (best === null || d < best.d) best = { x: c[0], y: c[1], d: d }
    })
  })
  return best === null ? null : { x: best.x, y: best.y }
}

// Alt+arrow: put the selected display flush against the nearest other
// display on the given side, centred along the other axis. Nearest is by
// centre distance, so the anchor is the display the user is looking at.
function snapBeside(rects, name, direction) {
  var me = null
  for (var i = 0; i < rects.length; i++) if (rects[i].name === name) me = rects[i]
  if (!me || me.disabled || me.mirrorOf) return null
  var cx = me.x + me.width / 2, cy = me.y + me.height / 2
  var anchor = null, bestD = Infinity
  arrangeable(rects).forEach(function (o) {
    if (o.name === name) return
    var ox = o.x + o.width / 2, oy = o.y + o.height / 2
    var d = (ox - cx) * (ox - cx) + (oy - cy) * (oy - cy)
    if (d < bestD) { bestD = d; anchor = o }
  })
  if (!anchor) return null
  var centreX = anchor.x + Math.trunc((anchor.width - me.width) / 2)
  var centreY = anchor.y + Math.trunc((anchor.height - me.height) / 2)
  if (direction === "left") return { x: anchor.x - me.width, y: centreY }
  if (direction === "right") return { x: anchor.x + anchor.width, y: centreY }
  if (direction === "up") return { x: centreX, y: anchor.y - me.height }
  if (direction === "down") return { x: centreX, y: anchor.y + anchor.height }
  return null
}

// ---------------------------------------------------------------- brightness

function brightnessName(percent) {
  var p = Math.round(percent)
  if (p >= 95) return "Sun blast"
  if (p >= 80) return "Solar flare"
  if (p >= 65) return "Golden hour"
  if (p >= 45) return "Even day"
  if (p >= 30) return "Soft glow"
  if (p >= 20) return "Lamp light"
  if (p >= 10) return "Candlelit"
  return "Night owl"
}

function parseState(raw) {
  try {
    var s = JSON.parse(String(raw || ""))
    if (s && Array.isArray(s.displays)) return s
  } catch (e) { /* fall through */ }
  return null
}

if (typeof module !== "undefined") {
  module.exports = {
    REFERENCE_WHITE: REFERENCE_WHITE, SDR_WHITE_FLOOR: SDR_WHITE_FLOOR, SCALE_PRESETS: SCALE_PRESETS,
    cleanScale: cleanScale, availableScales: availableScales, scaleIndex: scaleIndex, formatScale: formatScale, sameScale: sameScale, round5: round5,
    bitdepthFromFormat: bitdepthFromFormat, formatMode: formatMode, parseMode: parseMode, modeOptions: modeOptions, currentModeValue: currentModeValue,
    effectiveIntent: effectiveIntent, colourMode: colourMode, offeredModes: offeredModes, hdrUnavailableReason: hdrUnavailableReason, sdrWhiteRange: sdrWhiteRange, defaultSdrWhite: defaultSdrWhite,
    fieldsForMode: fieldsForMode, sdrWhiteToSlider: sdrWhiteToSlider, sliderToSdrWhite: sliderToSdrWhite,
    outputCaption: outputCaption, capabilityLine: capabilityLine, luminanceLine: luminanceLine, primariesLine: primariesLine,
    displayTitle: displayTitle, panelLine: panelLine, metaLine: metaLine,
    logicalSize: logicalSize, rectOf: rectOf, overlaps: overlaps, boundsOf: boundsOf, snapRect: snapRect, anyOverlap: anyOverlap, layoutCaption: layoutCaption,
    arrangeable: arrangeable, snapTargets: snapTargets, withRect: withRect, dragPosition: dragPosition,
    reflowAfterResize: reflowAfterResize, placeOutsideOverlaps: placeOutsideOverlaps, snapBeside: snapBeside,
    brightnessName: brightnessName, parseState: parseState, clamp: clamp, round2: round2
  }
}
