import QtQuick
import qs.Commons

// CIE 1931 xy plot of the panel's EDID primaries over sRGB, DCI-P3 (D65) and
// BT.2020, with the spectral locus for context and the gamut actually in use
// filled in. Drawn with Canvas so it re-themes with the shell tokens.
//
// The filled triangle is the one the output is using right now: sRGB primaries
// while the display is clamped to sRGB, the panel's own once wide gamut or HDR
// opens the container. Switching mode tweens between them, which is the whole
// point of the control — you can see the headroom you just bought.
//
// The fill colours are honest about being approximate: a chromaticity is
// converted to sRGB, negative components are lifted by adding white (the
// standard way of showing what is out of gamut without pretending otherwise),
// and the result is normalised. No display can show its own out-of-gamut
// colours correctly, this one included.
Item {
  id: root

  property var primaries: null      // { red:[x,y], green:[x,y], blue:[x,y], white:[x,y] }
  property string mode: "sdr"       // sdr | wide | hdr
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color surface: Color.popups.background
  property real fillOpacity: 0.55

  implicitWidth: Style.space(150)
  implicitHeight: Style.space(130)

  readonly property var srgbPrimaries: [[0.640, 0.330], [0.300, 0.600], [0.150, 0.060]]

  readonly property var panelPrimaries: {
    var p = root.primaries
    if (p && p.red && p.green && p.blue) return [p.red, p.green, p.blue]
    return root.srgbPrimaries
  }

  // 0 = clamped to sRGB, 1 = the panel's own primaries. The Behavior is what
  // makes a mode change legible rather than a jump cut.
  property real morph: root.mode === "sdr" ? 0 : 1
  Behavior on morph { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

  onMorphChanged: plot.requestPaint()
  onSurfaceChanged: plot.requestPaint()
  onPrimariesChanged: plot.requestPaint()
  onForegroundChanged: plot.requestPaint()
  onAccentChanged: plot.requestPaint()

  Canvas {
    id: plot
    anchors.fill: parent
    antialiasing: true

    readonly property var p3: [[0.680, 0.320], [0.265, 0.690], [0.150, 0.060]]
    readonly property var bt2020: [[0.708, 0.292], [0.170, 0.797], [0.131, 0.046]]

    // CIE 1931 2° spectral locus, 380-700 nm in 5 nm steps.
    readonly property var locus: [
      [0.1741,0.0050],[0.1740,0.0050],[0.1738,0.0049],[0.1736,0.0049],[0.1733,0.0048],
      [0.1730,0.0048],[0.1726,0.0048],[0.1721,0.0048],[0.1714,0.0051],[0.1703,0.0058],
      [0.1689,0.0069],[0.1669,0.0086],[0.1644,0.0109],[0.1611,0.0138],[0.1566,0.0177],
      [0.1510,0.0227],[0.1440,0.0297],[0.1355,0.0399],[0.1241,0.0578],[0.1096,0.0868],
      [0.0913,0.1327],[0.0687,0.2007],[0.0454,0.2950],[0.0235,0.4127],[0.0082,0.5384],
      [0.0039,0.6548],[0.0139,0.7502],[0.0389,0.8120],[0.0743,0.8338],[0.1142,0.8262],
      [0.1547,0.8059],[0.1929,0.7816],[0.2296,0.7543],[0.2658,0.7243],[0.3016,0.6923],
      [0.3373,0.6589],[0.3731,0.6245],[0.4087,0.5896],[0.4441,0.5547],[0.4788,0.5202],
      [0.5125,0.4866],[0.5448,0.4544],[0.5752,0.4242],[0.6029,0.3965],[0.6270,0.3725],
      [0.6482,0.3514],[0.6658,0.3340],[0.6801,0.3197],[0.6915,0.3083],[0.7006,0.2993],
      [0.7079,0.2920],[0.7140,0.2859],[0.7190,0.2809],[0.7230,0.2770],[0.7260,0.2740],
      [0.7283,0.2717],[0.7300,0.2700],[0.7311,0.2689],[0.7320,0.2680],[0.7327,0.2673],
      [0.7334,0.2666],[0.7340,0.2660],[0.7344,0.2656],[0.7346,0.2654],[0.7347,0.2653]
    ]

    // One scale for both axes, centred in whatever box it is given. x and y
    // in CIE 1931 are the same kind of quantity: stretching one against the
    // other moves every primary off its true place and makes the diagram a
    // decoration. The caller can size this freely and the geometry holds.
    readonly property real unit: Math.max(1, Math.min((width - 12) / 0.8, (height - 12) / 0.9))
    readonly property real insetX: (width - 0.8 * unit) / 2
    readonly property real insetY: (height - 0.9 * unit) / 2

    function px(v) { return insetX + v * unit }
    function py(v) { return height - insetY - v * unit }

    function lerpPoint(a, b, t) {
      return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]
    }

    // A chromaticity as this screen can best show it: convert to linear sRGB,
    // lift negatives by adding white rather than clipping them to black, then
    // normalise so every point renders at full brightness.
    function chromaColor(x, y, alpha) {
      if (y <= 0.00001) return Qt.rgba(0, 0, 0, 0)
      // Y is fixed at 1 and normalised away below, so the middle column of
      // the XYZ-to-linear-sRGB matrix appears here as a bare constant.
      var X = x / y
      var Z = (1 - x - y) / y
      var r =  3.2406 * X - 1.5372 - 0.4986 * Z
      var g = -0.9689 * X + 1.8758 + 0.0415 * Z
      var b =  0.0557 * X - 0.2040 + 1.0570 * Z
      var m = Math.min(r, g, b)
      if (m < 0) { r -= m; g -= m; b -= m }
      var mx = Math.max(r, g, b)
      if (mx > 0) { r /= mx; g /= mx; b /= mx }
      return Qt.rgba(encode(r), encode(g), encode(b), alpha)
    }

    function encode(c) {
      c = Math.max(0, Math.min(1, c))
      return c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055
    }

    function polygon(ctx, pts) {
      ctx.beginPath()
      ctx.moveTo(px(pts[0][0]), py(pts[0][1]))
      for (var i = 1; i < pts.length; i++) ctx.lineTo(px(pts[i][0]), py(pts[i][1]))
      ctx.closePath()
    }

    function outline(ctx, pts, stroke, dashed) {
      polygon(ctx, pts)
      ctx.setLineDash(dashed ? [3, 2] : [])
      ctx.lineWidth = dashed ? 1 : 1.5
      ctx.strokeStyle = stroke
      ctx.stroke()
      ctx.setLineDash([])
    }

    // A point on the triangle's barycentric grid: P(i,j) walks A to B as i
    // grows and B to C as j grows, so (0,0) is A, (n,0) is B and (n,n) is C.
    function meshPoint(tri, i, j, n) {
      var wa = 1 - i / n, wb = (i - j) / n, wc = j / n
      return [tri[0][0] * wa + tri[1][0] * wb + tri[2][0] * wc,
              tri[0][1] * wa + tri[1][1] * wb + tri[2][1] * wc]
    }

    // Each cell is filled with the colour of its own centre, which is what
    // makes the triangle read as a gamut rather than as a shape. 16 rows is
    // where the banding stops showing at this size.
    function meshFill(ctx, tri, alpha) {
      var n = 16
      // Clipped to the triangle, because the cells are drawn oversized and
      // would otherwise bleed past the very edge the outline is marking.
      ctx.save()
      polygon(ctx, tri)
      ctx.clip()
      for (var i = 0; i < n; i++) {
        for (var j = 0; j <= i; j++) {
          cell(ctx, [meshPoint(tri, i, j, n),
                     meshPoint(tri, i + 1, j, n),
                     meshPoint(tri, i + 1, j + 1, n)], alpha)
          if (j < i)
            cell(ctx, [meshPoint(tri, i, j, n),
                       meshPoint(tri, i + 1, j + 1, n),
                       meshPoint(tri, i, j + 1, n)], alpha)
        }
      }
      ctx.restore()
    }

    // Cells are grown a few percent about their own centre so neighbours
    // overlap. Antialiased edges that merely touch leave a pale seam on every
    // shared edge, and stroking them closed just draws the lattice instead.
    function cell(ctx, pts, alpha) {
      var cx = (pts[0][0] + pts[1][0] + pts[2][0]) / 3
      var cy = (pts[0][1] + pts[1][1] + pts[2][1]) / 3
      var grown = []
      for (var i = 0; i < 3; i++)
        grown.push([cx + (pts[i][0] - cx) * 1.2, cy + (pts[i][1] - cy) * 1.2])
      polygon(ctx, grown)
      ctx.fillStyle = chromaColor(cx, cy, alpha)
      ctx.fill()
    }

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var fg = root.foreground
      var dim = Qt.rgba(fg.r, fg.g, fg.b, 0.25)
      var ref = Qt.rgba(fg.r, fg.g, fg.b, 0.45)

      ctx.lineWidth = 1
      ctx.strokeStyle = dim
      ctx.strokeRect(px(0), py(0.9), px(0.8) - px(0), py(0) - py(0.9))

      // The spectral locus, closed by the line of purples: the shape that says
      // at a glance how much of what the eye can see is on the table.
      polygon(ctx, plot.locus)
      ctx.setLineDash([])
      ctx.lineWidth = 1
      ctx.strokeStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.30)
      ctx.stroke()

      outline(ctx, bt2020, ref, true)
      outline(ctx, p3, ref, true)
      outline(ctx, root.srgbPrimaries, ref, true)

      var panel = root.panelPrimaries
      var inUse = [lerpPoint(root.srgbPrimaries[0], panel[0], root.morph),
                   lerpPoint(root.srgbPrimaries[1], panel[1], root.morph),
                   lerpPoint(root.srgbPrimaries[2], panel[2], root.morph)]

      // The mesh is drawn opaque and dimmed afterwards in one pass. Filling
      // translucent cells that overlap would composite each overlap twice and
      // print the tessellation across the gamut.
      meshFill(ctx, inUse, 1.0)
      polygon(ctx, inUse)
      ctx.fillStyle = Qt.rgba(root.surface.r, root.surface.g, root.surface.b, 1 - root.fillOpacity)
      ctx.fill()
      outline(ctx, inUse, root.accent, false)

      // The panel's own corners stay outlined even while sRGB is in use, so
      // the headroom a mode change would buy is visible before taking it.
      if (root.morph < 0.98)
        outline(ctx, panel, Qt.rgba(fg.r, fg.g, fg.b, 0.7), false)

      var p = root.primaries
      if (p && p.white) {
        ctx.beginPath()
        ctx.arc(px(p.white[0]), py(p.white[1]), 2.5, 0, Math.PI * 2)
        ctx.fillStyle = fg
        ctx.fill()
        ctx.strokeStyle = Qt.rgba(0, 0, 0, 0.5)
        ctx.lineWidth = 1
        ctx.stroke()
      }

      ctx.fillStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.6)
      ctx.font = "bold " + Math.max(7, Math.round(Style.font.caption * 0.8)) + "px " + Style.font.family
      ctx.fillText("x", px(0.8) - 8, py(0) - 2)
      ctx.fillText("y", px(0) + 2, py(0.9) + 9)
    }
  }
}
