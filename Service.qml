import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "components"

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
  property bool busy: applyProc.running || keepProc.running || revertProc.running || applyQueue.length > 0
  property string lastError: ""
  readonly property var displays: state && Array.isArray(state.displays) ? state.displays : []
  readonly property string focused: state ? String(state.focused || "") : ""
  // Hyprland's live focus, for choosing a screen right now; `focused` above
  // lags by one state refresh.
  readonly property string liveFocused: Hyprland.focusedMonitor && Hyprland.focusedMonitor.name ? String(Hyprland.focusedMonitor.name) : focused
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
          root.maybeRecover()
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
  // apply() queues a FIFO of {change, immediately} requests behind whichever
  // one is currently running. A request queued behind one with the same
  // immediately flag merges into it (later field wins per display, per key;
  // null is a real value here too — it tells the backend to clear that
  // field, so it must overlay rather than be treated as absent) instead of
  // just replacing it, so unrelated fields queued mid-run (scale, then
  // rotation, then position) all reach the backend instead of only the
  // last one. A --now request never merges with a pending one: they always
  // run as separate, ordered process calls.
  property var applyQueue: []

  function apply(change, immediately) {
    var queue = applyQueue.slice()
    var tail = queue.length ? queue[queue.length - 1] : null
    if (tail && tail.immediately === immediately)
      queue[queue.length - 1] = { change: mergeApplyChange(tail.change, change), immediately: immediately }
    else
      queue.push({ change: change, immediately: immediately })
    applyQueue = queue
    if (!applyProc.running) runNextApply()
  }

  // Overlay `incoming` onto `base` (both are apply() change objects: an
  // optional `displays` array of {name, ...fields} and an optional `global`
  // object). Matches displays by name, appending ones `base` didn't have.
  function mergeApplyChange(base, incoming) {
    var displays = (base.displays || []).map(function(d) {
      var copy = {}
      for (var k in d) copy[k] = d[k]
      return copy
    })
    var byName = {}
    for (var i = 0; i < displays.length; i++) byName[displays[i].name] = displays[i]
    var incomingDisplays = incoming.displays || []
    for (var j = 0; j < incomingDisplays.length; j++) {
      var nd = incomingDisplays[j]
      var existing = byName[nd.name]
      if (!existing) { existing = { name: nd.name }; displays.push(existing); byName[nd.name] = existing }
      for (var k2 in nd) existing[k2] = nd[k2]
    }
    var merged = { displays: displays }
    if (base.global || incoming.global) {
      var g = {}
      for (var gk in base.global) g[gk] = base.global[gk]
      for (var gk2 in incoming.global) g[gk2] = incoming.global[gk2]
      merged.global = g
    }
    return merged
  }

  function runNextApply() {
    if (!applyQueue.length) return
    var queue = applyQueue.slice()
    var next = queue.shift()
    applyQueue = queue
    var args = [root.cli, "apply"]
    if (next.immediately) args.push("--now")
    args.push(JSON.stringify(next.change))
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

  // All three below: success is the exit code, not "did it write to
  // stderr" — the backend can warn on stderr and still exit 0 (e.g. an
  // EDID that doesn't advertise HDR), and die() can exit non-zero with
  // useful stdout already flushed. exited() and the stdio collectors'
  // streamFinished have no guaranteed order (see wifiqr/Panel.qml's
  // pwProc upstream for the same caveat), so the exit code is stashed in
  // onExited and only read once onRunningChanged fires — running is held
  // true until both collectors (waitForEnd: true) have finished, so by
  // then the exit code and the text are both settled.
  Process {
    id: applyProc
    property int lastExitCode: -1
    stdout: StdioCollector { id: applyOut; waitForEnd: true }
    stderr: StdioCollector { id: applyErr; waitForEnd: true }
    onExited: function(exitCode) { applyProc.lastExitCode = exitCode }
    onRunningChanged: {
      if (running) return
      var ok = applyProc.lastExitCode === 0
      var out = ok ? String(applyOut.text || "").trim() : String(applyErr.text || "").trim()
      if (!ok) root.lastError = out
      root.actionFinished("apply", ok, out)
      if (root.applyQueue.length) { root.runNextApply(); return }
      root.refresh()
    }
  }

  Process {
    id: keepProc
    command: [root.cli, "keep"]
    property int lastExitCode: -1
    stdout: StdioCollector { id: keepOut; waitForEnd: true }
    stderr: StdioCollector { id: keepErr; waitForEnd: true }
    onExited: function(exitCode) { keepProc.lastExitCode = exitCode }
    onRunningChanged: {
      if (running) return
      var ok = keepProc.lastExitCode === 0
      var out = ok ? String(keepOut.text || "").trim() : String(keepErr.text || "").trim()
      if (!ok) root.lastError = out
      root.actionFinished("keep", ok, out)
      root.refresh()
    }
  }

  Process {
    id: revertProc
    command: [root.cli, "revert"]
    property int lastExitCode: -1
    stdout: StdioCollector { id: revertOut; waitForEnd: true }
    stderr: StdioCollector { id: revertErr; waitForEnd: true }
    onExited: function(exitCode) { revertProc.lastExitCode = exitCode }
    onRunningChanged: {
      if (running) return
      var ok = revertProc.lastExitCode === 0
      var out = ok ? String(revertOut.text || "").trim() : String(revertErr.text || "").trim()
      if (!ok) root.lastError = out
      root.actionFinished("revert", ok, out)
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

  // ------------------------------------------------------------ recovery
  //
  // Every display off means nowhere to draw a Keep button and, straight after
  // boot, a black screen: a kept layout that switches a display off is
  // unconditional, so booting it without the other display attached leaves
  // nothing lit. The backend switches the built-in (or first) display back
  // on; this only notices. One attempt per dark spell, so a rescue the
  // compositor refuses cannot loop.
  property bool recoverAttempted: false

  function maybeRecover() {
    if (!displays.length) return
    for (var i = 0; i < displays.length; i++) if (displays[i].enabled) { recoverAttempted = false; return }
    if (recoverAttempted || recoverProc.running) return
    recoverAttempted = true
    recoverProc.running = true
  }

  Process {
    id: recoverProc
    command: [root.cli, "recover"]
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text).trim() !== "") root.lastError = String(text).trim()
    }
    onRunningChanged: if (!running) root.refresh()
  }

  // ------------------------------------------------------------ surfaces
  //
  // Which screens already show a Keep/Revert control of their own: the
  // studio (one window, on the screen it opened on) and any open popup (one
  // per bar). The every-screen strip below stays off those screens, and only
  // takes the keyboard while none of them is open. Surfaces bump the epoch
  // whenever they open or close; reading it inside these is what makes the
  // bindings re-run.
  property string studioScreen: ""
  property int surfaceEpoch: 0

  function surfacesChanged() { surfaceEpoch++ }

  function screenHasSurface(name) {
    if (surfaceEpoch < 0) return false
    if (studioScreen !== "" && studioScreen === name) return true
    for (var i = 0; i < popups.length; i++) if (popups[i].opened && popups[i].screenName === name) return true
    return false
  }

  readonly property bool anySurfaceOpen: {
    if (surfaceEpoch < 0) return false
    if (studioScreen !== "") return true
    for (var i = 0; i < popups.length; i++) if (popups[i].opened) return true
    return false
  }

  // The strip that gets the keyboard: the one on the focused screen, else the
  // first screen that has one.
  readonly property string keyboardScreen: {
    if (surfaceEpoch < 0) return ""
    var names = []
    for (var i = 0; i < Quickshell.screens.length; i++) {
      var n = String(Quickshell.screens[i].name)
      if (!screenHasSurface(n)) names.push(n)
    }
    if (names.indexOf(liveFocused) !== -1) return liveFocused
    return names.length ? names[0] : ""
  }

  // ------------------------------------------------------------ pending strip
  //
  // A Keep/Revert control on every screen while a change is pending, except
  // the screens whose studio or popup already shows one. It is owned here,
  // not by a surface, so it survives the surface losing its screen to the
  // very change it applied, and it exists at all for a change made from the
  // command line. While no surface is open the strip on the focused screen
  // has the keyboard: ↵ acts on the highlighted button (Keep by default),
  // esc reverts, h/l move between the two. Same keys as the studio's bar.
  property int stripCursor: 1
  onHasPendingChanged: if (hasPending) stripCursor = 1

  function handleStripKey(event) {
    var k = event.key
    if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) { if (stripCursor === 0) revert(); else keep(); return true }
    if (k === Qt.Key_Y) { keep(); return true }
    if (k === Qt.Key_Escape || k === Qt.Key_N || k === Qt.Key_R) { revert(); return true }
    if (k === Qt.Key_H || k === Qt.Key_Left) { stripCursor = 0; return true }
    if (k === Qt.Key_L || k === Qt.Key_Right) { stripCursor = 1; return true }
    return false
  }

  Variants {
    model: root.hasPending ? Quickshell.screens : []

    PanelWindow {
      id: stripWindow
      required property var modelData
      readonly property string screenName: modelData ? String(modelData.name) : ""
      readonly property bool shown: root.hasPending && !root.screenHasSurface(screenName)
      readonly property bool ownsKeyboard: shown && !root.anySurfaceOpen && root.keyboardScreen === screenName

      screen: modelData
      visible: shown
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "omarchy-displays-pending"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: ownsKeyboard ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
      anchors { top: true; left: true; right: true }
      margins.top: Style.bar.sizeHorizontal + Style.gapsOut * 2
      implicitHeight: stripCard.implicitHeight + Style.gapsOut * 2
      // Only the card takes input; the rest of the band lets clicks through.
      mask: Region { item: stripCard }

      onOwnsKeyboardChanged: if (ownsKeyboard) Qt.callLater(function() { stripKeys.forceActiveFocus() })

      BorderSurface {
        id: stripCard
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: Math.min(Style.space(600), stripWindow.width - Style.gapsOut * 4)
        implicitHeight: stripColumn.implicitHeight + contentTopInset + contentBottomInset
        color: Color.popups.background
        radius: Style.cornerRadius
        borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
        padding: Style.spacing.panelPadding

        FocusScope {
          id: stripKeys
          anchors.fill: parent
          anchors.topMargin: stripCard.contentTopInset
          anchors.rightMargin: stripCard.contentRightInset
          anchors.bottomMargin: stripCard.contentBottomInset
          anchors.leftMargin: stripCard.contentLeftInset
          focus: stripWindow.ownsKeyboard
          Keys.onPressed: function(event) { if (root.handleStripKey(event)) event.accepted = true }

          Column {
            id: stripColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            spacing: Style.spacing.xs

            ApplyBar {
              width: parent.width
              bare: true
              remaining: root.pendingRemaining
              total: root.revertSeconds
              foreground: Color.popups.text
              fontFamily: Style.font.family
              cursorIndex: stripWindow.ownsKeyboard ? root.stripCursor : -1
              onKeep: root.keep()
              onRevert: root.revert()
              onHovered: function(index, h) { if (h) root.stripCursor = index }
            }

            Text {
              visible: stripWindow.ownsKeyboard
              textFormat: Text.PlainText
              text: "↵ keep · esc revert · h/l choose"
              color: Qt.darker(Color.popups.text, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
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
      if (p.screenName === root.liveFocused) target = p
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
    function recover(): void { root.recoverAttempted = false; root.maybeRecover() }
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
