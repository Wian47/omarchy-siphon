import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

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
    root.checkThreshold()
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

  Timer {
    interval: root.watchClosely ? root.interval : Math.max(root.interval, 5000)
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.sample()
  }
}
