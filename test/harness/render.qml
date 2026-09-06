import QtQuick
import QtQuick.Window
import "../.." as Siphon
import "../../Model.js" as Model
import "../../History.js" as History

// Renders the shipped Panel.qml offscreen against a seeded history, so the day
// view can be looked at without a compositor and without touching the running
// shell. The `qs.Commons` and `qs.Ui` types beside this file stand in for
// Omarchy's; everything below the panel's own root is the real thing.
//
//   QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
//     qml6 -I test/harness test/harness/render.qml -- <outdir>
Window {
  id: harness
  visible: true
  width: 420
  height: 980
  color: "#0d1017"

  readonly property string todayKey: "2026-09-05"
  readonly property string outDir: Qt.application.arguments[Qt.application.arguments.length - 1]

  function seededHistory() {
    var h = History.emptyHistory()
    var week = [
      ["2026-08-31", { brave: [420000000, 9000000], curl: [80000000, 2000000] }],
      ["2026-09-01", { brave: [310000000, 6000000], spotify: [95000000, 1000000] }],
      ["2026-09-02", {}],
      ["2026-09-03", { curl: [1400000000, 40000000], brave: [150000000, 4000000] }],
      ["2026-09-04", { brave: [2600000000, 70000000], t3code: [180000000, 5000000] }],
      ["2026-09-05", {
        curl: [971000000, 12000000], mise: [191000000, 3000000],
        brave: [77100000, 2000000], "git-remote-http": [39800000, 900000],
        claude: [30900000, 800000], spotify: [11700000, 400000],
        t3code: [1560000, 90000]
      }]
    ]
    for (var i = 0; i < week.length; i++) {
      var apps = {}
      for (var name in week[i][1]) {
        apps[name] = { rx: week[i][1][name][0], tx: week[i][1][name][1] }
      }
      h = History.record(h, week[i][0], { apps: apps, unattributed: { rx: 40000000, tx: 900000 } })
    }
    return h
  }

  function liveState() {
    var udp = [{ name: "spotify", pid: 3, sockets: 11 }]
    var first = Model.applySample(Model.emptyState(), {
      atMs: 0, complete: true, udp: udp, iface: { rx: 0, tx: 0 },
      sockets: [{ key: "a", app: "claude", pid: 1, sent: 0, recv: 0 },
                { key: "b", app: "brave", pid: 2, sent: 0, recv: 0 }]
    })
    return Model.applySample(first, {
      atMs: 1000, complete: true, udp: udp, iface: { rx: 1400, tx: 175000 },
      sockets: [{ key: "a", app: "claude", pid: 1, sent: 160000, recv: 793 },
                { key: "b", app: "brave", pid: 2, sent: 18, recv: 8 }]
    })
  }

  QtObject {
    id: service
    readonly property var state: harness.liveState()
    property bool loaded: true
    property var udp: state.udp
    property var unattributed: state.unattributed
    property string lastError: ""
    property var history: harness.seededHistory()
    property string todayKey: harness.todayKey
    property var apps: Model.ranked(state)
    property real warnBytesPerSecond: 0
    property var settings: ({})
    property bool watchClosely: false
    function sample() {}
    function reset() {}
  }

  QtObject {
    id: shell
    function serviceFor(id) { return service }
  }

  QtObject {
    id: bar
    property color foreground: "#d8dee9"
    property color barForeground: "#d8dee9"
    property color urgent: "#f7768e"
    property string fontFamily: "monospace"
    property bool vertical: false
    property int barSize: 26
    property var shell: shell
  }

  Siphon.Panel {
    id: siphon
    bar: bar
    width: harness.width
    height: harness.height
  }

  // One frame per state worth looking at. Each grab is asynchronous, so the
  // next state is only set once the previous image has been written.
  readonly property var frames: [
    { name: "01-today", day: harness.todayKey },
    { name: "02-past-day", day: "2026-09-04" },
    { name: "03-empty-day", day: "2026-09-02" }
  ]
  property int frame: 0
  property int failures: 0

  function complain(message) {
    console.log("  FAIL " + message)
    harness.failures++
  }

  // The week strip's delegates, found by the properties they were given rather
  // than by walking a fixed path, so rearranging the column cannot silently
  // make this check pass against nothing.
  function weekCells(item, found) {
    var kids = item.children
    for (var i = 0; i < kids.length; i++) {
      if (kids[i].readable !== undefined && kids[i].modelData !== undefined) found.push(kids[i])
      else weekCells(kids[i], found)
    }
    return found
  }

  function pickerOf(cell) {
    for (var i = 0; i < cell.children.length; i++) {
      if (cell.children[i].cursorShape !== undefined) return cell.children[i]
    }
    return null
  }

  function checkStrip(shown) {
    var cells = weekCells(siphon, [])
    if (cells.length !== 7) return complain("the week strip has " + cells.length + " days, not 7")
    var lit = []
    var marked = []
    for (var i = 0; i < cells.length; i++) {
      var cell = cells[i]
      var key = cell.modelData.key
      if (cell.isShown) lit.push(key)
      if (cell.isToday) marked.push(key)
      var reachable = key <= harness.todayKey
      if (cell.readable !== reachable) complain(key + " is readable=" + cell.readable)
      var picker = pickerOf(cell)
      if (!picker) complain(key + " has nothing to click")
      else if (picker.enabled !== reachable) complain(key + " click enabled=" + picker.enabled)
    }
    if (lit.length !== 1 || lit[0] !== shown) complain("lit days are " + lit + ", expected " + shown)
    if (marked.length !== 1 || marked[0] !== harness.todayKey) complain("today marked as " + marked)
  }

  // The click itself, not an assignment standing in for it.
  function checkClickSelects() {
    var cells = weekCells(siphon, [])
    for (var i = 0; i < cells.length; i++) {
      var picker = pickerOf(cells[i])
      if (!picker || !picker.enabled) continue
      siphon.shownDay = harness.todayKey
      picker.clicked(null)
      if (siphon.shownDay !== cells[i].modelData.key) {
        complain("clicking " + cells[i].modelData.key + " left the panel on " + siphon.shownDay)
      }
    }
  }

  function pose() {
    if (frame >= frames.length) {
      checkClickSelects()
      console.log(harness.failures === 0
        ? "rendered " + frames.length + " frames, the week strip checks out"
        : harness.failures + " week strip check(s) failed")
      Qt.exit(harness.failures === 0 ? 0 : 1)
      return
    }
    siphon.shownDay = frames[frame].day
    console.log(frames[frame].name
      + " shownDay=" + siphon.shownDay
      + " ring=" + Model.formatDay(siphon.shownDay)
      + " total=" + Model.formatBytes(siphon.day.total)
      + " topApp=" + (siphon.day.topApp ? siphon.day.topApp.name : "none")
      + " change=" + Model.formatChange(siphon.day.change)
      + " apps=" + siphon.day.apps.length)
    checkStrip(frames[frame].day)
    settle.start()
  }

  function shoot() {
    var file = outDir + "/" + frames[frame].name + ".png"
    siphon.grabToImage(function (result) {
      result.saveToFile(file)
      frame++
      next.start()
    })
  }

  // The bars animate their colour, so the pose and the grab are separate
  // steps. Grabbing in the same tick as the change catches them mid-fade.
  Timer { id: settle; interval: 500; onTriggered: harness.shoot() }
  Timer { id: next; interval: 100; onTriggered: harness.pose() }
  Timer { interval: 300; running: true; onTriggered: { siphon.open(); next.start() } }
}
