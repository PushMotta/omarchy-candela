import QtQuick
import qs.Commons
import qs.Ui
import "../Model.js" as Model

// Arrangement canvas in logical pixels. Blocks are draggable with the mouse
// and nudgeable with the keyboard; edges snap to neighbours; overlap paints
// the offending blocks urgent. The canvas never writes anywhere: it emits
// `moved` and the studio decides what to do with it.
Item {
  id: root

  // [{ name, x, y, width, height, model, mode, scale, hdr, disabled, focused }]
  property var rects: []
  property string selectedName: ""
  property bool hasCursor: false
  property color foreground: Color.popups.text
  property color accent: Color.accent
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  // Snap distance measured on screen, not in logical pixels: the pull has to
  // feel the same whether the layout is zoomed to a quarter or a fortieth.
  property int snapThreshold: 12
  // Pointer travel, in screen px, before a press turns into a drag. Without it
  // a click that selects a display also nudges it by a pixel or two.
  property int dragStartThreshold: 4

  signal selected(string name)
  signal moved(string name, int x, int y)

  readonly property var bounds: Model.boundsOf(root.rects)
  readonly property real padding: Style.space(28)
  // Fit the whole layout with padding; never zoom past 1:4 so a lone display
  // does not fill the canvas edge to edge. Held still during a drag: refitting
  // under the pointer would move the block the user is trying to place.
  readonly property real factor: {
    var b = root.bounds
    if (b.width <= 0 || b.height <= 0) return 0.1
    var fx = (root.width - root.padding * 2) / b.width
    var fy = (root.height - root.padding * 2) / b.height
    return Math.max(0.01, Math.min(fx, fy, 0.25))
  }
  readonly property real originX: root.padding + ((root.width - root.padding * 2) - root.bounds.width * root.factor) / 2 - root.bounds.x * root.factor
  readonly property real originY: root.padding + ((root.height - root.padding * 2) - root.bounds.height * root.factor) / 2 - root.bounds.y * root.factor

  property var guides: []
  property string draggingName: ""
  // Where the dragged block currently sits, in logical px, after snapping.
  property real dragLogX: 0
  property real dragLogY: 0
  // Filtered once when the drag arms, not on every pointer event.
  property var dragTargets: []

  // The layout as it stands right now, with the dragged block at its live
  // position, so overlap and the caption describe what the user is seeing.
  readonly property var liveRects: root.draggingName === ""
    ? root.rects
    : Model.withRect(root.rects, root.draggingName, Math.round(root.dragLogX), Math.round(root.dragLogY))
  readonly property var overlap: Model.anyOverlap(Model.arrangeable(root.liveRects))

  readonly property var blankRect: ({ name: "", x: 0, y: 0, width: 0, height: 0,
                                      model: "", mode: "", scale: 1, hdr: false,
                                      disabled: true, mirrorOf: "", focused: false })

  function toPixelX(lx) { return root.originX + lx * root.factor }
  function toPixelY(ly) { return root.originY + ly * root.factor }
  function toLogicalX(px) { return (px - root.originX) / root.factor }
  function toLogicalY(py) { return (py - root.originY) / root.factor }

  // Delegates outlive a change to `rects`, so a display disappearing under the
  // pointer has to end the drag explicitly.
  onRectsChanged: {
    if (root.draggingName !== "" && rectByName(root.draggingName) === null) {
      root.draggingName = ""
      root.guides = []
    }
  }

  function rectByName(name) {
    for (var i = 0; i < rects.length; i++) if (rects[i].name === name) return rects[i]
    return null
  }

  function nudge(dx, dy) {
    var r = rectByName(selectedName)
    if (!r) return
    root.moved(r.name, r.x + dx, r.y + dy)
  }

  BorderSurface {
    anchors.fill: parent
    color: "transparent"
    radius: Style.cornerRadius
    borderSpec: root.hasCursor
      ? Border.controlSpec("hover-cursor", root.foreground, root.accent)
      : Border.controlSpec("normal", root.foreground, root.accent)
  }

  // Dot grid every 240 logical px, so the grid tells the scale of the layout.
  Canvas {
    id: grid
    anchors.fill: parent
    anchors.margins: 1
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var fg = root.foreground
      ctx.fillStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.16)
      var step = 240 * root.factor
      if (step < 8) step = 8
      var startX = (root.originX % step), startY = (root.originY % step)
      for (var x = startX; x < width; x += step)
        for (var y = startY; y < height; y += step) ctx.fillRect(Math.round(x), Math.round(y), 1, 1)
    }
    Connections {
      target: root
      function onFactorChanged() { grid.requestPaint() }
      function onOriginXChanged() { grid.requestPaint() }
      function onOriginYChanged() { grid.requestPaint() }
      function onForegroundChanged() { grid.requestPaint() }
      function onWidthChanged() { grid.requestPaint() }
      function onHeightChanged() { grid.requestPaint() }
    }
  }

  // Indexed by count, not by the array itself: a `var` array model rebuilds
  // every delegate on every change, which during a drag means rebuilding the
  // guides sixty times a second.
  Repeater {
    model: root.guides.length
    Rectangle {
      required property int index
      readonly property var guide: root.guides[index] !== undefined ? root.guides[index] : null
      visible: guide !== null
      color: root.accent
      opacity: 0.6
      x: guide && guide.axis === "x" ? Math.round(root.toPixelX(guide.at)) : 0
      y: guide && guide.axis === "y" ? Math.round(root.toPixelY(guide.at)) : 0
      width: guide && guide.axis === "x" ? 1 : root.width
      height: guide && guide.axis === "y" ? 1 : root.height
    }
  }

  // Also indexed by count, so the delegates survive a change to `rects`. They
  // hold the drag state and the position animations; rebuilding them mid-drag
  // drops both.
  Repeater {
    model: root.rects.length

    BorderSurface {
      id: block
      required property int index
      readonly property var disp: root.rects[index] !== undefined ? root.rects[index] : root.blankRect
      readonly property bool isSelected: disp.name !== "" && disp.name === root.selectedName
      readonly property bool isDragging: disp.name !== "" && root.draggingName === disp.name
      readonly property bool isOverlapping: root.overlap !== null && (root.overlap[0] === disp.name || root.overlap[1] === disp.name)

      visible: disp.name !== ""
      x: isDragging ? root.toPixelX(root.dragLogX) : Math.round(root.toPixelX(disp.x))
      y: isDragging ? root.toPixelY(root.dragLogY) : Math.round(root.toPixelY(disp.y))
      width: Math.max(24, Math.round(disp.width * root.factor))
      height: Math.max(16, Math.round(disp.height * root.factor))
      z: isSelected ? 2 : 1
      radius: Style.cornerRadius
      opacity: disp.disabled ? 0.45 : 1
      color: isSelected
        ? Util.alpha(root.foreground, 0.10)
        : Util.alpha(root.foreground, 0.06)
      borderSpec: isOverlapping
        ? Border.flat(root.urgent, Math.max(1, Style.space(2)))
        : (isSelected
          ? Border.flat(root.accent, Math.max(1, Style.space(2)))
          : Border.controlSpec("normal", root.foreground, root.accent))

      Behavior on x { enabled: !block.isDragging; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      Behavior on y { enabled: !block.isDragging; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      Behavior on width { enabled: !block.isDragging; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      Behavior on height { enabled: !block.isDragging; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

      Column {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: Style.space(10)
        spacing: Style.space(2)

        Row {
          spacing: Style.space(6)
          Rectangle {
            visible: block.disp.focused
            width: Style.space(6); height: width; radius: width / 2
            color: root.accent
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            textFormat: Text.PlainText
            text: block.disp.name
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }
          BorderSurface {
            visible: block.disp.hdr || block.disp.disabled || (block.disp.mirrorOf && block.disp.mirrorOf !== "")
            implicitWidth: badgeText.implicitWidth + Style.space(10)
            implicitHeight: badgeText.implicitHeight + Style.space(3)
            anchors.verticalCenter: parent.verticalCenter
            color: "transparent"
            radius: Style.cornerRadius
            borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
            Text {
              id: badgeText
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: block.disp.disabled ? "OFF" : (block.disp.mirrorOf ? "MIRROR" : "HDR")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }
        }
      }

      Text {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: Style.space(10)
        width: parent.width - Style.space(20)
        textFormat: Text.PlainText
        text: (block.disp.model ? block.disp.model + " · " : "") + block.disp.mode + " · " + block.disp.scale + "×\n" + block.disp.width + "×" + block.disp.height + " logical"
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        maximumLineCount: 2
        wrapMode: Text.NoWrap
        visible: parent.height > Style.space(56)
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: block.disp.disabled ? Qt.ArrowCursor : (block.isDragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor)
        // The press point and the block's origin, both in canvas coordinates.
        // `mouse.x` is relative to this MouseArea, which travels with the block
        // while it is dragged, so every reading is mapped back to the canvas
        // before it is used. Measuring in the moving frame feeds the block's
        // own displacement back into the next position and it oscillates.
        property real pressCanvasX: 0
        property real pressCanvasY: 0
        property real originLogX: 0
        property real originLogY: 0
        property bool armed: false
        // The display grabbed at press. A delegate is bound to an index, not to
        // a display, so if the list changes under the pointer this stops the
        // drag from carrying on with whatever moved into the slot.
        property string dragName: ""

        onPressed: function(mouse) {
          root.selected(block.disp.name)
          armed = false
          if (block.disp.disabled) return
          var p = mapToItem(root, mouse.x, mouse.y)
          pressCanvasX = p.x; pressCanvasY = p.y
          originLogX = block.disp.x; originLogY = block.disp.y
          dragName = block.disp.name
        }
        onPositionChanged: function(mouse) {
          if (block.disp.disabled || block.disp.name !== dragName) return
          var p = mapToItem(root, mouse.x, mouse.y)
          var dx = p.x - pressCanvasX
          var dy = p.y - pressCanvasY
          if (!armed) {
            if (Math.abs(dx) < root.dragStartThreshold && Math.abs(dy) < root.dragStartThreshold) return
            armed = true
            root.dragLogX = originLogX; root.dragLogY = originLogY
            root.dragTargets = Model.snapTargets(root.rects, block.disp.name)
            root.draggingName = block.disp.name
          }
          var snapped = Model.dragPosition({ name: block.disp.name, x: originLogX, y: originLogY,
                                             width: block.disp.width, height: block.disp.height },
                                           { x: dx / root.factor, y: dy / root.factor },
                                           root.dragTargets, root.snapThreshold / root.factor)
          root.guides = snapped.guides
          root.dragLogX = snapped.x
          root.dragLogY = snapped.y
        }
        onReleased: function(mouse) {
          if (!armed) return
          armed = false
          if (block.disp.name !== dragName) { root.draggingName = ""; root.guides = []; return }
          var lx = Math.round(root.dragLogX)
          var ly = Math.round(root.dragLogY)
          // A release over another display missed by a little; land it flush
          // against the nearest clear edge instead of leaving an overlap that
          // only greys out Apply. Keyboard nudges stay exact and may overlap.
          var placed = Model.placeOutsideOverlaps({ name: block.disp.name, x: lx, y: ly, width: block.disp.width, height: block.disp.height }, root.rects)
          if (placed) { lx = placed.x; ly = placed.y }
          // Commit before dropping the drag flag, so the block's position
          // binding already reads the new value and nothing animates backwards.
          if (lx !== block.disp.x || ly !== block.disp.y) root.moved(block.disp.name, lx, ly)
          root.draggingName = ""
          root.guides = []
        }
        onCanceled: { armed = false; dragName = ""; root.draggingName = ""; root.guides = [] }
      }
    }
  }

  Text {
    anchors.left: parent.left
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(12)
    textFormat: Text.PlainText
    text: {
      var s = Model.layoutCaption(root.liveRects) + " · logical px"
      if (root.overlap) s += " · " + root.overlap[0] + " overlaps " + root.overlap[1]
      else if (root.rects.length > 1) s += " · no overlap"
      return s
    }
    color: root.overlap ? root.urgent : Qt.darker(root.foreground, 1.4)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: root.overlap !== null
    elide: Text.ElideRight
    width: parent.width - Style.space(24)
  }
}
