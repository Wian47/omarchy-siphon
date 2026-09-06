import QtQuick
import qs.Commons

Item {
  id: root

  property Component iconComponent: null
  property string title: ""
  property string meta: ""
  property string detail: ""
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property Component trailingControl: null

  readonly property color dim: Qt.darker(foreground, 1.4)

  implicitHeight: Math.max(iconLoader.implicitHeight, labels.implicitHeight, trailing.implicitHeight)

  Loader {
    id: iconLoader
    sourceComponent: root.iconComponent
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
  }

  Column {
    id: labels
    anchors.left: iconLoader.right
    anchors.leftMargin: Style.space(14)
    anchors.right: parent.right
    anchors.rightMargin: trailing.width + Style.space(12)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    Text {
      textFormat: Text.PlainText
      width: parent.width
      elide: Text.ElideRight
      text: root.title
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      elide: Text.ElideRight
      text: root.meta.toUpperCase()
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2
    }
  }

  Loader {
    id: trailing
    sourceComponent: root.trailingControl
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
  }
}
