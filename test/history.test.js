// Tests for History.js, the persistence and aggregation layer.
// Run with: node test/history.test.js

const fs = require("fs")
const path = require("path")
const assert = require("assert")

const source = fs.readFileSync(path.join(__dirname, "..", "History.js"), "utf8")
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

function delta(apps, un) {
  return { apps: apps || {}, unattributed: un || { rx: 0, tx: 0 } }
}

function seed(entries) {
  let history = api.emptyHistory()
  for (const [key, apps, un] of entries) history = api.record(history, key, delta(apps, un))
  return history
}

const grand = h => {
  let total = 0
  for (const key in h.days) total += h.days[key].rx + h.days[key].tx
  for (const key in h.months) total += h.months[key].rx + h.months[key].tx
  return total
}

console.log("History keys")

test("a date becomes a sortable key and survives the round trip", () => {
  assert.strictEqual(api.dayKey(new Date(2026, 8, 4)), "2026-09-04")
  assert.strictEqual(api.dayKey(new Date(2026, 0, 1)), "2026-01-01")
  assert.strictEqual(api.dayKey(api.dateOf("2026-12-31")), "2026-12-31")
  assert.strictEqual(api.monthOf("2026-09-04"), "2026-09")
  assert.strictEqual(api.yearOf("2026-09-04"), "2026")
})

test("shifting days crosses months, years and a leap day", () => {
  assert.strictEqual(api.shiftDays("2026-09-30", 1), "2026-10-01")
  assert.strictEqual(api.shiftDays("2026-01-01", -1), "2025-12-31")
  assert.strictEqual(api.shiftDays("2028-02-28", 1), "2028-02-29")
  assert.strictEqual(api.daysBetween("2026-09-01", "2026-09-30"), 29)
})

test("a week starts on Monday", () => {
  assert.strictEqual(api.weekStart("2026-09-04", 1), "2026-08-31")
  assert.strictEqual(api.weekStart("2026-08-31", 1), "2026-08-31")
})

console.log("\nHistory.record")

test("a tick lands in its day, split by app and totalled", () => {
  const h = seed([["2026-09-04", { brave: { rx: 100, tx: 20 } }, { rx: 5, tx: 1 }]])
  const day = h.days["2026-09-04"]
  assert.strictEqual(day.apps.brave.rx, 100)
  assert.strictEqual(day.rx, 100)
  assert.strictEqual(day.tx, 20)
  assert.deepStrictEqual(day.un, { rx: 5, tx: 1 })
})

test("repeated ticks add up rather than replace", () => {
  const h = seed([
    ["2026-09-04", { brave: { rx: 100, tx: 0 } }],
    ["2026-09-04", { brave: { rx: 50, tx: 0 } }],
    ["2026-09-04", { curl: { rx: 7, tx: 0 } }]
  ])
  assert.strictEqual(h.days["2026-09-04"].apps.brave.rx, 150)
  assert.strictEqual(h.days["2026-09-04"].rx, 157)
})

test("an empty tick does not create a day, so idle nights stay off the chart", () => {
  const h = api.record(api.emptyHistory(), "2026-09-04", delta({}, { rx: 0, tx: 0 }))
  assert.deepStrictEqual(Object.keys(h.days), [])
})

test("recording does not mutate the history it was given", () => {
  const before = seed([["2026-09-04", { brave: { rx: 100, tx: 0 } }]])
  const after = api.record(before, "2026-09-04", delta({ brave: { rx: 1, tx: 0 } }))
  assert.strictEqual(before.days["2026-09-04"].rx, 100)
  assert.strictEqual(after.days["2026-09-04"].rx, 101)
})

console.log("\nHistory.prune")

test("a day inside the window is left alone", () => {
  const h = seed([["2026-09-04", { brave: { rx: 100, tx: 0 } }]])
  assert.strictEqual(api.prune(h, "2026-09-05", 95), h, "unchanged history is returned as-is")
})

// The retention boundary is the one place a byte could be counted twice: once
// in the day it came from and again in the month it was folded into.
test("a pruned day moves rather than copies, so nothing is counted twice", () => {
  const h = seed([
    ["2026-01-01", { brave: { rx: 1000, tx: 100 } }],
    ["2026-09-04", { brave: { rx: 7, tx: 3 } }]
  ])
  const before = grand(h)
  const after = api.prune(h, "2026-09-04", 95)
  assert.strictEqual(after.days["2026-01-01"], undefined, "the raw day is gone")
  assert.strictEqual(after.months["2026-01"].rx, 1000, "its app detail is kept at month resolution")
  assert.deepStrictEqual(after.years["2026"]["2026-01-01"], { rx: 1000, tx: 100 })
  assert.strictEqual(grand(after), before, "the grand total is unchanged by pruning")
})

test("pruning twice changes nothing the second time", () => {
  const h = seed([["2026-01-01", { brave: { rx: 1000, tx: 100 } }]])
  const once = api.prune(h, "2026-09-04", 95)
  const twice = api.prune(once, "2026-09-04", 95)
  assert.strictEqual(grand(twice), grand(once))
  assert.deepStrictEqual(twice.months, once.months)
})

console.log("\nHistory aggregation")

test("a month adds its live days to whatever was already rolled up", () => {
  let h = seed([
    ["2026-01-01", { brave: { rx: 1000, tx: 0 } }],
    ["2026-01-31", { brave: { rx: 500, tx: 0 } }]
  ])
  h = api.prune(h, "2026-05-01", 95)
  h = api.record(h, "2026-01-15", delta({ curl: { rx: 25, tx: 0 } }))
  const month = api.monthTotals(h, "2026-01")
  assert.strictEqual(month.rx, 1525, "rolled-up days plus the live one")
  assert.strictEqual(month.apps.brave.rx, 1500)
  assert.strictEqual(month.apps.curl.rx, 25)
})

