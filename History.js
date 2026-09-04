.pragma library

// Persistent network history, and every question the panel asks of it.
//
// On disk:
//   {
//     days:   { "2026-09-04": { rx, tx, un: {rx,tx}, apps: { brave: {rx,tx} } } },
//     months: { "2026-09":    { rx, tx, un: {rx,tx}, apps: { brave: {rx,tx} } } },
//     years:  { "2026":       { "2026-01-15": { rx, tx } } }
//   }
//
// `days` holds full detail for the retention window. When a day falls out of
// it, its app breakdown is folded into `months` and its totals are kept in
// `years`, so the calendar charts still have a bar for a day whose per-app
// detail has been let go. A day exists in exactly one of the two places, so
// nothing is counted twice.
//
// Every function here is pure. Service.qml owns the disk.

var KEEP_DAYS = 95

function pad2(n) {
  return n < 10 ? "0" + n : String(n)
}

function dayKey(date) {
  return date.getFullYear() + "-" + pad2(date.getMonth() + 1) + "-" + pad2(date.getDate())
}

function monthOf(key) {
  return String(key).slice(0, 7)
}

function yearOf(key) {
  return String(key).slice(0, 4)
}

function dateOf(key) {
  var parts = String(key).split("-")
  return new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
}

function shiftDays(key, count) {
  var date = dateOf(key)
  date.setDate(date.getDate() + count)
  return dayKey(date)
}

function daysBetween(fromKey, toKey) {
  return Math.round((dateOf(toKey).getTime() - dateOf(fromKey).getTime()) / 86400000)
}

function newBucket() {
  return { rx: 0, tx: 0, un: { rx: 0, tx: 0 }, apps: {} }
}

function emptyHistory() {
  return { days: {}, months: {}, years: {} }
}

function readBucket(raw) {
  var bucket = newBucket()
  if (!raw || typeof raw !== "object") return bucket
  bucket.rx = Number(raw.rx) || 0
  bucket.tx = Number(raw.tx) || 0
  if (raw.un && typeof raw.un === "object") {
    bucket.un.rx = Number(raw.un.rx) || 0
    bucket.un.tx = Number(raw.un.tx) || 0
  }
  if (raw.apps && typeof raw.apps === "object") {
    for (var name in raw.apps) {
      var app = raw.apps[name]
      if (!app || typeof app !== "object") continue
      bucket.apps[name] = { rx: Number(app.rx) || 0, tx: Number(app.tx) || 0 }
    }
  }
  return bucket
}

// Anything read off disk has been edited, truncated, or written by an older
// version. Every field is re-derived rather than trusted.
function readHistory(raw) {
  var history = emptyHistory()
  if (!raw || typeof raw !== "object") return history
  var section
  for (section in (raw.days || {})) {
    if (/^\d{4}-\d{2}-\d{2}$/.test(section)) history.days[section] = readBucket(raw.days[section])
  }
  for (section in (raw.months || {})) {
    if (/^\d{4}-\d{2}$/.test(section)) history.months[section] = readBucket(raw.months[section])
  }
  for (var year in (raw.years || {})) {
    if (!/^\d{4}$/.test(year)) continue
    var archive = raw.years[year]
    if (!archive || typeof archive !== "object") continue
    var kept = {}
    for (var key in archive) {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(key)) continue
      var day = archive[key]
      if (!day || typeof day !== "object") continue
      kept[key] = { rx: Number(day.rx) || 0, tx: Number(day.tx) || 0 }
    }
    history.years[year] = kept
  }
  return history
}

function mergeInto(bucket, delta) {
  var out = {
    rx: bucket.rx,
    tx: bucket.tx,
    un: { rx: bucket.un.rx, tx: bucket.un.tx },
    apps: {}
  }
  for (var kept in bucket.apps) {
    out.apps[kept] = { rx: bucket.apps[kept].rx, tx: bucket.apps[kept].tx }
  }
  var apps = delta.apps || {}
  for (var name in apps) {
    var moved = apps[name]
    var app = out.apps[name] || { rx: 0, tx: 0 }
    app.rx += moved.rx || 0
    app.tx += moved.tx || 0
    out.apps[name] = app
    out.rx += moved.rx || 0
    out.tx += moved.tx || 0
  }
  var loose = delta.unattributed || { rx: 0, tx: 0 }
  out.un.rx += loose.rx || 0
  out.un.tx += loose.tx || 0
  return out
}

