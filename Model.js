.pragma library

function codepoint(code) {
  if (String.fromCodePoint) return String.fromCodePoint(code)
  var offset = code - 0x10000
  return String.fromCharCode(0xD800 + (offset >> 10), 0xDC00 + (offset & 0x3FF))
}

var GLYPH_NETWORK = codepoint(0xF04E1)  // md-swap_horizontal
var GLYPH_DOWN = codepoint(0xF0045)     // md-arrow_down
var GLYPH_UP = codepoint(0xF005D)       // md-arrow_up
var GLYPH_RESET = codepoint(0xF0450)    // md-refresh

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

function udpOwners(text) {
  var seen = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var fields = line.trim().split(/\s+/)
    if (fields.length < 5) continue
    if (isLoopback(fields[2]) || isLoopback(fields[3])) continue
    var who = parseProcess(line)
    if (!who.app) continue
    if (!seen[who.app]) seen[who.app] = { name: who.app, pid: who.pid, sockets: 0 }
    seen[who.app].sockets += 1
  }
  var out = []
  for (var key in seen) out.push(seen[key])
  out.sort(function (a, b) {
    if (b.sockets !== a.sockets) return b.sockets - a.sockets
    return a.name < b.name ? -1 : a.name > b.name ? 1 : 0
  })
  return out
}

var UDP_MARK = "#udp"
var DEV_MARK = "#dev"

function sampleCommand() {
  return ["sh", "-c",
    "ss -tinpH; echo '" + UDP_MARK + "'; ss -unpH; echo '" + DEV_MARK + "'; cat /proc/net/dev"]
}

