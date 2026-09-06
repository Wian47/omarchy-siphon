import QtQuick
import qs.Commons

Rectangle {
  property color foreground: Color.foreground
  property real strength: 0.12
  implicitHeight: 1
  height: 1
  color: Qt.rgba(foreground.r, foreground.g, foreground.b, strength)
}
