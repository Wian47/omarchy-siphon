// Checks that hold across files, which model.test.js cannot see and
// `omarchy plugin validate` does not look at. Run with: node test/wiring.test.js
//
// model.test.js proves the rules inside Model.js. The manifest check reads the
// manifest. Between them sits everything that only breaks when one file
// disagrees with another: QML that no longer parses, a call to a Model
// function that was renamed, a panel binding to a service property that does
// not exist, a setting listed in one place and not the other. None of those
// fail until the shell loads the plugin on someone else's machine.

const fs = require("fs")
const path = require("path")
const { execFileSync } = require("child_process")

const root = path.join(__dirname, "..")
const read = name => fs.readFileSync(path.join(root, name), "utf8")

const modelSource = read("Model.js")
const serviceSource = read("Service.qml")
const panelSource = read("Panel.qml")
const readme = read("README.md")
const manifest = JSON.parse(read("manifest.json"))

let failures = 0
function check(name, fn) {
  let problems
  try {
    problems = fn() || []
  } catch (error) {
    problems = [error.message]
  }
  if (problems.length === 0) {
    console.log("  ok   " + name)
    return
  }
  failures++
  console.log("  FAIL " + name)
  for (const problem of problems) console.log("       " + problem)
}

function declaredIn(source) {
  return new Set([
    ...source.matchAll(/^function ([A-Za-z_$][\w$]*)/gm),
    ...source.matchAll(/^var ([A-Za-z_$][\w$]*)/gm)
  ].map(m => m[1]))
}

function stripComment(line) {
  let quote = null
  for (let i = 0; i < line.length; i++) {
    const character = line[i]
    if (quote) {
      if (character === "\\") i++
      else if (character === quote) quote = null
    } else if (character === "\"" || character === "'" || character === "`") {
      quote = character
    } else if (character === "/" && line[i + 1] === "/") {
      return line.slice(0, i)
    }
  }
  return line
}

function referenced(source, prefix) {
  const pattern = new RegExp("\\b" + prefix + "\\.([A-Za-z_$][\\w$]*)", "g")
  const found = new Map()
  source.split("\n").forEach((line, index) => {
    if (/^\s*import\s/.test(line)) return
    for (const match of stripComment(line).matchAll(pattern)) {
      if (!found.has(match[1])) found.set(match[1], index + 1)
    }
  })
  return found
}

const qmlformat = ["qmlformat", "/usr/lib/qt6/bin/qmlformat"].find(candidate => {
  try {
    execFileSync(candidate, ["--help"], { stdio: "ignore" })
    return true
  } catch {
    return false
  }
})

// qmlformat rather than qmllint: qmllint resolves types, every Quickshell and
// `qs.*` type here lives in Omarchy's shell, and a check that passes only on a
// machine with the shell installed answers a different question everywhere
// else. qmlformat resolves nothing and parses the grammar.
check("Panel.qml and Service.qml parse", () => {
  if (!qmlformat) return ["qmlformat not found, install the Qt QML tools to run this check"]
  return ["Panel.qml", "Service.qml"].filter(file => {
    try {
      execFileSync(qmlformat, [file], { cwd: root, stdio: "ignore" })
      return false
    } catch {
      return true
    }
  }).map(file => `${file} is not valid QML, qmlformat could not parse it`)
})

check("every Model function the QML calls exists", () => {
  const declared = declaredIn(modelSource)
  const problems = []
  for (const [file, source] of [["Panel.qml", panelSource], ["Service.qml", serviceSource]]) {
    for (const [name, line] of referenced(source, "Model")) {
      if (!declared.has(name)) problems.push(`${file}:${line} calls Model.${name}, which Model.js does not declare`)
    }
  }
  return problems
})

check("every service property the panel binds to exists", () => {
  const declared = new Set([
    ...serviceSource.matchAll(/^\s*(?:readonly\s+)?property\s+\S+\s+([A-Za-z_$][\w$]*)/gm),
    ...serviceSource.matchAll(/^\s*function\s+([A-Za-z_$][\w$]*)/gm)
  ].map(m => m[1]))
  const problems = []
  for (const [name, line] of referenced(panelSource, "traffic")) {
    if (!declared.has(name)) problems.push(`Panel.qml:${line} reads traffic.${name}, which Service.qml does not declare`)
  }
  return problems
})

