import QtQuick
import qs.Commons

// CIE 1931 xy plot of the panel's EDID primaries over sRGB, DCI-P3 (D65) and
// BT.2020 outlines. Drawn with Canvas so it re-themes with the shell tokens.
Item {
  id: root

  property var primaries: null      // { red:[x,y], green:[x,y], blue:[x,y], white:[x,y] }
  property color foreground: Color.foreground
  property color accent: Color.accent

  implicitWidth: Style.space(120)
  implicitHeight: Style.space(100)

  onPrimariesChanged: plot.requestPaint()
  onForegroundChanged: plot.requestPaint()
  onAccentChanged: plot.requestPaint()

  Canvas {
    id: plot
    anchors.fill: parent
    antialiasing: true

    readonly property var srgb: [[0.640, 0.330], [0.300, 0.600], [0.150, 0.060]]
    readonly property var p3: [[0.680, 0.320], [0.265, 0.690], [0.150, 0.060]]
    readonly property var bt2020: [[0.708, 0.292], [0.170, 0.797], [0.131, 0.046]]

    function px(v) { return 6 + v * (width - 12) / 0.8 }
    function py(v) { return height - 6 - v * (height - 12) / 0.9 }

    function triangle(ctx, pts, stroke, fill, dashed) {
      ctx.beginPath()
      ctx.moveTo(px(pts[0][0]), py(pts[0][1]))
      ctx.lineTo(px(pts[1][0]), py(pts[1][1]))
      ctx.lineTo(px(pts[2][0]), py(pts[2][1]))
      ctx.closePath()
      if (fill) { ctx.fillStyle = fill; ctx.fill() }
      ctx.setLineDash(dashed ? [3, 2] : [])
      ctx.lineWidth = dashed ? 1 : 1.5
      ctx.strokeStyle = stroke
      ctx.stroke()
      ctx.setLineDash([])
    }

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var fg = root.foreground
      var dim = Qt.rgba(fg.r, fg.g, fg.b, 0.25)
      var outline = Qt.rgba(fg.r, fg.g, fg.b, 0.45)

      ctx.lineWidth = 1
      ctx.strokeStyle = dim
      ctx.strokeRect(px(0), py(0.9), px(0.8) - px(0), py(0) - py(0.9))

      triangle(ctx, bt2020, outline, null, true)
      triangle(ctx, p3, outline, null, true)
      triangle(ctx, srgb, outline, null, true)

      var p = root.primaries
      if (p && p.red && p.green && p.blue) {
        var ac = root.accent
        triangle(ctx, [p.red, p.green, p.blue], ac, Qt.rgba(ac.r, ac.g, ac.b, 0.18), false)
        if (p.white) {
          ctx.beginPath()
          ctx.arc(px(p.white[0]), py(p.white[1]), 2, 0, Math.PI * 2)
          ctx.fillStyle = fg
          ctx.fill()
        }
      }

      ctx.fillStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.6)
      ctx.font = "bold " + Math.max(7, Math.round(Style.font.caption * 0.8)) + "px " + Style.font.family
      ctx.fillText("x", px(0.8) - 8, py(0) - 2)
      ctx.fillText("y", px(0) + 2, py(0.9) + 9)
    }
  }
}
