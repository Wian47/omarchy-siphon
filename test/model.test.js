// Tests for Model.js, the parsing and accounting layer. Run with: node test/model.test.js
//
// Model.js is a QML JavaScript resource, so it has a `.pragma library` line and
// no module exports. Loading it as plain source and evaluating it in a function
// scope keeps the shipped file free of a test-only export block while still
// letting the rules that decide "who is using the network" be checked without a
// compositor.

const fs = require("fs")
const path = require("path")
const assert = require("assert")

const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "")

const names = [
  ...source.matchAll(/^function ([A-Za-z_$][\w$]*)/gm),
  ...source.matchAll(/^var ([A-Za-z_$][\w$]*)/gm)
].map(m => m[1])
const api = new Function(source + "\nreturn {" + names.map(n => `${n}: ${n}`).join(",") + "};")()

let failures = 0
function test(name, fn) {
  try {
    fn()
    console.log("  ok   " + name)
  } catch (error) {
    failures++
    console.log("  FAIL " + name + "\n       " + error.message)
  }
}

function socketRecord(head, info) {
  return head + "\n\t " + info
}

function tcp(options) {
  const o = Object.assign({
    state: "ESTAB", local: "10.0.0.69:52710", peer: "93.184.216.34:443",
    app: "brave", pid: 4242, fd: 9, sent: 0, recv: 0
  }, options)
  return socketRecord(
    `${o.state} 0      0      ${o.local}      ${o.peer}   users:(("${o.app}",pid=${o.pid},fd=${o.fd}))`,
    `cubic wscale:7,10 rto:209 rtt:8.91/11.817 mss:1448 bytes_sent:${o.sent} bytes_acked:${o.sent} bytes_received:${o.recv} segs_out:110 segs_in:104`
  )
}

const NET_DEV = [
  "Inter-|   Receive                                                |  Transmit",
  " face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets",
  "    lo:  122549487  1000    0    0    0     0          0         0  122549487  1000",
  "  wlo1:  65770024774 500000 0    0    0     0          0         0  968013706  400000",
  " eno1:   2115913    2000    0    0    0     0          0         0  670598     1500",
  "docker0: 999999     10      0    0    0     0          0         0  888888     10",
  "br-70698e4729e1: 5  1 0 0 0 0 0 0 7 1"
].join("\n")

function sample(atMs, sockets, iface, udp) {
  return { atMs, sockets, iface: iface || { rx: 0, tx: 0 }, udp: udp || [] }
}

function prime(sockets, iface) {
  return api.applySample(api.emptyState(), sample(0, sockets, iface))
}

console.log("Model.parseSockets")

test("reads bytes and process out of a real ss record", () => {
  const parsed = api.parseSockets(tcp({ app: "gvfsd-smb", pid: 228775, sent: 10381, recv: 33717 }))
  assert.strictEqual(parsed.length, 1)
  assert.strictEqual(parsed[0].app, "gvfsd-smb")
  assert.strictEqual(parsed[0].pid, 228775)
  assert.strictEqual(parsed[0].sent, 10381)
  assert.strictEqual(parsed[0].recv, 33717)
})

test("keys a socket by both endpoints so two connections from one app stay apart", () => {
  const parsed = api.parseSockets([
    tcp({ local: "10.0.0.69:1111" }),
    tcp({ local: "10.0.0.69:2222" })
  ].join("\n"))
  assert.strictEqual(parsed.length, 2)
  assert.notStrictEqual(parsed[0].key, parsed[1].key)
})

test("drops loopback, because a local dev server is not network traffic", () => {
  const parsed = api.parseSockets([
    tcp({ local: "127.0.0.1:60364", peer: "127.0.0.1:3773", app: "t3code", recv: 954504 }),
    tcp({ local: "[::1]:8080", peer: "[::1]:5432", app: "psql", recv: 1000 }),
    tcp({ app: "brave", recv: 42 })
  ].join("\n"))
  assert.strictEqual(parsed.length, 1)
  assert.strictEqual(parsed[0].app, "brave")
})

test("skips a socket with no owning process rather than inventing one", () => {
  const orphan = socketRecord(
    "ESTAB 0      0      10.0.0.69:22      10.0.0.5:51234",
    "cubic bytes_sent:100 bytes_received:200"
  )
  assert.deepStrictEqual(api.parseSockets(orphan), [])
})

