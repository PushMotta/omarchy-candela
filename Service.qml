import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Headless singleton behind the Displays popup and studio. Owns the state
// cache (one `omarchy-displays state` call, shared), the hotplug listener,
// the pending-apply countdown, the identify badges, and the plugin's IPC
// target. Surfaces read `state` and call apply/keep/revert here so there is
// exactly one process talking to the backend at a time.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "pmotta.displays"
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    if (u.indexOf("file://") === 0) u = u.substring(7)
    return u.replace(/\/$/, "")
  }
  readonly property string cli: pluginDir + "/bin/omarchy-displays"

  // ------------------------------------------------------------ state
  property var state: null
  property bool loading: false
  property bool busy: applyProc.running || keepProc.running || revertProc.running
  property string lastError: ""
  readonly property var displays: state && Array.isArray(state.displays) ? state.displays : []
  readonly property string focused: state ? String(state.focused || "") : ""
  readonly property var pending: state && state.pending ? state.pending : null
  readonly property bool hasPending: pending !== null
  readonly property int revertSeconds: state && state.revertSeconds ? Number(state.revertSeconds) : 15
  property int now: Math.floor(Date.now() / 1000)
  readonly property int pendingRemaining: hasPending ? Math.max(0, Number(pending.expires) - now) : 0

  signal stateChangedExternally()
  signal actionFinished(string action, bool ok, string output)

  function displayByName(name) {
    for (var i = 0; i < displays.length; i++) if (displays[i].name === name) return displays[i]
    return null
  }

  function refresh() {
    if (stateProc.running) { refreshQueued = true; return }
    loading = true
    stateProc.running = true
  }
  property bool refreshQueued: false

  function scheduleRefresh() { refreshTimer.restart() }

  Process {
    id: stateProc
    command: [root.cli, "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseState(text)
        root.loading = false
        if (parsed) {
          root.state = parsed
          root.now = Math.floor(Date.now() / 1000)
          root.lastError = ""
          root.stateChangedExternally()
        } else {
          root.lastError = "omarchy-displays state returned no data"
        }
        if (root.refreshQueued) { root.refreshQueued = false; root.refresh() }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text).trim() !== "") console.warn("displays state:", String(text).trim())
    }
  }

  Timer {
    id: refreshTimer
    interval: 300
    repeat: false
    onTriggered: root.refresh()
  }

  // Tick the countdown while something is pending, then refresh once it
  // expires so the surfaces drop the bar even if the timer's notify was lost.
  Timer {
    interval: 1000
    repeat: true
    running: root.hasPending
    onTriggered: {
      root.now = Math.floor(Date.now() / 1000)
      if (root.pendingRemaining <= 0) root.scheduleRefresh()
    }
  }

  // ------------------------------------------------------------ actions
  //
  // apply() chains: while an apply runs, the newest change waits and runs
  // next (the backend merges onto pending, so intermediate ones can drop).
  property var queuedApply: null

  function apply(change, immediately) {
    var args = [root.cli, "apply"]
    if (immediately) args.push("--now")
    args.push(JSON.stringify(change))
    if (applyProc.running) { queuedApply = args; return }
    applyProc.command = args
    applyProc.running = true
  }

  function applyDisplay(name, fields, immediately) {
    var d = {}
    for (var k in fields) d[k] = fields[k]
    d.name = name
    apply({ displays: [d] }, immediately)
  }

  function keep() {
    if (keepProc.running) return
    keepProc.running = true
  }

  function revert() {
    if (revertProc.running) return
    revertProc.running = true
  }

  function setColourMode(name, mode) {
    var d = displayByName(name)
    if (!d) return
    applyDisplay(name, Model.fieldsForMode(mode, d.capabilities, Model.effectiveIntent(d)), false)
  }

  function setSdrWhite(name, nits) {
    applyDisplay(name, { sdr_max_luminance: Math.round(nits) }, true)
  }

  function setBrightness(name, percent) {
    if (!name) return
    brightnessProc.command = [root.cli, "brightness", name, Math.round(percent) + "%"]
    if (brightnessProc.running) { brightnessQueued = brightnessProc.command; return }
    brightnessProc.running = true
  }
  property var brightnessQueued: null

  Process {
    id: applyProc
    stdout: StdioCollector { id: applyOut; waitForEnd: true }
    stderr: StdioCollector { id: applyErr; waitForEnd: true }
    onRunningChanged: {
      if (running) return
      var err = String(applyErr.text || "").trim()
      root.lastError = err
      root.actionFinished("apply", err === "", err !== "" ? err : String(applyOut.text || "").trim())
      if (root.queuedApply) { var next = root.queuedApply; root.queuedApply = null; applyProc.command = next; applyProc.running = true; return }
      root.refresh()
    }
  }

  Process {
    id: keepProc
    command: [root.cli, "keep"]
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: keepErr; waitForEnd: true }
    onRunningChanged: {
      if (running) return
      var err = String(keepErr.text || "").trim()
      root.lastError = err
      root.actionFinished("keep", err === "", err)
      root.refresh()
    }
  }

  Process {
    id: revertProc
    command: [root.cli, "revert"]
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running) return
      root.actionFinished("revert", true, "")
      root.refresh()
    }
  }

  Process {
    id: brightnessProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running) return
      if (root.brightnessQueued) { var next = root.brightnessQueued; root.brightnessQueued = null; brightnessProc.command = next; brightnessProc.running = true }
    }
  }

  // ------------------------------------------------------------ hotplug
  //
  // Hyprland's event socket tells us when displays come and go and when the
  // config reloaded (which is how keep/revert land). One socat per session.
  readonly property string hyprSocket: {
    var runtime = Quickshell.env("XDG_RUNTIME_DIR") || ""
    var sig = Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || ""
    return runtime && sig ? runtime + "/hypr/" + sig + "/.socket2.sock" : ""
  }

  Process {
    id: eventProc
    command: ["socat", "-U", "-", "UNIX-CONNECT:" + root.hyprSocket]
    running: root.hyprSocket !== ""
    stdout: SplitParser {
      onRead: function(line) {
        var l = String(line || "")
        if (l.indexOf("monitoradded") === 0 || l.indexOf("monitorremoved") === 0 || l.indexOf("configreloaded") === 0 || l.indexOf("focusedmon") === 0)
          root.scheduleRefresh()
      }
    }
    onRunningChanged: if (!running && root.hyprSocket !== "") eventRestart.restart()
  }

  Timer {
    id: eventRestart
    interval: 2000
    repeat: false
    onTriggered: if (!eventProc.running) eventProc.running = true
  }

  // The backend rewrites pending.json on every apply/keep/revert, including
  // the detached revert timer, so watching it keeps the surfaces truthful.
  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/displays/pending.json"
    watchChanges: true
    printErrors: false
    onFileChanged: root.scheduleRefresh()
    onLoadFailed: root.scheduleRefresh()
  }

  // ------------------------------------------------------------ popups
  //
  // One Popup instance lives in every bar (one bar per screen). They register
  // here so a keybinding can toggle the one on the focused display.
  property var popups: []

  function registerPopup(p) {
    var next = popups.slice()
    if (next.indexOf(p) === -1) next.push(p)
    popups = next
  }

  function unregisterPopup(p) {
    popups = popups.filter(function(x) { return x !== p })
  }

  function togglePopup() {
    if (!popups.length) return false
    var target = null
    for (var i = 0; i < popups.length; i++) {
      var p = popups[i]
      if (p.opened) { p.close(); return true }
      if (p.screenName === root.focused) target = p
    }
    (target || popups[0]).open()
    return true
  }

  // ------------------------------------------------------------ identify
  property bool identifying: false

  function identify() {
    identifying = true
    identifyTimer.restart()
  }

  Timer {
    id: identifyTimer
    interval: 2200
    repeat: false
    onTriggered: root.identifying = false
  }

  Variants {
    model: root.identifying ? Quickshell.screens : []

    PanelWindow {
      id: badgeWindow
      required property var modelData
      readonly property var display: root.displayByName(modelData.name)

      screen: modelData
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "omarchy-displays-identify"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      mask: Region {}

      BorderSurface {
        anchors.centerIn: parent
        width: badgeColumn.implicitWidth + Style.space(44)
        height: badgeColumn.implicitHeight + Style.space(36)
        color: Color.popups.background
        radius: Style.cornerRadius
        borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
        opacity: root.identifying ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 140 } }

        Column {
          id: badgeColumn
          anchors.centerIn: parent
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            text: badgeWindow.modelData.name
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.displayLarge
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            text: {
              var d = badgeWindow.display
              if (!d) return ""
              var parts = []
              if (d.model) parts.push(String(d.model).trim())
              parts.push(d.x + ", " + d.y)
              parts.push(Model.metaLine(d).split(" · ").slice(0, 1).join(""))
              var mode = Model.colourMode(d)
              parts.push(mode === "hdr" ? "HDR" : (mode === "wide" ? "Wide" : "SDR"))
              return parts.join(" · ")
            }
            color: Qt.darker(Color.popups.text, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ IPC
  IpcHandler {
    target: root.pluginId

    function refresh(): void { root.refresh() }
    function identify(): void { root.identify() }
    function state(): string { return root.state ? JSON.stringify(root.state) : "{}" }
    function keep(): void { root.keep() }
    function revert(): void { root.revert() }
    function open(): void { if (root.shell) root.shell.summon(root.pluginId, "{}") }
    function popup(): string { return root.togglePopup() ? "ok" : "no popup" }
    function hdr(mode: string, display: string): string {
      var name = display && display !== "" ? display : root.focused
      var m = mode === "on" ? "hdr" : (mode === "wide" ? "wide" : "sdr")
      root.setColourMode(name, m)
      return "ok"
    }
  }

  Component.onCompleted: refresh()
}