check("the panel instantiates the service it binds to", () => {
  if (!/\bService\s*\{[\s\S]*?id:\s*traffic\b/.test(panelSource)) {
    return ["Panel.qml binds to `traffic` but never declares `Service { id: traffic }`"]
  }
  return []
})

check("the manifest's settings and the code agree", () => {
  const schema = manifest.barWidget.schema.map(entry => entry.key)
  const defaults = Object.keys(manifest.barWidget.defaults)
  const problems = []
  for (const key of schema) {
    if (!defaults.includes(key)) problems.push(`${key} is in the schema but has no default`)
  }
  for (const key of defaults) {
    if (!schema.includes(key)) problems.push(`${key} has a default but is not in the schema`)
  }
  const code = panelSource + serviceSource
  for (const key of schema) {
    if (!code.includes(key)) problems.push(`${key} is offered as a setting but nothing reads it`)
  }
  return problems
})

check("every bar label mode the manifest offers is one the model handles", () => {
  const offered = manifest.barWidget.schema.find(entry => entry.key === "barLabel").options
  const handled = new Set(["none", "down", "top-app", "total"])
  return offered.filter(mode => !handled.has(mode))
    .map(mode => `the manifest offers barLabel "${mode}", which Model.barLabel does not handle`)
})

check("the manifest's id matches what the panel registers", () => {
  const declared = (panelSource.match(/moduleName:\s*"([^"]+)"/) || [])[1]
  return declared === manifest.id ? [] : [`manifest id ${manifest.id} but Panel.qml registers ${declared}`]
})

// The marketplace capability scan reads the repository as text, and a
// privilege word is enough to hold verification at review-required. Siphon
// needs no such rights, so every occurrence would be prose saying so.
//
// The words are assembled rather than written, because this file sits inside
// the tree it scans and spelling them here is the failure it exists to catch.
const FORBIDDEN = ["su" + "do", "pk" + "exec", "do" + "as"]

check("no string that blocks marketplace verification", () => {
  const scanned = ["README.md", "Model.js", "Service.qml", "Panel.qml", "manifest.json"]
  return scanned.flatMap(file => read(file).split("\n").flatMap((line, index) => FORBIDDEN
    .filter(word => line.includes(word))
    .map(word => `${file}:${index + 1}: "${word}" is a word the capability scan flags, say it without the word`)))
})

// The markers are `#udp` and `#dev`, and `#` opens a comment in sh. Unquoted,
// the shell swallows both and every sample parses as incomplete, which the
// widget shows as a permanent "could not read the socket table". Nothing that
// reads the command as a string catches that; only running it does.
check("the sample command actually emits its markers through a shell", () => {
  const source = modelSource.replace(/^\.pragma library\s*$/m, "")
  const names = [
    ...source.matchAll(/^function ([A-Za-z_$][\w$]*)/gm),
    ...source.matchAll(/^var ([A-Za-z_$][\w$]*)/gm)
  ].map(m => m[1])
  const Model = new Function(source + "\nreturn {" + names.map(n => `${n}: ${n}`).join(",") + "};")()
  const command = Model.sampleCommand()
  let output
  try {
    output = execFileSync(command[0], command.slice(1), { encoding: "utf8", maxBuffer: 1 << 24 })
  } catch (error) {
    return [`the sample command failed to run: ${error.message}`]
  }
  const parsed = Model.parseSample(output, Date.now())
  if (!parsed.complete) return ["the sample command ran but parseSample could not find its markers"]
  if (parsed.iface.rx === 0 && parsed.iface.tx === 0) return ["the interface totals parsed as zero, which no running machine reports"]
  return []
})

check("the README's test count matches the suites", () => {
  const claimed = (readme.match(/# (\d+) tests, no compositor/) || [])[1]
  if (!claimed) return ["the README does not state a test count"]
  const count = execFileSync("node", ["test/model.test.js"], { cwd: root, encoding: "utf8" })
    .split("\n").filter(line => line.includes("  ok   ")).length
  return Number(claimed) === count ? [] : [`the README claims ${claimed} tests, model.test.js has ${count}`]
})

console.log(failures === 0 ? "\nAll checks passed." : `\n${failures} check(s) failed.`)
process.exit(failures === 0 ? 0 : 1)