test("a record with no byte counters reads as zero, not NaN", () => {
  const bare = socketRecord(
    'ESTAB 0 0 10.0.0.69:1 10.0.0.2:443 users:(("curl",pid=1,fd=3))',
    "cubic wscale:7,10 rto:209"
  )
  const parsed = api.parseSockets(bare)
  assert.strictEqual(parsed[0].sent, 0)
  assert.strictEqual(parsed[0].recv, 0)
})

test("empty and malformed input parse to nothing", () => {
  assert.deepStrictEqual(api.parseSockets(""), [])
  assert.deepStrictEqual(api.parseSockets(null), [])
  assert.deepStrictEqual(api.parseSockets("\t orphan info line with no header"), [])
})

console.log("\nModel.parseNetDev")

test("sums real interfaces and ignores loopback, docker and bridges", () => {
  const total = api.parseNetDev(NET_DEV)
  assert.strictEqual(total.rx, 65770024774 + 2115913)
  assert.strictEqual(total.tx, 968013706 + 670598)
})

test("an empty table totals zero instead of throwing", () => {
  assert.deepStrictEqual(api.parseNetDev(""), { rx: 0, tx: 0 })
})

console.log("\nModel.applySample")

test("the first sample sets a baseline and reports no traffic", () => {
  const state = prime([{ key: "a", app: "brave", pid: 1, sent: 5000, recv: 90000 }])
  assert.strictEqual(state.apps.brave.rx, 0, "counters at startup are a baseline, not usage")
  assert.strictEqual(state.apps.brave.rxRate, 0)
})

test("counts only what moved between two samples", () => {
  const first = prime([{ key: "a", app: "brave", pid: 1, sent: 1000, recv: 2000 }])
  const state = api.applySample(first, sample(2000, [
    { key: "a", app: "brave", pid: 1, sent: 1500, recv: 12000 }
  ]))
  assert.strictEqual(state.apps.brave.rx, 10000)
  assert.strictEqual(state.apps.brave.tx, 500)
  assert.strictEqual(state.apps.brave.rxRate, 5000, "10000 bytes over 2 seconds")
})

test("a reused port whose counters went backwards is a new connection, not a negative delta", () => {
  const first = prime([{ key: "a", app: "brave", pid: 1, sent: 900000, recv: 900000 }])
  const state = api.applySample(first, sample(1000, [
    { key: "a", app: "brave", pid: 1, sent: 40, recv: 80 }
  ]))
  assert.strictEqual(state.apps.brave.rx, 80)
  assert.strictEqual(state.apps.brave.tx, 40)
})

test("a socket seen for the first time contributes its whole counter", () => {
  const first = prime([])
  const state = api.applySample(first, sample(1000, [
    { key: "new", app: "curl", pid: 7, sent: 10, recv: 5000 }
  ]))
  assert.strictEqual(state.apps.curl.rx, 5000)
})

test("an app keeps its session total after its last socket closes", () => {
  const first = prime([{ key: "a", app: "curl", pid: 7, sent: 0, recv: 0 }])
  const busy = api.applySample(first, sample(1000, [
    { key: "a", app: "curl", pid: 7, sent: 100, recv: 60000 }
  ]))
  const gone = api.applySample(busy, sample(2000, []))
  assert.strictEqual(gone.apps.curl.rx, 60000, "the total survives the socket")
  assert.strictEqual(gone.apps.curl.rxRate, 0, "but it is no longer moving")
  assert.strictEqual(gone.apps.curl.sockets, 0)
})

test("an app that closed without ever transferring is forgotten", () => {
  const first = prime([{ key: "a", app: "idle", pid: 7, sent: 0, recv: 0 }])
  const gone = api.applySample(first, sample(1000, []))
  assert.strictEqual(gone.apps.idle, undefined)
})

test("two sockets of one app add up under a single name", () => {
  const first = prime([
    { key: "a", app: "brave", pid: 1, sent: 0, recv: 0 },
    { key: "b", app: "brave", pid: 1, sent: 0, recv: 0 }
  ])
  const state = api.applySample(first, sample(1000, [
    { key: "a", app: "brave", pid: 1, sent: 0, recv: 300 },
    { key: "b", app: "brave", pid: 1, sent: 0, recv: 700 }
  ]))
  assert.strictEqual(state.apps.brave.rx, 1000)
  assert.strictEqual(state.apps.brave.sockets, 2)
})

