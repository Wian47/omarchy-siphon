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

console.log("\nHistory periods")

test("a period covers the days a person means by its name", () => {
  const range = (scope, key) => {
    const start = api.periodStart(scope, key)
    return [start, api.periodEnd(scope, start)]
  }
  assert.deepStrictEqual(range("day", "2026-09-04"), ["2026-09-04", "2026-09-04"])
  assert.deepStrictEqual(range("week", "2026-09-04"), ["2026-08-31", "2026-09-06"])
  assert.deepStrictEqual(range("month", "2026-09-04"), ["2026-09-01", "2026-09-30"])
  assert.deepStrictEqual(range("year", "2026-09-04"), ["2026-01-01", "2026-12-31"])
  assert.deepStrictEqual(range("month", "2028-02-14"), ["2028-02-01", "2028-02-29"])
})

// Anchoring a month on an arbitrary day is the classic way to lose one. The
// 31st of January has to become the 28th of February, and a month later it is
// still the 28th, so a year of stepping forward lands three days early.
test("stepping a month back and forward returns to where it started", () => {
  let key = api.periodStart("month", "2026-01-31")
  for (let i = 0; i < 14; i++) key = api.shiftPeriod("month", key, 1)
  for (let i = 0; i < 14; i++) key = api.shiftPeriod("month", key, -1)
  assert.strictEqual(key, "2026-01-01")
})

test("stepping a period crosses the boundary above it", () => {
  assert.strictEqual(api.shiftPeriod("day", "2026-01-01", -1), "2025-12-31")
  assert.strictEqual(api.shiftPeriod("week", "2026-08-31", 1), "2026-09-07")
  assert.strictEqual(api.shiftPeriod("month", "2026-12-01", 1), "2027-01-01")
  assert.strictEqual(api.shiftPeriod("month", "2026-01-01", -1), "2025-12-01")
  assert.strictEqual(api.shiftPeriod("year", "2026-01-01", 1), "2027-01-01")
})

console.log("\nHistory.periodInsights")

// Which day it is comes from the service rather than the clock, so these name
// it instead of depending on the day they happen to run.
const TODAY = "2026-09-30"

const fourDays = () => seed([
  ["2026-09-02", { brave: { rx: 100, tx: 0 } }],
  ["2026-09-03", { brave: { rx: 400, tx: 0 } }],
  ["2026-09-04", { brave: { rx: 300, tx: 0 }, spotify: { rx: 100, tx: 0 } }]
])

test("a day reads its top app, the week around it and the change since yesterday", () => {
  const day = api.periodInsights(fourDays(), "day", "2026-09-04", TODAY)
  assert.strictEqual(day.total, 400)
  assert.strictEqual(day.topApp.name, "brave")
  assert.strictEqual(day.topApp.share, 0.75)
  assert.strictEqual(day.previous, 400)
  assert.strictEqual(day.change, 0, "same as yesterday reads as no change")
  assert.strictEqual(day.from, "2026-09-04")
  assert.strictEqual(day.series.length, 7, "a day has no parts, so its strip is its week")
  assert.strictEqual(day.series[0].key, "2026-08-31", "the week starts on Monday")
  assert.strictEqual(day.busiest.key, "2026-09-03")
  assert.strictEqual(day.childScope, "day")
})

test("a fall since the period before is a negative change, not an absolute one", () => {
  const h = seed([
    ["2026-09-03", { brave: { rx: 1000, tx: 0 } }],
    ["2026-09-04", { brave: { rx: 250, tx: 0 } }]
  ])
  assert.strictEqual(api.periodInsights(h, "day", "2026-09-04", TODAY).change, -750)
})

test("a week totals its own days and compares against the week before", () => {
  const h = seed([
    ["2026-08-26", { brave: { rx: 1000, tx: 0 } }],
    ["2026-09-02", { brave: { rx: 100, tx: 0 } }],
    ["2026-09-03", { brave: { rx: 400, tx: 0 } }],
    ["2026-09-04", { spotify: { rx: 300, tx: 0 } }]
  ])
  const week = api.periodInsights(h, "week", "2026-09-04", TODAY)
  assert.deepStrictEqual([week.from, week.to], ["2026-08-31", "2026-09-06"])
  assert.strictEqual(week.total, 800)
  assert.strictEqual(week.previous, 1000, "the week before is the one it is measured against")
  assert.strictEqual(week.change, -200)
  assert.strictEqual(week.series.length, 7)
  assert.strictEqual(week.busiest.key, "2026-09-03")
  assert.strictEqual(week.topApp.name, "brave")
  assert.strictEqual(week.activeDays, 3)
  assert.strictEqual(week.childScope, "day", "clicking a bar in a week opens that day")
})

test("a month is a strip of its own days and a year is a strip of months", () => {
  const h = fourDays()
  const month = api.periodInsights(h, "month", "2026-09-04", TODAY)
  assert.strictEqual(month.series.length, 30)
  assert.strictEqual(month.series[0].key, "2026-09-01")
  assert.strictEqual(month.childScope, "day")

  const year = api.periodInsights(h, "year", "2026-09-04", TODAY)
  assert.strictEqual(year.series.length, 12)
  assert.strictEqual(year.series[8].key, "2026-09")
  assert.strictEqual(year.childScope, "month", "clicking a bar in a year opens that month")
  assert.strictEqual(year.total, 900, "the year holds every day the seed recorded")
})

// A period is 365 days but only the days up to today have been observed.
// Counting the rest as tracked would drag every average down as it went on.
test("only days up to today count as tracked", () => {
  const h = seed([["2026-01-10", { brave: { rx: 100, tx: 0 } }]])
  const year = api.periodInsights(h, "year", "2026-01-10", "2026-04-15")
  assert.strictEqual(year.trackedDays, api.daysBetween("2026-01-01", "2026-04-15") + 1)
  assert.strictEqual(year.trackedDays, 105)
  assert.ok(year.trackedDays < 366, "the rest of the year is not tracked yet")
})

// A pruned day keeps its bytes and loses its applications. Summing the apps
// would report a week as smaller than the days drawn in its own strip.
test("a period keeps the bytes of days whose applications aged out", () => {
  let h = seed([
    ["2026-05-01", { brave: { rx: 1000, tx: 0 } }],
    ["2026-09-04", { brave: { rx: 60, tx: 0 } }]
  ])
  h = api.prune(h, "2026-09-04", 95)
  assert.ok(!h.days["2026-05-01"], "the day under test has to be out of the detail window")

  const week = api.periodInsights(h, "week", "2026-05-01", TODAY)
  assert.strictEqual(week.total, 1000, "the bytes survive")
  assert.strictEqual(week.apps.length, 0, "the breakdown does not")

  const month = api.periodInsights(h, "month", "2026-05-01", TODAY)
  assert.strictEqual(month.total, 1000)
  assert.strictEqual(month.topApp.name, "brave", "a month keeps what it folded in")
})

test("an empty period answers without throwing", () => {
  for (const scope of api.SCOPES) {
    const empty = api.periodInsights(api.emptyHistory(), scope, "2026-09-04", TODAY)
    assert.strictEqual(empty.total, 0, scope + " total")
    assert.strictEqual(empty.topApp, null, scope + " top app")
    assert.strictEqual(empty.peak, null, scope + " peak")
    assert.strictEqual(empty.busiest, null, scope + " busiest")
    assert.strictEqual(empty.averagePerActiveDay, 0, scope + " average")
    assert.ok(empty.series.length > 0, scope + " strip")
  }
})

console.log(failures === 0 ? "\nAll tests passed." : `\n${failures} test(s) failed.`)
process.exit(failures === 0 ? 0 : 1)