test("a year is the sum of its months", () => {
  const h = seed([
    ["2026-01-05", { brave: { rx: 100, tx: 0 } }],
    ["2026-06-05", { brave: { rx: 200, tx: 0 } }],
    ["2025-06-05", { brave: { rx: 999, tx: 0 } }]
  ])
  assert.strictEqual(api.yearTotals(h, "2026").rx, 300, "2025 stays out of it")
  assert.strictEqual(api.monthSeries(h, "2026").length, 12)
  assert.strictEqual(api.monthSeries(h, "2026")[0].total, 100)
})

test("a day that has aged out still has a bar, just no app breakdown", () => {
  let h = seed([["2026-01-01", { brave: { rx: 1000, tx: 100 } }]])
  h = api.prune(h, "2026-09-04", 95)
  const day = api.dayTotals(h, "2026-01-01")
  assert.strictEqual(day.rx, 1000)
  assert.strictEqual(day.detailed, false, "the panel should not claim to know which app")
  assert.deepStrictEqual(day.apps, {})
})

test("a day with no data reads as zero rather than undefined", () => {
  const day = api.dayTotals(api.emptyHistory(), "2026-09-04")
  assert.deepStrictEqual({ rx: day.rx, tx: day.tx, detailed: day.detailed }, { rx: 0, tx: 0, detailed: false })
})

test("a day series spans the range inclusively and fills the gaps", () => {
  const h = seed([["2026-09-02", { brave: { rx: 10, tx: 0 } }]])
  const series = api.daySeries(h, "2026-09-01", "2026-09-03")
  assert.deepStrictEqual(series.map(d => d.key), ["2026-09-01", "2026-09-02", "2026-09-03"])
  assert.deepStrictEqual(series.map(d => d.total), [0, 10, 0])
})

console.log("\nHistory insights")

test("apps rank by total with a share that sums to one", () => {
  const h = seed([["2026-09-04", {
    brave: { rx: 700, tx: 0 }, spotify: { rx: 200, tx: 0 }, curl: { rx: 100, tx: 0 }
  }]])
  const ranked = api.rankApps(api.dayTotals(h, "2026-09-04"), 2)
  assert.deepStrictEqual(ranked.map(a => a.name), ["brave", "spotify"])
  assert.strictEqual(ranked[0].share, 0.7)
})

test("peak, quietest, active count and streak read off a series", () => {
  const series = [
    { key: "a", total: 10 }, { key: "b", total: 0 }, { key: "c", total: 90 },
    { key: "d", total: 5 }, { key: "e", total: 40 }
  ]
  assert.strictEqual(api.peakDay(series).key, "c")
  assert.strictEqual(api.quietestDay(series).key, "d", "a day with no traffic is not the quietest, it is absent")
  assert.strictEqual(api.activeDays(series), 4)
  assert.strictEqual(api.longestStreak(series), 3)
  assert.strictEqual(api.seriesTotal(series), 145)
  assert.strictEqual(api.averagePerActiveDay(series), 145 / 4)
})

test("an empty series answers without throwing", () => {
  assert.strictEqual(api.peakDay([]), null)
  assert.strictEqual(api.quietestDay([]), null)
  assert.strictEqual(api.longestStreak([]), 0)
  assert.strictEqual(api.averagePerActiveDay([]), 0)
})

test("the unattributed share reports the size of the QUIC blind spot", () => {
  const h = seed([["2026-09-04", { brave: { rx: 750, tx: 0 } }, { rx: 250, tx: 0 }]])
  assert.strictEqual(api.unattributedShare(api.dayTotals(h, "2026-09-04")), 0.25)
  assert.strictEqual(api.unattributedShare(api.newBucket()), 0)
})

console.log("\nHistory.readHistory")

test("a file written by a future version keeps only what it understands", () => {
  const parsed = api.readHistory({
    days: { "2026-09-04": { rx: 5, tx: 1, apps: { brave: { rx: 5, tx: 1 } } }, "garbage": { rx: 9 } },
    months: { "2026-09": { rx: 2, tx: 0 }, "nope": { rx: 1 } },
    years: { "2026": { "2026-01-01": { rx: 3, tx: 0 }, "bad": { rx: 1 } }, "x": {} },
    future: "ignored"
  })
  assert.deepStrictEqual(Object.keys(parsed.days), ["2026-09-04"])
  assert.deepStrictEqual(Object.keys(parsed.months), ["2026-09"])
  assert.deepStrictEqual(Object.keys(parsed.years["2026"]), ["2026-01-01"])
})

test("nonsense on disk reads as an empty history rather than throwing", () => {
  for (const raw of [null, undefined, 42, "text", [], {}]) {
    assert.deepStrictEqual(api.readHistory(raw), api.emptyHistory())
  }
})

test("a string where a number should be reads as zero, not NaN", () => {
  const parsed = api.readHistory({ days: { "2026-09-04": { rx: "lots", tx: null, apps: { brave: "no" } } } })
  assert.strictEqual(parsed.days["2026-09-04"].rx, 0)
  assert.deepStrictEqual(parsed.days["2026-09-04"].apps, {})
})

console.log(failures === 0 ? "\nAll tests passed." : `\n${failures} test(s) failed.`)
process.exit(failures === 0 ? 0 : 1)