console.log("\nModel unattributed traffic")

test("what the interface saw but no socket explains becomes the unattributed row", () => {
  const first = prime([{ key: "a", app: "brave", pid: 1, sent: 0, recv: 0 }], { rx: 0, tx: 0 })
  const state = api.applySample(first, sample(1000, [
    { key: "a", app: "brave", pid: 1, sent: 0, recv: 1000 }
  ], { rx: 5000, tx: 0 }))
  assert.strictEqual(state.unattributed.rx, 4000, "QUIC, framing and other users land here")
  assert.strictEqual(state.unattributed.rxRate, 4000)
})

test("attribution above the interface count never goes negative", () => {
  const first = prime([{ key: "a", app: "brave", pid: 1, sent: 0, recv: 0 }], { rx: 0, tx: 0 })
  const state = api.applySample(first, sample(1000, [
    { key: "a", app: "brave", pid: 1, sent: 0, recv: 9000 }
  ], { rx: 100, tx: 0 }))
  assert.strictEqual(state.unattributed.rx, 0)
})

test("names the apps holding UDP sockets, because QUIC bytes are unmeasurable", () => {
  const udp = [
    '0 0 10.0.0.69:56068 35.186.224.26:443 users:(("spotify",pid=428385,fd=35))',
    '0 0 10.0.0.69:40842 35.186.224.24:443 users:(("spotify",pid=428385,fd=37))',
    '0 0 10.0.0.69:40201 40.104.14.210:443 users:(("brave",pid=203553,fd=32))',
    "0 0 10.0.0.69%wlo1:68 10.0.0.1:67",
    '0 0 127.0.0.1:5353 127.0.0.1:5353 users:(("avahi",pid=1,fd=1))'
  ].join("\n")
  const owners = api.udpOwners(udp)
  assert.deepStrictEqual(owners.map(o => o.name), ["spotify", "brave"], "busiest first")
  assert.strictEqual(owners[0].sockets, 2)
  assert.strictEqual(owners[0].pid, 428385)
})

test("a machine with no QUIC in flight names nobody", () => {
  assert.deepStrictEqual(api.udpOwners(""), [])
  assert.deepStrictEqual(api.udpOwners("0 0 10.0.0.69%wlo1:68 10.0.0.1:67"), [])
})

console.log("\nModel.parseSample")

test("splits one command's output into sockets, UDP owners and interfaces", () => {
  const text = [
    tcp({ app: "brave", pid: 1, sent: 10, recv: 20 }),
    "#udp",
    '0 0 10.0.0.69:56068 35.186.224.26:443 users:(("spotify",pid=428385,fd=35))',
    "#dev",
    NET_DEV
  ].join("\n")
  const parsed = api.parseSample(text, 1234)
  assert.strictEqual(parsed.complete, true)
  assert.strictEqual(parsed.atMs, 1234)
  assert.deepStrictEqual(parsed.sockets.map(s => s.app), ["brave"])
  assert.deepStrictEqual(parsed.udp.map(u => u.name), ["spotify"])
  assert.strictEqual(parsed.iface.rx, 65770024774 + 2115913)
})

test("a truncated read is marked incomplete rather than counted as idle", () => {
  const parsed = api.parseSample(tcp({ recv: 500 }), 1)
  assert.strictEqual(parsed.complete, false)
  assert.deepStrictEqual(parsed.sockets, [], "half a sample must not look like zero traffic")
})

test("the sample command asks for exactly the three inputs the model parses", () => {
  const command = api.sampleCommand()
  assert.strictEqual(command[0], "sh")
  assert.match(command[2], /ss -tinpH/)
  assert.match(command[2], /ss -unpH/)
  assert.match(command[2], /\/proc\/net\/dev/)
})

console.log("\nModel.ranked")

test("ranks by current rate, not by session total", () => {
  const first = prime([
    { key: "a", app: "backup", pid: 1, sent: 0, recv: 0 },
    { key: "b", app: "video", pid: 2, sent: 0, recv: 0 }
  ])
  const bulk = api.applySample(first, sample(1000, [
    { key: "a", app: "backup", pid: 1, sent: 0, recv: 900000 },
    { key: "b", app: "video", pid: 2, sent: 0, recv: 0 }
  ]))
  const now = api.applySample(bulk, sample(2000, [
    { key: "a", app: "backup", pid: 1, sent: 0, recv: 900000 },
    { key: "b", app: "video", pid: 2, sent: 0, recv: 50000 }
  ]))
  assert.strictEqual(api.ranked(now)[0].name, "video", "the heavy sleeper does not hold the top row")
})

