import QtQuick
import qs.Commons
import qs.Ui

// "Keep these settings?" strip shown while an apply is pending. The same
// component sits in the popup and the studio. The countdown itself runs in
// the backend's detached timer; this only draws what the service reports.
BorderSurface {
  id: root

  property int remaining: 0
  property int total: 15
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  // Panel-cursor index: 0 = Revert, 1 = Keep, -1 = none.
  property int cursorIndex: -1

  signal keep()
  signal revert()
  signal hovered(int index, bool isHovered)

  // Narrow hosts (the 380 px popup) drop the progress line and keep the
  // countdown in words; the studio's action bar has room for both.
  readonly property bool compact: width < Style.space(420)

  implicitHeight: content.implicitHeight + Style.spacing.xl * 2
  radius: Style.cornerRadius
  color: Style.hoverFillFor(foreground, Color.accent)
  borderSpec: Border.controlSpec("hover-cursor", foreground, Color.accent)

  Row {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.spacing.rowPaddingX
    anchors.rightMargin: Style.spacing.rowPaddingX
    spacing: Style.spacing.rowPaddingX

    Column {
      width: parent.width - buttons.width - (progress.visible ? progress.width + parent.spacing : 0) - parent.spacing
      spacing: Style.spacing.xs
      anchors.verticalCenter: parent.verticalCenter

      Text {
        textFormat: Text.PlainText
        text: root.compact ? "Keep changes?" : "Keep these settings?"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
        elide: Text.ElideRight
        width: parent.width
      }

      Text {
        textFormat: Text.PlainText
        text: "Reverting in " + root.remaining + " s unless kept."
        color: Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        width: parent.width
      }
    }

    Item {
      id: progress
      visible: !root.compact
      width: visible ? Style.space(70) : 0
      height: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter

      Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Style.selectedFillFor(root.foreground, Color.accent)
      }

      Rectangle {
        height: parent.height
        radius: height / 2
        color: Color.accent
        width: parent.width * (root.total > 0 ? Math.max(0, Math.min(1, root.remaining / root.total)) : 0)
        Behavior on width { NumberAnimation { duration: 900; easing.type: Easing.Linear } }
      }
    }

    Row {
      id: buttons
      spacing: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter

      Button {
        text: "Revert"
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.body
        hasCursor: root.cursorIndex === 0
        onClicked: root.revert()
        onHovered: function(h) { root.hovered(0, h) }
      }

      Button {
        text: "Keep"
        bordered: true
        active: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.body
        hasCursor: root.cursorIndex === 1
        onClicked: root.keep()
        onHovered: function(h) { root.hovered(1, h) }
      }
    }
  }
}