function isEmptyDelta(delta) {
  if (!delta) return true
  var loose = delta.unattributed || {}
  if (loose.rx || loose.tx) return false
  for (var name in (delta.apps || {})) return false
  return true
}

function record(history, key, delta) {
  if (isEmptyDelta(delta)) return history
  var days = {}
  for (var existing in history.days) days[existing] = history.days[existing]
  days[key] = mergeInto(days[key] || newBucket(), delta)
  return { days: days, months: history.months, years: history.years }
}

// Moves days past the retention window out of `days`, keeping their app
// breakdown at month resolution and their totals at day resolution.
function prune(history, todayKey, keepDays) {
  var keep = keepDays > 0 ? keepDays : KEEP_DAYS
  var stale = []
  for (var key in history.days) {
    if (daysBetween(key, todayKey) >= keep) stale.push(key)
  }
  if (stale.length === 0) return history

  var days = {}
  for (var live in history.days) {
    if (stale.indexOf(live) < 0) days[live] = history.days[live]
  }
  var months = {}
  for (var month in history.months) months[month] = history.months[month]
  var years = {}
  for (var year in history.years) years[year] = history.years[year]

  for (var i = 0; i < stale.length; i++) {
    var dropped = stale[i]
    var bucket = history.days[dropped]
    var mk = monthOf(dropped)
    months[mk] = mergeInto(months[mk] || newBucket(), {
      apps: bucket.apps,
      unattributed: bucket.un
    })
    var yk = yearOf(dropped)
    var archive = {}
    for (var seen in (years[yk] || {})) archive[seen] = years[yk][seen]
    archive[dropped] = { rx: bucket.rx, tx: bucket.tx }
    years[yk] = archive
  }
  return { days: days, months: months, years: years }
}

function dayTotals(history, key) {
  var live = history.days[key]
  if (live) return { rx: live.rx, tx: live.tx, un: live.un, apps: live.apps, detailed: true }
  var archived = (history.years[yearOf(key)] || {})[key]
  if (archived) {
    return { rx: archived.rx, tx: archived.tx, un: { rx: 0, tx: 0 }, apps: {}, detailed: false }
  }
  return { rx: 0, tx: 0, un: { rx: 0, tx: 0 }, apps: {}, detailed: false }
}

function monthTotals(history, monthKey) {
  var total = readBucket(history.months[monthKey])
  for (var key in history.days) {
    if (monthOf(key) !== monthKey) continue
    total = mergeInto(total, { apps: history.days[key].apps, unattributed: history.days[key].un })
  }
  return total
}

function yearTotals(history, year) {
  var total = newBucket()
  for (var month = 1; month <= 12; month++) {
    total = mergeInto(total, (function (bucket) {
      return { apps: bucket.apps, unattributed: bucket.un }
    })(monthTotals(history, year + "-" + pad2(month))))
  }
  return total
}

function monthSeries(history, year) {
  var out = []
  for (var month = 1; month <= 12; month++) {
    var key = year + "-" + pad2(month)
    var bucket = monthTotals(history, key)
    out.push({ key: key, month: month, rx: bucket.rx, tx: bucket.tx, total: bucket.rx + bucket.tx })
  }
  return out
}

function daySeries(history, fromKey, toKey) {
  var out = []
  var key = fromKey
  var guard = 0
  while (guard++ < 400) {
    var totals = dayTotals(history, key)
    out.push({ key: key, rx: totals.rx, tx: totals.tx, total: totals.rx + totals.tx })
    if (key === toKey) break
    key = shiftDays(key, 1)
  }
  return out
}

function weekStart(key, firstDay) {
  var date = dateOf(key)
  var offset = (date.getDay() - (firstDay || 1) + 7) % 7
  return shiftDays(key, -offset)
}

function rankApps(bucket, limit) {
  var out = []
  var total = 0
  for (var name in bucket.apps) {
    var app = bucket.apps[name]
    out.push({ name: name, rx: app.rx, tx: app.tx, total: app.rx + app.tx })
    total += app.rx + app.tx
  }
  out.sort(function (a, b) {
    if (b.total !== a.total) return b.total - a.total
    return a.name < b.name ? -1 : a.name > b.name ? 1 : 0
  })
  for (var i = 0; i < out.length; i++) {
    out[i].share = total > 0 ? out[i].total / total : 0
  }
  return limit > 0 ? out.slice(0, limit) : out
}

