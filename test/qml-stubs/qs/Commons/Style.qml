// Stand-in for the shell's qs.Commons singletons, only what the components under test read.
pragma Singleton
import QtQuick
QtObject {
  property var font: ({ family: "sans-serif", caption: 11, bodySmall: 12, body: 13, subtitle: 14 })
  property var spacing: ({ labelGap: 2, xs: 2, md: 8, xl: 16, rowPaddingX: 12 })
  property real cornerRadius: 4
  function space(n) { return n }
  function hoverFillFor(fg, accent) { return "#222" }
  function selectedFillFor(fg, accent) { return "#333" }
}
