// Drives Model.js against this machine's real sockets. Not part of the unit
// suite: it needs a live network, and it prints rather than asserts.
// Run with: node test/live.js [seconds]

const { execFileSync } = require("child_process")
const fs = require("fs")
const path = require("path")

const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "")
const names = [
  ...source.matchAll(/^function ([A-Za-z_$][\w$]*)/gm),
  ...source.matchAll(/^var ([A-Za-z_$][\w$]*)/gm)
].map(m => m[1])
const Model = new Function(source + "\nreturn {" + names.map(n => `${n}: ${n}`).join(",") + "};")()

const run = (cmd, args) => {
  try {
    return execFileSync(cmd, args, { encoding: "utf8", maxBuffer: 1 << 24 })
  } catch {
    return ""
  }
}

const collect = () => ({
  atMs: Date.now(),
  sockets: Model.parseSockets(run("ss", ["-tinpH"])),
  iface: Model.parseNetDev(fs.readFileSync("/proc/net/dev", "utf8")),
  udp: Model.udpOwners(run("ss", ["-unpH"]))
})

const ticks = Number(process.argv[2] || 5)
let state = Model.applySample(Model.emptyState(), collect())

let i = 0
const timer = setInterval(() => {
  state = Model.applySample(state, collect())
  const total = Model.totalRate(state)
  console.log(
    `\n[${++i}] down ${Model.formatRate(total.rx)}  up ${Model.formatRate(total.tx)}` +
    `  unattributed ${Model.formatRate(state.unattributed.rxRate)}` +
    `\n    unmeasured QUIC: ${state.udp.map(u => u.name + "(" + u.sockets + ")").join(", ") || "none"}`
  )
  for (const app of Model.ranked(state).slice(0, 5)) {
    console.log(
      "    " + app.name.padEnd(18) +
      ("↓ " + Model.formatRate(app.rxRate)).padEnd(16) +
      ("↑ " + Model.formatRate(app.txRate)).padEnd(16) +
      "session " + Model.formatBytes(app.rx + app.tx)
    )
  }
  if (i >= ticks) {
    clearInterval(timer)
    const attributed = Object.values(state.apps).reduce((n, a) => n + a.rx, 0)
    const seen = attributed + state.unattributed.rx
    console.log(
      "\ncoverage: " + (seen ? (100 * attributed / seen).toFixed(1) : "0") +
      "% of received bytes attributed to an application"
    )
  }
}, 2000)
