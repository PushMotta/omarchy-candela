// Offscreen check of components/DecimalField.qml: a TextField's text binding
// breaks the first time the user types, so a value that arrives afterwards
// (another display selected, a draft cleared) must be pushed in by hand,
// but never over text the user is editing. Run by test/qml-test.sh.
import QtQuick
import QtQuick.Window
import "../components"
Window {
  width: 300; height: 200; visible: true
  DecimalField { id: f; width: 200; value: 0.2; from: 0; to: 100 }
  Component.onCompleted: {
    var failed = 0
    function check(name, got, want) { var ok = got === want; if (!ok) failed++; console.warn((ok ? "ok   " : "FAIL ") + name + " " + JSON.stringify(got) + (ok ? "" : " wanted " + JSON.stringify(want))) }
    check("initial text", f.field.text, "0.2")
    f.field.text = "0.5"                 // what typing does: an assignment that breaks the binding
    f.value = 0.125                      // another display was selected
    check("a new value reaches an unfocused field", f.field.text, "0.125")
    f.field.forceActiveFocus()
    f.field.text = "0.7"                 // the user is mid-edit
    f.value = 0.3
    check("a new value leaves a focused edit alone", f.field.text, "0.7")
    f.field.text = "abc"; f.field.editingFinished()
    check("invalid input snaps back to the value", f.field.text, "0.3")
    console.warn(failed ? "QML FAILURES " + failed : "QML PASSED")
    Qt.exit(failed ? 1 : 0)
  }
}
