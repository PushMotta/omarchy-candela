import QtQuick
import qs.Commons

// "There is more below", in words. A scrolling column hides whatever runs
// past its bottom edge, and the shell's AsNeeded scrollbar paints nothing at
// rest, so nothing says so. This names the sections you cannot reach and
// scrolls to the first of them when clicked.
//
// A section counts as below when its *end* is past the edge rather than its
// heading: a section whose title sits just above the fold with its controls
// sliced in half is exactly the one worth naming. `slack` keeps a section
// that is a few pixels short of complete quiet.
//
// Markers are `{ item, name }` pairs in visual order. Their positions are
// mapped into the column rather than read off `y`, because a heading is
// usually nested a couple of levels inside the section it titles.
Item {
  id: root

  property var flick: null            // the Flickable inside a ScrollView
  property Item content: null         // the column it scrolls
  // The height the scroller would have if this line were not here. It has to
  // come from outside: measuring the view the line has already shortened
  // makes the test self-fulfilling — the column then overflows by exactly the
  // height of the line reporting it, and the line never goes away again.
  property real available: 0
  property var markers: []
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property real slack: Style.space(24)

  readonly property real viewHeight: flick ? flick.height : 0
  readonly property real contentHeight: content ? content.implicitHeight : 0
  readonly property real edge: (flick && flick.contentY !== undefined ? flick.contentY : 0) + viewHeight

  // Whether the column overflows at all decides the reserved space, and it
  // does not change as you scroll — so the line never resizes the surface
  // under the pointer. Whether anything is below right now decides the text.
  readonly property bool overflowing: contentHeight > available + 1
  readonly property bool more: contentHeight - edge > 4

  implicitHeight: Math.round(Style.font.caption * 1.7)
  height: overflowing ? implicitHeight : 0
  visible: overflowing

  property string names: ""

  function markerTop(item) {
    if (!item || !content) return 0
    return item.mapToItem(content, 0, 0).y
  }

  function sectionEnd(index) {
    for (var j = index + 1; j < markers.length; j++) {
      var next = markers[j].item
      if (next && next.visible) return markerTop(next)
    }
    return root.contentHeight
  }

  // mapToItem is a function call, not a binding, so the names are recomputed
  // on the three things that move them: the scroll position, the height of
  // the column, and the height of the view.
  function refresh() {
    if (!root.more) { root.names = ""; return }
    var out = []
    for (var i = 0; i < markers.length; i++) {
      var m = markers[i]
      if (m && m.item && m.item.visible && sectionEnd(i) - root.edge > root.slack) out.push(m.name)
    }
    root.names = out.join(" · ")
  }

  onEdgeChanged: refresh()
  onContentHeightChanged: refresh()
  onViewHeightChanged: refresh()
  onMoreChanged: refresh()
  Component.onCompleted: refresh()

  function scrollToFirstBelow() {
    if (!flick || flick.contentY === undefined) return
    for (var i = 0; i < markers.length; i++) {
      var m = markers[i]
      if (!m || !m.item || !m.item.visible || sectionEnd(i) - root.edge <= root.slack) continue
      var limit = Math.max(0, root.contentHeight - root.viewHeight)
      scrollAnim.target = flick
      // Never upward: the line is an offer to see what is below.
      scrollAnim.to = Math.min(limit, Math.max(flick.contentY, markerTop(m.item) - Style.spacing.md))
      scrollAnim.restart()
      return
    }
  }

  NumberAnimation {
    id: scrollAnim
    property: "contentY"
    duration: 220
    easing.type: Easing.OutCubic
  }

  Text {
    id: label
    anchors.fill: parent
    verticalAlignment: Text.AlignVCenter
    textFormat: Text.PlainText
    // Falls back to "more" when what is below is the tail of a section
    // already on screen — Advanced expanded, say — which names nothing but
    // is still out of reach.
    text: !root.more ? "" : "⌄ " + (root.names === "" ? "more" : root.names)
    color: Qt.darker(root.foreground, 1.4)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    elide: Text.ElideRight
    opacity: root.more ? 1 : 0

    Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
  }

  MouseArea {
    anchors.fill: parent
    enabled: root.more
    cursorShape: Qt.PointingHandCursor
    onClicked: root.scrollToFirstBelow()
  }
}
