import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "components"

// The Candela studio: arrangement canvas, per-display inspector, and an
// action bar with the keys printed. Every change is staged in `draft`; Apply
// sends the whole draft as one timed change, and the countdown bar offers
// Keep / Revert until the backend's timer fires.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "io.github.pushmotta.candela"
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
  // Logical pixels and cd/m² are not currency: no thousands separators.
  Component.onCompleted: {
    var fields = [posXField, posYField, maxLumField, avgLumField, customWidthField, customHeightField]
    for (var i = 0; i < fields.length; i++) if (fields[i] && fields[i].field) fields[i].field.locale = Qt.locale("C")
    minLumField.validatorLocale = "C"
  }

  function open(payloadJson) {
    var wanted = service ? service.liveFocused : ""
    var chosen = null
    for (var i = 0; i < Quickshell.screens.length; i++) if (Quickshell.screens[i].name === wanted) chosen = Quickshell.screens[i]
    targetScreen = chosen || (Quickshell.screens.length ? Quickshell.screens[0] : null)
    draft = ({})
    draftGlobal = ({})
    draftPlan = undefined
    draftVirtual = ({})
    wsPillIndex = 0
    advancedOpen = false
    helpOpen = false
    focusArea = "inspector"
    currentRow = "mode"
    if (service) service.refresh()
    if (!selectedName || !displayByName(selectedName)) selectedName = wanted || (displays.length ? displays[0].name : "")
    opened = true
    iccProc.running = true
    // Tell the service which screen shows a Keep/Revert of its own, so the
    // every-screen strip stays off it and hands over if this screen goes.
    if (service) { service.studioScreen = targetScreen ? String(targetScreen.name) : ""; service.surfacesChanged() }
    Qt.callLater(function() { keyScope.forceActiveFocus() })
  }

  // The password and its QR code are forgotten with the studio.
  function close() { opened = false; releaseScreen(); if (service) service.hideVirtualSecret() }

  function releaseScreen() {
    if (!service) return
    var mine = targetScreen ? String(targetScreen.name) : ""
    if (service.studioScreen === mine) { service.studioScreen = ""; service.surfacesChanged() }
  }

  Component.onDestruction: releaseScreen()

  // The change this studio applied can take its own screen away (switching it
  // off, or a mode the panel cannot show). A window whose screen has gone is
  // no place for the only Keep button: close, and the service's strip on the
  // surviving screens takes over the countdown.
  Connections {
    target: Quickshell
    function onScreensChanged() {
      if (!root.opened || !root.targetScreen) return
      var mine = String(root.targetScreen.name)
      for (var i = 0; i < Quickshell.screens.length; i++) if (String(Quickshell.screens[i].name) === mine) return
      root.requestClose()
    }
  }
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

  readonly property bool reducedMotion: service ? service.reducedMotion : false

  property var draft: ({})
  property var draftGlobal: ({})
  property var submittedDraft: ({})
  property var submittedGlobal: ({})
  property bool applyInFlight: false
  property int submittedRequestId: -1
  property var draftRevisions: ({})
  property var submittedRevisions: ({})
  property var draftGlobalRevisions: ({})
  property var submittedGlobalRevisions: ({})
  property int editRevision: 0
  // A virtual display's name and the device it was sized for ride in the
  // same change as its size, so one Apply and one undo cover both.
  property var draftVirtual: ({})
  property var submittedVirtual: ({})
  readonly property bool draftDirty: Object.keys(draft).length > 0 || Object.keys(draftGlobal).length > 0 || planDirty || Object.keys(draftVirtual).length > 0

  // ---------------------------------------------------------- workspace plan
  //
  // The plan is one thing for the whole desk (a home display per workspace,
  // and what each display shows when it lights up), so its draft is a single
  // object rather than per-display fields. undefined is "not edited".
  property var draftPlan: undefined
  property int planRevision: 0
  property int submittedPlanRevision: -1
  property int wsPillIndex: 0

  // Pending wins over kept, as for every other field.
  readonly property var savedPlan: {
    var w = service && service.state ? service.state.workspaces : null
    var p = !w ? null : (hasPending ? w.pendingConfig : w.kept)
    return { homes: (p && p.homes) || {}, shows: (p && p.shows) || {} }
  }
  readonly property var plan: draftPlan !== undefined ? draftPlan : savedPlan
  readonly property bool planDirty: draftPlan !== undefined
    && !(Model.samePlanHomes(draftPlan.homes, savedPlan.homes) && Model.samePlanHomes(Model.effectiveShows(draftPlan.homes, draftPlan.shows), Model.effectiveShows(savedPlan.homes, savedPlan.shows)))
  readonly property bool planOn: Object.keys(plan.homes).length > 0
  readonly property string planKind: Model.planKind(plan.homes, rects)

  // Live from Hyprland, so the chips follow a workspace moved by hand while
  // the studio is open.
  readonly property var openWorkspaces: {
    var out = [], values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var w = values[i]
      if (!(w.id >= 1)) continue
      out.push({ id: w.id, monitor: w.monitor ? String(w.monitor.name) : "", windows: w.toplevels ? w.toplevels.values.length : 0 })
    }
    return out
  }
  readonly property var shownWorkspaceIds: {
    var out = [], mons = Hyprland.monitors.values
    for (var i = 0; i < mons.length; i++) if (mons[i].activeWorkspace) out.push(mons[i].activeWorkspace.id)
    return out
  }
  readonly property var planMovesNow: Model.planMoves(plan.homes, openWorkspaces, Model.planOrder(rects))
  readonly property var savedMovesNow: Model.planMoves(savedPlan.homes, openWorkspaces, Model.planOrder(rects))
  // With a plan, each block carries the workspaces that live there; with
  // none, the ones that are there now, so the canvas always shows them.
  readonly property var planChips: {
    var out = {}
    for (var i = 0; i < displays.length; i++)
      out[displays[i].name] = planOn ? Model.chipsFor(displays[i].name, plan.homes, openWorkspaces, shownWorkspaceIds)
                                     : Model.openChipsFor(displays[i].name, openWorkspaces, shownWorkspaceIds)
    return out
  }
  readonly property string planLine: planOn
    ? Model.planLine(plan.homes, rects)
    : "Workspaces open on whichever display has focus. The chips show where yours are now."
  readonly property string planNote: {
    var m = planMovesNow
    if (!m.length) return ""
    var one = m.length === 1
    var lead = one ? "Workspace " + Model.workspaceLabel(m[0].id) + " is on " + m[0].from + " now."
                   : "Workspaces " + Model.workspaceList(m.map(function(x) { return x.id })) + " are away from home."
    return lead + (planDirty ? " Apply moves " + (one ? "it" : "them") + " home." : " Send home moves " + (one ? "it" : "them") + " back.")
  }
  readonly property bool displayCanBeHome: !!display && !mirrorOf(display)

  function copyMap(m) { var o = {}; for (var k in (m || {})) o[k] = m[k]; return o }

  function setPlan(homes, shows) {
    draftPlan = { homes: homes, shows: shows || {} }
    planRevision++
    // Back to exactly what is saved is no edit at all.
    if (!planDirty) draftPlan = undefined
  }

  // Off and the presets replace the plan; Custom from Off starts from where
  // the open workspaces are now, and from a preset it changes nothing (any
  // edit to the pills is what makes a plan custom).
  function choosePlan(kind) {
    if (kind === "custom") {
      if (planKind === "off") setPlan(placementHomes(), {})
      return
    }
    setPlan(Model.presetPlan(kind, rects), {})
  }

  function toggleHome(d, id) {
    if (!d || mirrorOf(d)) return
    var homes = copyMap(plan.homes), key = String(id)
    if (homes[key] === d.name) delete homes[key]
    else homes[key] = d.name
    setPlan(homes, copyMap(plan.shows))
  }

  function placementHomes() {
    var homes = {}, usable = Model.planOrder(rects)
    for (var i = 0; i < openWorkspaces.length; i++) {
      var w = openWorkspaces[i]
      if (w.id <= 10 && usable.indexOf(w.monitor) !== -1) homes[String(w.id)] = w.monitor
    }
    return homes
  }

  // Dragging a chip with no plan starts one from where the open workspaces
  // are, the way Custom does, so only the dragged one changes.
  function moveHome(id, name) {
    var target = displayByName(name)
    if (!target || mirrorOf(target)) return
    var homes = planOn ? copyMap(plan.homes) : placementHomes()
    homes[String(id)] = name
    setPlan(homes, copyMap(plan.shows))
  }

  function setShow(d, id) {
    if (!d) return
    var shows = copyMap(plan.shows)
    shows[d.name] = String(id)
    setPlan(copyMap(plan.homes), shows)
  }

  // A mirror shows another display's picture, so its homes go with it to the
  // display it mirrors, in the same change.
  function setMirror(d, value) {
    setField(d.name, "mirror", value)
    if (value && Model.homesOn(plan.homes, d.name).length) setPlan(Model.rehomeFrom(plan.homes, d.name, value), copyMap(plan.shows))
  }

  function homesCaption(d) {
    if (!d) return ""
    if (mirrorOf(d)) return d.name + " mirrors " + mirrorOf(d) + ", so it shows " + mirrorOf(d) + "'s workspaces and cannot be a home."
    var parts = [], others = {}
    for (var k in plan.homes) if (plan.homes[k] !== d.name) { (others[plan.homes[k]] = others[plan.homes[k]] || []).push(Number(k)) }
    for (var n in others) parts.push(Model.workspaceList(others[n]) + " live on " + n)
    var line = parts.length ? parts.join(", ") + "." : ""
    if (!enabledOf(d) && Model.homesOn(plan.homes, d.name).length) line += (line ? " " : "") + d.name + " is off, so its workspaces open on another display until it is on."
    if (planDirty) line += (line ? " " : "") + "Apply: " + Model.planSummary(planKind, planMovesNow).replace(/^Plan [A-Za-z]+ · /, "") + "."
    return line
  }

  function setField(name, key, value) {
    var next = {}
    for (var n in draft) { next[n] = {}; for (var k in draft[n]) next[n][k] = draft[n][k] }
    if (!next[name]) next[name] = {}
    var base = displayByName(name)
    var original = base ? Model.effectiveIntent(base)[key] : undefined
    // While Apply is running, restoring the old value is still a new edit:
    // once that request lands, it must be sent again to undo the submitted
    // field. `null` is the backend's explicit clear operation.
    var restoringSubmitted = applyInFlight && submittedDraft[name] && submittedDraft[name][key] !== undefined
    if ((value === original || (value === null && original === undefined)) && !restoringSubmitted) delete next[name][key]
    else if (restoringSubmitted && value === undefined) next[name][key] = null
    else next[name][key] = value
    if (Object.keys(next[name]).length === 0) delete next[name]
    draft = next
    var revisions = {}
    for (var rn in draftRevisions) { revisions[rn] = {}; for (var rk in draftRevisions[rn]) revisions[rn][rk] = draftRevisions[rn][rk] }
    if (!revisions[name]) revisions[name] = {}
    revisions[name][key] = ++editRevision
    draftRevisions = revisions
  }

  // A new mode, scale or rotation changes the display's logical size. The
  // neighbours that sat flush against (or beyond) its old right and bottom
  // edges follow the edge, so a flush layout stays flush instead of opening
  // a gap or an overlap the user then has to drag closed.
  function setSizeField(d, key, value) {
    var before = null
    for (var i = 0; i < rects.length; i++) if (rects[i].name === d.name) before = rects[i]
    setField(d.name, key, value)
    if (!before) return
    var moves = Model.reflowAfterResize(rects, d.name, { width: before.width, height: before.height })
    for (var m = 0; m < moves.length; m++) moveDisplay(moves[m].name, moves[m].x, moves[m].y)
  }

  function setGlobal(key, value) {
    var next = {}
    for (var k in draftGlobal) next[k] = draftGlobal[k]
    var g = service && service.state ? service.state.global : null
    var original = Model.effectiveGlobal(g)[key]
    var restoringSubmitted = applyInFlight && submittedGlobal[key] !== undefined
    if ((value === original || (value === null && original === undefined)) && !restoringSubmitted) delete next[key]
    else if (restoringSubmitted && value === undefined) next[key] = null
    else next[key] = value
    draftGlobal = next
    var revisions = {}
    for (var rk in draftGlobalRevisions) revisions[rk] = draftGlobalRevisions[rk]
    revisions[key] = ++editRevision
    draftGlobalRevisions = revisions
  }

  // Whether the selected display's draft touches this inspector row.
  function rowChanged(rowId) {
    if (rowId.indexOf("ws") === 0) return rowId !== "wssend" && planDirty
    var dv = display ? draftVirtual[display.name] : null
    if (rowId === "vlabel") return !!dv && dv.label !== undefined
    if (rowId === "vsize" && dv && dv.device !== undefined) return true
    return !!display && Model.rowChanged(rowId, draft[display.name], draftGlobal)
  }

  // Put one row back to what is kept by dropping its fields from the draft.
  // A size field moves the flush neighbours back the way setSizeField moved
  // them, and dropping a capability override or an ICC pick can leave the
  // colour mode unreachable, which reconcileColour settles.
  function resetRow(rowId) {
    var d = display
    if (!d || applyInFlight || !rowChanged(rowId)) return
    // The plan is one thing: putting any of its rows back puts it all back.
    if (rowId.indexOf("ws") === 0) { draftPlan = undefined; return }
    if (rowId === "vlabel") { setVirtualMeta(d.name, "label", undefined); return }
    if (rowId === "vsize") setVirtualMeta(d.name, "device", undefined)
    var f = Model.rowFields(rowId)
    var before = null
    for (var i = 0; i < rects.length; i++) if (rects[i].name === d.name) before = rects[i]
    if (f.display.length && draft[d.name]) {
      var next = {}, revs = {}
      for (var n in draft) { next[n] = {}; for (var k in draft[n]) next[n][k] = draft[n][k] }
      for (var rn in draftRevisions) { revs[rn] = {}; for (var rk in draftRevisions[rn]) revs[rn][rk] = draftRevisions[rn][rk] }
      for (var j = 0; j < f.display.length; j++) { delete next[d.name][f.display[j]]; if (revs[d.name]) delete revs[d.name][f.display[j]] }
      if (Object.keys(next[d.name]).length === 0) delete next[d.name]
      draft = next
      draftRevisions = revs
    }
    if (f.global.length) {
      var g = {}, grevs = {}
      for (var gk in draftGlobal) g[gk] = draftGlobal[gk]
      for (var gr in draftGlobalRevisions) grevs[gr] = draftGlobalRevisions[gr]
      for (var m = 0; m < f.global.length; m++) { delete g[f.global[m]]; delete grevs[f.global[m]] }
      draftGlobal = g
      draftGlobalRevisions = grevs
    }
    var sized = f.display.some(function(key) { return key === "mode" || key === "scale" || key === "transform" })
    if (sized && before) {
      var moves = Model.reflowAfterResize(rects, d.name, { width: before.width, height: before.height })
      for (var mv = 0; mv < moves.length; mv++) moveDisplay(moves[mv].name, moves[mv].x, moves[mv].y)
    }
    if (rowId === "caphdr" || rowId === "capwide" || rowId === "icc") reconcileColour(d)
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
  function resolutionOf(d) {
    var m = Model.parseMode(modeOf(d))
    return m ? m.width + "x" + m.height : ""
  }
  function setResolution(d, resolution) {
    var choices = Model.refreshOptions(d, resolution)
    if (!choices.length) return
    var current = Model.parseMode(modeOf(d)), best = choices[0]
    if (current) for (var i = 0; i < choices.length; i++)
      if (Math.abs(choices[i].refresh - current.refresh) < Math.abs(best.refresh - current.refresh)) best = choices[i]
    setSizeField(d, "mode", best.value)
  }
  function colourOf(d) {
    var dr = draft[d.name] || {}
    if (dr.cm !== undefined) return (dr.cm === "hdr" || dr.cm === "hdredid") ? "hdr" : (dr.bitdepth === 10 ? "wide" : "sdr")
    return Model.colourMode(d)
  }
  function sdrWhiteOf(d) { return Number(field(d, "sdr_max_luminance", d.live ? d.live.sdrMaxLuminance : Model.SDR_WHITE_FLOOR)) || Model.SDR_WHITE_FLOOR }
  function eotfOf(d) { return String(field(d, "sdr_eotf", "default")) }
  function iccOf(d) { return String(field(d, "icc", "")) }
  function presetOf(d) { return String(field(d, "cm", d.live ? d.live.cm : "srgb")) }
  function saturationOf(d) {
    var v = Number(field(d, "sdrsaturation", d.live ? d.live.sdrSaturation : 1))
    return isNaN(v) ? 1 : v
  }
  // Fallback -1, not 0: Hyprland's own convention is 1 force-on / 0
  // force-off / -1 trust-the-EDID, and a display that has never had this
  // field set is exactly the "absent" case, not "forced off".
  function capOf(d, key) { return Number(field(d, key, 0)) }
  function lumOf(d, key) { var v = field(d, key, null); return v === null || v === undefined ? NaN : Number(v) }
  function autoHdrOf() {
    if (draftGlobal.cm_auto_hdr !== undefined) return Number(draftGlobal.cm_auto_hdr)
    var g = service && service.state ? service.state.global : null
    var effective = Model.effectiveGlobal(g)
    if (effective.cm_auto_hdr !== undefined) return Number(effective.cm_auto_hdr)
    return g && g.cm_auto_hdr !== null && g.cm_auto_hdr !== undefined ? Number(g.cm_auto_hdr) : 1
  }

  function setColour(d, mode) {
    var f = Model.fieldsForMode(mode, d.capabilities, Model.effectiveIntent(d))
    for (var k in f) setField(d.name, k, f[k])
  }

  // What offeredModes/hdrUnavailableReason need to see: draft values count,
  // not just what has already been kept or is pending, so an override or an
  // ICC pick that has not been applied yet still gates the pills right away.
  function colourIntent(d) {
    return { icc: field(d, "icc", ""), supports_hdr: capOf(d, "supports_hdr"), supports_wide_color: capOf(d, "supports_wide_color") }
  }

  // A capability override can make the draft's current colour mode
  // unreachable (e.g. forcing HDR off while the draft sits in HDR). Move it
  // to the best mode still offered so the draft never asks the backend to
  // apply a state it will reject.
  function reconcileColour(d) {
    if (!d) return
    var offered = Model.offeredModes(d.capabilities, colourIntent(d))
    if (offered.indexOf(colourOf(d)) === -1) setColour(d, offered.indexOf("wide") !== -1 ? "wide" : "sdr")
  }

  function hdrReasonSentence(d) {
    // Only worth a sentence when HDR is blocked rather than absent: a panel
    // that never reported HDR would otherwise carry this line forever. Same
    // rule as the popup's caption.
    if (!d || !d.capabilities || !d.capabilities.supportsHdr) return ""
    var reason = Model.hdrUnavailableReason(d.capabilities, colourIntent(d))
    return reason ? "HDR is unavailable while " + reason + "." : ""
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
                 model: String(d.model || "").trim(), mode: modeOf(d).replace("@", " @ ") + " Hz", scale: Model.formatScale(scaleOf(d)),
                 hdr: colourOf(d) === "hdr", disabled: !enabledOf(d), mirrorOf: mirrorOf(d), focused: d.focused === true,
                 virtual: d.virtual === true })
    }
    return out
  }
  readonly property var overlap: Model.anyOverlap(rects.filter(function(r) { return !r.disabled && !r.mirrorOf }))
  readonly property int hdrCount: rects.filter(function(r) { return r.hdr }).length

  // ---------------------------------------------------------- apply
  function applyDraft() {
    if (!service || !draftDirty || overlap || applyInFlight) return
    var change = { displays: [] }
    for (var name in draft) {
      var entry = { name: name }
      for (var k in draft[name]) entry[k] = draft[name][k]
      change.displays.push(entry)
    }
    if (Object.keys(draftGlobal).length) change.global = draftGlobal
    // A change that only touches the plan carries no displays key: that is
    // how the backend knows it can keep it at once, without a countdown.
    if (planDirty) change.workspaces = Model.workspaceChange(savedPlan, draftPlan)
    if (Object.keys(draftVirtual).length) change.virtual = draftVirtual
    submittedVirtual = draftVirtual
    if (!change.displays.length) delete change.displays
    submittedPlanRevision = planDirty ? planRevision : -1
    submittedDraft = draft
    submittedGlobal = draftGlobal
    submittedRevisions = draftRevisions
    submittedGlobalRevisions = draftGlobalRevisions
    applyInFlight = true
    submittedRequestId = service.apply(change, false)
  }

  Connections {
    target: root.service
    function onRequestFinished(requestId, action, ok, output) {
      if (action !== "apply" || !root.applyInFlight || requestId !== root.submittedRequestId) return
      root.applyInFlight = false
      if (!ok) return
      var next = {}
      for (var n in root.draft) {
        next[n] = {}
        for (var k in root.draft[n]) if (!root.submittedDraft[n] || !root.submittedRevisions[n] || root.draftRevisions[n][k] !== root.submittedRevisions[n][k]) next[n][k] = root.draft[n][k]
        if (Object.keys(next[n]).length === 0) delete next[n]
      }
      var ng = {}
      for (var gk in root.draftGlobal) if (!root.submittedGlobalRevisions[gk] || root.draftGlobalRevisions[gk] !== root.submittedGlobalRevisions[gk]) ng[gk] = root.draftGlobal[gk]
      root.draft = next; root.draftGlobal = ng
      if (root.submittedPlanRevision !== -1 && root.planRevision === root.submittedPlanRevision) root.draftPlan = undefined
      if (root.draftVirtual === root.submittedVirtual) root.draftVirtual = ({})
      root.focusArea = "actions"; root.actionIndex = 1
    }
  }

  // Revert, in order: a pending change; else the draft; else, when the last
  // thing kept was a workspace plan (kept at once, with no countdown to
  // revert from), that plan.
  function revertOrDiscard() {
    if (hasPending && service) { service.revert(); return }
    if (!draftDirty && service && service.undoAvailable) { service.revert(); return }
    draft = ({})
    draftGlobal = ({})
    draftPlan = undefined
    draftVirtual = ({})
  }

  function moveDisplay(name, x, y) {
    setField(name, "position", x + "x" + y)
  }

  // ---------------------------------------------------------- virtual displays
  readonly property bool isVirtual: !!display && display.virtual === true
  readonly property var virtualState: service ? service.virtualState : ({ wayvnc: false, viewer: null, addresses: [], displays: {} })
  readonly property var virtualInfo: isVirtual ? ((virtualState.displays || {})[display.name] || {}) : ({})
  readonly property var virtualNetwork: virtualInfo.network || ({})
  property bool addingVirtual: false
  property int chooserIndex: 1
  readonly property var virtualUses: [
    { use: "extra", title: "Extra screen", caption: "Use a tablet or another computer as one more screen. It sits beside your displays, so the mouse and windows move onto it. You see it on that device, which needs a VNC viewer app: RealVNC Viewer is free for iPad, Android, Mac and Windows." },
    { use: "stage", title: "Stage", caption: "A screen of an exact size, 1920×1080 to start, to share in a call or record. Choose it in the screen-share picker and watch it in Candela's window; Omarchy's own screen recording only sees it with its portal setting on. It sits apart, out of the mouse's way." },
    { use: "bench", title: "Test bench", caption: "See an app at a size or on a device you don't have: pick the device, watch it in Candela's window, and move the mouse onto it to use it. Nothing to install." } ]
  property string removeArmedFor: ""
  Timer { id: removeArm; interval: 4000; onTriggered: root.removeArmedFor = "" }

  function sizeOf(d) { var m = Model.parseMode(modeOf(d)); return m ? m.width + "x" + m.height : "" }
  function pixelsOf(d) { var m = Model.parseMode(modeOf(d)); return m ? { width: m.width, height: m.height } : { width: 0, height: 0 } }
  // "custom" is chosen, not only matched: picking it shows the fields even
  // while the size still happens to be a preset's.
  property bool customSizeChosen: false
  function virtualPresetOf(d) {
    if (customSizeChosen) return "custom"
    var p = pixelsOf(d)
    return Model.virtualPresetChosen(deviceOf(d), p.width, p.height, scaleOf(d))
  }
  function keptVirtual(name) { return (virtualState.displays || {})[name] || {} }
  function deviceOf(d) {
    var dv = draftVirtual[d.name]
    if (dv && dv.device !== undefined) return dv.device
    return keptVirtual(d.name).device || null
  }
  function labelOf(d) {
    var dv = draftVirtual[d.name]
    if (dv && dv.label !== undefined) return dv.label
    return keptVirtual(d.name).label || ""
  }
  // undefined drops the field from the draft; a value equal to what is kept
  // drops it too, so the row is only marked while it really changes.
  function setVirtualMeta(name, key, value) {
    var next = {}
    for (var n in draftVirtual) { next[n] = {}; for (var k in draftVirtual[n]) next[n][k] = draftVirtual[n][k] }
    var kept = keptVirtual(name)[key]
    if (kept === undefined) kept = null
    if (!next[name]) next[name] = {}
    if (value === undefined || value === kept) delete next[name][key]
    else next[name][key] = value
    if (Object.keys(next[name]).length === 0) delete next[name]
    draftVirtual = next
  }
  function setVirtualLabel(d, text) {
    var t = String(text || "").trim()
    setVirtualMeta(d.name, "label", t.length ? t : undefined)
  }
  function orientationOf(d) { var p = pixelsOf(d); return Model.virtualOrientation(p.width, p.height) }
  function setVirtualPreset(d, id) {
    if (id === "custom") { customSizeChosen = true; setVirtualMeta(d.name, "device", null); return }
    customSizeChosen = false
    var preset = Model.virtualPresetById(id)
    if (!preset) return
    setSizeField(d, "mode", Model.virtualModeFor(preset, orientationOf(d), refreshOfVirtual(d)))
    setSizeField(d, "scale", preset.scale)
    setVirtualMeta(d.name, "device", id)
  }
  function setOrientation(d, orientation) {
    var p = pixelsOf(d)
    if (Model.virtualOrientation(p.width, p.height) === orientation) return
    setSizeField(d, "mode", p.height + "x" + p.width + "@" + refreshOfVirtual(d))
  }
  function setCustomSize(d, width, height) {
    if (width < 320 || height < 240 || width > 8192 || height > 8192) return
    setVirtualMeta(d.name, "device", null)
    setSizeField(d, "mode", Math.round(width) + "x" + Math.round(height) + "@" + refreshOfVirtual(d))
  }
  onSelectedNameChanged: customSizeChosen = false
  function refreshOfVirtual(d) { var m = Model.parseMode(modeOf(d)); return m ? Math.round(m.refresh) : 60 }
  function setVirtualRefresh(d, hz) { setSizeField(d, "mode", sizeOf(d) + "@" + hz) }
  function setPlacement(d, placement) {
    var p = Model.virtualPositionFor(rects, d.name, placement)
    moveDisplay(d.name, p.x, p.y)
  }
  function addVirtual(use) {
    addingVirtual = false
    if (service) service.virtualAdd(use)
  }
  // Removing asks twice: it closes viewers someone may be using.
  function removeVirtual(d) {
    if (!d || !service) return
    if (removeArmedFor !== d.name) { removeArmedFor = d.name; removeArm.restart(); return }
    removeArmedFor = ""
    service.virtualRemove(d.name)
  }
  readonly property bool previewOpen: isVirtual && !!service && service.previews.indexOf(display.name) !== -1
  readonly property int virtualWindows: Number(virtualInfo.windows || 0)
  readonly property bool virtualUnseen: isVirtual && display !== null && display.enabled !== false && !!service && service.virtualUnseen(display.name)
  function virtualViewCaption() {
    return "A live picture in a Candela window, nothing on the network. Watching only: to work in it, place it beside your displays and move the pointer there."
  }

  Connections {
    target: root.service
    function onVirtualFinished(action, ok, output) {
      // A display just added is the one you want to look at next.
      if (action === "add" && ok && /^VIRTUAL-[0-9]+$/.test(output)) root.selectedName = output
    }
  }

  // ---------------------------------------------------------- keyboard
  property string focusArea: "inspector"   // "canvas" | "inspector" | "actions"
  property string currentRow: "mode"
  property bool advancedOpen: false
  // 0..2 (Identify/Revert/Apply) normally, 0..1 (Revert/Keep) while pending.
  // Lands on Keep when a countdown starts, matching the bar's own default,
  // and back on Apply when it ends so the cursor isn't left on a Revert
  // that no longer means "discard the draft".
  property int actionIndex: 2
  onHasPendingChanged: {
    actionIndex = hasPending ? 1 : 2
    // The sheet would cover the countdown, so a pending change closes it.
    if (hasPending) helpOpen = false
  }

  // The key sheet (?): every key the studio knows, grouped by where it acts.
  property bool helpOpen: false
  readonly property var keySections: [
    { title: "Everywhere", keys: [
      ["?", "this sheet"],
      ["⇥  ⇧⇥", "canvas ⇄ workspaces ⇄ inspector ⇄ actions"],
      ["w", "the workspace plan, under the canvas"],
      ["+", "add a virtual display"],
      ["\u2212", "remove the selected virtual display (press twice)"],
      ["1–9  [ ]", "select a display"],
      ["a", "apply the draft"],
      ["r", "discard the draft, or revert a pending change"],
      ["i", "identify: a label on each screen"],
      ["esc", "leave a field, revert a pending change, or close"] ] },
    { title: "Inspector", keys: [
      ["j k  ↓ ↑", "next and previous row"],
      ["h l  ← →", "adjust the row"],
      ["⇧ h l", "larger steps for position and luminance"],
      ["↵  space", "open a dropdown, edit a field, or toggle"],
      ["↵ on a workspace", "make this display its home, or clear it"],
      ["⌫", "reset the row to what is kept"] ] },
    { title: "Canvas", keys: [
      ["arrows", "nudge 10 px, with ⇧ 100 px"],
      ["⌥ arrows", "flush beside the nearest display, centred"],
      ["0", "move to the origin"],
      ["j k", "next and previous display"],
      ["⌫", "reset its position"],
      ["drag with ⌥", "move without snapping"],
      ["drag a workspace", "give it another home display"] ] },
    { title: "Workspace plan", keys: [
      ["h l", "Off, Split, Alternate"],
      ["j", "into the selected display's homes"],
      ["⌫", "put the plan back to what is kept"] ] },
    { title: "Actions and countdown", keys: [
      ["h l", "choose a button"],
      ["↵", "press it; Keep while a change is pending"],
      ["r  esc", "revert a pending change"] ] }
  ]

  readonly property var rows: {
    var list = isVirtual
      ? ["vlabel", "vsize", "vorient"].concat(display && virtualPresetOf(display) === "custom" ? ["vcustomw", "vcustomh"] : [])
          .concat(["vrefresh", "scale", "posx", "posy", "vplace", "enabled", "vwindow", "vnetwork"])
      : ["mode", "refresh", "vrr", "scale", "rotation", "posx", "posy", "mirror", "enabled"]
    if (isVirtual) {
      if (!virtualState.wayvnc) list.push("vinstall")
      if (virtualNetwork.on) list.push("vaddress", "vsecret", "vlogin")
      list.push("vremove")
    }
    if (caps.available) {
      list.push("colour")
      if (display && colourOf(display) === "hdr") list.push("sdrwhite")
      list.push("transfer", "icc")
    }
    if (planOn) {
      list.push("wshomes")
      if (display && Model.homesOn(plan.homes, display.name).length) list.push("wsshows")
    }
    if (!planDirty && savedMovesNow.length) list.push("wssend")
    if (caps.available) {
      list.push("advanced")
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
        var res = Model.resolutionOptions(d).map(function(o) { return o.value })
        if (res.length) setResolution(d, cycle(res, resolutionOf(d), delta)); break
      }
      case "refresh": {
        var rates = Model.refreshOptions(d, resolutionOf(d)).map(function(o) { return o.value })
        if (rates.length) setSizeField(d, "mode", cycle(rates, modeOf(d), delta)); break
      }
      case "vrr": setField(d.name, "vrr", cycle([0, 1, 2], vrrOf(d), delta)); break
      case "scale": {
        var scales = Model.availableScales(d.width, d.height)
        var i = Model.scaleIndex(scales, scaleOf(d)); if (i < 0) i = 0
        var n = Math.max(0, Math.min(scales.length - 1, i + delta))
        setSizeField(d, "scale", scales[n].effective); break
      }
      case "rotation": setSizeField(d, "transform", cycle([0, 1, 2, 3], transformOf(d), delta)); break
      case "posx": { var p = positionOf(d); moveDisplay(d.name, p.x + delta * step, p.y); break }
      case "posy": { var q = positionOf(d); moveDisplay(d.name, q.x, q.y + delta * step); break }
      case "mirror": {
        var m = [""].concat(displays.filter(function(o) { return o.name !== d.name }).map(function(o) { return o.name }))
        setMirror(d, cycle(m, mirrorOf(d), delta)); break
      }
      case "wshomes": wsPillIndex = Math.max(0, Math.min(Model.WORKSPACE_IDS.length - 1, wsPillIndex + delta)); break
      case "wsshows": {
        var homes = Model.homesOn(plan.homes, d.name).map(String)
        if (homes.length) setShow(d, cycle(homes, Model.effectiveShows(plan.homes, plan.shows)[d.name] || homes[0], delta)); break
      }
      case "wssend": break
      case "vsize": setVirtualPreset(d, cycle(Model.virtualPresetOptions().map(function(o) { return o.value }), virtualPresetOf(d), delta)); break
      case "vorient": setOrientation(d, orientationOf(d) === "landscape" ? "portrait" : "landscape"); break
      case "vcustomw": { var pw = pixelsOf(d); setCustomSize(d, pw.width + delta * (big ? 100 : 10), pw.height); break }
      case "vcustomh": { var ph = pixelsOf(d); setCustomSize(d, ph.width, ph.height + delta * (big ? 100 : 10)); break }
      case "vrefresh": setVirtualRefresh(d, cycle([30, 60], refreshOfVirtual(d), delta)); break
      case "vplace": setPlacement(d, Model.virtualPlacement(rects, d.name) === "beside" ? "apart" : "beside"); break
      case "vaddress": {
        var addrs = (virtualState.addresses || []).map(function(a) { return a.address })
        if (addrs.length > 1 && service) service.virtualView(d.name, "network", true, ["--address", cycle(addrs, virtualNetwork.address || addrs[0], delta)])
        break
      }
      case "enabled": setField(d.name, "enabled", !enabledOf(d)); break
      case "colour": setColour(d, cycle(Model.offeredModes(d.capabilities, colourIntent(d)), colourOf(d), delta)); break
      case "sdrwhite": {
        var r = Model.sdrWhiteRange(d.capabilities)
        setField(d.name, "sdr_max_luminance", Math.max(r.min, Math.min(r.max, sdrWhiteOf(d) + delta * 10))); break
      }
      case "transfer": setField(d.name, "sdr_eotf", cycle(["default", "gamma22", "srgb"], eotfOf(d), delta)); break
      case "icc": {
        if (colourOf(d) === "hdr") break   // picker is disabled while the draft is in HDR
        var paths = [""].concat(iccOptions.map(function(o) { return o.value }).filter(function(v) { return v !== "" }))
        setField(d.name, "icc", cycle(paths, iccOf(d), delta)); break
      }
      case "preset": setField(d.name, "cm", cycle(["auto", "srgb", "dcip3", "dp3", "adobe", "wide", "edid", "hdr", "hdredid"], presetOf(d), delta)); break
      case "saturation": setField(d.name, "sdrsaturation", Model.round2(Math.max(0, Math.min(2, saturationOf(d) + delta * 0.05)))); break
      case "minlum": adjustLum(d, "min_luminance", delta * (big ? 1 : 0.1), 0.005); break
      case "maxlum": adjustLum(d, "max_luminance", delta * step, 1); break
      case "avglum": adjustLum(d, "max_avg_luminance", delta * step, 1); break
      case "caphdr": setField(d.name, "supports_hdr", cycle([0, 1, -1], capOf(d, "supports_hdr"), delta)); reconcileColour(d); break
      case "capwide": setField(d.name, "supports_wide_color", cycle([0, 1, -1], capOf(d, "supports_wide_color"), delta)); reconcileColour(d); break
      case "autohdr": setGlobal("cm_auto_hdr", cycle([0, 1, 2], autoHdrOf(), delta)); break
    }
  }

  function cyclePlan(delta) {
    var kinds = ["off", "split", "alternate"]
    if (planKind === "custom") kinds.push("custom")
    choosePlan(cycle(kinds, planKind, delta))
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
      case "mode": resolutionDropdown.toggle(); break
      case "refresh": refreshDropdown.toggle(); break
      case "enabled": setField(d.name, "enabled", !enabledOf(d)); break
      case "advanced": advancedOpen = !advancedOpen; break
      case "wshomes": toggleHome(d, Model.WORKSPACE_IDS[wsPillIndex]); break
      case "wssend": if (service) service.sendWorkspacesHome(); break
      case "vwindow": if (service) service.togglePreview(d.name); break
      case "vsize": sizeDropdown.toggle(); break
      case "vlabel": nameField.forceActiveFocus(); nameField.selectAll(); break
      case "vcustomw": customWidthField.field.forceActiveFocus(); break
      case "vcustomh": customHeightField.field.forceActiveFocus(); break
      case "vinstall": if (service) service.installWayvnc(); break
      case "vnetwork": if (service && virtualState.wayvnc && (enabledOf(d) || virtualNetwork.on)) service.virtualView(d.name, "network", !virtualNetwork.on); break
      case "vsecret": if (service) service.showVirtualSecret(d.name); break
      case "vlogin": if (service) service.virtualView(d.name, "network", true, ["--at-login", virtualNetwork.atLogin ? "no" : "yes"]); break
      case "vremove": removeVirtual(d); break
      case "icc": if (colourOf(d) !== "hdr") iccDropdown.toggle(); break   // disabled while the draft is in HDR
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

  function selectRelative(delta) {
    if (!displays.length) return
    var idx = displays.map(function(x) { return x.name }).indexOf(selectedName)
    selectDisplayIndex((idx + delta + displays.length) % displays.length)
  }

  readonly property bool anyPopupOpen: resolutionDropdown.popupOpen || refreshDropdown.popupOpen || iccDropdown.popupOpen || sizeDropdown.popupOpen
  readonly property bool textEditing: keyScope.activeFocus === false && (posXField.field.activeFocus || posYField.field.activeFocus || customWidthField.field.activeFocus || customHeightField.field.activeFocus || nameField.activeFocus || minLumField.field.activeFocus || maxLumField.field.activeFocus || avgLumField.field.activeFocus)

  function handleKey(event) {
    if (anyPopupOpen) return false
    var k = event.key
    if (helpOpen) {
      if (k === Qt.Key_Escape || k === Qt.Key_Question) helpOpen = false
      return true
    }
    if (addingVirtual) {
      if (k === Qt.Key_Escape) addingVirtual = false
      else if (k === Qt.Key_H || k === Qt.Key_Left) chooserIndex = Math.max(0, chooserIndex - 1)
      else if (k === Qt.Key_L || k === Qt.Key_Right) chooserIndex = Math.min(virtualUses.length - 1, chooserIndex + 1)
      else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) addVirtual(virtualUses[chooserIndex].use)
      return true
    }
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var alt = (event.modifiers & Qt.AltModifier) !== 0
    if (k === Qt.Key_Escape) {
      if (textEditing) { keyScope.forceActiveFocus(); return true }
      if (hasPending) { service.revert(); return true }
      requestClose(); return true
    }
    if (textEditing) return false
    if (k === Qt.Key_Question) { if (!hasPending) helpOpen = true; return true }
    if (k === Qt.Key_Backspace || k === Qt.Key_Delete) {
      if (focusArea === "inspector") resetRow(currentRow)
      else if (focusArea === "canvas") resetRow("posx")
      else if (focusArea === "workspaces") { if (!applyInFlight) draftPlan = undefined }
      return true
    }
    if (k === Qt.Key_W) { focusArea = "workspaces"; return true }
    if (k === Qt.Key_Plus || k === Qt.Key_Equal) { addingVirtual = true; return true }
    if (k === Qt.Key_Minus && isVirtual) { removeVirtual(display); return true }
    if (k === Qt.Key_Tab || k === Qt.Key_Backtab) {
      var order = ["canvas", "workspaces", "inspector", "actions"]
      var i = order.indexOf(focusArea)
      focusArea = order[(i + (k === Qt.Key_Backtab ? -1 : 1) + order.length) % order.length]
      return true
    }
    if (k >= Qt.Key_1 && k <= Qt.Key_9) { selectDisplayIndex(k - Qt.Key_1); return true }
    if (k === Qt.Key_BracketLeft) { selectRelative(-1); return true }
    if (k === Qt.Key_BracketRight) { selectRelative(1); return true }
    if (k === Qt.Key_A) { applyDraft(); return true }
    if (k === Qt.Key_R) { revertOrDiscard(); return true }
    if (k === Qt.Key_I) { if (service) service.identify(); return true }
    if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) {
      if (focusArea === "actions") {
        // Pending mode has exactly two targets, Revert and Keep, in that
        // order — the normal three-target Identify/Revert/Apply mapping
        // does not apply while the countdown strip has replaced the bar.
        if (hasPending) { if (actionIndex === 0) { if (service) service.revert() } else if (service) service.keep() }
        else if (actionIndex === 0) { if (service) service.identify() }
        else if (actionIndex === 1) revertOrDiscard()
        else applyDraft()
        return true
      }
      if (focusArea === "inspector") { rowActivate(); return true }
      return true
    }
    var down = k === Qt.Key_J || k === Qt.Key_Down
    var up = k === Qt.Key_K || k === Qt.Key_Up
    var left = k === Qt.Key_H || k === Qt.Key_Left
    var right = k === Qt.Key_L || k === Qt.Key_Right
    if (focusArea === "canvas") {
      // ⌥ + arrow: flush against the nearest display on that side, centred.
      // 0: the origin, where Hyprland's own auto placement starts.
      if (alt && (left || right || up || down)) {
        var beside = Model.snapBeside(rects, selectedName, left ? "left" : (right ? "right" : (up ? "up" : "down")))
        if (beside) moveDisplay(selectedName, beside.x, beside.y)
        return true
      }
      if (k === Qt.Key_0) { if (display) moveDisplay(display.name, 0, 0); return true }
      if (k === Qt.Key_J && !shift) { selectDisplayIndex((displays.map(function(x) { return x.name }).indexOf(selectedName) + 1) % Math.max(1, displays.length)); return true }
      if (k === Qt.Key_K && !shift) { selectDisplayIndex((displays.map(function(x) { return x.name }).indexOf(selectedName) - 1 + displays.length) % Math.max(1, displays.length)); return true }
      var step = shift ? 100 : 10
      if (left) { canvas.nudge(-step, 0); return true }
      if (right) { canvas.nudge(step, 0); return true }
      if (up) { canvas.nudge(0, -step); return true }
      if (down) { canvas.nudge(0, step); return true }
      return false
    }
    if (focusArea === "workspaces") {
      if (left) { cyclePlan(-1); return true }
      if (right) { cyclePlan(1); return true }
      if (down) { focusArea = "inspector"; if (planOn) currentRow = "wshomes"; return true }
      if (up) { focusArea = "canvas"; return true }
      return false
    }
    if (focusArea === "actions") {
      var maxAction = hasPending ? 1 : 2
      if (left) { actionIndex = Math.max(0, actionIndex - 1); return true }
      if (right) { actionIndex = Math.min(maxAction, actionIndex + 1); return true }
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
    // Stays up while the card fades out, the way the shell's own PopupCard
    // does, so dismissing is a movement rather than a cut.
    visible: root.opened || card.opacity > 0
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-candela-studio"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    Rectangle {
      anchors.fill: parent
      color: root.scrim
      opacity: root.opened ? 1 : 0
      Behavior on opacity { enabled: !root.reducedMotion; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
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

      // The shell's card timing (140 ms OutCubic), with the rise kept to 1.5%
      // so the studio settles into place instead of zooming.
      opacity: root.opened ? 1 : 0
      scale: root.opened ? 1 : 0.985
      Behavior on opacity { enabled: !root.reducedMotion; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
      Behavior on scale { enabled: !root.reducedMotion; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

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
              text: "Candela"
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
            id: bodyItem
            width: parent.width
            height: parent.height - y - actionsArea.height - parent.spacing

            DisplayCanvas {
              id: canvas
              anchors.left: parent.left
              // Top-aligned: the canvas and the inspector start on the same
              // line, and what used to be a void underneath now carries the
              // panel's identity, so nothing is stranded.
              anchors.top: parent.top
              width: Math.round(parent.width * 0.58)
              // Hug the arrangement instead of filling the column: two wide
              // displays in a tall box left the layout stranded in a field of
              // grid. The floor keeps a comfortable drop area under a very
              // wide layout, and the ceiling is simply the room available.
              height: Math.round(Math.max(parent.height * 0.42,
                                          Math.min(parent.height, canvas.preferredHeight)))
              Behavior on height { enabled: !root.reducedMotion; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
              reducedMotion: root.reducedMotion
              rects: root.rects
              selectedName: root.selectedName
              hasCursor: root.focusArea === "canvas"
              foreground: root.foreground
              accent: root.accent
              urgent: root.urgent
              fontFamily: root.fontFamily
              chips: root.planChips
              note: root.planNote
              onSelected: function(name) { root.selectedName = name; root.focusArea = "canvas" }
              onMoved: function(name, x, y) { root.moveDisplay(name, x, y) }
              onChipDropped: function(workspace, name) { root.moveHome(workspace, name) }
              removeArmedFor: root.removeArmedFor
              onRemoveRequested: function(name) { var d = root.displayByName(name); if (d) { root.selectedName = name; root.removeVirtual(d) } }
            }

            // Add a virtual display: top right of the canvas, or +.
            Button {
              anchors.top: canvas.top
              anchors.right: canvas.right
              anchors.margins: Style.space(8)
              z: 5
              text: "+ Virtual"
              fontSize: Style.font.caption
              bordered: true
              foreground: root.foreground; fontFamily: root.fontFamily
              tooltipText: "Add a virtual display (+)"
              onClicked: root.addingVirtual = true
            }

            Rectangle {
              id: virtualChooser
              visible: root.addingVirtual
              anchors.fill: canvas
              z: 6
              color: root.background
              border.color: Util.alpha(root.foreground, 0.25)
              border.width: 1
              radius: Style.cornerRadius
              MouseArea { anchors.fill: parent }
              Column {
                anchors.fill: parent
                anchors.margins: Style.space(16)
                spacing: Style.spacing.md
                Item {
                  width: parent.width
                  implicitHeight: chooserTitle.implicitHeight
                  Text { id: chooserTitle; textFormat: Text.PlainText; text: "Add a virtual display. What is it for?"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.title; font.bold: true; anchors.left: parent.left }
                  Text { textFormat: Text.PlainText; text: "h/l choose · ↵ add · esc cancel"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; anchors.right: parent.right; anchors.verticalCenter: chooserTitle.verticalCenter }
                }
                Row {
                  width: parent.width
                  spacing: Style.spacing.md
                  Repeater {
                    model: root.virtualUses
                    CursorSurface {
                      required property var modelData
                      required property int index
                      width: (parent.width - parent.spacing * 2) / 3
                      height: useColumn.implicitHeight + Style.spacing.md * 2
                      hasCursor: root.chooserIndex === index
                      outline: true
                      foreground: root.foreground
                      accent: root.accent
                      Column {
                        id: useColumn
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                        anchors.margins: Style.spacing.md
                        spacing: Style.spacing.xs
                        Text { textFormat: Text.PlainText; text: modelData.title; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
                        Text { textFormat: Text.PlainText; text: modelData.caption; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; width: parent.width }
                      }
                      MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: root.chooserIndex = index
                        onClicked: root.addVirtual(modelData.use)
                      }
                    }
                  }
                }
                Text {
                  textFormat: Text.PlainText
                  text: "It is added at once, with no countdown: it cannot blank a real display. For two minutes, r undoes it. Candela's window shows it here; only the extra screen needs wayvnc on this computer and a VNC viewer app on the other device."
                  color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; width: parent.width
                }
              }
            }

            // ----- panel identity, under the canvas
            //
            // This is what the display *is* rather than what you can do to
            // it, so it belongs beside the picture of the desk and not at the
            // top of a column of controls, where it pushed the colour
            // controls — the point of the tool — off the bottom of the card.
            // It holds no InspectorRow, so the keyboard's row order is
            // untouched by living here.
            // ----- the workspace plan, under the picture of the desk
            //
            // A plan is about the whole desk, so it sits with the canvas
            // rather than in the inspector, which describes one display;
            // there it was the last row of a long column and easy to miss.
            CursorSurface {
              id: workspaceStrip
              anchors.left: parent.left
              anchors.right: canvas.right
              anchors.top: canvas.bottom
              anchors.topMargin: Style.spacing.panelGap
              height: stripColumn.implicitHeight + Style.spacing.md * 2
              hasCursor: root.focusArea === "workspaces"
              foreground: root.foreground
              accent: root.accent

              // The changed mark, as on an inspector row: click it or ⌫ to put
              // the plan back to what is kept.
              Rectangle {
                visible: root.planDirty
                width: Math.max(2, Style.space(2))
                radius: width / 2
                x: Math.round((Style.spacing.md - width) / 2)
                anchors.top: parent.top; anchors.bottom: parent.bottom
                anchors.topMargin: Style.spacing.md; anchors.bottomMargin: Style.spacing.md
                color: root.accent
              }
              MouseArea {
                visible: root.planDirty && !root.applyInFlight
                width: Style.spacing.md
                height: parent.height
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.focusArea = "workspaces"; root.draftPlan = undefined }
              }

              Column {
                id: stripColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.spacing.md
                spacing: Style.spacing.md
                Item {
                  width: parent.width
                  implicitHeight: Math.max(stripHeader.implicitHeight, stripGroup.implicitHeight)
                  PanelSectionHeader { id: stripHeader; text: "WORKSPACES"; foreground: root.foreground; fontFamily: root.fontFamily; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter }
                  ButtonGroup {
                    id: stripGroup
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    options: [{ value: "off", label: "Off" }, { value: "split", label: "Split" }, { value: "alternate", label: "Alternate" }, { value: "custom", label: "Custom" }]
                    value: root.planKind
                    foreground: root.foreground; background: root.background; accent: root.accent; fontFamily: root.fontFamily
                    focusable: false
                    onChanged: function(v) { root.choosePlan(v) }
                    onHovered: function(i, h) { if (h) root.focusArea = "workspaces" }
                  }
                }
                Text {
                  textFormat: Text.PlainText
                  text: root.planLine
                  color: root.planOn ? root.foreground : root.dim
                  font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: root.planOn
                  wrapMode: Text.WordWrap
                  width: parent.width
                }
              }
              HoverHandler { onHoveredChanged: if (hovered) root.focusArea = "workspaces" }
            }

            Column {
              id: panelInfo
              anchors.left: parent.left
              anchors.top: workspaceStrip.bottom
              anchors.topMargin: Style.spacing.panelGap
              anchors.right: canvas.right
              // Bounded and clipped: on a card short enough that the canvas
              // and the plot cannot both have what they want, this gets cut
              // rather than drawn over the action bar.
              height: Math.max(0, bodyItem.height - panelInfo.y)
              clip: true
              spacing: Style.spacing.md

              Column {
                id: identityColumn
                width: parent.width
                spacing: Style.spacing.xs
                Item {
                  width: parent.width
                  implicitHeight: Math.max(identityTitle.implicitHeight, identityRemove.visible ? identityRemove.implicitHeight : 0)
                  Text {
                    id: identityTitle
                    textFormat: Text.PlainText
                    text: !root.display ? "No display"
                      : root.isVirtual ? root.display.name + " · " + (root.virtualInfo.label || "Virtual")
                      : root.display.name + " · " + String(root.display.description || root.display.model || "").trim()
                    color: root.foreground
                    font.family: root.fontFamily; font.pixelSize: Style.font.title; font.bold: true
                    elide: Text.ElideRight
                    width: parent.width - (identityRemove.visible ? identityRemove.width + Style.spacing.md : 0)
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  // A virtual display can be removed, not only switched off;
                  // where its name is, so it is never hard to find.
                  Button {
                    id: identityRemove
                    visible: root.isVirtual
                    readonly property bool armed: root.display !== null && root.removeArmedFor === root.display.name
                    text: armed ? "Press again to remove" : "Remove"
                    fontSize: Style.font.caption
                    bordered: true
                    foreground: armed ? root.urgent : root.foreground; fontFamily: root.fontFamily
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    onClicked: root.removeVirtual(root.display)
                  }
                }
                Text {
                  textFormat: Text.PlainText
                  text: !root.display ? ""
                    : root.isVirtual ? "Virtual: it exists only in Hyprland and is recreated when the shell starts. No EDID, so SDR only."
                    : Model.panelLine(root.display)
                  color: root.dim
                  font.family: root.fontFamily; font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap; width: parent.width
                }
                // Nobody looking at it: the pointer and windows can still go
                // there, so say so, and offer its windows back.
                Item {
                  visible: root.virtualUnseen
                  width: parent.width
                  implicitHeight: Math.max(unseenText.implicitHeight, gatherButton.visible ? gatherButton.implicitHeight : 0)
                  Text {
                    id: unseenText
                    textFormat: Text.PlainText
                    text: "Nobody is viewing it through Candela: its window is closed and no network viewer is connected."
                      + (root.virtualWindows > 0 ? " " + root.virtualWindows + (root.virtualWindows === 1 ? " window is" : " windows are") + " on it." : "")
                    color: root.virtualWindows > 0 ? root.foreground : root.dim
                    font.family: root.fontFamily; font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                    width: parent.width - (gatherButton.visible ? gatherButton.width + Style.spacing.md : 0)
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Button {
                    id: gatherButton
                    visible: root.virtualWindows > 0
                    text: root.virtualWindows === 1 ? "Bring it here" : "Bring them here"
                    fontSize: Style.font.caption
                    bordered: true
                    foreground: root.foreground; fontFamily: root.fontFamily
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    onClicked: if (root.display && root.service) root.service.virtualGather(root.display.name)
                  }
                }
              }

              Row {
                id: capRow
                width: parent.width
                spacing: Style.spacing.xxl
                visible: root.caps.available === true
                // Top-aligned, not centred against the plot: centring left a
                // hole between the panel's name and what it can do.
                Column {
                  width: parent.width - gamut.width - parent.spacing
                  spacing: Style.spacing.xs
                  Text { textFormat: Text.PlainText; text: Model.capabilityLine(root.caps); color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true; elide: Text.ElideRight; width: parent.width }
                  Text { textFormat: Text.PlainText; text: Model.luminanceLine(root.caps); visible: text !== ""; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight; width: parent.width }
                  Text { textFormat: Text.PlainText; text: root.caps.primaries ? "Primaries (EDID) " + Model.primariesLine(root.caps) : ""; visible: text !== ""; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; width: parent.width }
                  Text { textFormat: Text.PlainText; text: "filled: in use · outline: panel · dashed: BT.2020, P3, sRGB"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; width: parent.width }
                  Text { textFormat: Text.PlainText; text: "Illustrative, not measured · ICC and custom presets not represented"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; width: parent.width }
                }
                // Room to be an instrument here, which it never had wedged
                // beside the identity text at the top of the inspector.
                GamutPlot {
                  id: gamut
                  reducedMotion: root.reducedMotion
                  // Takes the height the column has left, and a width in the
                  // diagram's own 0.8:0.9 proportion so the plot is all
                  // diagram and no padding.
                  height: Math.round(Math.max(Style.space(120),
                                              Math.min(Style.space(360),
                                                       bodyItem.height - panelInfo.y - capRow.y)))
                  width: Math.round(height * 0.8 / 0.9)
                  primaries: root.caps.primaries || null
                  // Draft-aware, so the triangle grows the moment Wide or
                  // HDR is chosen rather than waiting for the apply.
                  mode: root.display ? root.colourOf(root.display) : "sdr"
                  foreground: root.foreground
                  accent: root.accent
                  surface: root.background
                }
              }
            }

            FoldHint {
              id: foldHint
              anchors.left: inspectorScroll.left
              anchors.right: inspectorScroll.right
              anchors.bottom: parent.bottom
              flick: inspectorScroll.contentItem
              content: inspector
              available: bodyItem.height
              foreground: root.foreground
              fontFamily: root.fontFamily
              reducedMotion: root.reducedMotion
              markers: [
                { item: signalHeader, name: "signal" },
                { item: geometryHeader, name: "geometry" },
                { item: viewHeader, name: "view" },
                { item: colourHeader, name: "colour" },
                { item: workspacesHeader, name: "workspaces" },
                { item: advancedSection, name: "advanced" }
              ]
            }

            ScrollView {
              id: inspectorScroll
              anchors.left: canvas.right
              anchors.leftMargin: Style.spacing.panelGap
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.bottom: foldHint.top
              clip: true
              ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
              ScrollBar.vertical.policy: inspector.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

              Column {
                id: inspector
                width: inspectorScroll.availableWidth
                spacing: Style.spacing.xl

                // ----- a virtual display's name, before its size: it also names the
                // workspace it opens on.
                InspectorRow {
                  rowId: "vlabel"
                  visible: root.isVirtual
                  Column {
                    width: parent.width; spacing: Style.spacing.labelGap
                    RowLabel { text: "Name" }
                    TextField {
                      id: nameField
                      width: parent.width
                      maximumLength: 32
                      text: root.display && root.isVirtual ? root.labelOf(root.display) : ""
                      placeholderText: root.display ? root.display.name : ""
                      foreground: root.foreground; accent: root.accent
                      font.family: root.fontFamily; font.pixelSize: Style.font.body
                      hasCursor: root.focusArea === "inspector" && root.currentRow === "vlabel"
                      onTextEdited: if (root.display) root.setVirtualLabel(root.display, text)
                      onAccepted: keyScope.forceActiveFocus()
                      Keys.onEscapePressed: keyScope.forceActiveFocus()
                      onHoveredChanged: if (hovered) { root.focusArea = "inspector"; root.currentRow = "vlabel" }
                    }
                    Text {
                      textFormat: Text.PlainText
                      readonly property string slug: root.display ? (Model.virtualWorkspaceSlug(root.labelOf(root.display)) || root.display.name.toLowerCase()) : ""
                      text: "It opens on its own workspace, \u201C" + slug + "\u201D, so 1\u20130 stay yours."
                      color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; width: parent.width
                    }
                  }
                }

                // ----- signal
                PanelSectionHeader { id: signalHeader; text: root.isVirtual ? "SIZE" : "SIGNAL"; foreground: root.foreground; fontFamily: root.fontFamily }

                // A virtual display has no EDID and no modes of its own: any
                // size Hyprland is given is the size it has.
                InspectorRow {
                  rowId: "vsize"
                  visible: root.isVirtual
                  Column {
                    width: parent.width; spacing: Style.spacing.labelGap
                    SearchableDropdown {
                      id: sizeDropdown
                      width: parent.width
                      label: "Device or size"
                      options: Model.virtualPresetOptions()
                      value: root.display && root.isVirtual ? root.virtualPresetOf(root.display) : ""
                      placeholderText: "Search devices and sizes…"
                      emptyText: "No match: choose Custom size"
                      foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
                      hasCursor: root.focusArea === "inspector" && root.currentRow === "vsize"
                      onChanged: function(v) { if (root.display) root.setVirtualPreset(root.display, v) }
                      onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "vsize" } }
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: root.display ? root.sizeOf(root.display).replace("x", "×") + " pixels at " + Model.formatScale(root.scaleOf(root.display)) + "×, so it looks the size it does on the device." : ""
                      color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; width: parent.width
                    }
                  }
                }

                InspectorRow {
                  rowId: "vorient"
                  visible: root.isVirtual
                  Column {
                    width: parent.width; spacing: Style.spacing.labelGap
                    RowLabel { text: "Orientation" }
                    ButtonGroup {
                      options: [{ value: "landscape", label: "Landscape" }, { value: "portrait", label: "Portrait" }]
                      value: root.display && root.isVirtual ? root.orientationOf(root.display) : "landscape"
                      foreground: root.foreground; background: root.background; accent: root.accent; fontFamily: root.fontFamily
                      focusable: false
                      onChanged: function(v) { if (root.display) root.setOrientation(root.display, v) }
                      onHovered: function(i, h) { if (h) { root.focusArea = "inspector"; root.currentRow = "vorient" } }
                    }
                  }
                }

                Row {
                  width: parent.width
                  spacing: Style.spacing.xl
                  visible: root.isVirtual && root.display !== null && root.virtualPresetOf(root.display) === "custom"
                  InspectorRow {
                    rowId: "vcustomw"
                    width: (parent.width - parent.spacing) / 2
                    NumberField {
                      id: customWidthField
                      label: "Width (pixels)"
                      value: root.display && root.isVirtual ? root.pixelsOf(root.display).width : 1920
                      from: 320; to: 8192; stepSize: 10
                      fieldWidth: parent.width
                      foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
                      hasCursor: root.focusArea === "inspector" && root.currentRow === "vcustomw"
                      onModified: function(v) { if (root.display) root.setCustomSize(root.display, v, root.pixelsOf(root.display).height) }
                      onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "vcustomw" } }
                    }
                  }
                  InspectorRow {
                    rowId: "vcustomh"
                    width: (parent.width - parent.spacing) / 2
                    NumberField {
                      id: customHeightField
                      label: "Height (pixels)"
                      value: root.display && root.isVirtual ? root.pixelsOf(root.display).height : 1080
                      from: 240; to: 8192; stepSize: 10
                      fieldWidth: parent.width
                      foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
                      hasCursor: root.focusArea === "inspector" && root.currentRow === "vcustomh"
                      onModified: function(v) { if (root.display) root.setCustomSize(root.display, root.pixelsOf(root.display).width, v) }
                      onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "vcustomh" } }
                    }
                  }
                }

                InspectorRow {
                  rowId: "vrefresh"
                  visible: root.isVirtual
                  Column {
                    width: parent.width; spacing: Style.spacing.labelGap
                    RowLabel { text: "Refresh" }
                    ButtonGroup {
                      options: [{ value: "30", label: "30 Hz" }, { value: "60", label: "60 Hz" }]
                      value: root.display ? String(root.refreshOfVirtual(root.display)) : "60"
                      foreground: root.foreground; background: root.background; accent: root.accent; fontFamily: root.fontFamily
                      focusable: false
                      onChanged: function(v) { if (root.display) root.setVirtualRefresh(root.display, Number(v)) }
                      onHovered: function(i, h) { if (h) { root.focusArea = "inspector"; root.currentRow = "vrefresh" } }
                    }
                  }
                }

                InspectorRow {
                  rowId: "mode"
                  visible: !root.isVirtual
                  // Two keyboard rows share this surface: the cursor sits on
                  // whichever dropdown the row name says.
                  hasCursor: root.focusArea === "inspector" && (root.currentRow === "mode" || root.currentRow === "refresh")
                  Row {
                    width: parent.width
                    spacing: Style.spacing.md
                    Dropdown {
                      id: resolutionDropdown
                      width: (parent.width - parent.spacing) * 0.58
                      label: "Resolution"
                      options: root.display ? Model.resolutionOptions(root.display) : []
                      value: root.display ? root.resolutionOf(root.display) : ""
                      foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
                      hasCursor: root.focusArea === "inspector" && root.currentRow === "mode"
                      onChanged: function(v) { if (root.display) root.setResolution(root.display, v) }
                      onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "mode" } }
                    }
                    Dropdown {
                      id: refreshDropdown
                      width: parent.width - x
                      label: "Refresh"
                      options: root.display ? Model.refreshOptions(root.display, root.resolutionOf(root.display)) : []
                      value: root.display ? root.modeOf(root.display) : ""
                      foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
                      hasCursor: root.focusArea === "inspector" && root.currentRow === "refresh"
                      onChanged: function(v) { if (root.display) root.setSizeField(root.display, "mode", v) }
                      onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "refresh" } }
                    }
                  }
                }

                InspectorRow {
                  rowId: "vrr"
                  visible: !root.isVirtual
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
                PanelSectionHeader { id: geometryHeader; text: "GEOMETRY"; foreground: root.foreground; fontFamily: root.fontFamily }

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
                          text: Model.formatScale(modelData.effective) + "x"
                          fontSize: Style.font.caption
                          foreground: root.foreground; fontFamily: root.fontFamily
                          horizontalPadding: Style.spacing.sm; verticalPadding: Style.spacing.controlPaddingY
                          bordered: true
                          active: root.display ? Model.sameScale(root.scaleOf(root.display), modelData.effective) : false
                          onClicked: if (root.display) root.setSizeField(root.display, "scale", modelData.effective)
                          onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "scale" } }
                        }
                      }
                    }
                  }
                }

                InspectorRow {
                  rowId: "rotation"
                  visible: !root.isVirtual
                  Column {
                    width: parent.width; spacing: Style.spacing.labelGap
                    RowLabel { text: "Rotation" }
                    ButtonGroup {
                      options: [{ value: "0", label: "0°" }, { value: "1", label: "90°" }, { value: "2", label: "180°" }, { value: "3", label: "270°" }]
                      value: root.display ? String(root.transformOf(root.display)) : "0"
                      foreground: root.foreground; background: root.background; accent: root.accent; fontFamily: root.fontFamily
                      focusable: false
                      onChanged: function(v) { if (root.display) root.setSizeField(root.display, "transform", Number(v)) }
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
                  // A mirror cannot be captured, and a virtual display is nobody's picture.
                  visible: !root.isVirtual
                  Column {
                    width: parent.width; spacing: Style.spacing.labelGap
                    RowLabel { text: "Mirror" }
                    ButtonGroup {
                      options: [{ value: "", label: "None" }].concat(root.displays.filter(function(o) { return root.display && o.name !== root.display.name && !o.virtual }).map(function(o) { return { value: o.name, label: o.name } }))
                      value: root.display ? root.mirrorOf(root.display) : ""
                      foreground: root.foreground; background: root.background; accent: root.accent; fontFamily: root.fontFamily
                      focusable: false
                      onChanged: function(v) { if (root.display) root.setMirror(root.display, v) }
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

                InspectorRow {
                  rowId: "vplace"
                  visible: root.isVirtual
                  Column {
                    width: parent.width; spacing: Style.spacing.labelGap
                    RowLabel { text: "Placement" }
                    ButtonGroup {
                      options: [{ value: "beside", label: "Beside your displays" }, { value: "apart", label: "Apart" }]
                      value: root.display ? Model.virtualPlacement(root.rects, root.display.name) : "apart"
                      foreground: root.foreground; background: root.background; accent: root.accent; fontFamily: root.fontFamily
                      focusable: false
                      onChanged: function(v) { if (root.display) root.setPlacement(root.display, v) }
                      onHovered: function(i, h) { if (h) { root.focusArea = "inspector"; root.currentRow = "vplace" } }
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: root.display && Model.virtualPlacement(root.rects, root.display.name) === "beside"
                        ? "Beside: the pointer and windows cross to it like any display."
                        : "Apart: the pointer cannot wander onto it, and network viewers can watch but not use it. Windows get there through the workspace plan or SUPER+SHIFT+number."
                      color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; width: parent.width
                    }
                  }
                }

                // ----- view: how a virtual display is seen. Each control acts
                // at once; none of them is part of the draft.
                PanelSeparator { visible: root.isVirtual; foreground: root.foreground }
                PanelSectionHeader { id: viewHeader; visible: root.isVirtual; text: "VIEW"; foreground: root.foreground; fontFamily: root.fontFamily }

                InspectorRow {
                  rowId: "vwindow"
                  visible: root.isVirtual
                  Toggle {
                    width: parent.width
                    label: "In a window on this desk"
                    description: root.virtualViewCaption()
                    checked: root.previewOpen
                    foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
                    hasCursor: root.focusArea === "inspector" && root.currentRow === "vwindow"
                    onClicked: if (root.display && root.service) root.service.togglePreview(root.display.name)
                    onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "vwindow" } }
                  }
                }

                InspectorRow {
                  rowId: "vnetwork"
                  visible: root.isVirtual
                  Toggle {
                    width: parent.width
                    label: "On the network"
                    description: !root.virtualState.wayvnc ? "For a tablet or another computer. It needs wayvnc, which is not installed yet."
                      : !root.virtualNetwork.on && root.display && !root.enabledOf(root.display) ? "The display is off. Switch it on to offer it on the network."
                      : root.virtualNetwork.on
                        ? "Encrypted (RSA-AES), behind a username and password. "
                          + (root.virtualNetwork.input ? "Viewers can use it." : "Watch-only while it sits apart, so a viewer can never leave your pointer out of reach: place it beside your displays to let them use it.")
                      : "Off. For a tablet or another computer on your network, which needs a VNC viewer app to show it."
                    checked: root.virtualNetwork.on === true
                    // A display that is off is never served (it would be a real one).
                    enabled: root.virtualState.wayvnc === true && root.display !== null && (root.enabledOf(root.display) || root.virtualNetwork.on === true)
                    opacity: enabled ? 1 : 0.6
                    foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
                    hasCursor: root.focusArea === "inspector" && root.currentRow === "vnetwork"
                    onClicked: if (root.display && root.service && enabled) root.service.virtualView(root.display.name, "network", !root.virtualNetwork.on)
                    onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "vnetwork" } }
                  }
                }

                // How to connect, step by step, while network viewing is on.
                // Not a keyboard row: there is nothing to press in it.
                Column {
                  visible: root.isVirtual && root.virtualNetwork.on === true
                  width: parent.width
                  spacing: Style.spacing.xs
                  leftPadding: Style.spacing.md
                  RowLabel { text: "How to connect" }
                  Repeater {
                    model: [
                      "1. On the other device, install a VNC viewer: RealVNC Viewer (iPad, iPhone, Android, Mac, Windows), bVNC (Android) or TigerVNC (Mac, Windows, Linux). macOS's own Screen Sharing cannot connect securely.",
                      "2. Copy the password onto that device first: Show it below and scan the QR code. The login must be finished within 30 seconds of connecting.",
                      "3. Connect to " + (root.virtualNetwork.address || "") + ":" + (root.virtualNetwork.port || "") + " with the username candela, paste the password, and let the app remember it."
                    ]
                    Text {
                      required property var modelData
                      width: parent.width - Style.spacing.md
                      textFormat: Text.PlainText
                      text: modelData
                      color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
                    }
                  }
                  Text {
                    visible: root.virtualNetwork.firewall === "blocked"
                    width: parent.width - Style.spacing.md
                    textFormat: Text.PlainText
                    text: "Your firewall drops connections to this port, so no device can reach it yet. To let your network in, run this in a terminal as root: " + (root.virtualNetwork.firewallAllow || "")
                    color: root.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; wrapMode: Text.WrapAnywhere
                  }
                }

                InspectorRow {
                  rowId: "vinstall"
                  visible: root.isVirtual && root.virtualState.wayvnc !== true
                  Column {
                    width: parent.width; spacing: Style.spacing.labelGap
                    Button {
                      text: "Install wayvnc"
                      bordered: true
                      foreground: root.foreground; fontFamily: root.fontFamily
                      hasCursor: root.focusArea === "inspector" && root.currentRow === "vinstall"
                      onClicked: if (root.service) root.service.installWayvnc()
                      onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "vinstall" } }
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: "Opens a terminal with Omarchy's installer, which asks for your password. Only network viewing needs it."
                      color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; width: parent.width
                    }
                  }
                }

                InspectorRow {
                  rowId: "vaddress"
                  visible: root.isVirtual && root.virtualNetwork.on === true
                  Column {
                    width: parent.width; spacing: Style.spacing.labelGap
                    RowLabel { text: "Address · port " + (root.virtualNetwork.port || "") }
                    ButtonGroup {
                      options: (root.virtualState.addresses || []).map(function(a) { return { value: a.address, label: a.address + " · " + a.interface } })
                      value: root.virtualNetwork.address || ""
                      foreground: root.foreground; background: root.background; accent: root.accent; fontFamily: root.fontFamily
                      focusable: false
                      // Only a different address restarts the server, which drops whoever is connected.
                      onChanged: function(v) { if (root.display && root.service && v !== root.virtualNetwork.address) root.service.virtualView(root.display.name, "network", true, ["--address", v]) }
                      onHovered: function(i, h) { if (h) { root.focusArea = "inspector"; root.currentRow = "vaddress" } }
                    }
                  }
                }

                InspectorRow {
                  rowId: "vsecret"
                  visible: root.isVirtual && root.virtualNetwork.on === true
                  Column {
                    width: parent.width
                    spacing: Style.spacing.md
                    readonly property bool shown: root.service && root.display && root.service.virtualSecretFor === root.display.name && !!root.service.virtualSecret
                    Item {
                      width: parent.width
                      implicitHeight: Math.max(secretText.implicitHeight, secretButton.implicitHeight)
                      readonly property bool shown: parent.shown
                      Text {
                        id: secretText
                        textFormat: Text.PlainText
                        text: "Username candela · password " + (parent.shown ? root.service.virtualSecret.password : "••••••••••••••••")
                        color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
                        anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                      }
                      Button {
                        id: secretButton
                        text: parent.shown ? "Hide" : "Show"
                        bordered: true
                        foreground: root.foreground; fontFamily: root.fontFamily
                        hasCursor: root.focusArea === "inspector" && root.currentRow === "vsecret"
                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        onClicked: if (root.display && root.service) root.service.showVirtualSecret(root.display.name)
                        onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "vsecret" } }
                      }
                    }
                    // The password as a QR code, for the tablet's camera to copy:
                    // the login has to be finished within 30 seconds of connecting,
                    // which is too short to type it there. Dark on white whatever
                    // the theme, because that is what cameras read.
                    Row {
                      visible: parent.shown && !!root.service.virtualSecret.qr
                      spacing: Style.spacing.xl
                      Rectangle {
                        width: Style.space(176); height: width
                        color: "white"
                        Image {
                          anchors.fill: parent
                          anchors.margins: Style.space(4)
                          smooth: false
                          fillMode: Image.PreserveAspectFit
                          source: parent.parent.visible ? "data:image/png;base64," + root.service.virtualSecret.qr : ""
                        }
                      }
                      Text {
                        width: Style.space(200)
                        anchors.verticalCenter: parent.verticalCenter
                        textFormat: Text.PlainText
                        text: "Scan it with the tablet's camera and copy the password. Then connect, enter the username candela, paste it, and let the app remember it: the login must be finished within 30 seconds of connecting."
                        color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
                      }
                    }
                  }
                }

                InspectorRow {
                  rowId: "vlogin"
                  visible: root.isVirtual && root.virtualNetwork.on === true
                  Column {
                    width: parent.width; spacing: Style.spacing.md
                    Toggle {
                      width: parent.width
                      label: "Offer it again at login"
                      description: root.virtualNetwork.atLogin ? "It is back on the network every time you log in." : "Off: after a login it is only on this desk until you turn this on."
                      checked: root.virtualNetwork.atLogin === true
                      foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
                      hasCursor: root.focusArea === "inspector" && root.currentRow === "vlogin"
                      onClicked: if (root.display && root.service) root.service.virtualView(root.display.name, "network", true, ["--at-login", root.virtualNetwork.atLogin ? "no" : "yes"])
                      onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "vlogin" } }
                    }
                    Repeater {
                      model: root.virtualNetwork.clients || []
                      Item {
                        required property var modelData
                        width: parent.width
                        implicitHeight: Math.max(clientText.implicitHeight, clientButton.implicitHeight)
                        Text { id: clientText; textFormat: Text.PlainText; text: (modelData.address || "a client") + " is connected"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter }
                        Button {
                          id: clientButton
                          text: "Disconnect"; bordered: true; fontSize: Style.font.caption
                          foreground: root.foreground; fontFamily: root.fontFamily
                          anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                          onClicked: if (root.display && root.service) root.service.virtualDisconnect(root.display.name, modelData.id)
                        }
                      }
                    }
                  }
                }

                InspectorRow {
                  rowId: "vremove"
                  visible: root.isVirtual
                  Button {
                    readonly property bool armed: root.display !== null && root.removeArmedFor === root.display.name
                    text: armed ? "Press again to remove " + root.display.name : "Remove " + (root.display ? root.display.name : "")
                    bordered: true
                    foreground: armed ? root.urgent : root.foreground; fontFamily: root.fontFamily
                    hasCursor: root.focusArea === "inspector" && root.currentRow === "vremove"
                    onClicked: root.removeVirtual(root.display)
                    onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "vremove" } }
                  }
                }

                // ----- colour
                PanelSeparator { visible: root.caps.available === true; foreground: root.foreground }
                PanelSectionHeader { id: colourHeader; visible: root.caps.available === true; text: "COLOUR"; foreground: root.foreground; fontFamily: root.fontFamily }

                InspectorRow {
                  rowId: "colour"
                  visible: root.caps.available === true
                  Column {
                    width: parent.width; spacing: Style.spacing.labelGap
                    ButtonGroup {
                      options: root.display ? Model.offeredModes(root.caps, root.colourIntent(root.display)).map(function(m) { return { value: m, label: m === "sdr" ? "SDR" : (m === "wide" ? "Wide" : "HDR") } }) : []
                      value: root.display ? root.colourOf(root.display) : "sdr"
                      foreground: root.foreground; background: root.background; accent: root.accent; fontFamily: root.fontFamily
                      focusable: false
                      onChanged: function(v) { if (root.display) root.setColour(root.display, v) }
                      onHovered: function(i, h) { if (h) { root.focusArea = "inspector"; root.currentRow = "colour" } }
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: root.display ? root.hdrReasonSentence(root.display) : ""
                      visible: text !== ""
                      color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; width: parent.width
                    }
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
                    Text { textFormat: Text.PlainText; text: root.display ? Model.sdrWhiteClientNote(root.sdrWhiteOf(root.display), false) : ""; visible: text !== ""; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; width: parent.width }
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
                    readonly property bool hdrDraft: root.display && root.colourOf(root.display) === "hdr"
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
                      enabled: !parent.hdrDraft
                      opacity: enabled ? 1 : 0.45
                      onChanged: function(v) { if (root.display) root.setField(root.display.name, "icc", v) }
                      onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "icc" } }
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: parent.hdrDraft ? "Clear HDR to load an ICC profile." : "A profile forces the sRGB transfer and replaces the colour preset. HDR is unavailable while one is loaded."
                      color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; width: parent.width
                    }
                  }
                }

                // ----- workspaces: the selected display's share of the plan.
                // The plan itself is the strip under the canvas.
                PanelSeparator { visible: workspacesHeader.visible; foreground: root.foreground }
                PanelSectionHeader { id: workspacesHeader; visible: root.planOn || (!root.planDirty && root.savedMovesNow.length > 0); text: "WORKSPACES"; foreground: root.foreground; fontFamily: root.fontFamily }

                InspectorRow {
                  rowId: "wshomes"
                  visible: root.planOn
                  Column {
                    width: parent.width; spacing: Style.spacing.labelGap
                    Item {
                      width: parent.width; implicitHeight: homesLabel.implicitHeight
                      RowLabel { id: homesLabel; text: "Lives on " + (root.display ? root.display.name : ""); anchors.left: parent.left }
                      Text {
                        textFormat: Text.PlainText
                        text: (root.display ? Model.homesOn(root.plan.homes, root.display.name).length : 0) + " of 10"
                        color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true
                        anchors.right: parent.right
                      }
                    }
                    Grid {
                      id: homesGrid
                      width: parent.width
                      columns: Model.WORKSPACE_IDS.length
                      spacing: Style.spacing.xs
                      readonly property real cellWidth: (width - spacing * (columns - 1)) / columns
                      Repeater {
                        model: Model.WORKSPACE_IDS
                        Button {
                          required property var modelData
                          required property int index
                          readonly property string home: root.plan.homes[String(modelData)] || ""
                          readonly property bool here: root.display !== null && home === root.display.name
                          width: homesGrid.cellWidth
                          text: Model.workspaceLabel(modelData)
                          fontSize: Style.font.caption
                          foreground: root.foreground; fontFamily: root.fontFamily
                          horizontalPadding: 0; verticalPadding: Style.spacing.controlPaddingY
                          bordered: true
                          active: here
                          hasCursor: root.focusArea === "inspector" && root.currentRow === "wshomes" && root.wsPillIndex === index
                          enabled: root.displayCanBeHome
                          // Homed on another display: there, but quieter.
                          opacity: !enabled ? 0.45 : (home !== "" && !here ? 0.6 : 1)
                          tooltipText: home === "" ? "No home: opens where focus is" : (here ? "Lives here" : "Lives on " + home)
                          onClicked: { root.wsPillIndex = index; if (root.display) root.toggleHome(root.display, modelData) }
                          onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "wshomes"; root.wsPillIndex = index } }
                        }
                      }
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: root.homesCaption(root.display)
                      visible: text !== ""
                      color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; width: parent.width
                    }
                  }
                }

                InspectorRow {
                  rowId: "wsshows"
                  visible: root.planOn && root.display !== null && Model.homesOn(root.plan.homes, root.display.name).length > 0
                  Column {
                    width: parent.width; spacing: Style.spacing.labelGap
                    RowLabel { text: "Shows when it lights up" }
                    ButtonGroup {
                      options: root.display ? Model.homesOn(root.plan.homes, root.display.name).map(function(id) { return { value: String(id), label: Model.workspaceLabel(id) } }) : []
                      value: root.display ? (Model.effectiveShows(root.plan.homes, root.plan.shows)[root.display.name] || "") : ""
                      foreground: root.foreground; background: root.background; accent: root.accent; fontFamily: root.fontFamily
                      focusable: false
                      onChanged: function(v) { if (root.display) root.setShow(root.display, v) }
                      onHovered: function(i, h) { if (h) { root.focusArea = "inspector"; root.currentRow = "wsshows" } }
                    }
                  }
                }

                InspectorRow {
                  rowId: "wssend"
                  visible: !root.planDirty && root.savedMovesNow.length > 0
                  Column {
                    width: parent.width; spacing: Style.spacing.labelGap
                    Button {
                      text: "Send open workspaces home"
                      bordered: true
                      foreground: root.foreground; fontFamily: root.fontFamily
                      hasCursor: root.focusArea === "inspector" && root.currentRow === "wssend"
                      onClicked: if (root.service) root.service.sendWorkspacesHome()
                      onHovered: function(h) { if (h) { root.focusArea = "inspector"; root.currentRow = "wssend" } }
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: Model.planSummary(Model.planKind(root.savedPlan.homes, root.rects), root.savedMovesNow).replace(/^Plan [A-Za-z]+ · m/, "M") + ". The plan itself does not change."
                      color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; width: parent.width
                    }
                  }
                }

                // ----- advanced
                PanelSeparator { visible: root.caps.available === true; foreground: root.foreground }

                InspectorRow {
                  id: advancedSection
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
                    DecimalField {
                      id: minLumField
                      label: "Min cd/m²"
                      value: root.display ? (isNaN(root.lumOf(root.display, "min_luminance")) ? root.edidLum("min_luminance") : root.lumOf(root.display, "min_luminance")) : 0
                      from: 0; to: 100
                      foreground: root.foreground; accent: root.accent; fontFamily: root.fontFamily
                      hasCursor: root.focusArea === "inspector" && root.currentRow === "minlum"
                      onModified: function(v) { if (root.display) root.setField(root.display.name, "min_luminance", v) }
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
                      onChanged: function(v) { if (root.display) { root.setField(root.display.name, "supports_hdr", Number(v)); root.reconcileColour(root.display) } }
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
                      onChanged: function(v) { if (root.display) { root.setField(root.display.name, "supports_wide_color", Number(v)); root.reconcileColour(root.display) } }
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
            implicitHeight: root.hasPending
              ? applyBar.implicitHeight + pendingHint.implicitHeight + Style.spacing.xs
              : Math.max(hintText.implicitHeight, actionButtons.implicitHeight) + Style.spacing.md

            ApplyBar {
              id: applyBar
              visible: root.hasPending
              width: parent.width
              anchors.top: parent.top
              remaining: root.service ? root.service.pendingRemaining : 0
              total: root.service ? root.service.revertSeconds : 15
              foreground: root.foreground
              fontFamily: root.fontFamily
              cursorIndex: root.focusArea === "actions" ? Math.min(1, root.actionIndex) : -1
              summary: root.service ? root.service.pendingSummary : "Display settings changed"
              phase: root.service ? root.service.operationPhase : "previewing"
              error: root.service ? root.service.recoveryError : ""
              reducedMotion: root.reducedMotion
              onKeep: root.service.keep()
              onRevert: root.service.revert()
              onHovered: function(index, h) { if (h) { root.focusArea = "actions"; root.actionIndex = index } }
            }

            // Pending mode's own keyboard hint, same style as the normal
            // bar's, printed under the strip instead of sharing its row.
            Text {
              id: pendingHint
              visible: root.hasPending
              textFormat: Text.PlainText
              text: "↵ keep · r revert · esc revert"
              color: root.dim
              font.family: root.fontFamily; font.pixelSize: Style.font.caption
              anchors.top: applyBar.bottom
              anchors.topMargin: Style.spacing.xs
              anchors.left: parent.left
            }

            Rectangle { visible: !root.hasPending; width: parent.width; height: 1; color: Util.alpha(root.foreground, 0.12); anchors.top: parent.top }

            Text {
              id: hintText
              visible: !root.hasPending
              textFormat: Text.PlainText
              // Non-breaking spaces inside each pair: the strip wraps at the
              // separators, never between a key and what it does.
              text: ["?\u00A0all\u00A0keys"].concat(root.focusArea === "inspector" && root.rowChanged(root.currentRow) ? ["⌫\u00A0reset\u00A0row"] : []).concat(["j/k\u00A0rows", "h/l\u00A0adjust",
                     "⇥ canvas ⇄ workspaces ⇄ inspector ⇄ actions", "w\u00A0workspaces",
                     "arrows nudge 10 px, ⇧ 100, ⌥ flush beside",
                     "0\u00A0origin", "1–9\u00A0[\u00A0]\u00A0select",
                     "a\u00A0apply", "r\u00A0" + (root.draftDirty ? "discard" : (root.service && root.service.undoAvailable && !root.hasPending ? "undo\u00A0" + root.service.undoWhat : "revert")),
                     "i\u00A0identify", "esc\u00A0close"]).join(" · ")
              color: root.dim
              font.family: root.fontFamily; font.pixelSize: Style.font.caption
              anchors.left: parent.left; anchors.right: actionButtons.left; anchors.rightMargin: Style.space(16)
              anchors.verticalCenter: actionButtons.verticalCenter
              // Two lines rather than one elided one: a keyboard surface that
              // hides half its own keys behind an ellipsis teaches nothing.
              wrapMode: Text.WordWrap
              maximumLineCount: 2
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
                // Says what it would do: discard the draft, revert the countdown,
                // or undo the last change kept at once, while that lasts.
                readonly property bool undoes: !root.draftDirty && !root.hasPending && root.service !== null && root.service.undoAvailable
                text: root.draftDirty ? "Discard" : (undoes ? "Undo" : "Revert"); bordered: true
                tooltipText: undoes ? "Undo " + root.service.undoWhat + " (" + root.service.undoRemaining + " s left)" : ""
                enabled: root.draftDirty || root.hasPending || (root.service !== null && root.service.undoAvailable)
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

      // ---------- key sheet (?) ----------
      Rectangle {
        id: keySheet
        anchors.fill: keyScope
        visible: root.helpOpen
        color: root.background
        MouseArea { anchors.fill: parent; onClicked: root.helpOpen = false }
        Column {
          anchors.fill: parent
          spacing: Style.spacing.panelGap
          Item {
            width: parent.width
            implicitHeight: sheetTitle.implicitHeight
            Text { id: sheetTitle; textFormat: Text.PlainText; text: "Keys"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.heading; font.bold: true; anchors.left: parent.left }
            Text { textFormat: Text.PlainText; text: "? or esc to close"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; anchors.right: parent.right; anchors.verticalCenter: sheetTitle.verticalCenter }
          }
          Flow {
            id: sheetFlow
            width: parent.width
            spacing: Style.space(32)
            readonly property real columnWidth: (width - spacing) / 2
            Repeater {
              model: root.keySections
              delegate: Column {
                id: sheetSection
                required property var modelData
                width: sheetFlow.columnWidth
                spacing: Style.spacing.xs
                RowLabel { text: sheetSection.modelData.title }
                Repeater {
                  model: sheetSection.modelData.keys
                  delegate: Row {
                    id: sheetRow
                    required property var modelData
                    spacing: Style.spacing.md
                    Text { textFormat: Text.PlainText; text: sheetRow.modelData[0]; width: Style.space(120); color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
                    Text { textFormat: Text.PlainText; text: sheetRow.modelData[1]; width: sheetFlow.columnWidth - Style.space(120) - Style.spacing.md; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                  }
                }
              }
            }
          }
          Text { textFormat: Text.PlainText; text: "A mark in a row's left margin means the draft changes it; click the mark or press ⌫ to put that row back."; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap; width: parent.width }
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
    // A row that grows under the cursor (the SDR white note appearing) must
    // stay in view, so follow it again once the layout has settled.
    onHeightChanged: if (hasCursor) Qt.callLater(function() { root.ensureRowVisible(irow) })
    // The changed mark: an accent rule in the row's left margin while the
    // draft touches this row. Clicking it, or ⌫ on the row, resets the row.
    readonly property bool changed: root.rowChanged(rowId)
    Rectangle {
      visible: irow.changed
      width: Math.max(2, Style.space(2))
      radius: width / 2
      x: Math.round((Style.spacing.md - width) / 2)
      anchors.top: parent.top; anchors.bottom: parent.bottom
      anchors.topMargin: Style.spacing.md; anchors.bottomMargin: Style.spacing.md
      color: root.accent
    }
    MouseArea {
      visible: irow.changed && !root.applyInFlight
      width: Style.spacing.md
      height: parent.height
      cursorShape: Qt.PointingHandCursor
      onClicked: { root.focusArea = "inspector"; root.currentRow = irow.rowId; root.resetRow(irow.rowId) }
    }
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
