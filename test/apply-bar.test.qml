// Offscreen check of components/ApplyBar.qml: the wording per phase, the
// summary in the caption, and the failed phase showing the recovery error
// without a countdown. Run by test/qml-test.sh.
import QtQuick
import QtQuick.Window
import "../components"
Window {
  width: 700; height: 300; visible: true
  ApplyBar { id: wide; width: 600; remaining: 12; total: 15; summary: "DP-2: mode"; phase: "previewing" }
  ApplyBar { id: narrow; width: 300; remaining: 12; total: 15; summary: "DP-2: mode"; phase: "previewing" }
  function title(bar) { return bar.children[0].children[0].children[0].text }
  function caption(bar) { return bar.children[0].children[0].children[1].text }
  function countdownVisible(bar) { return bar.children[1].visible }
  Component.onCompleted: {
    var failed = 0
    function check(name, got, want) { var ok = got === want; if (!ok) failed++; console.warn((ok ? "ok   " : "FAIL ") + name + " " + JSON.stringify(got) + (ok ? "" : " wanted " + JSON.stringify(want))) }
    check("wide title asks the question", title(wide), "Keep these settings?")
    check("narrow title is the short question", title(narrow), "Keep changes?")
    check("caption carries countdown and summary", caption(wide), "Reverting in 12 s unless kept · DP-2: mode")
    check("countdown rule shows while previewing", countdownVisible(wide), true)
    wide.phase = "saving"
    check("saving caption", caption(wide), "Saving…")
    wide.phase = "failed"; wide.error = "Hyprland reports config errors: x\n   continued"
    check("failed title", title(wide), "Display change failed")
    check("failed caption names the choices and the error on one line", caption(wide), "Keep retries · Revert restores · Hyprland reports config errors: x continued")
    check("no countdown rule behind a failed change", countdownVisible(wide), false)
    console.warn(failed ? "QML FAILURES " + failed : "QML PASSED")
    Qt.exit(failed ? 1 : 0)
  }
}
