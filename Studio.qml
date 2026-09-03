import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "components"

// The Displays studio: arrangement canvas, per-display inspector, and an
// action bar with the keys printed. Every change is staged in `draft`; Apply
// sends the whole draft as one timed change, and the countdown bar offers
// Keep / Revert until the backend's timer fires.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "pmotta.displays"
  property bool opened: false
  property var targetScreen: null

  readonly property var displays: service ? service.displays : []
  readonly property bool hasPending: service ? service.hasPending : false

  // ---------------------------------------------------------- theme
  readonly property color background: Color.popups.background
  readonly property color foreground: Color.popups.text
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color scrim: Color.menu.scrim
  readonly property string fontFamily: Style.font.family
  readonly property var borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

  // PanelSlider wants a bar-shaped object for its colours.
  readonly property var fakeBar: QtObject {
    readonly property color foreground: root.foreground
    readonly property color background: root.background
    readonly property color urgent: root.urgent
    readonly property string fontFamily: root.fontFamily
    readonly property string position: "top"
    readonly property bool vertical: false
    readonly property int barSize: Style.bar.sizeHorizontal
  }

  // ---------------------------------------------------------- lifecycle
  function open(payloadJson) {
    var wanted = service ? service.focused : ""
    var chosen = null
    for (var i = 0; i < Quickshell.screens.length; i++) if (Quickshell.screens[i].name === wanted) chosen = Quickshell.screens[i]
    targetScreen = chosen || (Quickshell.screens.length ? Quickshell.screens[0] : null)
    draft = ({})
    draftGlobal = ({})
    advancedOpen = false
    focusArea = "inspector"
    currentRow = "mode"
    if (service) service.refresh()
    if (!selectedName || !displayByName(selectedName)) selectedName = wanted || (displays.length ? displays[0].name : "")
    opened = true
    iccProc.running = true
    Qt.callLater(function() { keyScope.forceActiveFocus() })
  }

  function close() { opened = false }
  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  // ---------------------------------------------------------- selection + draft
  property string selectedName: ""
  readonly property var display: displayByName(selectedName) || (displays.length ? displays[0] : null)
  readonly property var caps: display && display.capabilities ? display.capabilities : ({})

  function displayByName(name) {
    for (var i = 0; i < displays.length; i++) if (displays[i].name === name) return displays[i]
    return null
  }

  property var draft: ({})
  property var draftGlobal: ({})
  readonly property bool draftDirty: Object.keys(draft).length > 0 || Object.keys(draftGlobal).length > 0

  function setField(name, key, value) {
    var next = {}
    for (var n in draft) { next[n] = {}; for (var k in draft[n]) next[n][k] = draft[n][k] }
    if (!next[name]) next[name] = {}
    next[name][key] = value
    draft = next
  }

  function setGlobal(key, value) {
    var next = {}
    for (var k in draftGlobal) next[k] = draftGlobal[k]
    next[key] = value
    draftGlobal = next
  }

  // Draft → pending → kept → live, in that order.
  function field(d, key, fallback) {
    if (!d) return fallback
    var dr = draft[d.name]
    if (dr && dr[key] !== undefined) return dr[key]
    var intent = Model.effectiveIntent(d)
    if (intent[key] !== undefined && intent[key] !== null) return intent[key]
    return fallback
  }

  function positionOf(d) {
    var p = field(d, "position", null)
    if (typeof p === "string") { var m = p.match(/^(-?\d+)x(-?\d+)$/); if (m) return { x: Number(m[1]), y: Number(m[2]) } }
    return { x: Number(d.x) || 0, y: Number(d.y) || 0 }
  }

  function scaleOf(d) { return Number(field(d, "scale", d.scale)) || 1 }
  function transformOf(d) { return Number(field(d, "transform", d.transform)) || 0 }
  function enabledOf(d) { return field(d, "enabled", d.enabled) !== false }
  function mirrorOf(d) { var m = field(d, "mirror", d.mirrorOf === "none" ? "" : d.mirrorOf); return m || "" }
  function vrrOf(d) { return Number(field(d, "vrr", d.vrr ? 1 : 0)) }
  function modeOf(d) { return String(field(d, "mode", Model.currentModeValue(d))) }
  function colourOf(d) {
    var dr = draft[d.name] || {}
    if (dr.cm !== undefined) return (dr.cm === "hdr" || dr.cm === "hdredid") ? "hdr" : (dr.bitdepth === 10 ? "wide" : "sdr")
    return Model.colourMode(d)
  }
  function sdrWhiteOf(d) { return Number(field(d, "sdr_max_luminance", d.live ? d.live.sdrMaxLuminance : Model.SDR_WHITE_FLOOR)) || Model.SDR_WHITE_FLOOR }
  function eotfOf(d) { return String(field(d, "sdr_eotf", "default")) }
  function iccOf(d) { return String(field(d, "icc", "")) }
  function presetOf(d) { return String(field(d, "cm", d.live ? d.live.cm : "srgb")) }
  function saturationOf(d) { return Number(field(d, "sdrsaturation", d.live ? d.live.sdrSaturation : 1)) || 1 }
  function capOf(d, key) { return Number(field(d, key, 0)) }
  function lumOf(d, key) { var v = field(d, key, null); return v === null || v === undefined ? NaN : Number(v) }
  function autoHdrOf() {
    if (draftGlobal.cm_auto_hdr !== undefined) return Number(draftGlobal.cm_auto_hdr)
    var g = service && service.state ? service.state.global : null
    if (g && g.kept && g.kept.cm_auto_hdr !== undefined) return Number(g.kept.cm_auto_hdr)
    return g && g.cm_auto_hdr !== null && g.cm_auto_hdr !== undefined ? Number(g.cm_auto_hdr) : 1
  }

  function setColour(d, mode) {
    var f = Model.fieldsForMode(mode, d.capabilities, Model.effectiveIntent(d))
    for (var k in f) setField(d.name, k, f[k])
  }

  readonly property var rects: {
    var out = []
    for (var i = 0; i < displays.length; i++) {
      var d = displays[i]
      var pos = positionOf(d)
      var size = Model.logicalSize(d, scaleOf(d), transformOf(d))
      var mode = Model.parseMode(modeOf(d))
      if (mode && mode.width > 0) size = Model.logicalSize({ width: mode.width, height: mode.height }, scaleOf(d), transformOf(d))
      out.push({ name: d.name, x: pos.x, y: pos.y, width: size.width, height: size.height,
                 model: String(d.model || "").trim(), mode: modeOf(d).replace("@", " @ ") + " Hz", scale: Model.round2(scaleOf(d)),
                 hdr: colourOf(d) === "hdr", disabled: !enabledOf(d), mirrorOf: mirrorOf(d), focused: d.focused === true })
    }
    return out
  }
  readonly property var overlap: Model.anyOverlap(rects.filter(function(r) { return !r.disabled && !r.mirrorOf }))
  readonly property int hdrCount: rects.filter(function(r) { return r.hdr }).length

  // ---------------------------------------------------------- apply
  function applyDraft() {
    if (!service || !draftDirty || overlap) return
    var change = { displays: [] }
    for (var name in draft) {
      var entry = { name: name }
      for (var k in draft[name]) entry[k] = draft[name][k]
      change.displays.push(entry)
    }
    if (Object.keys(draftGlobal).length) change.global = draftGlobal
    service.apply(change, false)
    draft = ({})
    draftGlobal = ({})
  }

  function revertOrDiscard() {
    if (hasPending && service) { service.revert(); return }
    draft = ({})
    draftGlobal = ({})
  }

  function moveDisplay(name, x, y) {
    setField(name, "position", x + "x" + y)
  }

  // ---------------------------------------------------------- keyboard
  property string focusArea: "inspector"   // "canvas" | "inspector" | "actions"
  property string currentRow: "mode"
  property bool advancedOpen: false
  property int actionIndex: 2

  readonly property var rows: {
    var list = ["mode", "vrr", "scale", "rotation", "posx", "posy", "mirror", "enabled"]
    if (caps.available) {
      list.push("colour")
      if (display && colourOf(display) === "hdr") list.push("sdrwhite")
      list.push("transfer", "icc", "advanced")
      if (advancedOpen) {
        list.push("preset", "saturation", "minlum", "maxlum", "avglum", "caphdr", "capwide", "autohdr")
      }
    }
    return list
  }

  function rowMove(delta) {
    var idx = rows.indexOf(currentRow)
    if (idx < 0) { currentRow = rows[0]; return }
    var next = Math.max(0, Math.min(rows.length - 1, idx + delta))
    currentRow = rows[next]
  }

  function cycle(options, current, delta) {
    var idx = options.indexOf(current)
    if (idx < 0) idx = 0
    var next = (idx + delta + options.length) % options.length
    return options[next]
  }

  function rowAdjust(delta, big) {
    var d = display
    if (!d) return
    var step = big ? 100 : 10
    switch (currentRow) {
      case "mode": {
        var opts = Model.modeOptions(d).map(function(o) { return o.value })
        if (opts.length) setField(d.name, "mode", cycle(opts, modeOf(d), delta)); break
      }
      case "vrr": setField(d.name, "vrr", cycle([0, 1, 2], vrrOf(d), delta)); break
      case "scale": {
        var scales = Model.availableScales(d.width, d.height)
        var i = Model.scaleIndex(scales, scaleOf(d)); if (i < 0) i = 0
        var n = Math.max(0, Math.min(scales.length - 1, i + delta))
        setField(d.name, "scale", Number(scales[n].label)); break
      }
      case "rotation": setField(d.name, "transform", cycle([0, 1, 2, 3], transformOf(d), delta)); break
      case "posx": { var p = positionOf(d); moveDisplay(d.name, p.x + delta * step, p.y); break }
      case "posy": { var q = positionOf(d); moveDisplay(d.name, q.x, q.y + delta * step); break }
      case "mirror": {
        var m = [""].concat(displays.filter(function(o) { return o.name !== d.name }).map(function(o) { return o.name }))
        setField(d.name, "mirror", cycle(m, mirrorOf(d), delta)); break
      }
      case "enabled": setField(d.name, "enabled", !enabledOf(d)); break
      case "colour": setColour(d, cycle(Model.offeredModes(d.capabilities), colourOf(d), delta)); break
      case "sdrwhite": {
        var r = Model.sdrWhiteRange(d.capabilities)
        setField(d.name, "sdr_max_luminance", Math.max(r.min, Math.min(r.max, sdrWhiteOf(d) + delta * 10))); break
      }
      case "transfer": setField(d.name, "sdr_eotf", cycle(["default", "gamma22", "srgb"], eotfOf(d), delta)); break
      case "icc": {
        var paths = [""].concat(iccOptions.map(function(o) { return o.value }).filter(function(v) { return v !== "" }))
        setField(d.name, "icc", cycle(paths, iccOf(d), delta)); break
      }
      case "preset": setField(d.name, "cm", cycle(["auto", "srgb", "dcip3", "dp3", "adobe", "wide", "edid", "hdr", "hdredid"], presetOf(d), delta)); break
      case "saturation": setField(d.name, "sdrsaturation", Model.round2(Math.max(0, Math.min(2, saturationOf(d) + delta * 0.05)))); break
      case "minlum": adjustLum(d, "min_luminance", delta * (big ? 1 : 0.1), 0.005); break
      case "maxlum": adjustLum(d, "max_luminance", delta * step, 1); break
      case "avglum": adjustLum(d, "max_avg_luminance", delta * step, 1); break
      case "caphdr": setField(d.name, "supports_hdr", cycle([0, 1, -1], capOf(d, "supports_hdr"), delta)); break
      case "capwide": setField(d.name, "supports_wide_color", cycle([0, 1, -1], capOf(d, "supports_wide_color"), delta)); break
      case "autohdr": setGlobal("cm_auto_hdr", cycle([0, 1, 2], autoHdrOf(), delta)); break
    }
  }

  function adjustLum(d, key, delta, floor) {
    var cur = lumOf(d, key)
    if (isNaN(cur)) cur = edidLum(key)
    var next = Math.max(floor, Math.round((cur + delta) * 1000) / 1000)
    setField(d.name, key, next)
  }

  function edidLum(key) {
    var h = caps.hdr || {}
    if (key === "min_luminance") return Number(h.minLuminance) || 0.005
    if (key === "max_luminance") return Number(h.maxLuminance) || 400
    return Number(h.maxFrameAverageLuminance) || Number(h.maxLuminance) || 400
  }

  function rowActivate() {
    var d = display
    if (!d) return
    switch (currentRow) {
      case "mode": modeDropdown.toggle(); break
      case "enabled": setField(d.name, "enabled", !enabledOf(d)); break
      case "advanced": advancedOpen = !advancedOpen; break
      case "icc": iccDropdown.toggle(); break
      case "posx": posXField.field.forceActiveFocus(); break
      case "posy": posYField.field.forceActiveFocus(); break
      case "minlum": minLumField.field.forceActiveFocus(); break
      case "maxlum": maxLumField.field.forceActiveFocus(); break
      case "avglum": avgLumField.field.forceActiveFocus(); break
      default: rowAdjust(1, false)
    }
  }

  function selectDisplayIndex(i) {
    if (displays[i]) selectedName = displays[i].name
  }

  readonly property bool anyPopupOpen: modeDropdown.popupOpen || iccDropdown.popupOpen
  readonly property bool textEditing: keyScope.activeFocus === false && (posXField.field.activeFocus || posYField.field.activeFocus || minLumField.field.activeFocus || maxLumField.field.activeFocus || avgLumField.field.activeFocus)

  function handleKey(event) {
    if (anyPopupOpen) return false
    var k = event.key
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    if (k === Qt.Key_Escape) {
      if (textEditing) { keyScope.forceActiveFocus(); return true }
      if (hasPending) { service.revert(); return true }
      requestClose(); return true
    }
    if (textEditing) return false
    if (k === Qt.Key_Tab || k === Qt.Key_Backtab) {
      var order = ["canvas", "inspector", "actions"]
      var i = order.indexOf(focusArea)
      focusArea = order[(i + (k === Qt.Key_Backtab ? -1 : 1) + order.length) % order.length]
      return true
    }
    if (k >= Qt.Key_1 && k <= Qt.Key_9) { selectDisplayIndex(k - Qt.Key_1); return true }
    if (k === Qt.Key_A) { applyDraft(); return true }
    if (k === Qt.Key_R) { revertOrDiscard(); return true }
    if (k === Qt.Key_I) { if (service) service.identify(); return true }
    if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) {
      if (focusArea === "actions") { if (actionIndex === 0) { if (service) service.identify() } else if (actionIndex === 1) revertOrDiscard(); else applyDraft(); return true }
      if (focusArea === "inspector") { rowActivate(); return true }
      return true
    }
    var down = k === Qt.Key_J || k === Qt.Key_Down
    var up = k === Qt.Key_K || k === Qt.Key_Up
    var left = k === Qt.Key_H || k === Qt.Key_Left
    var right = k === Qt.Key_L || k === Qt.Key_Right
    if (focusArea === "canvas") {
      if (k === Qt.Key_J && !shift) { selectDisplayIndex((displays.map(function(x) { return x.name }).indexOf(selectedName) + 1) % Math.max(1, displays.length)); return true }
      if (k === Qt.Key_K && !shift) { selectDisplayIndex((displays.map(function(x) { return x.name }).indexOf(selectedName) - 1 + displays.length) % Math.max(1, displays.length)); return true }
      var step = shift ? 100 : 10
      if (left) { canvas.nudge(-step, 0); return true }
      if (right) { canvas.nudge(step, 0); return true }
      if (up) { canvas.nudge(0, -step); return true }
      if (down) { canvas.nudge(0, step); return true }
      return false
    }
    if (focusArea === "actions") {
      if (left) { actionIndex = Math.max(0, actionIndex - 1); return true }
      if (right) { actionIndex = Math.min(2, actionIndex + 1); return true }
      if (up) { focusArea = "inspector"; return true }
      return false
    }
    if (down) { rowMove(1); return true }
    if (up) { rowMove(-1); return true }
    if (left) { rowAdjust(-1, shift); return true }
    if (right) { rowAdjust(1, shift); return true }
    return false
  }

  // ---------------------------------------------------------- ICC list
  property var iccOptions: [{ value: "", label: "None" }]
  Process {
    id: iccProc
    command: [root.service ? root.service.cli : "true", "icc", "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var list = [{ value: "", label: "None" }]
        try {
          var parsed = JSON.parse(String(text || "[]"))
          for (var i = 0; i < parsed.length; i++) list.push({ value: parsed[i].path, label: parsed[i].name, description: parsed[i].path })
        } catch (e) { /* keep None */ }
        root.iccOptions = list
      }
    }
  }

  // ---------------------------------------------------------- window
  PanelWindow {
    id: window
    visible: root.opened
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-displays-studio"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    Rectangle {
      anchors.fill: parent
      color: root.scrim
      MouseArea { anchors.fill: parent; onClicked: root.requestClose() }
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(1120), window.width - Style.gapsOut * 4)
      height: Math.min(Style.space(880), window.height - Style.gapsOut * 4)
      anchors.centerIn: parent
      color: root.background
      radius: Style.cornerRadius
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: {} }

      FocusScope {
        id: keyScope
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        focus: true
        Keys.onPressed: function(event) { if (root.handleKey(event)) event.accepted = true }

        Column {
          anchors.fill: parent
          spacing: Style.spacing.panelGap

          // ---------- header ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(titleText.implicitHeight, headerCaption.implicitHeight)
            Text {
              id: titleText
              textFormat: Text.PlainText
              text: "Displays"
              color: root.foreground
              font.family: root.fontFamily; font.pixelSize: Style.font.heading; font.bold: true
              anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              id: headerCaption
              textFormat: Text.PlainText
              text: {
                var parts = [root.displays.length + (root.displays.length === 1 ? " display" : " displays")]
                if (root.hdrCount > 0) parts.push(root.hdrCount + " in HDR")
                parts.push(root.hasPending ? "pending" : (root.draftDirty ? "edited" : "layout unchanged"))
                if (root.service && root.service.lastError) parts.push(root.service.lastError)
                return parts.join(" · ")
              }
              color: root.service && root.service.lastError ? root.urgent : root.dim
              font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true
              anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideLeft
              width: Math.min(implicitWidth, parent.width - titleText.implicitWidth - Style.space(20))
            }
          }

          // ---------- body ----------
          Item {
            width: parent.width
            height: parent.height - y - actionsArea.height - parent.spacing

            DisplayCanvas {
              id: canvas
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: Math.round(parent.width * 0.58)
              rects: root.rects
              selectedName: root.selectedName
              hasCursor: root.focusArea === "canvas"
              foreground: root.foreground
              accent: root.accent
              urgent: root.urgent
              fontFamily: root.fontFamily
              onSelected: function(name) { root.selectedName = name; root.focusArea = "canvas" }
              onMoved: function(name, x, y) { root.moveDisplay(name, x, y) }
            }

            ScrollView {
              id: inspectorScroll
              anchors.left: canvas.right
              anchors.leftMargin: Style.spacing.panelGap
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              clip: true
              ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
              ScrollBar.vertical.policy: inspector.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

              Column {
                id: inspector
                width: inspectorScroll.availableWidth
                spacing: Style.spacing.xl

                // ----- panel identity
                Column {
                  width: parent.width
                  spacing: Style.spacing.xs
                  Text {
                    textFormat: Text.PlainText
                    text: root.display ? root.display.name + " · " + String(root.display.description || root.display.model || "").trim() : "No display"
                    color: root.foreground
                    font.family: root.fontFamily; font.pixelSize: Style.font.title; font.bold: true
                    elide: Text.ElideRight; width: parent.width
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.display ? Model.panelLine(root.display) : ""
                    color: root.dim
                    font.family: root.fontFamily; font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap; width: parent.width
                  }
                }

                Row {
                  width: parent.width
                  spacing: Style.spacing.xxl
                  visible: root.caps.available === true
                  Column {
                    width: parent.width - gamut.width - parent.spacing
                    spacing: Style.spacing.xs
                    anchors.verticalCenter: parent.verticalCenter
                    Text { textFormat: Text.PlainText; text: Model.capabilityLine(root.caps); color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true; elide: Text.ElideRight; width: parent.width }
                    Text { textFormat: Text.PlainText; text: Model.luminanceLine(root.caps); visible: text !== ""; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight; width: parent.width }
                    Text { textFormat: Text.PlainText; text: root.caps.primaries ? "Primaries (EDID) " + Model.primariesLine(root.caps) : ""; visible: text !== ""; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; width: parent.width }
                    Text { textFormat: Text.PlainText; text: "solid: panel · dashed: BT.2020, P3, sRGB"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; width: parent.width }
                  }
                  GamutPlot { id: gamut; primaries: root.caps.primaries || null; foreground: root.foreground; accent: root.accent }
                }

                // ----- signal
                PanelSeparator { foreground: root.foreground }
                PanelSectionHeader { text: "SIGNAL"; foreground: root.foreground; fontFamily: root.fontFamily }

                InspectorRow {
                  rowId: "mode"
                  Dropdown {
                    id: modeDropdown
                    width: parent.width
                    label: "Mode"
                    options: root.display ? Model.modeOptions(root.display) : []
                    value: root.display ? root.modeOf(root.display) : ""
                    foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
                    hasCursor: root.focusArea === "inspector" && root.currentRow === "mode"
                    onChanged: function(v) { if (root.display) root.setField(root.display.name, "mode", v) }
                    onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "mode" } }
                  }
                }

                InspectorRow {
                  rowId: "vrr"
                  Column {
                    width: parent.width; spacing: Style.spacing.labelGap
                    RowLabel { text: "Variable refresh" }
                    ButtonGroup {
                      options: [{ value: "0", label: "Off" }, { value: "1", label: "On" }, { value: "2", label: "Fullscreen" }]
                      value: root.display ? String(root.vrrOf(root.display)) : "0"
                      foreground: root.foreground; background: root.background; accent: root.accent; fontFamily: root.fontFamily
                      focusable: false
                      onChanged: function(v) { if (root.display) root.setField(root.display.name, "vrr", Number(v)) }
                      onHovered: function(i, h) { if (h) { root.focusArea = "inspector"; root.currentRow = "vrr" } }
                    }
                  }
                }

                // ----- geometry
                PanelSeparator { foreground: root.foreground }
                PanelSectionHeader { text: "GEOMETRY"; foreground: root.foreground; fontFamily: root.fontFamily }

                InspectorRow {
                  rowId: "scale"
                  Column {
                    width: parent.width; spacing: Style.spacing.labelGap
                    RowLabel { text: "Scale" }
                    Grid {
                      id: scaleGrid
                      width: parent.width
                      readonly property var scales: root.display ? Model.availableScales(root.display.width, root.display.height) : []
                      columns: Math.max(1, scales.length)
                      spacing: Style.spacing.xs
                      readonly property real cellWidth: scales.length > 0 ? (width - spacing * (columns - 1)) / columns : 0
                      Repeater {
                        model: scaleGrid.scales
                        Button {
                          required property var modelData
                          width: scaleGrid.cellWidth
                          text: modelData.effective + "x"
                          fontSize: Style.font.caption
                          foreground: root.foreground; fontFamily: root.fontFamily
                          horizontalPadding: Style.spacing.sm; verticalPadding: Style.spacing.controlPaddingY
                          bordered: true
                          active: root.display ? Model.round2(root.scaleOf(root.display)) === modelData.effective : false
                          onClicked: if (root.display) root.setField(root.display.name, "scale", Number(modelData.label))
                          onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "scale" } }
                        }
                      }
                    }
                  }
                }

                InspectorRow {
                  rowId: "rotation"
                  Column {
                    width: parent.width; spacing: Style.spacing.labelGap
                    RowLabel { text: "Rotation" }
                    ButtonGroup {
                      options: [{ value: "0", label: "0°" }, { value: "1", label: "90°" }, { value: "2", label: "180°" }, { value: "3", label: "270°" }]
                      value: root.display ? String(root.transformOf(root.display)) : "0"
                      foreground: root.foreground; background: root.background; accent: root.accent; fontFamily: root.fontFamily
                      focusable: false
                      onChanged: function(v) { if (root.display) root.setField(root.display.name, "transform", Number(v)) }
                      onHovered: function(i, h) { if (h) { root.focusArea = "inspector"; root.currentRow = "rotation" } }
                    }
                  }
                }

                Row {
                  width: parent.width
                  spacing: Style.spacing.xl
                  InspectorRow {
                    rowId: "posx"
                    width: (parent.width - parent.spacing) / 2
                    NumberField {
                      id: posXField
                      label: "X (logical px)"
                      value: root.display ? root.positionOf(root.display).x : 0
                      from: -32768; to: 32768; stepSize: 10
                      fieldWidth: parent.width
                      foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
                      hasCursor: root.focusArea === "inspector" && root.currentRow === "posx"
                      onModified: function(v) { if (root.display) root.moveDisplay(root.display.name, v, root.positionOf(root.display).y) }
                      onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "posx" } }
                    }
                  }
                  InspectorRow {
                    rowId: "posy"
                    width: (parent.width - parent.spacing) / 2
                    NumberField {
                      id: posYField
                      label: "Y (logical px)"
                      value: root.display ? root.positionOf(root.display).y : 0
                      from: -32768; to: 32768; stepSize: 10
                      fieldWidth: parent.width
                      foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
                      hasCursor: root.focusArea === "inspector" && root.currentRow === "posy"
                      onModified: function(v) { if (root.display) root.moveDisplay(root.display.name, root.positionOf(root.display).x, v) }
                      onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "posy" } }
                    }
                  }
                }

                InspectorRow {
                  rowId: "mirror"
                  Column {
                    width: parent.width; spacing: Style.spacing.labelGap
                    RowLabel { text: "Mirror" }
                    ButtonGroup {
                      options: [{ value: "", label: "None" }].concat(root.displays.filter(function(o) { return root.display && o.name !== root.display.name }).map(function(o) { return { value: o.name, label: o.name } }))
                      value: root.display ? root.mirrorOf(root.display) : ""
                      foreground: root.foreground; background: root.background; accent: root.accent; fontFamily: root.fontFamily
                      focusable: false
                      onChanged: function(v) { if (root.display) root.setField(root.display.name, "mirror", v) }
                      onHovered: function(i, h) { if (h) { root.focusArea = "inspector"; root.currentRow = "mirror" } }
                    }
                  }
                }

                InspectorRow {
                  rowId: "enabled"
                  Toggle {
                    width: parent.width
                    label: "Enabled"
                    description: root.display && root.enabledOf(root.display) ? "Turning a display off keeps its rule so it comes back where it was." : "Off. Enable to bring it back at its last geometry."
                    checked: root.display ? root.enabledOf(root.display) : false
                    foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
                    hasCursor: root.focusArea === "inspector" && root.currentRow === "enabled"
                    onClicked: if (root.display) root.setField(root.display.name, "enabled", !root.enabledOf(root.display))
                    onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "enabled" } }
                  }
                }

                // ----- colour
                PanelSeparator { visible: root.caps.available === true; foreground: root.foreground }
                PanelSectionHeader { visible: root.caps.available === true; text: "COLOUR"; foreground: root.foreground; fontFamily: root.fontFamily }

                InspectorRow {
                  rowId: "colour"
                  visible: root.caps.available === true
                  ButtonGroup {
                    options: Model.offeredModes(root.caps).map(function(m) { return { value: m, label: m === "sdr" ? "SDR" : (m === "wide" ? "Wide" : "HDR") } })
                    value: root.display ? root.colourOf(root.display) : "sdr"
                    foreground: root.foreground; background: root.background; accent: root.accent; fontFamily: root.fontFamily
                    focusable: false
                    onChanged: function(v) { if (root.display) root.setColour(root.display, v) }
                    onHovered: function(i, h) { if (h) { root.focusArea = "inspector"; root.currentRow = "colour" } }
                  }
                }

                InspectorRow {
                  rowId: "sdrwhite"
                  visible: root.caps.available === true && root.display && root.colourOf(root.display) === "hdr"
                  Column {
                    width: parent.width; spacing: Style.spacing.md
                    readonly property var range: Model.sdrWhiteRange(root.caps)
                    Item {
                      width: parent.width; implicitHeight: sdrLabel.implicitHeight
                      RowLabel { id: sdrLabel; text: "SDR white"; anchors.left: parent.left }
                      Text { textFormat: Text.PlainText; text: (root.display ? Math.round(root.sdrWhiteOf(root.display)) : 0) + " cd/m²"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; anchors.right: parent.right }
                    }
                    Item {
                      width: parent.width
                      height: sdrSlider.implicitHeight
                      PanelSlider {
                        id: sdrSlider
                        bar: root.fakeBar
                        anchors.fill: parent
                        minimum: 0; maximum: 100; step: 1; integer: true
                        value: root.display ? Math.round(Model.sdrWhiteToSlider(root.sdrWhiteOf(root.display), parent.parent.range) * 100) : 0
                        onReleased: function(v) { if (root.display) root.setField(root.display.name, "sdr_max_luminance", Model.sliderToSdrWhite(v / 100, parent.parent.range)) }
                      }
                      Rectangle {
                        width: Math.max(1, Style.space(2)); height: Style.space(12); radius: 1; color: root.accent
                        anchors.verticalCenter: parent.verticalCenter
                        x: Model.sdrWhiteToSlider(Model.REFERENCE_WHITE, parent.parent.range) * parent.width - width / 2
                        visible: parent.parent.range.max > Model.REFERENCE_WHITE
                      }
                    }
                    Text { textFormat: Text.PlainText; text: parent.range.min + " → " + parent.range.max + " cd/m² (max-average from EDID). 203 marked: BT.2408 reference white."; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; width: parent.width }
                  }
                }

                InspectorRow {
                  rowId: "transfer"
                  visible: root.caps.available === true
                  Column {
                    width: parent.width; spacing: Style.spacing.labelGap
                    RowLabel { text: "SDR transfer" }
                    ButtonGroup {
                      options: [{ value: "default", label: "Default" }, { value: "gamma22", label: "Gamma 2.2" }, { value: "srgb", label: "sRGB" }]
                      value: root.display ? root.eotfOf(root.display) : "default"
                      foreground: root.foreground; background: root.background; accent: root.accent; fontFamily: root.fontFamily
                      focusable: false
                      onChanged: function(v) { if (root.display) root.setField(root.display.name, "sdr_eotf", v) }
                      onHovered: function(i, h) { if (h) { root.focusArea = "inspector"; root.currentRow = "transfer" } }
                    }
                    Text { textFormat: Text.PlainText; text: "Default follows Hyprland (gamma 2.2 since 0.55). Choose sRGB if terminals look lighter than before 0.53."; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; width: parent.width }
                  }
                }

                InspectorRow {
                  rowId: "icc"
                  visible: root.caps.available === true
                  Column {
                    width: parent.width; spacing: Style.spacing.labelGap
                    SearchableDropdown {
                      id: iccDropdown
                      width: parent.width
                      label: "ICC profile"
                      options: root.iccOptions
                      value: root.display ? root.iccOf(root.display) : ""
                      placeholderText: "Search profiles…"
                      emptyText: "No .icc or .icm files in ~/.local/share/icc, ~/.color/icc or /usr/share/color/icc"
                      foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
                      hasCursor: root.focusArea === "inspector" && root.currentRow === "icc"
                      onChanged: function(v) { if (root.display) root.setField(root.display.name, "icc", v) }
                      onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "icc" } }
                    }
                    Text { textFormat: Text.PlainText; text: "A profile forces the sRGB transfer and replaces the colour preset. HDR is unavailable while one is loaded."; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; width: parent.width }
                  }
                }

                // ----- advanced
                PanelSeparator { visible: root.caps.available === true; foreground: root.foreground }

                InspectorRow {
                  rowId: "advanced"
                  visible: root.caps.available === true
                  Item {
                    width: parent.width
                    implicitHeight: advancedRow.implicitHeight
                    Row {
                      id: advancedRow
                      width: parent.width
                      spacing: Style.space(8)
                      Text { text: root.advancedOpen ? "−" : "+"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.title; width: Style.space(22); horizontalAlignment: Text.AlignHCenter; anchors.verticalCenter: parent.verticalCenter }
                      Text { textFormat: Text.PlainText; text: "Advanced · preset, luminance and capability overrides, auto-HDR"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; width: parent.width - Style.space(22) - Style.space(16) - Style.space(16); elide: Text.ElideRight; anchors.verticalCenter: parent.verticalCenter }
                      Text { text: root.advancedOpen ? "⌄" : "›"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.subtitle; width: Style.space(16); horizontalAlignment: Text.AlignRight; anchors.verticalCenter: parent.verticalCenter }
                    }
                    MouseArea { anchors.fill: parent; onClicked: root.advancedOpen = !root.advancedOpen; cursorShape: Qt.PointingHandCursor }
                  }
                }

                InspectorRow {
                  rowId: "preset"
                  visible: root.advancedOpen
                  Column {
                    width: parent.width; spacing: Style.spacing.labelGap
                    RowLabel { text: "Colour preset (writes cm directly)" }
                    ButtonGroup {
                      options: ["auto", "srgb", "dcip3", "dp3", "adobe", "wide", "edid", "hdr", "hdredid"]
                      value: root.display ? root.presetOf(root.display) : "srgb"
                      fontSize: Style.font.caption
                      foreground: root.foreground; background: root.background; accent: root.accent; fontFamily: root.fontFamily
                      focusable: false
                      onChanged: function(v) { if (root.display) root.setField(root.display.name, "cm", v) }
                      onHovered: function(i, h) { if (h) { root.focusArea = "inspector"; root.currentRow = "preset" } }
                    }
                  }
                }

                InspectorRow {
                  rowId: "saturation"
                  visible: root.advancedOpen
                  Column {
                    width: parent.width; spacing: Style.spacing.md
                    Item {
                      width: parent.width; implicitHeight: satLabel.implicitHeight
                      RowLabel { id: satLabel; text: "SDR saturation in HDR"; anchors.left: parent.left }
                      Text { textFormat: Text.PlainText; text: root.display ? root.saturationOf(root.display).toFixed(2) : "1.00"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; anchors.right: parent.right }
                    }
                    PanelSlider {
                      bar: root.fakeBar
                      width: parent.width
                      minimum: 0; maximum: 2; step: 0.05
                      value: root.display ? root.saturationOf(root.display) : 1
                      onReleased: function(v) { if (root.display) root.setField(root.display.name, "sdrsaturation", Model.round2(v)) }
                    }
                  }
                }

                Row {
                  width: parent.width
                  spacing: Style.spacing.xl
                  visible: root.advancedOpen
                  InspectorRow {
                    rowId: "minlum"
                    width: (parent.width - parent.spacing * 2) / 3
                    NumberField {
                      id: minLumField
                      label: "Min cd/m²"
                      value: root.display ? Math.round((isNaN(root.lumOf(root.display, "min_luminance")) ? root.edidLum("min_luminance") : root.lumOf(root.display, "min_luminance")) * 1000) : 0
                      from: 0; to: 100000; stepSize: 100
                      fieldWidth: parent.width
                      foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
                      hasCursor: root.focusArea === "inspector" && root.currentRow === "minlum"
                      onModified: function(v) { if (root.display) root.setField(root.display.name, "min_luminance", v / 1000) }
                      onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "minlum" } }
                    }
                  }
                  InspectorRow {
                    rowId: "maxlum"
                    width: (parent.width - parent.spacing * 2) / 3
                    NumberField {
                      id: maxLumField
                      label: "Peak cd/m²"
                      value: root.display ? Math.round(isNaN(root.lumOf(root.display, "max_luminance")) ? root.edidLum("max_luminance") : root.lumOf(root.display, "max_luminance")) : 0
                      from: 0; to: 10000; stepSize: 10
                      fieldWidth: parent.width
                      foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
                      hasCursor: root.focusArea === "inspector" && root.currentRow === "maxlum"
                      onModified: function(v) { if (root.display) root.setField(root.display.name, "max_luminance", v) }
                      onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "maxlum" } }
                    }
                  }
                  InspectorRow {
                    rowId: "avglum"
                    width: (parent.width - parent.spacing * 2) / 3
                    NumberField {
                      id: avgLumField
                      label: "Average cd/m²"
                      value: root.display ? Math.round(isNaN(root.lumOf(root.display, "max_avg_luminance")) ? root.edidLum("max_avg_luminance") : root.lumOf(root.display, "max_avg_luminance")) : 0
                      from: 0; to: 10000; stepSize: 10
                      fieldWidth: parent.width
                      foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
                      hasCursor: root.focusArea === "inspector" && root.currentRow === "avglum"
                      onModified: function(v) { if (root.display) root.setField(root.display.name, "max_avg_luminance", v) }
                      onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "avglum" } }
                    }
                  }
                }

                Text {
                  visible: root.advancedOpen
                  textFormat: Text.PlainText
                  text: "Luminances default to the EDID values shown; min is in thousandths. They are the mastering-display numbers Hyprland sends with PQ output."
                  color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; width: parent.width
                }

                InspectorRow {
                  rowId: "caphdr"
                  visible: root.advancedOpen
                  Column {
                    width: parent.width; spacing: Style.spacing.labelGap
                    RowLabel { text: "HDR capability override (supports_hdr)" }
                    ButtonGroup {
                      options: [{ value: "0", label: "Auto (EDID)" }, { value: "1", label: "Force on" }, { value: "-1", label: "Force off" }]
                      value: root.display ? String(root.capOf(root.display, "supports_hdr")) : "0"
                      foreground: root.foreground; background: root.background; accent: root.accent; fontFamily: root.fontFamily
                      focusable: false
                      onChanged: function(v) { if (root.display) root.setField(root.display.name, "supports_hdr", Number(v)) }
                      onHovered: function(i, h) { if (h) { root.focusArea = "inspector"; root.currentRow = "caphdr" } }
                    }
                  }
                }

                InspectorRow {
                  rowId: "capwide"
                  visible: root.advancedOpen
                  Column {
                    width: parent.width; spacing: Style.spacing.labelGap
                    RowLabel { text: "Wide colour override (supports_wide_color)" }
                    ButtonGroup {
                      options: [{ value: "0", label: "Auto (EDID)" }, { value: "1", label: "Force on" }, { value: "-1", label: "Force off" }]
                      value: root.display ? String(root.capOf(root.display, "supports_wide_color")) : "0"
                      foreground: root.foreground; background: root.background; accent: root.accent; fontFamily: root.fontFamily
                      focusable: false
                      onChanged: function(v) { if (root.display) root.setField(root.display.name, "supports_wide_color", Number(v)) }
                      onHovered: function(i, h) { if (h) { root.focusArea = "inspector"; root.currentRow = "capwide" } }
                    }
                  }
                }

                InspectorRow {
                  rowId: "autohdr"
                  visible: root.advancedOpen
                  Column {
                    width: parent.width; spacing: Style.spacing.labelGap
                    RowLabel { text: "Auto HDR for fullscreen content (global, render:cm_auto_hdr)" }
                    ButtonGroup {
                      options: [{ value: "0", label: "Off" }, { value: "1", label: "HDR" }, { value: "2", label: "HDR (EDID primaries)" }]
                      value: String(root.autoHdrOf())
                      foreground: root.foreground; background: root.background; accent: root.accent; fontFamily: root.fontFamily
                      focusable: false
                      onChanged: function(v) { root.setGlobal("cm_auto_hdr", Number(v)) }
                      onHovered: function(i, h) { if (h) { root.focusArea = "inspector"; root.currentRow = "autohdr" } }
                    }
                    Text { textFormat: Text.PlainText; text: "Hyprland's default is on. It has open bugs when the display is not in sRGB (#12971, #15185); nothing here changes it unless you do."; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; width: parent.width }
                  }
                }

                Item { width: parent.width; height: Style.space(6) }
              }
            }
          }

          // ---------- actions ----------
          Item {
            id: actionsArea
            width: parent.width
            implicitHeight: root.hasPending ? applyBar.implicitHeight : Math.max(hintText.implicitHeight, actionButtons.implicitHeight) + Style.spacing.md

            ApplyBar {
              id: applyBar
              visible: root.hasPending
              width: parent.width
              remaining: root.service ? root.service.pendingRemaining : 0
              total: root.service ? root.service.revertSeconds : 15
              foreground: root.foreground
              fontFamily: root.fontFamily
              cursorIndex: root.focusArea === "actions" ? Math.min(1, root.actionIndex) : -1
              onKeep: root.service.keep()
              onRevert: root.service.revert()
              onHovered: function(index, h) { if (h) { root.focusArea = "actions"; root.actionIndex = index } }
            }

            Rectangle { visible: !root.hasPending; width: parent.width; height: 1; color: Util.alpha(root.foreground, 0.12); anchors.top: parent.top }

            Text {
              id: hintText
              visible: !root.hasPending
              textFormat: Text.PlainText
              text: "j/k rows · h/l adjust · ⇥ canvas ⇄ inspector ⇄ actions · arrows nudge 10 px, ⇧ 100 · 1–9 select · a apply · r " + (root.draftDirty ? "discard" : "revert") + " · i identify · esc close"
              color: root.dim
              font.family: root.fontFamily; font.pixelSize: Style.font.caption
              anchors.left: parent.left; anchors.right: actionButtons.left; anchors.rightMargin: Style.space(16)
              anchors.verticalCenter: actionButtons.verticalCenter
              elide: Text.ElideRight
            }

            Row {
              id: actionButtons
              visible: !root.hasPending
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              spacing: Style.spacing.md

              Button {
                text: "Identify"; bordered: true
                foreground: root.foreground; fontFamily: root.fontFamily
                hasCursor: root.focusArea === "actions" && root.actionIndex === 0
                onClicked: if (root.service) root.service.identify()
                onHovered: function(h) { if (h) { root.focusArea = "actions"; root.actionIndex = 0 } }
              }
              Button {
                text: root.draftDirty ? "Discard" : "Revert"; bordered: true
                enabled: root.draftDirty || root.hasPending
                opacity: enabled ? 1 : 0.45
                foreground: root.foreground; fontFamily: root.fontFamily
                hasCursor: root.focusArea === "actions" && root.actionIndex === 1
                onClicked: root.revertOrDiscard()
                onHovered: function(h) { if (h) { root.focusArea = "actions"; root.actionIndex = 1 } }
              }
              Button {
                text: root.overlap ? "Overlap" : "Apply"; bordered: true; active: root.draftDirty && !root.overlap
                enabled: root.draftDirty && !root.overlap
                opacity: enabled ? 1 : 0.45
                foreground: root.overlap ? root.urgent : root.foreground; fontFamily: root.fontFamily
                hasCursor: root.focusArea === "actions" && root.actionIndex === 2
                onClicked: root.applyDraft()
                onHovered: function(h) { if (h) { root.focusArea = "actions"; root.actionIndex = 2 } }
              }
            }
          }
        }
      }
    }
  }

  // ---------------------------------------------------------- row chrome
  component InspectorRow: CursorSurface {
    id: irow
    property string rowId: ""
    default property alias content: irowContent.data
    width: parent ? parent.width : implicitWidth
    implicitHeight: irowContent.implicitHeight + Style.spacing.md * 2
    hasCursor: root.focusArea === "inspector" && root.currentRow === rowId
    foreground: root.foreground
    accent: root.accent
    onHasCursorChanged: if (hasCursor) root.ensureRowVisible(irow)
    Item {
      id: irowContent
      anchors.fill: parent
      anchors.margins: Style.spacing.md
      implicitHeight: children.length ? children[0].implicitHeight : 0
    }
    HoverHandler { onHoveredChanged: if (hovered) { root.focusArea = "inspector"; root.currentRow = irow.rowId } }
  }

  component RowLabel: Text {
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }

  function ensureRowVisible(item) {
    var flick = inspectorScroll.contentItem
    if (!item || !flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y, bottom = top + (item.height || 0)
    var viewTop = flick.contentY, viewBottom = viewTop + flick.height
    if (top < viewTop + 6) flick.contentY = Math.max(0, top - 6)
    else if (bottom > viewBottom - 6) flick.contentY = bottom + 6 - flick.height
  }
}
