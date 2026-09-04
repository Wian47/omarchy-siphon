import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar icon plus popup listing which applications are using the network.
//
// The list is ranked by what is moving now rather than by session total, so
// the row at the top is the answer to "what is slowing this down" at the
// moment the panel is opened.
Panel {
  id: root

  moduleName: "wian47.siphon"
  ipcTarget: "siphon"
  manageIpc: true

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool vertical: bar ? bar.vertical : false
  readonly property string labelMode: vertical ? "none" : String(setting("barLabel", "total"))
  readonly property string barLabel: Model.barLabel(root.live, labelMode)
  readonly property string barTooltip: Model.summary(root.live)

  readonly property var apps: traffic ? traffic.apps : []
  readonly property real warnRate: traffic ? traffic.warnBytesPerSecond : 0
  readonly property bool overThreshold: warnRate > 0 && apps.length > 0
    && (apps[0].rxRate + apps[0].txRate) >= warnRate

  // The bar sizes a widget from its implicit size, and the button inside the
  // Loader is the only thing that knows how wide a label makes it.
  implicitWidth: button.item ? button.item.implicitWidth : 0
  implicitHeight: button.item ? button.item.implicitHeight : (bar ? bar.barSize : Style.bar.sizeHorizontal)

  // The shell loads a plugin's "service" entry point exactly once and hands
  // the same instance to every widget that asks. The bar creates this panel
  // more than once, and two samplers writing one history file would race each
  // other, so the single instance has to come from the shell rather than from
  // a `Service {}` declared here.
  readonly property var traffic: bar && bar.shell ? bar.shell.serviceFor("wian47.siphon") : null
  readonly property bool ready: traffic ? traffic.loaded : false
  readonly property var live: traffic ? traffic.state : Model.emptyState()
  readonly property var udp: traffic ? traffic.udp : []
  readonly property var unattributed: traffic
    ? traffic.unattributed
    : ({ rx: 0, tx: 0, rxRate: 0, txRate: 0 })
  readonly property string serviceError: traffic ? traffic.lastError : ""

  onTrafficChanged: if (traffic) traffic.settings = root.settings
  onOpenedChanged: {
    if (!traffic) return
    traffic.watchClosely = opened
    if (opened) traffic.sample()
  }

  function handleBarPress(buttonCode) {
    if (buttonCode === Qt.MiddleButton) { if (traffic) traffic.reset() }
    else root.toggle()
  }

  Loader {
    id: button
    anchors.fill: parent
    sourceComponent: root.labelMode !== "none" && root.barLabel !== "" ? labelledButton : iconButton
  }

  Component {
    id: iconButton

    BarIconButton {
      anchors.fill: parent
      bar: root.bar
      text: Model.GLYPH_NETWORK
      tooltipText: root.barTooltip
      active: root.overThreshold
      onPressed: function (buttonCode) { root.handleBarPress(buttonCode) }
    }
  }

  Component {
    id: labelledButton

    WidgetButton {
      anchors.fill: parent
      bar: root.bar
      text: Model.GLYPH_NETWORK + "  " + root.barLabel
      tooltipText: root.barTooltip
      active: root.overThreshold
      onPressed: function (buttonCode) { root.handleBarPress(buttonCode) }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (text) {
        if ((text === "r" || text === "R") && root.traffic) root.traffic.reset()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(10)

          PanelHero {
            width: parent.width
            title: "Network by application"
            meta: Model.summary(root.live)
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: Model.GLYPH_NETWORK
                color: root.overThreshold ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              PanelActionButton {
                iconText: Model.GLYPH_RESET
                tooltipText: "Reset the session totals"
                foreground: root.foreground
                onClicked: if (root.traffic) root.traffic.reset()
              }
            }
          }

          Text {
            width: parent.width
            visible: root.serviceError !== ""
            text: root.serviceError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: root.ready && root.apps.length === 0
            text: "No application holds a network connection right now."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.apps

            Item {
              required property var modelData
              width: column.width
              height: Style.space(34)

              readonly property bool moving: (modelData.rxRate + modelData.txRate) > 0
              readonly property bool loud: root.warnRate > 0
                && (modelData.rxRate + modelData.txRate) >= root.warnRate

              Text {
                id: appName
                anchors.left: parent.left
                anchors.top: parent.top
                width: parent.width * 0.42
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: modelData.name
                color: loud ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                anchors.left: appName.left
                anchors.top: appName.bottom
                text: modelData.sockets > 0
                  ? modelData.sockets + (modelData.sockets === 1 ? " connection" : " connections")
                  : "idle"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                id: rates
                anchors.right: parent.right
                anchors.top: parent.top
                horizontalAlignment: Text.AlignRight
                text: Model.GLYPH_DOWN + " " + Model.formatRate(modelData.rxRate)
                  + "   " + Model.GLYPH_UP + " " + Model.formatRate(modelData.txRate)
                color: moving ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                anchors.right: rates.right
                anchors.top: rates.bottom
                text: "session " + Model.formatBytes(modelData.rx + modelData.tx)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          PanelSeparator {
            width: parent.width
            visible: root.unattributed.rxRate > 0 || root.udp.length > 0
            foreground: root.foreground
          }

          PanelSectionHeader {
            width: parent.width
            visible: root.unattributed.rxRate > 0 || root.udp.length > 0
            text: "Not attributable"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          // The kernel reports byte counters for TCP sockets only. QUIC rides
          // on UDP, which carries no such counter, so its bytes can be seen
          // arriving at the interface but cannot be charged to the process
          // that asked for them. Naming the processes holding UDP sockets is
          // the honest half of that answer; inventing a number for them would
          // be the dishonest one.
          Text {
            width: parent.width
            visible: root.unattributed.rxRate > 0 || root.udp.length > 0
            text: {
              var rate = Model.GLYPH_DOWN + " " + Model.formatRate(root.unattributed.rxRate)
                + "   " + Model.GLYPH_UP + " " + Model.formatRate(root.unattributed.txRate)
              var who = Model.unmeasuredNote(root.live)
              return who === ""
                ? rate + "\nPacket headers and connections owned by other users."
                : rate + "\nQUIC from " + who + ", packet headers, and other users."
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
