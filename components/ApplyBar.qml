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
  // Inside a popup or the studio the strip draws its own frame and fill. On a
  // floating card of its own (the service's every-screen strip) the card is
  // the frame, and a second one inside it reads as clutter.
  property bool bare: false

  signal keep()
  signal revert()
  signal hovered(int index, bool isHovered)

  // Narrow hosts (the 380 px popup) shorten the wording; the countdown rule
  // itself is drawn on the strip's own bottom edge, so it fits any width.
  readonly property bool compact: width < Style.space(420)

  readonly property real fraction: total > 0 ? Math.max(0, Math.min(1, remaining / total)) : 0
  // The last few seconds are the ones worth noticing. Nothing moves faster —
  // only the colour changes, so the strip warns without flapping.
  readonly property bool urgentSoon: remaining <= 5

  implicitHeight: content.implicitHeight + (bare ? Style.spacing.md : Style.spacing.xl) * 2
  radius: Style.cornerRadius
  color: bare ? "transparent" : Style.hoverFillFor(foreground, Color.accent)
  borderSpec: bare ? Border.none() : Border.controlSpec("hover-cursor", foreground, Color.accent)

  Row {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: root.bare ? 0 : Style.spacing.rowPaddingX
    anchors.rightMargin: root.bare ? 0 : Style.spacing.rowPaddingX
    spacing: Style.spacing.rowPaddingX

    Column {
      width: parent.width - buttons.width - parent.spacing
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
        color: root.urgentSoon ? Color.urgent : Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        width: parent.width

        Behavior on color { ColorAnimation { duration: 400 } }
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

  // The countdown reads as part of the strip's own bottom edge rather than as
  // a widget parked next to the buttons: a rule that drains left to right for
  // the whole width of whatever is holding it. The backend owns the clock and
  // reports whole seconds, so the animation carries the eye between ticks.
  Item {
    id: countdown
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: root.borderBottom
    height: Math.max(1, Style.space(2))
    visible: root.remaining > 0 || root.fraction > 0

    Rectangle {
      anchors.fill: parent
      color: Style.selectedFillFor(root.foreground, Color.accent)
      opacity: 0.5
    }

    Rectangle {
      height: parent.height
      width: parent.width * root.fraction
      color: root.urgentSoon ? Color.urgent : Color.accent

      Behavior on width { NumberAnimation { duration: 1000; easing.type: Easing.Linear } }
      Behavior on color { ColorAnimation { duration: 400 } }
    }
  }
}
