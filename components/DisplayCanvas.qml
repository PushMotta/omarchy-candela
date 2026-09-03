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
  property int snapThreshold: 40

  signal selected(string name)
  signal moved(string name, int x, int y)

  readonly property var bounds: Model.boundsOf(root.rects)
  readonly property var overlap: Model.anyOverlap(root.rects)
  readonly property real padding: Style.space(28)
  // Fit the whole layout with padding; never zoom past 1:4 so a lone display
  // does not fill the canvas edge to edge.
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
  property real dragX: 0
  property real dragY: 0

  function toPixelX(lx) { return root.originX + lx * root.factor }
  function toPixelY(ly) { return root.originY + ly * root.factor }
  function toLogicalX(px) { return (px - root.originX) / root.factor }
  function toLogicalY(py) { return (py - root.originY) / root.factor }

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

  Repeater {
    model: root.guides
    Rectangle {
      required property var modelData
      color: root.accent
      opacity: 0.6
      x: modelData.axis === "x" ? Math.round(root.toPixelX(modelData.at)) : 0
      y: modelData.axis === "y" ? Math.round(root.toPixelY(modelData.at)) : 0
      width: modelData.axis === "x" ? 1 : root.width
      height: modelData.axis === "y" ? 1 : root.height
    }
  }

  Repeater {
    model: root.rects

    BorderSurface {
      id: block
      required property var modelData
      readonly property bool isSelected: modelData.name === root.selectedName
      readonly property bool isDragging: root.draggingName === modelData.name
      readonly property bool isOverlapping: root.overlap !== null && (root.overlap[0] === modelData.name || root.overlap[1] === modelData.name)

      x: isDragging ? root.dragX : Math.round(root.toPixelX(modelData.x))
      y: isDragging ? root.dragY : Math.round(root.toPixelY(modelData.y))
      width: Math.max(24, Math.round(modelData.width * root.factor))
      height: Math.max(16, Math.round(modelData.height * root.factor))
      z: isSelected ? 2 : 1
      radius: Style.cornerRadius
      opacity: modelData.disabled ? 0.45 : 1
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

      Column {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: Style.space(10)
        spacing: Style.space(2)

        Row {
          spacing: Style.space(6)
          Rectangle {
            visible: block.modelData.focused
            width: Style.space(6); height: width; radius: width / 2
            color: root.accent
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            textFormat: Text.PlainText
            text: block.modelData.name
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }
          BorderSurface {
            visible: block.modelData.hdr || block.modelData.disabled || (block.modelData.mirrorOf && block.modelData.mirrorOf !== "")
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
              text: block.modelData.disabled ? "OFF" : (block.modelData.mirrorOf ? "MIRROR" : "HDR")
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
        text: (block.modelData.model ? block.modelData.model + " · " : "") + block.modelData.mode + " · " + block.modelData.scale + "×\n" + block.modelData.width + "×" + block.modelData.height + " logical"
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
        cursorShape: block.modelData.disabled ? Qt.ArrowCursor : (block.isDragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor)
        property real pressX: 0
        property real pressY: 0
        property real startX: 0
        property real startY: 0

        onPressed: function(mouse) {
          root.selected(block.modelData.name)
          if (block.modelData.disabled) return
          pressX = mouse.x; pressY = mouse.y
          startX = block.x; startY = block.y
          root.dragX = block.x; root.dragY = block.y
          root.draggingName = block.modelData.name
        }
        onPositionChanged: function(mouse) {
          if (!block.isDragging) return
          var px = startX + (mouse.x - pressX)
          var py = startY + (mouse.y - pressY)
          var proposed = { name: block.modelData.name, x: Math.round(root.toLogicalX(px)), y: Math.round(root.toLogicalY(py)), width: block.modelData.width, height: block.modelData.height }
          var snapped = Model.snapRect(proposed, root.rects, root.snapThreshold / root.factor)
          root.guides = snapped.guides
          root.dragX = root.toPixelX(snapped.x)
          root.dragY = root.toPixelY(snapped.y)
        }
        onReleased: function(mouse) {
          if (!block.isDragging) return
          var lx = Math.round(root.toLogicalX(root.dragX))
          var ly = Math.round(root.toLogicalY(root.dragY))
          root.draggingName = ""
          root.guides = []
          if (lx !== block.modelData.x || ly !== block.modelData.y) root.moved(block.modelData.name, lx, ly)
        }
        onCanceled: { root.draggingName = ""; root.guides = [] }
      }
    }
  }

  Text {
    anchors.left: parent.left
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(12)
    textFormat: Text.PlainText
    text: {
      var s = Model.layoutCaption(root.rects) + " · logical px"
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
