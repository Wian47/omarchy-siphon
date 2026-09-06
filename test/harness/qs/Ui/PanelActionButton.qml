import QtQuick
import qs.Commons

Rectangle {
  id: root

  property string iconText: ""
  property string tooltipText: ""
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.icon
  property real size: Style.space(22)

  signal clicked()

  implicitWidth: size
  implicitHeight: size
  width: size
  height: size
  color: "transparent"

  Text {
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: root.iconText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
  }

  MouseArea {
    anchors.fill: parent
    onClicked: root.clicked()
  }
}
