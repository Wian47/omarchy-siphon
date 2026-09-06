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
      ["2026-03-14", { brave: [1200000000, 30000000], spotify: [220000000, 4000000] }],
      ["2026-06-02", { curl: [640000000, 15000000] }],
      ["2026-07-20", { brave: [880000000, 21000000], claude: [140000000, 3000000] }],
      ["2026-08-24", { brave: [300000000, 7000000] }],
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
    { name: "01-day-today", scope: "day", anchor: harness.todayKey, cells: 7 },
    { name: "02-day-past", scope: "day", anchor: "2026-09-04", cells: 7 },
    { name: "03-day-empty", scope: "day", anchor: "2026-09-02", cells: 7 },
    { name: "04-week", scope: "week", anchor: "2026-08-31", cells: 7 },
    { name: "05-week-past", scope: "week", anchor: "2026-08-24", cells: 7 },
    { name: "06-month", scope: "month", anchor: "2026-09-01", cells: 30 },
    { name: "07-month-past", scope: "month", anchor: "2026-03-01", cells: 31 },
    { name: "08-year", scope: "year", anchor: "2026-01-01", cells: 12 }
  ]
  property int frame: 0
  property int failures: 0

  function complain(message) {
    console.log("  FAIL " + message)
    harness.failures++
  }

  // Found by the properties they were given rather than by walking a fixed
  // path, so rearranging the column cannot silently make a check pass against
  // nothing.
  function findAll(item, has, found) {
    var kids = item.children
    for (var i = 0; i < kids.length; i++) {
      if (kids[i][has] !== undefined) found.push(kids[i])
      else findAll(kids[i], has, found)
    }
    return found
  }

  function stripCells() {
    return findAll(siphon, "readable", [])
  }

  function scopeButtons() {
    return findAll(siphon, "selected", [])
  }

  function pickerOf(cell) {
    for (var i = 0; i < cell.children.length; i++) {
      if (cell.children[i].cursorShape !== undefined) return cell.children[i]
    }
    return null
  }

  function checkStrip(want) {
    var cells = stripCells()
    if (cells.length !== want.cells) {
      return complain(want.name + " strip has " + cells.length + " bars, not " + want.cells)
    }
    var lit = []
    var marked = []
    for (var i = 0; i < cells.length; i++) {
      var cell = cells[i]
      var key = cell.modelData.key
      if (cell.isShown) lit.push(key)
      if (cell.isToday) marked.push(key)
      var reachable = key <= siphon.reachable
      if (cell.readable !== reachable) complain(key + " is readable=" + cell.readable)
      var picker = pickerOf(cell)
      if (!picker) complain(key + " has nothing to click")
      else if (picker.enabled !== reachable) complain(key + " click enabled=" + picker.enabled)
    }
    var wantLit = want.scope === "day" ? [want.anchor] : []
    if (String(lit) !== String(wantLit)) complain(want.name + " lit " + lit + ", expected " + wantLit)
    // A day view's strip is the week around it, which can hold today even when
    // the day being read does not, so the mark follows the strip's own range.
    var first = cells[0].modelData.key
    var last = cells[cells.length - 1].modelData.key
    var wantMarked = first <= siphon.reachable && siphon.reachable <= last ? [siphon.reachable] : []
    if (String(marked) !== String(wantMarked)) complain(want.name + " marked " + marked + ", expected " + wantMarked)
  }

  // Clicking a bar is a size down: a bar in a year opens that month, a bar in
  // a month or a week opens that day, and a bar in a day view moves the day.
  function checkClickOpens() {
    for (var f = 0; f < frames.length; f++) {
      siphon.scope = frames[f].scope
      siphon.anchor = frames[f].anchor
      var cells = stripCells()
      var child = siphon.period.childScope
      for (var i = cells.length - 1; i >= 0; i--) {
        var picker = pickerOf(cells[i])
        if (!picker || !picker.enabled) continue
        var key = cells[i].modelData.key
        picker.clicked(null)
        if (siphon.scope !== child) {
          complain(frames[f].name + " opened scope " + siphon.scope + ", expected " + child)
        }
        if (siphon.anchor !== History.periodStart(child, key)) {
          complain(frames[f].name + " opened " + siphon.anchor + ", expected the period holding " + key)
        }
        break
      }
    }
  }

  function checkScopeButtons() {
    var buttons = scopeButtons()
    if (buttons.length !== History.SCOPES.length) {
      return complain("the panel offers " + buttons.length + " sizes, not " + History.SCOPES.length)
    }
    for (var i = 0; i < buttons.length; i++) {
      var picker = pickerOf(buttons[i])
      if (!picker) { complain(buttons[i].modelData + " has nothing to click"); continue }
      picker.clicked(null)
      if (siphon.scope !== buttons[i].modelData) {
        complain("clicking " + buttons[i].modelData + " left the panel on " + siphon.scope)
      }
      if (!buttons[i].selected) complain(buttons[i].modelData + " is selected but does not say so")
    }
  }

  // Switching size from a period holding today lands on today, so the way to
  // this morning is one click rather than a walk back through the calendar.
  function checkSwitchingKeepsThePlace() {
    siphon.scope = "year"
    siphon.anchor = "2026-01-01"
    siphon.selectScope("day")
    if (siphon.anchor !== harness.todayKey) {
      complain("leaving this year for a day landed on " + siphon.anchor + ", not today")
    }
    siphon.scope = "year"
    siphon.anchor = "2024-01-01"
    siphon.selectScope("day")
    if (siphon.anchor !== "2024-01-01") {
      complain("leaving a past year for a day landed on " + siphon.anchor + ", not where it was")
    }
  }

  // Nothing has happened after today, so nothing offers to step there.
  function checkNextStops() {
    for (var f = 0; f < frames.length; f++) {
      siphon.scope = frames[f].scope
      siphon.anchor = frames[f].anchor
      var arrows = findAll(siphon, "iconText", []).filter(function (a) {
        return a.iconText === Model.GLYPH_NEXT
      })
      if (arrows.length !== 1) { complain(frames[f].name + " has " + arrows.length + " next arrows"); continue }
      var open = siphon.period.to < harness.todayKey
      if (arrows[0].enabled !== open) {
        complain(frames[f].name + " next arrow enabled=" + arrows[0].enabled + ", expected " + open)
      }
    }
  }

  function pose() {
    if (frame >= frames.length) {
      checkClickOpens()
      checkScopeButtons()
      checkSwitchingKeepsThePlace()
      checkNextStops()
      console.log(harness.failures === 0
        ? "rendered " + frames.length + " frames, the period controls check out"
        : harness.failures + " period check(s) failed")
      Qt.exit(harness.failures === 0 ? 0 : 1)
      return
    }
    siphon.scope = frames[frame].scope
    siphon.anchor = frames[frame].anchor
    console.log(frames[frame].name
      + " " + siphon.periodName
      + " total=" + Model.formatBytes(siphon.period.total)
      + " topApp=" + (siphon.period.topApp ? siphon.period.topApp.name : "none")
      + " " + Model.PREVIOUS_LABEL[siphon.scope] + "=" + Model.formatChange(siphon.period.change)
      + " bars=" + siphon.period.series.length)
    checkStrip(frames[frame])
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
