.pragma library

var LOOPBACK = /^(127\.|\[?::1\]?$|\[::1\])/
var VIRTUAL = /^(lo|docker|br-|veth|virbr|vnet)/

function isLoopback(address) {
  return LOOPBACK.test(address)
}

function isVirtualInterface(name) {
  return VIRTUAL.test(name)
}

function splitHostPort(field) {
  var cut = field.lastIndexOf(":")
  if (cut < 0) return { host: field, port: 0 }
  return { host: field.slice(0, cut), port: parseInt(field.slice(cut + 1), 10) || 0 }
}

function parseProcess(line) {
  var m = line.match(/users:\(\("([^"]+)",pid=(\d+)/)
  if (!m) return { app: "", pid: 0 }
  return { app: m[1], pid: parseInt(m[2], 10) }
}

function parseSockets(text) {
  var out = []
  var lines = String(text || "").split("\n")
  var head = null
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (!line.trim()) continue
    if (!/^\s/.test(line)) {
      head = line
      continue
    }
    if (!head) continue

    var fields = head.trim().split(/\s+/)
    var local = fields[3] || ""
    var peer = fields[4] || ""
    head = null
    if (isLoopback(local) || isLoopback(peer)) continue

    var who = parseProcess(fields.join(" "))
    if (!who.app) continue

    var sent = line.match(/\bbytes_sent:(\d+)/)
    var recv = line.match(/\bbytes_received:(\d+)/)
    out.push({
      key: local + ">" + peer,
      app: who.app,
      pid: who.pid,
      sent: sent ? parseInt(sent[1], 10) : 0,
      recv: recv ? parseInt(recv[1], 10) : 0
    })
  }
  return out
}

function parseNetDev(text) {
  var total = { rx: 0, tx: 0 }
  var lines = String(text || "").split("\n")
  for (var i = 2; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var cut = line.indexOf(":")
    if (cut < 0) continue
    var name = line.slice(0, cut).trim()
    if (isVirtualInterface(name)) continue
    var f = line.slice(cut + 1).trim().split(/\s+/)
    total.rx += parseInt(f[0], 10) || 0
    total.tx += parseInt(f[8], 10) || 0
  }
  return total
}

function countUdpSockets(text) {
  var n = 0
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var fields = lines[i].trim().split(/\s+/)
    if (fields.length < 5) continue
    if (isLoopback(fields[3]) || isLoopback(fields[4])) continue
    if (/users:\(\(/.test(lines[i])) n++
  }
  return n
}

function socketDelta(previous, current) {
  if (!previous) return { sent: current.sent, recv: current.recv }
  if (current.sent < previous.sent || current.recv < previous.recv) {
    return { sent: current.sent, recv: current.recv }
  }
  return { sent: current.sent - previous.sent, recv: current.recv - previous.recv }
}

function emptyState() {
  return {
    atMs: 0,
    sockets: {},
    apps: {},
    iface: { rx: 0, tx: 0 },
    unattributed: { rx: 0, tx: 0, rxRate: 0, txRate: 0 },
    udpSockets: 0,
    primed: false
  }
}

function applySample(state, sample) {
  var elapsed = state.primed ? (sample.atMs - state.atMs) / 1000 : 0
  var next = {
    atMs: sample.atMs,
    sockets: {},
    apps: {},
    iface: sample.iface,
    unattributed: {
      rx: state.unattributed.rx,
      tx: state.unattributed.tx,
      rxRate: 0,
      txRate: 0
    },
    udpSockets: sample.udpSockets || 0,
    primed: true
  }

  var attributedRx = 0
  var attributedTx = 0

  for (var i = 0; i < sample.sockets.length; i++) {
    var s = sample.sockets[i]
    next.sockets[s.key] = { sent: s.sent, recv: s.recv }

    var delta = elapsed > 0
      ? socketDelta(state.sockets[s.key], s)
      : { sent: 0, recv: 0 }
    attributedRx += delta.recv
    attributedTx += delta.sent

    var carried = state.apps[s.app]
    var app = next.apps[s.app] || {
      name: s.app,
      pid: s.pid,
      rx: carried ? carried.rx : 0,
      tx: carried ? carried.tx : 0,
      rxRate: 0,
      txRate: 0,
      sockets: 0
    }
    app.rx += delta.recv
    app.tx += delta.sent
    app.sockets += 1
    next.apps[s.app] = app
  }

  for (var name in state.apps) {
    if (next.apps[name]) continue
    var idle = state.apps[name]
    if (!idle.rx && !idle.tx) continue
    next.apps[name] = {
      name: name,
      pid: idle.pid,
      rx: idle.rx,
      tx: idle.tx,
      rxRate: 0,
      txRate: 0,
      sockets: 0
    }
  }

  if (elapsed > 0) {
    for (var key in next.apps) {
      var a = next.apps[key]
      var was = state.apps[key]
      a.rxRate = Math.max(0, (a.rx - (was ? was.rx : 0)) / elapsed)
      a.txRate = Math.max(0, (a.tx - (was ? was.tx : 0)) / elapsed)
    }
    var ifaceRx = Math.max(0, sample.iface.rx - state.iface.rx)
    var ifaceTx = Math.max(0, sample.iface.tx - state.iface.tx)
    var missRx = Math.max(0, ifaceRx - attributedRx)
    var missTx = Math.max(0, ifaceTx - attributedTx)
    next.unattributed.rx += missRx
    next.unattributed.tx += missTx
    next.unattributed.rxRate = missRx / elapsed
    next.unattributed.txRate = missTx / elapsed
  }

  return next
}

function ranked(state) {
  var out = []
  for (var key in state.apps) out.push(state.apps[key])
  out.sort(function (a, b) {
    var byRate = (b.rxRate + b.txRate) - (a.rxRate + a.txRate)
    if (byRate) return byRate
    var byTotal = (b.rx + b.tx) - (a.rx + a.tx)
    if (byTotal) return byTotal
    return a.name < b.name ? -1 : a.name > b.name ? 1 : 0
  })
  return out
}

function totalRate(state) {
  var rx = 0
  var tx = 0
  for (var key in state.apps) {
    rx += state.apps[key].rxRate
    tx += state.apps[key].txRate
  }
  return { rx: rx, tx: tx }
}

var RATE_UNITS = ["B/s", "kB/s", "MB/s", "GB/s"]
var SIZE_UNITS = ["B", "kB", "MB", "GB", "TB"]

function scale(value, units) {
  var n = Math.max(0, value || 0)
  var i = 0
  while (n >= 1000 && i < units.length - 1) {
    n /= 1000
    i++
  }
  var digits = i === 0 || n >= 100 ? 0 : n >= 10 ? 1 : 2
  return n.toFixed(digits) + " " + units[i]
}

function formatRate(bytesPerSecond) {
  return scale(bytesPerSecond, RATE_UNITS)
}

function formatBytes(bytes) {
  return scale(bytes, SIZE_UNITS)
}

function barLabel(state, mode) {
  if (mode === "none") return ""
  var total = totalRate(state)
  if (mode === "down") return formatRate(total.rx)
  if (mode === "top-app") {
    var top = ranked(state)[0]
    return top && (top.rxRate + top.txRate) > 0 ? top.name : ""
  }
  return formatRate(total.rx + total.tx)
}
