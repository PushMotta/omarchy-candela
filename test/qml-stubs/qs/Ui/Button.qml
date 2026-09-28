// Stand-in for the shell's Button: the properties and signals ApplyBar uses.
import QtQuick
Item {
  property string text: ""; property bool bordered: false; property bool active: false; property bool hasCursor: false
  property color foreground: "#ddd"; property string fontFamily: ""; property int fontSize: 13
  signal clicked(); signal hovered(bool h)
  implicitWidth: 60; implicitHeight: 24; width: implicitWidth; height: implicitHeight
}
