// Stand-in for the shell's qs.Commons singletons, only what the components under test read.
pragma Singleton
import QtQuick
QtObject { property color foreground: "#ddd"; property color accent: "#4af"; property color urgent: "#f55" }