function activeDays(series) {
  var count = 0
  for (var i = 0; i < series.length; i++) if (series[i].total > 0) count++
  return count
}

function peakDay(series) {
  var best = null
  for (var i = 0; i < series.length; i++) {
    if (series[i].total <= 0) continue
    if (!best || series[i].total > best.total) best = series[i]
  }
  return best
}

function quietestDay(series) {
  var worst = null
  for (var i = 0; i < series.length; i++) {
    if (series[i].total <= 0) continue
    if (!worst || series[i].total < worst.total) worst = series[i]
  }
  return worst
}

function longestStreak(series) {
  var best = 0
  var run = 0
  for (var i = 0; i < series.length; i++) {
    if (series[i].total > 0) {
      run++
      if (run > best) best = run
    } else {
      run = 0
    }
  }
  return best
}

function seriesTotal(series) {
  var total = 0
  for (var i = 0; i < series.length; i++) total += series[i].total
  return total
}

function averagePerActiveDay(series) {
  var active = activeDays(series)
  return active > 0 ? seriesTotal(series) / active : 0
}

// The share of bytes the interface counted that no socket could account for.
// Mostly QUIC, which carries no per-socket counter, plus packet framing.
function unattributedShare(bucket) {
  var loose = bucket.un.rx + bucket.un.tx
  var seen = bucket.rx + bucket.tx + loose
  return seen > 0 ? loose / seen : 0
}

function yearRange(year) {
  return { from: year + "-01-01", to: year + "-12-31" }
}

// Everything the year view puts on a card. Numbers only: the panel owns the
// prose and the units, so these stay comparable and testable.
function yearInsights(history, year) {
  var range = yearRange(year)
  var series = daySeries(history, range.from, range.to)
  var today = dayKey(new Date())
  var tracked = []
  for (var i = 0; i < series.length; i++) {
    if (series[i].key <= today) tracked.push(series[i])
  }
  var months = monthSeries(history, year)
  var ranked = months.slice().sort(function (a, b) { return b.total - a.total })
  var busiest = []
  for (var m = 0; m < ranked.length && busiest.length < 2; m++) {
    if (ranked[m].total > 0) busiest.push(ranked[m])
  }
  var quietMonth = null
  for (var q = 0; q < months.length; q++) {
    if (months[q].total <= 0) continue
    if (!quietMonth || months[q].total < quietMonth.total) quietMonth = months[q]
  }
  var bucket = yearTotals(history, year)
  return {
    year: year,
    total: bucket.rx + bucket.tx,
    rx: bucket.rx,
    tx: bucket.tx,
    trackedDays: tracked.length,
    activeDays: activeDays(tracked),
    peak: peakDay(tracked),
    quietest: quietestDay(tracked),
    streak: longestStreak(tracked),
    averagePerActiveDay: averagePerActiveDay(tracked),
    topMonths: busiest,
    quietestMonth: quietMonth,
    unattributedShare: unattributedShare(bucket),
    apps: rankApps(bucket, 0)
  }
}

// Everything the today view needs, including the week it sits in.
function dayInsights(history, key) {
  var bucket = dayTotals(history, key)
  var start = weekStart(key, 1)
  var week = daySeries(history, start, shiftDays(start, 6))
  var yesterday = dayTotals(history, shiftDays(key, -1))
  var ranked = rankApps(bucket, 0)
  var busiest = peakDay(week)
  return {
    key: key,
    total: bucket.rx + bucket.tx,
    rx: bucket.rx,
    tx: bucket.tx,
    detailed: bucket.detailed,
    apps: ranked,
    topApp: ranked.length > 0 && ranked[0].total > 0 ? ranked[0] : null,
    week: week,
    weekStartKey: start,
    yesterday: yesterday.rx + yesterday.tx,
    change: (bucket.rx + bucket.tx) - (yesterday.rx + yesterday.tx),
    busiestOfWeek: busiest,
    unattributedShare: unattributedShare(bucket)
  }
}
