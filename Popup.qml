import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model
import "components"

// Bar widget + popup: the daily controls for one display at a time.
// Brightness, SDR white (in HDR), scale, colour mode, the display list, and
// two actions. Everything heavier lives in the studio (Arrange…).
//
// Cursor model follows the first-party panels: root owns cursorActive +
// focusSection + selectedIndex; every target binds hasCursor and reports
// hover so keyboard and pointer share one highlight.
Panel {
  id: root
  // Bar widgets (kind "bar-widget", loaded through Bar.qml's ModuleSlot) are
  // only ever handed `bar`, `moduleName`, and `settings` — never a
  // `manifest`, unlike the service/overlay kinds (Service.qml, Studio.qml)
  // which the shell loads through a different path that does inject one.
  // The bar overwrites `moduleName` with whatever id is configured in
  // shell.json the instant this widget is mounted, so in normal operation
  // this literal is only ever the value before that happens. Keep it in
  // sync with manifest.json's "id" by hand if the plugin is ever renamed.
  moduleName: "io.github.pushmotta.candela"
  manageIpc: false

  // The bar can be null for a beat while a bar instance is created or torn
  // down on a monitor change; every colour and font read goes through these.
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property string fam: bar ? bar.fontFamily : Style.font.family

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor(root.moduleName) : null
  readonly property var state: service ? service.state : null
  readonly property var displays: service ? service.displays : []
  readonly property string focusedName: service ? service.focused : ""
  readonly property bool hasPending: service ? service.hasPending : false

  // The display the popup drives. Defaults to the focused one on open.
  property string selectedName: ""
  readonly property var display: {
    for (var i = 0; i < displays.length; i++) if (displays[i].name === selectedName) return displays[i]
    return displays.length > 0 ? displays[0] : null
  }
  readonly property var caps: display && display.capabilities ? display.capabilities : ({})
  readonly property string colourMode: display ? Model.colourMode(display) : "sdr"
  // Pending wins over kept — the same view Model.offeredModes and
  // Model.hdrUnavailableReason need to honour the ICC/forced-off/no-HDR
  // invariants consistently with the rest of the app.
  readonly property var intent: Model.effectiveIntent(display)
  readonly property var offeredModes: Model.offeredModes(caps, intent)
  readonly property int enabledCount: {
    var n = 0
    for (var i = 0; i < displays.length; i++) if (displays[i].enabled) n++
    return n
  }

  // Brightness for the selected display. The state only carries the focused
  // display's value (DDC reads are slow), so the rest is read on demand.
  property int brightnessPercent: 0
  property bool brightnessAvailable: false
  property real wheelAccumulator: 0
  // Which display the running DDC read is for, and which display asked for
  // one while it was busy — so a read finishing never paints its result
  // under a display the popup has since moved on from.
  property string brightnessReadFor: ""
  property string brightnessReadNext: ""

  // SDR white: a live preview value while dragging, else the compositor's.
  readonly property var sdrRange: Model.sdrWhiteRange(caps)
  readonly property int sdrWhite: display && display.live ? Math.round(Number(display.live.sdrMaxLuminance) || Model.SDR_WHITE_FLOOR) : Model.SDR_WHITE_FLOOR
  property int sdrPreview: -1

  readonly property var scaleValues: display ? Model.availableScales(display.width, display.height) : []

  // ---------------------------------------------------------- cursor model
  property string focusSection: "brightness"
  property int selectedIndex: -1
  property bool cursorActive: false

  readonly property var visibleSections: {
    var list = []
    // Visual order: the pending strip sits under the hero, so it comes first.
    if (hasPending) list.push("pending")
    if (displays.length > 1) list.push("chips")
    if (brightnessAvailable) list.push("brightness")
    if (colourMode === "hdr") list.push("sdrwhite")
    if (display && display.enabled) list.push("scale")
    if (caps.available && display && display.enabled) list.push("colour")
    if (displays.length > 1) list.push("displays")
    list.push("actions")
    return list
  }

  function sectionCount(section) {
    if (section === "chips") return displays.length
    if (section === "scale") return scaleValues.length
    if (section === "colour") return offeredModes.length
    if (section === "displays") return displays.length
    if (section === "actions") return 2
    if (section === "pending") return 2
    return 0
  }

  function sectionIsHorizontal(section) {
    return section === "chips" || section === "scale" || section === "colour" || section === "pending" || section === "brightness" || section === "sdrwhite"
  }

  function sectionFirstIndex(section) {
    if (section === "brightness" || section === "sdrwhite") return -1
    if (section === "chips") return Math.max(0, indexOfDisplay(selectedName))
    if (section === "scale") return Math.max(0, activeScaleIndex())
    if (section === "colour") return Math.max(0, offeredModes.indexOf(colourMode))
    if (section === "pending") return 1
    return 0
  }

  function indexOfDisplay(name) {
    for (var i = 0; i < displays.length; i++) if (displays[i].name === name) return i
    return -1
  }

  function activeScaleIndex() {
    return display ? Model.scaleIndex(scaleValues, display.scale) : -1
  }

  function moveCursor(delta) {
    var sections = visibleSections
    if (!sections.length) return
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) { focusSection = sections[0]; selectedIndex = sectionFirstIndex(focusSection); return }
    var horizontal = sectionIsHorizontal(focusSection)
    var max = horizontal ? 0 : sectionCount(focusSection) - 1
    if (delta > 0) {
      if (!horizontal && selectedIndex < max) { selectedIndex++; return }
      if (sIdx < sections.length - 1) { focusSection = sections[sIdx + 1]; selectedIndex = sectionFirstIndex(focusSection) }
    } else {
      if (!horizontal && selectedIndex > 0) { selectedIndex--; return }
      if (sIdx > 0) {
        var prev = sections[sIdx - 1]
        focusSection = prev
        selectedIndex = sectionIsHorizontal(prev) ? sectionFirstIndex(prev) : sectionCount(prev) - 1
      }
    }
  }

  function moveCursorH(delta) {
    if (focusSection === "brightness") { adjustBrightness(delta * 5); return }
    if (focusSection === "sdrwhite") { adjustSdrWhite(delta * 10); return }
    if (!sectionIsHorizontal(focusSection)) return
    var count = sectionCount(focusSection)
    if (count === 0) return
    selectedIndex = Math.max(0, Math.min(count - 1, selectedIndex + delta))
  }

  function activateCursor() {
    if (!display) return
    switch (focusSection) {
      case "chips":
        if (displays[selectedIndex]) selectDisplay(displays[selectedIndex].name)
        break
      case "scale":
        if (scaleValues[selectedIndex]) setScale(scaleValues[selectedIndex].effective)
        break
      case "colour":
        if (offeredModes[selectedIndex]) setColourMode(offeredModes[selectedIndex])
        break
      case "displays":
        // Enter picks the display up; only Enter on the display already picked
        // reaches its power, and off still needs the confirming press.
        var target = displays[selectedIndex]
        if (!target) break
        if (target.name !== selectedName) selectDisplay(target.name)
        else powerAction(target)
        break
      case "actions":
        if (selectedIndex === 0) identify(); else openStudio()
        break
      case "pending":
        if (selectedIndex === 0) service.revert(); else service.keep()
        break
    }
  }

  function clampCursor() {
    var sections = visibleSections
    if (!sections.length) return
    if (sections.indexOf(focusSection) < 0) { focusSection = sections[0]; selectedIndex = sectionFirstIndex(focusSection); return }
    var count = sectionCount(focusSection)
    if (focusSection === "brightness" || focusSection === "sdrwhite") { selectedIndex = -1; return }
    if (count === 0) { focusSection = sections[0]; selectedIndex = sectionFirstIndex(focusSection); return }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  function hoverInto(section, index) {
    cursorActive = true
    focusSection = section
    selectedIndex = index
  }

  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y, bottom = top + (item.height || 0)
    var viewTop = flick.contentY, viewBottom = viewTop + flick.height
    if (top < viewTop + 6) flick.contentY = Math.max(0, top - 6)
    else if (bottom > viewBottom - 6) flick.contentY = bottom + 6 - flick.height
  }

  onVisibleSectionsChanged: clampCursor()
  onDisplaysChanged: {
    if (indexOfDisplay(selectedName) < 0 && displays.length > 0) selectedName = focusedName || displays[0].name
    if (armedOffName !== "" && indexOfDisplay(armedOffName) < 0) disarmOff()
    clampCursor()
  }
  // Covers both switching the selected display and the state arriving for
  // the first time (display goes from null to the initial selection), so
  // the bar icon's wheel works before the popup has ever been opened.
  onDisplayChanged: readBrightness()

  // ---------------------------------------------------------- actions
  function selectDisplay(name) {
    if (name === selectedName) return
    selectedName = name
    // readBrightness() runs via onDisplayChanged below, once `display`
    // re-resolves to the new selection.
  }

  function setScale(scale) {
    if (!display || !service) return
    service.applyDisplay(display.name, { scale: scale }, false)
  }

  function setColourMode(mode) {
    if (!display || !service || mode === colourMode) return
    service.setColourMode(display.name, mode)
  }

  // Switching a display off blanks a screen the user may be reading, so it is
  // the one action here that will not happen on a single click. The first
  // press arms the row and says so; a second press within the window carries
  // it out. Anything else — moving the cursor off the row, the window running
  // out, reopening the popup — puts the safety back on. Switching a display
  // on is harmless and stays immediate.
  property string armedOffName: ""
  property double armedAt: 0
  // A double click is one gesture, not two decisions: the confirming press is
  // only taken once the arming has had time to be read.
  readonly property int armSettleMs: 250

  function armOff(name) { armedOffName = name; armedAt = Date.now(); armWindow.restart() }
  function disarmOff() { armedOffName = ""; armWindow.stop() }

  function powerAction(d) {
    if (!d || !service) return
    if (!d.enabled) { disarmOff(); service.applyDisplay(d.name, { enabled: true }, false); return }
    if (enabledCount <= 1) return
    if (armedOffName === d.name) {
      if (Date.now() - armedAt < armSettleMs) { armWindow.restart(); return }
      disarmOff()
      service.applyDisplay(d.name, { enabled: false }, false)
      return
    }
    armOff(d.name)
  }

  // The arm is tied to the cursor: it only stands while the cursor is still on
  // the row that armed it.
  function disarmIfCursorMoved() {
    if (armedOffName === "") return
    if (focusSection !== "displays") { disarmOff(); return }
    var d = displays[selectedIndex]
    if (!d || d.name !== armedOffName) disarmOff()
  }

  onFocusSectionChanged: disarmIfCursorMoved()
  onSelectedIndexChanged: disarmIfCursorMoved()

  function identify() { if (service) service.identify() }

  function openStudio() {
    if (bar && bar.shell) bar.shell.summon(root.moduleName, "{}")
    root.close()
  }

  function readBrightness() {
    if (!service || !display) { brightnessAvailable = false; return }
    if (display.brightness !== null && display.brightness !== undefined) {
      brightnessAvailable = true
      brightnessPercent = Number(display.brightness)
      return
    }
    if (brightnessProc.running) {
      // A read is already in flight for another display; remember this one
      // and pick it up when that read finishes rather than dropping it or
      // starting a second process against the same collector.
      brightnessReadNext = display.name
      return
    }
    brightnessReadNext = ""
    brightnessReadFor = display.name
    brightnessProc.command = [service.cli, "brightness", display.name]
    brightnessProc.running = true
  }

  function setBrightness(value) {
    var pct = Math.max(1, Math.min(100, Math.round(value)))
    brightnessPercent = pct
    if (service && display) service.setBrightness(display.name, pct)
  }

  function adjustBrightness(delta) {
    if (!brightnessAvailable) return
    setBrightness(brightnessPercent + delta)
  }

  function showBrightnessOsd(percent) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({ icon: "brightness", value: percent }))
  }

  function commitSdrWhite(nits) {
    if (!service || !display) return
    var clamped = Math.round(Math.max(sdrRange.min, Math.min(sdrRange.max, nits)))
    sdrPreview = clamped
    service.setSdrWhite(display.name, clamped)
    sdrSettle.restart()
  }

  function adjustSdrWhite(delta) {
    commitSdrWhite((sdrPreview >= 0 ? sdrPreview : sdrWhite) + delta)
  }

  Timer {
    id: armWindow
    interval: 4000
    repeat: false
    onTriggered: root.armedOffName = ""
  }

  Timer {
    id: sdrSettle
    interval: 1500
    repeat: false
    onTriggered: root.sdrPreview = -1
  }

  Process {
    id: brightnessProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var v = String(text || "").trim()
        // Apply only if the popup is still looking at the display this read
        // was started for: switching DP-1 → DP-2 while DP-1's read is in
        // flight must not paint DP-1's value under DP-2's label.
        if (root.display && root.display.name === root.brightnessReadFor) {
          root.brightnessAvailable = /^[0-9]+$/.test(v)
          if (root.brightnessAvailable) root.brightnessPercent = Math.max(0, Math.min(100, parseInt(v, 10)))
        }
        root.brightnessReadFor = ""
      }
    }
    // The queued read starts here, not in onStreamFinished: that signal can
    // fire while `running` is still true, and readBrightness() would only
    // queue itself again.
    onRunningChanged: {
      if (running || root.brightnessReadNext === "") return
      var next = root.brightnessReadNext
      root.brightnessReadNext = ""
      if (root.display && root.display.name === next) root.readBrightness()
    }
  }

  Timer {
    id: brightnessDebounce
    interval: 180
    repeat: false
    onTriggered: root.setBrightness(root.brightnessPercent)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Which screen this bar instance sits on, so the service can pick the
  // popup on the focused display when a keybinding toggles it.
  readonly property string screenName: {
    var w = button.QsWindow.window
    return w && w.screen ? String(w.screen.name) : ""
  }

  onServiceChanged: if (service) service.registerPopup(root)
  Component.onCompleted: if (service) service.registerPopup(root)
  Component.onDestruction: if (service) service.unregisterPopup(root)

  onOpenedChanged: {
    // The service keeps a Keep/Revert strip off any screen whose popup is
    // open, and takes the keyboard for it only while none is.
    if (service) service.surfacesChanged()
    if (opened) {
      if (service) service.refresh()
      // Follow the live focus on every open: the popup drives the display the
      // user is looking at, and the bar instance it opened from sits there.
      var live = service ? service.liveFocused : focusedName
      if (indexOfDisplay(live) >= 0) selectedName = live
      else if (!selectedName || indexOfDisplay(selectedName) < 0) selectedName = focusedName || (displays.length ? displays[0].name : "")
      readBrightness()
      focusSection = visibleSections.length ? visibleSections[0] : "actions"
      selectedIndex = sectionFirstIndex(focusSection)
      cursorActive = false
    }
    disarmOff()
  }

  Connections {
    target: root.service
    // Not gated on `opened`: a fresh shell must have brightness ready for
    // the bar icon's wheel before the popup is opened for the first time.
    function onStateChangedExternally() { root.readBrightness() }
  }

  // ---------------------------------------------------------- bar button
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.displays.length > 1 ? "󰍺" : "󰍹"
    onPressed: function(b) { root.toggle() }
    onWheelMoved: function(delta) {
      if (!root.brightnessAvailable) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.setBrightness(root.brightnessPercent + wheel.steps * 5)
      root.showBrightnessOsd(root.brightnessPercent)
    }
  }

  // ---------------------------------------------------------- popup
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // No cap of our own: the popup grows with its content (SDR white appears in
    // HDR, the pending strip while a change waits) and the helper bounds it by
    // what the screen has, like the built-in network and bluetooth popups.
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight)

    // Entering HDR grows the popup by a whole section, and leaving shrinks it;
    // easing that at the shell's card timing turns a jump into a movement. The
    // popup is a Wayland surface, so this resizes it every frame it runs: if a
    // compositor ever renders that steppy, dropping this Behavior is the fix.
    Behavior on contentHeight { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveCursorH(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding { target: scrollArea.contentItem; property: "interactive"; value: panelColumn.implicitHeight > scrollArea.height }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.spacing.panelGap

          // ---------- Hero ----------
          PanelHero {
            title: root.display ? Model.displayTitle(root.display) : "Candela"
            meta: root.display ? Model.metaLine(root.display) : (root.service ? (root.service.loading ? "READING DISPLAYS" : "NO DISPLAYS") : "SERVICE NOT LOADED")
            foreground: root.fg
            fontFamily: root.fam
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.displays.length > 1 ? "󰍺" : "󰍹"
                color: root.fg
                font.family: root.fam
                font.pixelSize: Style.font.display
              }
            }
          }

          // ---------- Pending apply (under the hero so it is never clipped) ----------
          PanelSeparator { visible: root.hasPending; foreground: root.fg }

          ApplyBar {
            visible: root.hasPending
            width: parent.width
            remaining: root.service ? root.service.pendingRemaining : 0
            total: root.service ? root.service.revertSeconds : 15
            foreground: root.fg
            fontFamily: root.fam
            cursorIndex: root.cursorActive && root.focusSection === "pending" ? root.selectedIndex : -1
            onKeep: root.service.keep()
            onRevert: root.service.revert()
            onHovered: function(index, h) { if (h) root.hoverInto("pending", index) }
          }

          // ---------- Display chips ----------
          Row {
            visible: root.displays.length > 1
            spacing: Style.spacing.md
            Repeater {
              model: root.displays
              Button {
                required property var modelData
                required property int index
                text: modelData.name
                fontSize: Style.font.caption
                bordered: true
                foreground: root.fg
                fontFamily: root.fam
                horizontalPadding: Style.spacing.lg
                verticalPadding: Style.spacing.sm
                active: modelData.name === root.selectedName
                hasCursor: root.cursorActive && root.focusSection === "chips" && root.selectedIndex === index
                onClicked: root.selectDisplay(modelData.name)
                onHovered: function(h) { if (h) root.hoverInto("chips", index) }
              }
            }
          }

          // ---------- Brightness ----------
          PanelSeparator { visible: root.brightnessAvailable; foreground: root.fg }

          Column {
            visible: root.brightnessAvailable
            width: parent.width
            spacing: Style.spacing.md

            Item {
              width: parent.width
              implicitHeight: Math.max(brightnessHeader.implicitHeight, brightnessValue.implicitHeight)
              PanelSectionHeader { id: brightnessHeader; text: "BRIGHTNESS"; foreground: root.fg; fontFamily: root.fam; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter }
              Text {
                id: brightnessValue
                textFormat: Text.PlainText
                text: Math.round(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent) + "%"
                color: Qt.darker(root.fg, 1.4)
                font.family: root.fam; font.pixelSize: Style.font.caption; font.bold: true
                anchors.right: parent.right; anchors.rightMargin: Style.space(6); anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: brightnessRow
              width: parent.width
              height: brightnessSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "brightness"
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(brightnessRow)
              foreground: root.fg
              outline: true
              PanelSlider {
                id: brightnessSlider
                bar: root.bar
                anchors.fill: parent; anchors.leftMargin: Style.space(6); anchors.rightMargin: Style.space(6)
                minimum: 1; maximum: 100; step: 1; integer: true
                value: root.brightnessPercent
                onMoved: function(v) { root.brightnessPercent = Math.round(v); brightnessDebounce.restart() }
                onReleased: function(v) { brightnessDebounce.stop(); root.setBrightness(v) }
              }
              HoverHandler { onHoveredChanged: if (hovered) root.hoverInto("brightness", -1) }
            }
          }

          // ---------- SDR white (HDR only) ----------
          PanelSeparator { visible: root.colourMode === "hdr"; foreground: root.fg }

          Column {
            visible: root.colourMode === "hdr"
            width: parent.width
            spacing: Style.spacing.md

            Item {
              width: parent.width
              implicitHeight: Math.max(sdrHeader.implicitHeight, sdrValue.implicitHeight)
              PanelSectionHeader { id: sdrHeader; text: "SDR WHITE"; foreground: root.fg; fontFamily: root.fam; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter }
              Text {
                id: sdrValue
                textFormat: Text.PlainText
                text: (sdrSlider.dragging ? Model.sliderToSdrWhite(sdrSlider.liveValue / 100, root.sdrRange) : (root.sdrPreview >= 0 ? root.sdrPreview : root.sdrWhite)) + " cd/m²"
                color: Qt.darker(root.fg, 1.4)
                font.family: root.fam; font.pixelSize: Style.font.caption; font.bold: true
                anchors.right: parent.right; anchors.rightMargin: Style.space(6); anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: sdrRow
              width: parent.width
              height: sdrSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "sdrwhite"
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sdrRow)
              foreground: root.fg
              outline: true

              PanelSlider {
                id: sdrSlider
                bar: root.bar
                anchors.fill: parent; anchors.leftMargin: Style.space(6); anchors.rightMargin: Style.space(6)
                minimum: 0; maximum: 100; step: 1; integer: true
                value: Math.round(Model.sdrWhiteToSlider(root.sdrPreview >= 0 ? root.sdrPreview : root.sdrWhite, root.sdrRange) * 100)
                onReleased: function(v) { root.commitSdrWhite(Model.sliderToSdrWhite(v / 100, root.sdrRange)) }
              }

              // Reference white mark at 203 cd/m² (BT.2408), in the accent.
              Rectangle {
                width: Math.max(1, Style.space(2))
                height: Style.space(12)
                radius: 1
                color: Color.accent
                anchors.verticalCenter: parent.verticalCenter
                x: Style.space(6) + Model.sdrWhiteToSlider(Model.REFERENCE_WHITE, root.sdrRange) * (parent.width - Style.space(12)) - width / 2
                visible: root.sdrRange.max > Model.REFERENCE_WHITE
              }

              HoverHandler { onHoveredChanged: if (hovered) root.hoverInto("sdrwhite", -1) }
            }

            Text {
              textFormat: Text.PlainText
              text: root.sdrRange.min + " → " + root.sdrRange.max + " cd/m². Marked: " + Model.REFERENCE_WHITE + ", the BT.2408 reference white."
              color: Qt.darker(root.fg, 1.5)
              font.family: root.fam; font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              width: parent.width - Style.space(12)
              x: Style.space(6)
            }
          }

          // ---------- Scale ----------
          PanelSeparator { visible: root.display && root.display.enabled; foreground: root.fg }

          Column {
            visible: root.display && root.display.enabled
            width: parent.width
            spacing: Style.spacing.lg

            Item {
              width: parent.width
              implicitHeight: Math.max(scaleHeader.implicitHeight, scaleTarget.implicitHeight)
              PanelSectionHeader { id: scaleHeader; text: "SCALE"; foreground: root.fg; fontFamily: root.fam; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter }
              Text {
                id: scaleTarget
                textFormat: Text.PlainText
                text: root.display ? root.display.name : ""
                visible: root.displays.length > 1
                color: Qt.darker(root.fg, 1.4)
                font.family: root.fam; font.pixelSize: Style.font.caption; font.bold: true
                anchors.right: parent.right; anchors.rightMargin: Style.space(6); anchors.verticalCenter: parent.verticalCenter
              }
            }

            Grid {
              id: scaleGrid
              width: parent.width
              columns: Math.max(1, root.scaleValues.length)
              spacing: Style.spacing.xs
              readonly property real cellWidth: root.scaleValues.length > 0 ? (width - spacing * (columns - 1)) / columns : 0
              Repeater {
                model: root.scaleValues
                Button {
                  required property var modelData
                  required property int index
                  width: scaleGrid.cellWidth
                  text: Model.formatScale(modelData.effective) + "x"
                  fontSize: Style.font.caption
                  foreground: root.fg
                  fontFamily: root.fam
                  horizontalPadding: Style.spacing.sm
                  verticalPadding: Style.spacing.controlPaddingY
                  bordered: true
                  active: root.activeScaleIndex() === index
                  hasCursor: root.cursorActive && root.focusSection === "scale" && root.selectedIndex === index
                  onClicked: root.setScale(modelData.effective)
                  onHovered: function(h) { if (h) root.hoverInto("scale", index) }
                }
              }
            }
          }

          // ---------- Colour ----------
          PanelSeparator { visible: root.caps.available === true && root.display && root.display.enabled; foreground: root.fg }

          Column {
            visible: root.caps.available === true && root.display && root.display.enabled
            width: parent.width
            spacing: Style.spacing.lg

            Item {
              width: parent.width
              implicitHeight: Math.max(colourHeader.implicitHeight, colourCaps.implicitHeight)
              PanelSectionHeader { id: colourHeader; text: "COLOUR"; foreground: root.fg; fontFamily: root.fam; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter }
              Text {
                id: colourCaps
                textFormat: Text.PlainText
                text: "EDID: " + Model.capabilityLine(root.caps)
                color: Qt.darker(root.fg, 1.4)
                font.family: root.fam; font.pixelSize: Style.font.caption; font.bold: true
                elide: Text.ElideLeft
                width: Math.min(implicitWidth, parent.width - colourHeader.implicitWidth - Style.space(16))
                anchors.right: parent.right; anchors.rightMargin: Style.space(6); anchors.verticalCenter: parent.verticalCenter
              }
            }

            Grid {
              id: colourGrid
              width: parent.width
              columns: Math.max(1, root.offeredModes.length)
              spacing: Style.spacing.md
              readonly property real cellWidth: root.offeredModes.length > 0 ? (width - spacing * (columns - 1)) / columns : 0
              Repeater {
                model: root.offeredModes
                Button {
                  required property var modelData
                  required property int index
                  width: colourGrid.cellWidth
                  text: modelData === "sdr" ? "SDR" : (modelData === "wide" ? "Wide" : "HDR")
                  fontSize: Style.font.body
                  foreground: root.fg
                  fontFamily: root.fam
                  bordered: true
                  active: root.colourMode === modelData
                  hasCursor: root.cursorActive && root.focusSection === "colour" && root.selectedIndex === index
                  onClicked: root.setColourMode(modelData)
                  onHovered: function(h) { if (h) root.hoverInto("colour", index) }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              text: {
                if (!root.display) return ""
                var caption = "Output " + Model.outputCaption(root.display)
                // Only surface the reason when HDR is blocked rather than
                // genuinely unsupported — every SDR-only panel would
                // otherwise carry this line for no reason.
                if (root.caps.supportsHdr && root.offeredModes.indexOf("hdr") === -1) {
                  var reason = Model.hdrUnavailableReason(root.caps, root.intent)
                  if (reason) caption += " · HDR unavailable: " + reason
                }
                return caption
              }
              color: Qt.darker(root.fg, 1.5)
              font.family: root.fam; font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              width: parent.width
            }
          }

          // ---------- Displays ----------
          PanelSeparator { visible: root.displays.length > 1; foreground: root.fg }

          Column {
            visible: root.displays.length > 1
            width: parent.width
            spacing: Style.spacing.lg

            PanelSectionHeader { text: "DISPLAYS"; foreground: root.fg; fontFamily: root.fam }

            Repeater {
              model: root.displays
              DisplayRow {
                required property var modelData
                required property int index
                width: panelColumn.width
                display: modelData
                rowIndex: index
              }
            }
          }

          // ---------- Actions ----------
          PanelSeparator { foreground: root.fg }

          Column {
            width: parent.width
            spacing: Style.spacing.xxs

            ActionRow { width: panelColumn.width; rowIndex: 0; icon: "󰋼"; label: "Identify displays"; onActivated: root.identify() }
            ActionRow { width: panelColumn.width; rowIndex: 1; icon: "󰕮"; label: "Arrange…"; onActivated: root.openStudio() }
          }

          Text {
            visible: root.service && root.service.lastError !== ""
            textFormat: Text.PlainText
            text: root.service ? root.service.lastError : ""
            color: root.urgentColor
            font.family: root.fam; font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            width: parent.width
          }

          Item { width: parent.width; height: Style.space(2) }
        }
      }
    }
  }

  // ---------------------------------------------------------- row components
  component DisplayRow: CursorSurface {
    id: row
    required property var display
    required property int rowIndex
    readonly property bool canToggle: display && (!display.enabled || root.enabledCount > 1)
    readonly property bool armed: display && root.armedOffName === display.name

    hasCursor: root.cursorActive && root.focusSection === "displays" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(row)
    current: display && display.name === root.selectedName
    foreground: root.fg
    implicitHeight: inner.implicitHeight + Style.spacing.xl

    Row {
      id: inner
      anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6); anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        text: "󰍹"
        color: root.fg
        font.family: root.fam; font.pixelSize: Style.font.title
        width: Style.space(22); horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Row {
        spacing: Style.space(6)
        width: parent.width - Style.space(22) - Style.space(16) - Style.space(16)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          textFormat: Text.PlainText
          text: Model.displayTitle(row.display)
          color: root.fg
          font.family: root.fam; font.pixelSize: Style.font.body
          elide: Text.ElideRight
          anchors.verticalCenter: parent.verticalCenter
        }
        Tag { visible: row.display.focused; text: "focused" }
        Tag { visible: Model.colourMode(row.display) === "hdr"; text: "HDR" }
        Tag { visible: row.display.mirrorOf && row.display.mirrorOf !== "none"; text: "mirror" }
        Tag { visible: !row.display.enabled; text: "off" }
        Tag { visible: row.armed; urgent: true; text: "turn off?" }
      }

      Text {
        textFormat: Text.PlainText
        text: "󰐥"
        color: row.armed ? root.urgentColor : root.fg
        opacity: row.armed ? 1.0 : (row.display.enabled ? (row.canToggle ? 0.85 : 0.3) : 0.4)
        font.family: root.fam; font.pixelSize: Style.font.subtitle
        width: Style.space(16); horizontalAlignment: Text.AlignRight
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.hoverInto("displays", row.rowIndex)
      onClicked: root.selectDisplay(row.display.name)
    }

    // Declared after the row's own area, so the power target sits on top of it.
    MouseArea {
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: Style.space(30)
      hoverEnabled: true
      enabled: row.canToggle
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.hoverInto("displays", row.rowIndex)
      onClicked: root.powerAction(row.display)
    }
  }

  component Tag: BorderSurface {
    id: tag
    property string text: ""
    property bool urgent: false
    implicitWidth: tagText.implicitWidth + Style.space(8)
    implicitHeight: tagText.implicitHeight + Style.space(2)
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    color: "transparent"
    radius: Style.cornerRadius
    borderSpec: tag.urgent
      ? Border.flat(root.urgentColor, Math.max(1, Style.space(1)))
      : Border.controlSpec("normal", root.fg, Color.accent)
    Text {
      id: tagText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: tag.text
      color: tag.urgent ? root.urgentColor : Qt.darker(root.fg, 1.4)
      font.family: root.fam; font.pixelSize: Style.font.caption; font.bold: true
    }
  }

  component ActionRow: CursorSurface {
    id: action
    property int rowIndex: 0
    property string icon: ""
    property string label: ""
    signal activated()

    hasCursor: root.cursorActive && root.focusSection === "actions" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(action)
    foreground: root.fg
    implicitHeight: actionInner.implicitHeight + Style.spacing.xl

    Row {
      id: actionInner
      anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6); anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)
      Text { text: action.icon; color: root.fg; font.family: root.fam; font.pixelSize: Style.font.title; width: Style.space(22); horizontalAlignment: Text.AlignHCenter; anchors.verticalCenter: parent.verticalCenter }
      Text { textFormat: Text.PlainText; text: action.label; color: root.fg; font.family: root.fam; font.pixelSize: Style.font.body; width: parent.width - Style.space(22) - Style.space(16) - Style.space(16); elide: Text.ElideRight; anchors.verticalCenter: parent.verticalCenter }
      Text { text: "›"; color: Qt.darker(root.fg, 1.4); font.family: root.fam; font.pixelSize: Style.font.subtitle; width: Style.space(16); horizontalAlignment: Text.AlignRight; anchors.verticalCenter: parent.verticalCenter }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.hoverInto("actions", action.rowIndex)
      onClicked: action.activated()
    }
  }
}
