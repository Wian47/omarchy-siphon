import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model
import "History.js" as History

// Owns the sampling loop. One process per tick asks the kernel three
// questions: which TCP sockets exist and how many payload bytes each has
// carried, which processes hold UDP sockets, and what the interfaces
// themselves have counted.
//
// Nothing here needs elevated rights. Per-socket byte counters come from the
// kernel's own socket diagnostics, which report a process's own sockets to
// that process's owner. Sockets belonging to other users appear without a
// name and are left out rather than guessed at.
Item {
  id: root

  property var settings: ({})

  readonly property string home: Quickshell.env("HOME")
  readonly property string dataDir: home + "/.config/omarchy/siphon"
  readonly property string historyPath: dataDir + "/history.json"

  // Raw per-day detail is kept for this long. Older days keep their totals and
  // give up their per-app breakdown to the month, so the file cannot grow
  // without bound while the calendar charts still have a bar for every day.
  readonly property int keepDays: 95

  property var history: History.emptyHistory()
  property string todayKey: ""
  property bool historyLoaded: false

  property var state: Model.emptyState()
  property bool loaded: false
  property string lastError: ""

  // The panel sets this while it is open, so the list stays current while
  // someone is reading it and ticks slowly while nobody is.
  property bool watchClosely: false

  readonly property var apps: Model.ranked(state)
  readonly property var udp: state.udp
  readonly property var total: Model.totalRate(state)
  readonly property var unattributed: state.unattributed

  readonly property int interval: {
    var configured = Number(settings.refreshIntervalSec)
    var seconds = configured > 0 ? configured : 2
    return Math.max(1, Math.min(30, seconds)) * 1000
  }

  readonly property real warnBytesPerSecond: {
    var mbps = Number(settings.notifyThresholdMbps)
    return mbps > 0 ? mbps * 125000 : 0
  }

  property string _warnedApp: ""

  function sample() {
    if (sampleProcess.running) return
    sampleProcess.command = Model.sampleCommand()
    sampleProcess.running = true
  }

  function apply(text) {
    var next = Model.parseSample(text, Date.now())
    if (!next.complete) {
      root.lastError = "could not read the socket table"
      return
    }
    root.lastError = ""
    root.state = Model.applySample(root.state, next)
    root.loaded = true
    root.remember(root.state.delta)
    root.checkThreshold()
  }

  // Ticks are only banked once the file on disk has been read. Recording
  // before that would write a history containing today and nothing else, and
  // the load would then overwrite it.
  function remember(delta) {
    if (!historyLoaded) return
    var key = History.dayKey(new Date())
    if (key !== root.todayKey) root.todayKey = key
    var next = History.record(root.history, key, delta)
    if (next === root.history) return
    root.history = next
    saveTimer.restart()
  }

  function onHistoryLoaded() {
    var raw = {
      days: historyAdapter.days,
      months: historyAdapter.months,
      years: historyAdapter.years
    }
    root.todayKey = History.dayKey(new Date())
    root.history = History.prune(History.readHistory(raw), root.todayKey, root.keepDays)
    root.historyLoaded = true
  }

  function onHistoryLoadFailed() {
    root.todayKey = History.dayKey(new Date())
    root.history = History.emptyHistory()
    root.historyLoaded = true
  }

  // Reassigns fresh top-level objects so the JsonAdapter notices the change.
  function persist() {
    if (!historyLoaded) return
    root.history = History.prune(root.history, History.dayKey(new Date()), root.keepDays)
    historyAdapter.days = root.history.days
    historyAdapter.months = root.history.months
    historyAdapter.years = root.history.years
    historyFile.writeAdapter()
  }

  function checkThreshold() {
    if (warnBytesPerSecond <= 0) return
    var top = apps.length > 0 ? apps[0] : null
    if (!top || (top.rxRate + top.txRate) < warnBytesPerSecond) {
      root._warnedApp = ""
      return
    }
    if (root._warnedApp === top.name) return
    root._warnedApp = top.name
    notifyProcess.command = ["notify-send", "-a", "Siphon", "-i", "network-transmit-receive",
                             top.name + " is using " + Model.formatRate(top.rxRate + top.txRate),
                             "Above the " + Number(settings.notifyThresholdMbps) + " Mbps you asked to hear about."]
    notifyProcess.running = true
  }

  function reset() {
    root.state = Model.emptyState()
    root.loaded = false
    root._warnedApp = ""
    root.sample()
  }

  Process {
    id: sampleProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.apply(text)
    }
    onExited: function (exitCode) {
      if (exitCode !== 0 && !root.loaded) root.lastError = "the socket table could not be read"
    }
  }

  Process {
    id: notifyProcess
  }

  Process {
    id: ensureDirProcess
    running: true
    command: ["sh", "-c",
      "mkdir -p \"$HOME/.config/omarchy/siphon\"; f=\"$HOME/.config/omarchy/siphon/history.json\"; [ -f \"$f\" ] || printf '{}\\n' > \"$f\""]
    onExited: historyFile.reload()
  }

  FileView {
    id: historyFile
    path: root.historyPath
    printErrors: false
    atomicWrites: true
    onLoaded: root.onHistoryLoaded()
    onLoadFailed: root.onHistoryLoadFailed()

    JsonAdapter {
      id: historyAdapter
      property var days: ({})
      property var months: ({})
      property var years: ({})
    }
  }

  // Batches writes so a busy machine does not rewrite the file every tick.
  Timer {
    id: saveTimer
    interval: 20000
    repeat: false
    onTriggered: root.persist()
  }

  Component.onDestruction: root.persist()

  Timer {
    interval: root.watchClosely ? root.interval : Math.max(root.interval, 5000)
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.sample()
  }
}