function parseSample(text, atMs) {
  var body = String(text || "")
  var udpAt = body.indexOf("\n" + UDP_MARK)
  var devAt = body.indexOf("\n" + DEV_MARK)
  if (udpAt < 0 || devAt < 0 || devAt < udpAt) {
    return { atMs: atMs, sockets: [], udp: [], iface: { rx: 0, tx: 0 }, complete: false }
  }
  return {
    atMs: atMs,
    sockets: parseSockets(body.slice(0, udpAt)),
    udp: udpOwners(body.slice(udpAt + UDP_MARK.length + 1, devAt)),
    iface: parseNetDev(body.slice(devAt + DEV_MARK.length + 1)),
    complete: true
  }
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
    udp: [],
    delta: { apps: {}, unattributed: { rx: 0, tx: 0 } },
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
    udp: sample.udp || [],
    primed: true,
    // What moved during this tick alone, which is what the history layer
    // accumulates into the current day. The running totals above are for the
    // live panel and reset with the shell.
    delta: { apps: {}, unattributed: { rx: 0, tx: 0 } }
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

    if (delta.recv || delta.sent) {
      var moved = next.delta.apps[s.app] || { rx: 0, tx: 0 }
      moved.rx += delta.recv
      moved.tx += delta.sent
      next.delta.apps[s.app] = moved
    }
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
    next.delta.unattributed.rx = missRx
    next.delta.unattributed.tx = missTx
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

var RATE_UNITS = ["B/s", "kB/s", "MB/s", "GB/s", "TB/s"]
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

function summary(state) {
  if (!state.primed) return "Sampling"
  var total = totalRate(state)
  var loose = state.unattributed.rxRate + state.unattributed.txRate
  if (total.rx + total.tx > 0) {
    return formatRate(total.rx) + " down, " + formatRate(total.tx) + " up"
  }
  if (loose > 0) {
    return formatRate(state.unattributed.rxRate) + " down, "
      + formatRate(state.unattributed.txRate) + " up, none of it attributable"
  }
  return "Nothing is using the network"
}

function unmeasuredNote(state) {
  if (!state.udp || state.udp.length === 0) return ""
  var names = []
  for (var i = 0; i < state.udp.length && i < 3; i++) names.push(state.udp[i].name)
  var more = state.udp.length - names.length
  return names.join(", ") + (more > 0 ? " and " + more + " more" : "")
}

// The bar font is monospace, so a label of a constant number of characters is
// a label of a constant width. Every mode pads to its own budget: without it
// the widget resizes each time the rate crosses a digit or a unit, and the
// icons to its left shuffle along with it.
var RATE_WIDTH = 9
var NAME_WIDTH = 10

// Pads short text and cuts long text, so the result is always exactly `width`
// characters. Cutting only bites at rates no interface can reach, but making
// it an invariant of the function beats reasoning about which ones can.
//
// The padding is a no-break space rather than a plain one. Qt drops trailing
// whitespace when it measures a string, which would collapse the padding on
// exactly the short labels it exists to widen.
var PAD = "\u00a0"

function fixedWidth(text, width, alignRight) {
  var out = String(text)
  if (out.length > width) out = out.slice(0, width - 1) + "\u2026"
  while (out.length < width) out = alignRight ? PAD + out : out + PAD
  return out
}

function barLabel(state, mode) {
  if (mode === "none") return ""
  var total = totalRate(state)
  if (mode === "top-app") {
    var top = ranked(state)[0]
    var name = top && (top.rxRate + top.txRate) > 0 ? top.name : ""
    return fixedWidth(name, NAME_WIDTH, false)
  }
  var rate = mode === "down" ? total.rx : total.rx + total.tx
  return fixedWidth(formatRate(rate), RATE_WIDTH, true)
}

// A stable colour per application, so the donut and its legend agree and an
// app keeps its colour between sessions. Hashed from the name rather than
// assigned by rank, which would recolour the whole chart whenever the order
// changed.
// Ordered so consecutive entries sit in different hue families. Collision
// probing walks this list, so neighbours are what a crowded chart ends up
// using and they have to be told apart at the size of a legend dot.
var PALETTE = [
  "#7aa2f7", "#f7768e", "#9ece6a", "#bb9af7", "#e0af68",
  "#2ac3de", "#ff9e64", "#d291e4", "#8fd6a9", "#cfc9a4"
]

function colorIndex(name) {
  var text = String(name || "")
  var hash = 0
  for (var i = 0; i < text.length; i++) {
    hash = (hash * 31 + text.charCodeAt(i)) % 100000007
  }
  return hash % PALETTE.length
}

function appColor(name) {
  return PALETTE[colorIndex(name)]
}

// Hashing alone collides: with ten colours, seven apps share one about as
// often as not, and a chart with two identical slices is unreadable. Each app
// starts at its hashed colour and takes the next free one if that is gone, so
// colours stay put while the set does and are always distinct within a chart.
function assignColors(apps) {
  var taken = {}
  var out = {}
  for (var i = 0; i < apps.length; i++) {
    var name = apps[i].name
    var start = colorIndex(name)
    var pick = start
    for (var probe = 0; probe < PALETTE.length; probe++) {
      var candidate = (start + probe) % PALETTE.length
      if (!taken[candidate]) {
        pick = candidate
        break
      }
    }
    taken[pick] = true
    out[name] = PALETTE[pick]
  }
  return out
}

// Returns the apps with their colour already on them. The panel used to hold
// a separate name-to-colour map and look each delegate up in it, which left a
// window where a delegate had been built for a new app but the map had not yet
// recomputed, and the dot came out undefined. One list means nothing to go
// stale against.
function withColors(apps) {
  var assigned = assignColors(apps)
  var out = []
  for (var i = 0; i < apps.length; i++) {
    var app = apps[i]
    out.push({
      name: app.name,
      rx: app.rx,
      tx: app.tx,
      total: app.total,
      share: app.share,
      color: assigned[app.name]
    })
  }
  return out
}

function formatShare(fraction) {
  var percent = Math.max(0, Math.min(1, fraction || 0)) * 100
  return (percent >= 10 || percent === 0 ? percent.toFixed(0) : percent.toFixed(1)) + "%"
}

function formatChange(bytes) {
  if (!bytes) return "no change"
  return (bytes > 0 ? "+" : "−") + formatBytes(Math.abs(bytes))
}

function formatDay(key) {
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  var parts = String(key).split("-")
  if (parts.length !== 3) return String(key)
  return months[Number(parts[1]) - 1] + " " + Number(parts[2])
}

var WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
var GLYPH_CALENDAR = codepoint(0xF00ED)  // md-calendar
var GLYPH_BACK = codepoint(0xF004D)      // md-arrow_left
var GLYPH_PREV = codepoint(0xF0141)      // md-chevron_left
var GLYPH_NEXT = codepoint(0xF0142)      // md-chevron_right
