import QtQuick
import qs.Commons

Item {
  id: root

  property QtObject bar: null
  property string text: ""
  property string tooltipText: ""
  property bool active: false
  property real horizontalMargin: 8.5

  signal pressed(int buttonCode)

  implicitWidth: label.implicitWidth + horizontalMargin * 2
  implicitHeight: Style.bar.sizeHorizontal

  Text {
    id: label
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: root.text
    color: root.active ? Color.urgent : Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    onClicked: function (event) { root.pressed(event.button) }
  }
}