test("ties break by name so the list does not shuffle on its own", () => {
  const state = prime([
    { key: "b", app: "bravo", pid: 2, sent: 0, recv: 0 },
    { key: "a", app: "alpha", pid: 1, sent: 0, recv: 0 }
  ])
  assert.deepStrictEqual(api.ranked(state).map(a => a.name), ["alpha", "bravo"])
})

console.log("\nModel formatting")

test("rates read in the unit a person would say out loud", () => {
  assert.strictEqual(api.formatRate(0), "0 B/s")
  assert.strictEqual(api.formatRate(999), "999 B/s")
  assert.strictEqual(api.formatRate(1500), "1.50 kB/s")
  assert.strictEqual(api.formatRate(1500000), "1.50 MB/s")
  assert.strictEqual(api.formatRate(125000000), "125 MB/s")
})

test("sizes and rates use the same ladder with different tails", () => {
  assert.strictEqual(api.formatBytes(0), "0 B")
  assert.strictEqual(api.formatBytes(2400000), "2.40 MB")
  assert.strictEqual(api.formatBytes(3000000000000), "3.00 TB")
})

test("a negative or missing number formats as zero rather than NaN", () => {
  assert.strictEqual(api.formatRate(-5), "0 B/s")
  assert.strictEqual(api.formatBytes(undefined), "0 B")
})

console.log("\nModel.summary")

test("summary says what is happening in a sentence", () => {
  assert.strictEqual(api.summary(api.emptyState()), "Sampling")
  const idle = prime([{ key: "a", app: "brave", pid: 1, sent: 0, recv: 0 }])
  assert.strictEqual(api.summary(idle), "Nothing is using the network")
  const busy = api.applySample(idle, sample(1000, [
    { key: "a", app: "brave", pid: 1, sent: 2000, recv: 8000 }
  ]))
  assert.strictEqual(api.summary(busy), "8.00 kB/s down, 2.00 kB/s up")
})

test("traffic nobody can be charged for is still reported, not called idle", () => {
  const first = prime([], { rx: 0, tx: 0 })
  const loose = api.applySample(first, sample(1000, [], { rx: 5000, tx: 2000 }))
  assert.strictEqual(api.summary(loose), "5.00 kB/s down, 2.00 kB/s up, none of it attributable")
})

test("the unmeasured note names who holds QUIC sockets and stops at three", () => {
  const none = prime([])
  assert.strictEqual(api.unmeasuredNote(none), "")
  const four = api.applySample(none, sample(1000, [], { rx: 0, tx: 0 }, [
    { name: "spotify", pid: 1, sockets: 5 },
    { name: "brave", pid: 2, sockets: 2 },
    { name: "chrome", pid: 3, sockets: 1 },
    { name: "steam", pid: 4, sockets: 1 }
  ]))
  assert.strictEqual(api.unmeasuredNote(four), "spotify, brave, chrome and 1 more")
})

console.log("\nModel.barLabel")

// The label padding character, asserted here so a change to it fails loudly
// rather than silently widening every label by nothing.
const PAD = "\u00a0"

test("padding uses a character Qt will not trim", () => {
  assert.strictEqual(api.PAD, PAD)
})

function busyState(rx, tx, name) {
  const app = name || "brave"
  const first = prime([{ key: "a", app: app, pid: 1, sent: 0, recv: 0 }])
  return api.applySample(first, sample(1000, [
    { key: "a", app: app, pid: 1, sent: tx, recv: rx }
  ]))
}

test("each label mode says what it promises", () => {
  const first = prime([
    { key: "a", app: "brave", pid: 1, sent: 0, recv: 0 },
    { key: "b", app: "spotify", pid: 2, sent: 0, recv: 0 }
  ])
  const state = api.applySample(first, sample(1000, [
    { key: "a", app: "brave", pid: 1, sent: 1000, recv: 4000 },
    { key: "b", app: "spotify", pid: 2, sent: 0, recv: 500 }
  ]))
  assert.strictEqual(api.barLabel(state, "none"), "")
  assert.strictEqual(api.barLabel(state, "down"), "4.50 kB/s")
  assert.strictEqual(api.barLabel(state, "total"), "5.50 kB/s")
  assert.strictEqual(api.barLabel(state, "top-app"), "brave" + PAD.repeat(5))
})

