import QtQuick
import QtQuick.Shapes
import Quickshell
import qs.Commons
import qs.Ui
import "../Model.js" as Model

// Arrangement canvas in logical pixels. Blocks are draggable with the mouse
// and nudgeable with the keyboard; edges snap to neighbours; overlap paints
// the offending blocks urgent. The canvas never writes anywhere: it emits
// `moved` and the studio decides what to do with it.
//
// With a workspace plan, each block also carries chips for the workspaces
// that live there. Dragging a chip onto another block emits `chipDropped`;
// what that means is the studio's business too.
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
  property real zoom: 1
  property real panX: 0
  property real panY: 0
  property bool snapBypass: false
  property bool reducedMotion: false
  // { displayName: [{ id, label, used, shown, away, ghost, where, home }] }
  property var chips: ({})
  // A second caption line, for what the plan is about to do.
  property string note: 
  function fit() { zoom = 1; panX = 0; panY = 0 }
  function zoomIn() { zoom = Math.min(4, zoom * 1.2) }
  function zoomOut() { zoom = Math.max(0.5, zoom / 1.2) }

  // The desktop's own wallpaper, dimmed, inside every block. A display
  // arranger whose blocks show what is actually on those displays stops being
  // a diagram and starts being a picture of the desk. Omarchy keeps the
  // current one on a symlink it rewrites on every theme change.
  readonly property string wallpaperPath: "file://" + Quickshell.env("HOME") + "/.local/state/omarchy/current/background"
  property url wallpaperSource: ""
  property real wallpaperOpacity: 0.28

  // The symlink's target changes but its path does not, so a bound source
  // would never reload. Clearing it first is what makes the next assignment a
  // change, and `cache: false` is what makes that assignment reach the disk.
  function loadWallpaper() {
    root.wallpaperSource = ""
    Qt.callLater(function() { root.wallpaperSource = root.wallpaperPath })
  }

  Component.onCompleted: root.loadWallpaper()

  Connections {
    target: Color
    function onBackgroundChanged() { root.loadWallpaper() }
  }

  signal selected(string name)
  signal moved(string name, int x, int y)
  signal chipDropped(int workspace, string name)
  // The × on a virtual display's block: the studio asks for a second press.
  signal removeRequested(string name)
  property string removeArmedFor: ""

  // A chip in flight: which workspace, the pointer in canvas coordinates,
  // and the block under it.
  property int chipDragId: 0
  property string chipDragLabel: ""
  property real chipDragX: 0
  property real chipDragY: 0
  readonly property string chipDropName: {
    if (root.chipDragId === 0) return ""
    for (var i = root.rects.length - 1; i >= 0; i--) {
      var r = root.rects[i]
      if (r.disabled || r.mirrorOf) continue
      var x = root.toPixelX(r.x), y = root.toPixelY(r.y)
      if (root.chipDragX >= x && root.chipDragX <= x + r.width * root.factor && root.chipDragY >= y && root.chipDragY <= y + r.height * root.factor) return r.name
    }
    return ""
  }

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
    return Math.max(0.01, Math.min(fx, fy, 0.25)) * root.zoom
  }
  // What height this canvas would need to hold the layout at the width it has,
  // so the frame can hug the arrangement instead of stranding it in the middle
  // of a tall empty box. Deliberately independent of `factor`, which reads
  // `height` back: routing it through the factor would bind height to height.
  readonly property real preferredHeight: {
    var b = root.bounds
    if (b.width <= 0 || b.height <= 0) return 0
    var inner = Math.max(1, root.width - root.padding * 2)
    return inner * (b.height / b.width) + root.padding * 2
  }

  readonly property real originX: root.padding + ((root.width - root.padding * 2) - root.bounds.width * root.factor) / 2 - root.bounds.x * root.factor + root.panX
  readonly property real originY: root.padding + ((root.height - root.padding * 2) - root.bounds.height * root.factor) / 2 - root.bounds.y * root.factor + root.panY

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
    if (!r || r.disabled || r.mirrorOf) return
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
      // Delegates are created and destroyed as guides come and go, so the
      // fade lives on creation rather than on a binding.
      opacity: 0
      Component.onCompleted: opacity = 0.6
      Behavior on opacity { enabled: !root.reducedMotion; NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
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
      readonly property bool isDropTarget: root.chipDropName !== "" && root.chipDropName === disp.name
      readonly property var blockChips: root.chips[disp.name] || []
      // Chips get the room between the name and the bottom edge, never the
      // name's: they shrink to fit (24 down to 16), and if they still do not,
      // the size caption gives them its room. Seen on the desk with four
      // displays, where DP-2's second row of chips covered its name.
      readonly property real chipTop: titleColumn.y + titleColumn.height + Style.space(6)
      function chipRows(size) {
        var per = Math.max(1, Math.floor((width - Style.space(20) + Style.space(4)) / (size + Style.space(4))))
        return Math.ceil(blockChips.length / per)
      }
      function chipFit(room) {
        for (var s = 24; s >= 16; s -= 2) {
          var size = Style.space(s)
          if (chipRows(size) * (size + Style.space(4)) - Style.space(4) <= room) return size
        }
        return 0
      }
      readonly property real roomWithInfo: height - chipTop - Style.space(18) - infoText.implicitHeight
      readonly property real roomWithoutInfo: height - chipTop - Style.space(10)
      readonly property bool infoShown: height > Style.space(56) && (blockChips.length === 0 || chipFit(roomWithInfo) > 0)
      readonly property real chipSize: blockChips.length === 0 ? 0 : chipFit(infoShown ? roomWithInfo : roomWithoutInfo)

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
        : disp.virtual === true ? Border.none()
        : (isSelected || isDropTarget
          ? Border.flat(root.accent, Math.max(1, Style.space(2)))
          : Border.controlSpec("normal", root.foreground, root.accent))

      Behavior on x { enabled: !block.isDragging && !root.reducedMotion; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      Behavior on y { enabled: !block.isDragging && !root.reducedMotion; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      Behavior on width { enabled: !block.isDragging && !root.reducedMotion; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      Behavior on height { enabled: !block.isDragging && !root.reducedMotion; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      Behavior on color { enabled: !root.reducedMotion; ColorAnimation { duration: 120 } }
      Behavior on opacity { enabled: !root.reducedMotion; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

      // A virtual display is drawn with a dashed edge: it is real to Hyprland
      // and to the layout, but there is no panel behind it.
      Shape {
        anchors.fill: parent
        visible: block.disp.virtual === true
        z: 1
        ShapePath {
          strokeColor: block.isSelected || block.isDropTarget ? root.accent : Util.alpha(root.foreground, 0.7)
          strokeWidth: block.isSelected ? Math.max(1, Style.space(2)) : 1
          strokeStyle: ShapePath.DashLine
          dashPattern: [4, 3]
          fillColor: "transparent"
          startX: 0.5; startY: 0.5
          PathLine { x: block.width - 0.5; y: 0.5 }
          PathLine { x: block.width - 0.5; y: block.height - 0.5 }
          PathLine { x: 0.5; y: block.height - 0.5 }
          PathLine { x: 0.5; y: 0.5 }
        }
      }

      // A virtual display can be removed from its block: bottom right, where
      // nothing else sits (the name and its badge fill the top).
      Rectangle {
        id: removeBox
        visible: block.disp.virtual === true && block.width > Style.space(80)
        z: 3
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        anchors.margins: Style.space(8)
        readonly property bool armed: root.removeArmedFor === block.disp.name
        width: armed ? removeLabel.implicitWidth + Style.space(12) : Style.space(20)
        height: Style.space(20)
        radius: Style.cornerRadius > 0 ? Style.space(4) : 0
        color: removeArea.containsMouse || armed ? Util.alpha(root.urgent, 0.25) : "transparent"
        border.width: 1
        border.color: armed ? root.urgent : Util.alpha(root.foreground, 0.4)
        Text {
          id: removeLabel
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: parent.armed ? "remove?" : "×"
          color: parent.armed ? root.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
        MouseArea {
          id: removeArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.removeRequested(block.disp.name)
        }
      }

      // The picture on that screen, inset so a themed corner radius never
      // clips it and the block still reads as a panel with a bezel rather
      // than as a thumbnail. A display that is off shows no picture.
      Item {
        anchors.fill: parent
        anchors.margins: Math.max(2, Math.round(Math.min(block.width, block.height) * 0.045))
        clip: true
        visible: !block.disp.disabled && wall.status === Image.Ready

        Image {
          id: wall
          anchors.fill: parent
          source: root.wallpaperSource
          cache: false
          asynchronous: true
          mipmap: true
          fillMode: Image.PreserveAspectCrop
          sourceSize.width: 640
          opacity: root.wallpaperOpacity
        }
      }

      Column {
        id: titleColumn
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
            id: nameText
            textFormat: Text.PlainText
            text: block.disp.name
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }
          BorderSurface {
            // Only where it fits beside the name: on a narrow block it would
            // run over the block's edge.
            visible: (block.disp.hdr || block.disp.disabled || block.disp.virtual === true || (block.disp.mirrorOf && block.disp.mirrorOf !== ""))
              && nameText.implicitWidth + Style.space(6) + implicitWidth + (block.disp.focused ? Style.space(12) : 0) <= block.width - Style.space(20)
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
              text: block.disp.disabled ? "OFF" : (block.disp.mirrorOf ? "MIRROR" : (block.disp.virtual === true ? "VIRTUAL" : "HDR"))
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }
        }
      }

      // Two lines that each elide: one text with a line break in it only
      // elides its last line, and a narrow block let the first run into its
      // neighbour.
      Column {
        id: infoText
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: Style.space(10)
        width: parent.width - Style.space(20) - (removeBox.visible ? removeBox.width + Style.space(6) : 0)
        visible: block.infoShown
        Repeater {
          model: [(block.disp.model ? block.disp.model + " · " : "") + block.disp.mode + " · " + block.disp.scale + "×",
                  block.disp.width + "×" + block.disp.height + " logical"]
          Text {
            required property var modelData
            width: infoText.width
            textFormat: Text.PlainText
            text: modelData
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
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
            root.dragTargets = root.snapBypass || (mouse.modifiers & Qt.AltModifier) ? [] : Model.snapTargets(root.rects, block.disp.name)
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

      // The workspaces that live on this display, drawn over the block's own
      // mouse area so that pressing a chip never starts moving the display.
      Flow {
        z: 2
        visible: block.chipSize > 0
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: infoText.visible ? infoText.top : parent.bottom
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        anchors.bottomMargin: infoText.visible ? Style.space(8) : Style.space(10)
        spacing: Style.space(4)

        Repeater {
          model: block.blockChips

          Item {
            id: chip
            required property var modelData
            readonly property bool dashed: modelData.away || modelData.ghost
            width: block.chipSize
            height: block.chipSize
            // Here now but living elsewhere: drawn faintly where it is.
            opacity: modelData.ghost ? 0.55 : 1

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius > 0 ? Style.space(4) : 0
              color: chip.modelData.used ? Util.alpha(root.foreground, 0.18) : "transparent"
              border.width: chip.dashed || chip.modelData.used ? 0 : 1
              border.color: Util.alpha(root.foreground, 0.4)
            }
            // Away from home: a dashed outline, dotted for the faint copy.
            Shape {
              anchors.fill: parent
              visible: chip.dashed
              ShapePath {
                strokeColor: Util.alpha(root.foreground, 0.75)
                strokeWidth: 1
                strokeStyle: ShapePath.DashLine
                dashPattern: chip.modelData.ghost ? [1, 2] : [3, 2]
                fillColor: "transparent"
                startX: 0.5; startY: 0.5
                PathLine { x: chip.width - 0.5; y: 0.5 }
                PathLine { x: chip.width - 0.5; y: chip.height - 0.5 }
                PathLine { x: 0.5; y: chip.height - 0.5 }
                PathLine { x: 0.5; y: 0.5 }
              }
            }
            Text {
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: chip.modelData.label
              color: chip.modelData.used || chip.modelData.away ? root.foreground : Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Math.min(Style.font.bodySmall, Math.round(block.chipSize * 0.55))
              font.bold: true
            }
            // On screen now.
            Rectangle {
              visible: chip.modelData.shown
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.top: parent.bottom
              anchors.topMargin: Style.space(2)
              width: parent.width - Style.space(6)
              height: Math.max(2, Style.space(2))
              radius: height / 2
              color: root.accent
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: root.chipDragId !== 0 ? Qt.ClosedHandCursor : Qt.OpenHandCursor
              property real pressX: 0
              property real pressY: 0
              property bool armed: false
              onPressed: function(mouse) {
                root.selected(block.disp.name)
                var p = mapToItem(root, mouse.x, mouse.y)
                pressX = p.x; pressY = p.y
                armed = false
              }
              onPositionChanged: function(mouse) {
                var p = mapToItem(root, mouse.x, mouse.y)
                if (!armed) {
                  if (Math.abs(p.x - pressX) < root.dragStartThreshold && Math.abs(p.y - pressY) < root.dragStartThreshold) return
                  armed = true
                  root.chipDragId = chip.modelData.id
                  root.chipDragLabel = chip.modelData.label
                }
                root.chipDragX = p.x
                root.chipDragY = p.y
              }
              onReleased: {
                var target = root.chipDropName
                var id = root.chipDragId
                armed = false
                root.chipDragId = 0
                if (id !== 0 && target !== "") root.chipDropped(id, target)
              }
              onCanceled: { armed = false; root.chipDragId = 0 }
            }
          }
        }
      }
    }
  }

  // The chip being dragged, under the pointer.
  Rectangle {
    z: 5
    visible: root.chipDragId !== 0
    width: Style.space(22)
    height: width
    x: root.chipDragX - width / 2
    y: root.chipDragY - height / 2
    radius: Style.cornerRadius > 0 ? Style.space(4) : 0
    color: Util.alpha(root.accent, 0.35)
    border.color: root.accent
    border.width: 1
    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: root.chipDragLabel
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  // Datum mark at logical 0, 0. Two displays at 0,0 and 2400,0 say nothing
  // about which way the coordinates run until you can see where zero is. It
  // draws over the blocks because a display usually sits on the origin, and a
  // mark hidden underneath one tells nobody anything.
  Item {
    z: 3
    x: Math.round(root.toPixelX(0))
    y: Math.round(root.toPixelY(0))
    visible: x > -12 && x < root.width + 12 && y > -12 && y < root.height + 12

    Rectangle { x: -5; y: 0; width: 11; height: 1; color: Util.alpha(root.foreground, 0.5) }
    Rectangle { x: 0; y: -5; width: 1; height: 11; color: Util.alpha(root.foreground, 0.5) }
  }

  // At the top: the layout fills the canvas down to the caption, and the
  // top edge has the same padding with nothing on it.
  Text {
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.margins: Style.space(12)
    visible: root.note !== ""
    textFormat: Text.PlainText
    text: root.note
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    elide: Text.ElideRight
    width: parent.width - Style.space(24)
  }

  Text {
    id: layoutCaptionText
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
