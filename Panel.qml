import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "History.js" as History

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
  readonly property var history: traffic ? traffic.history : History.emptyHistory()
  readonly property string todayKey: traffic && traffic.todayKey !== ""
    ? traffic.todayKey
    : History.dayKey(new Date())

  // "today" or "year". The year view is a drill-down from the same panel
  // rather than a second popup, so the back control returns here.
  property string scope: "today"
  property string shownYear: History.yearOf(todayKey)

  readonly property var today: History.dayInsights(history, todayKey)
  readonly property var todayApps: Model.withColors(today.apps.slice(0, 7))
  readonly property var year: History.yearInsights(history, shownYear)

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
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

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
            title: root.scope === "today" ? "Network by application" : root.shownYear
            meta: root.scope === "today"
              ? Model.summary(root.live)
              : Model.formatBytes(root.year.total) + " moved"
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
              Row {
                spacing: Style.space(2)

                PanelActionButton {
                  visible: root.scope === "year"
                  iconText: Model.GLYPH_PREV
                  tooltipText: "Previous year"
                  foreground: root.foreground
                  onClicked: root.shownYear = String(Number(root.shownYear) - 1)
                }

                PanelActionButton {
                  visible: root.scope === "year"
                  iconText: Model.GLYPH_NEXT
                  tooltipText: "Next year"
                  foreground: root.foreground
                  onClicked: root.shownYear = String(Number(root.shownYear) + 1)
                }

                PanelActionButton {
                  iconText: root.scope === "today" ? Model.GLYPH_CALENDAR : Model.GLYPH_BACK
                  tooltipText: root.scope === "today" ? "Show the year" : "Back to today"
                  foreground: root.foreground
                  onClicked: {
                    if (root.scope === "today") {
                      root.shownYear = History.yearOf(root.todayKey)
                      root.scope = "year"
                    } else {
                      root.scope = "today"
                    }
                  }
                }

                PanelActionButton {
                  iconText: Model.GLYPH_RESET
                  tooltipText: "Reset the live session totals"
                  foreground: root.foreground
                  onClicked: if (root.traffic) root.traffic.reset()
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.scope === "today" && root.serviceError !== ""
            text: root.serviceError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: root.scope === "today" && root.ready && root.apps.length === 0
            text: "No application holds a network connection right now."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }


          // ------------------------------------------------------- today
          Item {
            width: parent.width
            visible: root.scope === "today"
            implicitHeight: todayColumn.implicitHeight

            Column {
              id: todayColumn
              width: parent.width
              spacing: Style.space(10)

              Row {
                width: parent.width
                spacing: Style.space(14)

                Canvas {
                  id: donut
                  width: Style.space(96)
                  height: Style.space(96)

                  readonly property var slices: root.todayApps
                  readonly property real sliceTotal: root.today.total
                  onSlicesChanged: requestPaint()
                  onSliceTotalChanged: requestPaint()

                  onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    var mid = width / 2
                    var outer = mid - Style.space(2)
                    var inner = outer * 0.62
                    if (sliceTotal <= 0) {
                      ctx.beginPath()
                      ctx.arc(mid, mid, (outer + inner) / 2, 0, Math.PI * 2)
                      ctx.lineWidth = outer - inner
                      ctx.strokeStyle = Qt.rgba(root.foreground.r, root.foreground.g,
                                                root.foreground.b, 0.12)
                      ctx.stroke()
                      return
                    }
                    var angle = -Math.PI / 2
                    for (var i = 0; i < slices.length; i++) {
                      var sweep = (slices[i].total / sliceTotal) * Math.PI * 2
                      ctx.beginPath()
                      ctx.arc(mid, mid, (outer + inner) / 2, angle, angle + sweep)
                      ctx.lineWidth = outer - inner
                      ctx.strokeStyle = slices[i].color
                      ctx.stroke()
                      angle += sweep
                    }
                  }

                  Column {
                    anchors.centerIn: parent
                    spacing: 0

                    Text {
                      anchors.horizontalCenter: parent.horizontalCenter
                      text: Model.formatDay(root.todayKey)
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      anchors.horizontalCenter: parent.horizontalCenter
                      text: Model.formatBytes(root.today.total)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.subtitle
                    }
                  }
                }

                Column {
                  width: parent.width - donut.width - Style.space(14)
                  spacing: Style.space(3)

                  Repeater {
                    model: root.todayApps

                    Item {
                      required property var modelData
                      width: parent.width
                      height: Style.space(15)

                      Rectangle {
                        id: dot
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(6)
                        height: width
                        radius: width / 2
                        color: modelData.color
                      }

                      Text {
                        anchors.left: dot.right
                        anchors.leftMargin: Style.space(6)
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width * 0.5
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: modelData.name
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }

                      Text {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: Model.formatBytes(modelData.total)
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                    }
                  }

                  Text {
                    visible: root.today.apps.length === 0
                    text: root.today.detailed
                      ? "Nothing recorded today yet."
                      : "This day is older than the detail window."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              // Week bars. Heights are shares of the week's own peak, so a
              // quiet week still reads rather than flattening to nothing.
              Item {
                width: parent.width
                height: Style.space(52)

                readonly property real peak: {
                  var top = 0
                  for (var i = 0; i < root.today.week.length; i++) {
                    if (root.today.week[i].total > top) top = root.today.week[i].total
                  }
                  return top
                }

                Row {
                  anchors.fill: parent
                  spacing: Style.space(4)

                  Repeater {
                    model: root.today.week

                    Item {
                      required property var modelData
                      required property int index
                      width: (parent.width - Style.space(4) * 6) / 7
                      height: parent.height

                      readonly property bool isToday: modelData.key === root.todayKey

                      Rectangle {
                        anchors.bottom: dayName.top
                        anchors.bottomMargin: Style.space(4)
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width * 0.62
                        radius: Style.space(2)
                        height: {
                          var room = parent.height - dayName.height - Style.space(4)
                          var peak = parent.parent.parent.peak
                          if (peak <= 0) return Style.space(2)
                          return Math.max(Style.space(2), room * (modelData.total / peak))
                        }
                        color: isToday ? root.foreground : Qt.rgba(root.foreground.r,
                          root.foreground.g, root.foreground.b, 0.28)
                      }

                      Text {
                        id: dayName
                        anchors.bottom: parent.bottom
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: Model.WEEKDAYS[index]
                        color: isToday ? root.foreground : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }
              }

              Repeater {
                model: [
                  {
                    label: "Top app",
                    value: root.today.topApp
                      ? root.today.topApp.name + "  " + Model.formatShare(root.today.topApp.share)
                      : "nothing yet"
                  },
                  {
                    label: "vs yesterday",
                    value: Model.formatChange(root.today.change)
                  },
                  {
                    label: "Busiest day this week",
                    value: root.today.busiestOfWeek
                      ? Model.formatDay(root.today.busiestOfWeek.key) + "  "
                        + Model.formatBytes(root.today.busiestOfWeek.total)
                      : "nothing yet"
                  },
                  {
                    label: "Down / up",
                    value: Model.formatBytes(root.today.rx) + "  /  " + Model.formatBytes(root.today.tx)
                  }
                ]

                Item {
                  required property var modelData
                  width: todayColumn.width
                  height: Style.space(17)

                  Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.label
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.value
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }
          }

          // -------------------------------------------------------- year
          Item {
            width: parent.width
            visible: root.scope === "year"
            implicitHeight: yearColumn.implicitHeight

            Column {
              id: yearColumn
              width: parent.width
              spacing: Style.space(8)

              Repeater {
                model: History.monthSeries(root.history, root.shownYear)

                Item {
                  required property var modelData
                  width: parent.width
                  height: Style.space(16)

                  readonly property real peak: {
                    var top = 0
                    var months = History.monthSeries(root.history, root.shownYear)
                    for (var i = 0; i < months.length; i++) {
                      if (months[i].total > top) top = months[i].total
                    }
                    return top
                  }

                  Text {
                    id: monthName
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(30)
                    text: Model.MONTHS[modelData.month - 1]
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Rectangle {
                    anchors.left: monthName.right
                    anchors.verticalCenter: parent.verticalCenter
                    height: Style.space(8)
                    radius: Style.space(2)
                    width: {
                      var room = parent.width - monthName.width - Style.space(56)
                      if (peak <= 0 || modelData.total <= 0) return 0
                      return Math.max(Style.space(2), room * (modelData.total / peak))
                    }
                    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.45)
                  }

                  Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.total > 0 ? Model.formatBytes(modelData.total) : "0 B"
                    color: modelData.total > 0 ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              PanelSeparator {
                width: parent.width
                foreground: root.foreground
              }

              PanelSectionHeader {
                width: parent.width
                text: "Insights " + root.shownYear
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Grid {
                width: parent.width
                columns: 2
                spacing: Style.space(6)

                Repeater {
                  model: [
                    {
                      title: "MOVED",
                      value: Model.formatBytes(root.year.total),
                      detail: Model.formatBytes(root.year.rx) + " down, "
                        + Model.formatBytes(root.year.tx) + " up."
                    },
                    {
                      title: "BUSIEST MONTHS",
                      value: root.year.topMonths.length > 0
                        ? root.year.topMonths.map(function (m) {
                            return Model.MONTHS[m.month - 1]
                          }).join(" · ")
                        : "nothing yet",
                      detail: "Where the year's traffic went."
                    },
                    {
                      title: "DAY COUNT",
                      value: root.year.activeDays + " of " + root.year.trackedDays + " days",
                      detail: "Days with traffic, out of days observed."
                    },
                    {
                      title: "PEAK DAY",
                      value: root.year.peak
                        ? Model.formatDay(root.year.peak.key) + " · " + Model.formatBytes(root.year.peak.total)
                        : "nothing yet",
                      detail: "Nothing above it."
                    },
                    {
                      title: "LONGEST STREAK",
                      value: root.year.streak + (root.year.streak === 1 ? " day" : " days"),
                      detail: "Consecutive days with traffic."
                    },
                    {
                      title: "AVERAGE DAY",
                      value: Model.formatBytes(root.year.averagePerActiveDay),
                      detail: "Per day that saw any traffic."
                    },
                    {
                      title: "TOP APP",
                      value: root.year.apps.length > 0
                        ? root.year.apps[0].name + " · " + Model.formatShare(root.year.apps[0].share)
                        : "nothing yet",
                      detail: "Biggest share of the year."
                    },
                    {
                      title: "UNATTRIBUTED",
                      value: Model.formatShare(root.year.unattributedShare),
                      detail: "QUIC and framing, which carry no per-socket count."
                    }
                  ]

                  Rectangle {
                    required property var modelData
                    width: (yearColumn.width - Style.space(6)) / 2
                    implicitHeight: cardBody.implicitHeight + Style.space(16)
                    radius: Style.space(6)
                    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)

                    Column {
                      id: cardBody
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.top: parent.top
                      anchors.margins: Style.space(8)
                      spacing: Style.space(2)

                      Text {
                        width: parent.width
                        text: modelData.title
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                      Text {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: modelData.value
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                      Text {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: modelData.detail
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }
              }
            }
          }

          PanelSectionHeader {
            width: parent.width
            visible: root.scope === "today"
            text: "Right now"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.apps

            Item {
              required property var modelData
              width: column.width
              visible: root.scope === "today"
              height: visible ? Style.space(34) : 0

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
            visible: root.scope === "today" && (root.unattributed.rxRate > 0 || root.udp.length > 0)
            foreground: root.foreground
          }

          PanelSectionHeader {
            width: parent.width
            visible: root.scope === "today" && (root.unattributed.rxRate > 0 || root.udp.length > 0)
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
            visible: root.scope === "today" && (root.unattributed.rxRate > 0 || root.udp.length > 0)
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