test("an idle machine names no top app", () => {
  const state = prime([{ key: "a", app: "brave", pid: 1, sent: 0, recv: 0 }])
  assert.strictEqual(api.barLabel(state, "top-app"), PAD.repeat(10))
  assert.strictEqual(api.barLabel(state, "total"), PAD.repeat(4) + "0 B/s")
})

// The bar font is monospace, so equal character counts are equal pixel widths.
// Unpadded, the widget resizes every time the rate crosses a digit or a unit
// and shunts the icons beside it along the bar.
test("a rate label is the same width at every magnitude", () => {
  const widths = new Set()
  for (let exponent = 0; exponent < 16; exponent++) {
    for (const mantissa of [1, 1.5, 9.99, 12.3, 99, 125, 999]) {
      const rate = mantissa * Math.pow(10, exponent)
      widths.add(api.barLabel(busyState(rate, 0), "down").length)
      widths.add(api.barLabel(busyState(rate, rate), "total").length)
    }
  }
  widths.add(api.barLabel(prime([]), "total").length)
  assert.deepStrictEqual([...widths], [9], `rate labels varied in width: ${[...widths]}`)
})

test("an app-name label is the same width whatever the app is called", () => {
  const widths = new Set()
  for (const name of ["v", "brave", "gvfsd-smb", "claude-desktop", "a".repeat(60)]) {
    widths.add(api.barLabel(busyState(5000, 0, name), "top-app").length)
  }
  widths.add(api.barLabel(prime([]), "top-app").length)
  assert.deepStrictEqual([...widths], [10], `name labels varied in width: ${[...widths]}`)
})

test("a name too long to fit is cut with an ellipsis rather than overflowing", () => {
  assert.strictEqual(api.barLabel(busyState(5000, 0, "claude-desktop"), "top-app"), "claude-de\u2026")
})

console.log("\nModel presentation helpers")

test("colours in one chart are all different", () => {
  const apps = ["brave", "spotify", "curl", "claude", "t3code", "quickshell", "gvfsd-smb"]
    .map(name => ({ name }))
  const assigned = api.assignColors(apps)
  const used = apps.map(a => assigned[a.name])
  assert.strictEqual(new Set(used).size, apps.length, "two slices sharing a colour cannot be told apart")
})

test("more apps than colours reuses rather than running out", () => {
  const apps = Array.from({ length: 30 }, (unused, i) => ({ name: "app" + i }))
  const assigned = api.assignColors(apps)
  assert.strictEqual(Object.keys(assigned).length, 30)
  for (const name in assigned) assert.ok(/^#[0-9a-f]{6}$/.test(assigned[name]))
})

test("an app keeps its colour whatever its rank", () => {
  assert.strictEqual(api.appColor("brave"), api.appColor("brave"))
  assert.notStrictEqual(api.appColor("brave"), api.appColor("spotify"))
  assert.ok(/^#[0-9a-f]{6}$/.test(api.appColor("anything")))
  assert.ok(/^#[0-9a-f]{6}$/.test(api.appColor("")), "an unnamed app still gets a colour")
})

test("shares read as percentages and keep a decimal only when small", () => {
  assert.strictEqual(api.formatShare(0.75), "75%")
  assert.strictEqual(api.formatShare(0.014), "1.4%")
  assert.strictEqual(api.formatShare(0), "0%")
  assert.strictEqual(api.formatShare(1.4), "100%", "a share cannot exceed the whole")
})

test("a change carries its direction, and no change says so", () => {
  assert.strictEqual(api.formatChange(0), "no change")
  assert.strictEqual(api.formatChange(2400000), "+2.40 MB")
  assert.strictEqual(api.formatChange(-2400000), "\u22122.40 MB")
})

test("a day key reads as a date a person would say", () => {
  assert.strictEqual(api.formatDay("2026-09-04"), "Sep 4")
  assert.strictEqual(api.formatDay("2026-12-31"), "Dec 31")
  assert.strictEqual(api.formatDay("nonsense"), "nonsense")
})

console.log(failures === 0 ? "\nAll tests passed." : `\n${failures} test(s) failed.`)
process.exit(failures === 0 ? 0 : 1)
