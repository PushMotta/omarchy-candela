import QtQuick
import QtQuick.Controls
import qs.Commons

Column {
  id: root
  property string label: ""
  property real value: 0
  property bool hasCursor: false
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property alias field: input
  property real from: 0
  property real to: 100
  property alias validatorLocale: numberValidator.locale
  signal modified(real value)
  signal hovered(bool hovered)
  function formatted() { return root.value.toFixed(3).replace(/0+$/, "").replace(/\.$/, "") }
  // Typing breaks the text binding below, so a value that arrives afterwards
  // (another display selected, a draft cleared) has to be pushed in by hand.
  onValueChanged: if (!input.activeFocus) input.text = formatted()
  spacing: Style.spacing.labelGap
  Text { text: root.label; color: Qt.darker(root.foreground, 1.4); font.family: root.fontFamily; font.pixelSize: Style.font.caption }
  TextField {
    id: input
    objectName: "decimalLuminanceField"
    width: parent.width
    text: root.formatted()
    color: root.foreground; font.family: root.fontFamily; selectByMouse: true
    validator: DoubleValidator { id: numberValidator; bottom: root.from; top: root.to; decimals: 3; notation: DoubleValidator.StandardNotation }
    Accessible.name: root.label
    onEditingFinished: {
      var n = Number(text.replace(",", "."))
      if (acceptableInput && isFinite(n) && n >= root.from && n <= root.to) root.modified(n)
      else text = root.formatted()
    }
    background: Rectangle { color: "transparent"; radius: Style.cornerRadius; border.width: root.hasCursor || input.activeFocus ? 2 : 1; border.color: root.hasCursor || input.activeFocus ? root.accent : Qt.darker(root.foreground, 1.8) }
    HoverHandler { onHoveredChanged: root.hovered(hovered) }
  }
}
