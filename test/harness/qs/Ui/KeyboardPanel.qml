import QtQuick
import qs.Commons

Item {
  id: root

  property Item anchorItem: null
  property QtObject bar: null
  property var owner: null
  property var focusTarget: null
  property bool open: false
  property int padding: Style.space(12)
  property int contentWidth: Style.space(280)
  property int contentHeight: Style.space(200)

  default property alias content: body.data

  function fittedContentWidth(want) { return want }
  function fittedContentHeight(want, cap) { return Math.min(want, cap) }

  width: contentWidth + padding * 2
  height: contentHeight + padding * 2

  Rectangle {
    anchors.fill: parent
    radius: Style.space(8)
    color: "#11151c"
  }

  Item {
    id: body
    x: root.padding
    y: root.padding
    width: root.contentWidth
    height: root.contentHeight
  }
}
