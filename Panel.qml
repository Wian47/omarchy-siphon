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

  // The whole view reads one period: a scope, and the day that period starts
  // on. Assigned rather than bound, because a binding would be broken by the
  // first step and then never follow the date over midnight again.
  property string scope: "day"
  property string anchor: History.periodStart(scope, todayKey)
  onTodayKeyChanged: root.anchor = History.periodStart(root.scope, todayKey)

  readonly property var period: History.periodInsights(history, scope, anchor, todayKey)
  readonly property var periodApps: Model.withColors(period.apps.slice(0, 7))
  readonly property string periodName: Model.periodLabel(period.scope, period.from, period.to)
  readonly property bool showsToday: period.from <= todayKey && todayKey <= period.to

  // The last part of the strip that has happened. Day keys are zero-padded and
  // so are month keys, so ordering them as strings orders them as dates, and
  // this is also the test for a bar with nothing behind it to open.
  readonly property string reachable: period.childScope === "month"
    ? History.monthOf(todayKey) : todayKey

  onTrafficChanged: if (traffic) traffic.settings = root.settings
  onOpenedChanged: {
    if (opened) root.anchor = History.periodStart(root.scope, root.todayKey)
    if (!traffic) return
    traffic.watchClosely = opened
    if (opened) traffic.sample()
  }

  function handleBarPress(buttonCode) {
    if (buttonCode === Qt.MiddleButton) { if (traffic) traffic.reset() }
    else root.toggle()
  }

  // Switching size keeps your place. A period holding today re-anchors on
  // today, so leaving the year view for the day view lands on this morning
  // rather than on the first of January.
  function selectScope(next) {
    var place = root.showsToday ? root.todayKey : root.period.from
    root.scope = next
    root.anchor = History.periodStart(next, place)
  }

  function stepPeriod(count) {
    root.anchor = History.shiftPeriod(root.scope, root.anchor, count)
  }

  // A bar in the strip is a part of the period, so opening one is a size down.
  // A day's strip is the week around it, whose parts are days, which is how
  // clicking a weekday moves the day view without leaving it.
  function openChild(key) {
    var child = root.period.childScope
    root.scope = child
    root.anchor = History.periodStart(child, key)
  }

  function childName(key) {
    var child = root.period.childScope
    var start = History.periodStart(child, key)
    return Model.periodLabel(child, start, History.periodEnd(child, start))
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
      text: Model.GLYPH_NETWORK + " " + root.barLabel
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
                tooltipText: "Reset the live session totals"
                foreground: root.foreground
                onClicked: if (root.traffic) root.traffic.reset()
              }
            }
          }

          // The period being read, and the four sizes it comes in. The arrows
          // step by one of whatever size is selected.
          Item {
            width: parent.width
            height: Style.space(22)

            PanelActionButton {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              iconText: Model.GLYPH_PREV
              tooltipText: "Previous " + root.scope
              foreground: root.foreground
              onClicked: root.stepPeriod(-1)
            }

            Text {
              anchors.centerIn: parent
              text: root.periodName
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            PanelActionButton {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              // Nothing has happened after today, so there is nowhere to step to.
              enabled: root.period.to < root.todayKey
              iconText: Model.GLYPH_NEXT
              tooltipText: "Next " + root.scope
              foreground: root.foreground
              onClicked: root.stepPeriod(1)
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: History.SCOPES

              Rectangle {
                id: filter
                required property var modelData
                readonly property bool selected: filter.modelData === root.scope

                width: (parent.width - Style.space(4) * 3) / 4
                height: Style.space(22)
                radius: Style.space(6)
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
                               filter.selected ? 0.18 : (choose.containsMouse ? 0.10 : 0.04))

                Behavior on color {
                  ColorAnimation { duration: 60 }
                }

                Text {
                  anchors.centerIn: parent
                  text: filter.modelData
                  color: filter.selected ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                MouseArea {
                  id: choose
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectScope(filter.modelData)
                }
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


          // ------------------------------------------------------ period
          Column {
            id: periodColumn
            width: parent.width
            spacing: Style.space(10)

            Row {
              width: parent.width
              spacing: Style.space(14)

              Canvas {
                id: donut
                width: Style.space(96)
                height: Style.space(96)

                readonly property var slices: root.periodApps
                readonly property real sliceTotal: root.period.total
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

                // The navigator above already names the period, so the ring
                // says how much rather than saying when a second time.
                Column {
                  anchors.centerIn: parent
                  spacing: 0

                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Model.formatBytes(root.period.total)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.subtitle
                  }
                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "moved"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              Column {
                width: parent.width - donut.width - Style.space(14)
                spacing: Style.space(3)

                Repeater {
                  model: root.periodApps

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
                  width: parent.width
                  wrapMode: Text.WordWrap
                  visible: root.period.apps.length === 0
                  text: Model.emptyPeriodNote(root.period.scope, root.periodName,
                                              root.showsToday, root.period.total)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // The parts of the period, as bars. Heights are shares of the
            // strip's own peak, so a quiet week still reads rather than
            // flattening to nothing.
            Item {
              id: strip
              width: parent.width
              height: Style.space(52)

              readonly property var entries: root.period.series
              // A month has thirty-odd bars and a week has seven. The same gap
              // between both would leave the month more gap than bar.
              readonly property real gap: strip.entries.length > 12 ? Style.space(2) : Style.space(4)
              readonly property real peak: {
                var top = 0
                for (var i = 0; i < strip.entries.length; i++) {
                  if (strip.entries[i].total > top) top = strip.entries[i].total
                }
                return top
              }

              Row {
                anchors.fill: parent
                spacing: strip.gap

                Repeater {
                  model: strip.entries

                  Item {
                    id: cell
                    required property var modelData
                    required property int index
                    width: (strip.width - strip.gap * (strip.entries.length - 1)) / strip.entries.length
                    height: parent.height

                    // Only a day view lights a bar, because only there is one
                    // bar the period itself. Everywhere else the whole strip
                    // is the period and the mark that matters is today's.
                    readonly property bool isShown: root.scope === "day" && cell.modelData.key === root.period.from
                    readonly property bool isToday: cell.modelData.key === root.reachable
                    readonly property bool readable: cell.modelData.key <= root.reachable

                    Rectangle {
                      anchors.bottom: cellName.top
                      anchors.bottomMargin: Style.space(4)
                      anchors.horizontalCenter: parent.horizontalCenter
                      width: parent.width * 0.62
                      radius: Style.space(2)
                      // A part that saw nothing draws nothing. The floor below
                      // is so a small share still reads, and applying it to
                      // zero would draw twelve identical stubs across a year
                      // that only moved bytes in one month.
                      height: {
                        var room = cell.height - cellName.height - Style.space(4)
                        // The lit bar keeps a floor whatever it holds, because
                        // there it marks a selection rather than a quantity.
                        if (strip.peak <= 0 || cell.modelData.total <= 0) {
                          return cell.isShown ? Style.space(2) : 0
                        }
                        return Math.max(Style.space(2), room * (cell.modelData.total / strip.peak))
                      }
                      color: cell.isShown
                        ? root.foreground
                        : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
                                  pick.containsMouse ? 0.55 : (cell.readable ? 0.28 : 0.12))

                      Behavior on color {
                        ColorAnimation { duration: 60 }
                      }
                    }

                    // Lit is the part being read, underlined is the part
                    // happening now. They are separate marks because they are
                    // separate facts, and the underline is the way back.
                    Text {
                      id: cellName
                      anchors.bottom: parent.bottom
                      anchors.horizontalCenter: parent.horizontalCenter
                      text: Model.stripLabel(root.period.scope, cell.modelData.key, cell.index)
                      color: cell.isShown ? root.foreground : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.underline: cell.isToday
                    }

                    MouseArea {
                      id: pick
                      anchors.fill: parent
                      enabled: cell.readable
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.openChild(cell.modelData.key)
                    }
                  }
                }
              }
            }

            Repeater {
              model: [
                {
                  label: "Top app",
                  value: root.period.topApp
                    ? root.period.topApp.name + "  " + Model.formatShare(root.period.topApp.share)
                    : "nothing yet"
                },
                {
                  label: Model.PREVIOUS_LABEL[root.period.scope],
                  value: Model.formatChange(root.period.change)
                },
                {
                  label: Model.busiestLabel(root.period.scope),
                  value: root.period.busiest
                    ? root.childName(root.period.busiest.key) + "  "
                      + Model.formatBytes(root.period.busiest.total)
                    : "nothing yet"
                },
                {
                  label: "Down / up",
                  value: Model.formatBytes(root.period.rx) + "  /  " + Model.formatBytes(root.period.tx)
                }
              ]

              Item {
                required property var modelData
                width: periodColumn.width
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

            // Everything below counts days, so a single day has nothing to
            // say here that the rows above have not already said.
            PanelSeparator {
              width: parent.width
              visible: root.scope !== "day"
              foreground: root.foreground
            }

            PanelSectionHeader {
              width: parent.width
              visible: root.scope !== "day"
              text: "Insights"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Grid {
              width: parent.width
              visible: root.scope !== "day"
              columns: 2
              spacing: Style.space(6)

              Repeater {
                model: [
                  {
                    title: "DAY COUNT",
                    value: root.period.activeDays + " of " + root.period.trackedDays + " days",
                    detail: "Days with traffic, out of days observed."
                  },
                  {
                    title: "PEAK DAY",
                    value: root.period.peak
                      ? Model.formatDay(root.period.peak.key) + " · " + Model.formatBytes(root.period.peak.total)
                      : "nothing yet",
                    detail: "Nothing above it."
                  },
                  {
                    title: "QUIETEST DAY",
                    value: root.period.quietest
                      ? Model.formatDay(root.period.quietest.key) + " · " + Model.formatBytes(root.period.quietest.total)
                      : "nothing yet",
                    detail: "The lightest day that saw anything at all."
                  },
                  {
                    title: "LONGEST STREAK",
                    value: root.period.streak + (root.period.streak === 1 ? " day" : " days"),
                    detail: "Consecutive days with traffic."
                  },
                  {
                    title: "AVERAGE DAY",
                    value: Model.formatBytes(root.period.averagePerActiveDay),
                    detail: "Per day that saw any traffic."
                  },
                  {
                    title: "UNATTRIBUTED",
                    value: Model.formatShare(root.period.unattributedShare),
                    detail: "QUIC and framing, which carry no per-socket count."
                  }
                ]

                Rectangle {
                  required property var modelData
                  width: (periodColumn.width - Style.space(6)) / 2
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

          PanelSectionHeader {
            width: parent.width
            text: "Right now"
            foreground: root.foreground
            fontFamily: root.fontFamily
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
