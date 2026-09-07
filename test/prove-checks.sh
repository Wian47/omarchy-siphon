#!/usr/bin/env bash
# Proves wiring.test.js fails when each invariant it claims to guard is broken.
# A check nobody has watched fail is a check nobody knows works, and two of
# these have already passed for the wrong reason: the capability scan once
# flagged the words in its own source, and the Service check once flagged the
# comment explaining itself.
#
# Each case copies the plugin to a scratch directory, breaks one thing, and
# expects a non-zero exit. Run with: bash test/prove-checks.sh
set -u

SRC=$(cd "$(dirname "$0")/.." && pwd)
LAB=$(mktemp -d)
trap 'rm -rf "$LAB"' EXIT

pass=0
missed=0

run_suite() {
  if [ "$1" = render ]; then bash test/render.sh "$LAB/out"; else node "test/$1.test.js"; fi
}

attempt() {
  local name=$1 mutate=$2 suite=${3:-wiring}
  rm -rf "$LAB/repo"
  cp -r "$SRC" "$LAB/repo"
  rm -rf "$LAB/repo/.git"
  ( cd "$LAB/repo" && eval "$mutate" )
  if ( cd "$LAB/repo" && run_suite "$suite" >/dev/null 2>&1 ); then
    echo "  MISSED $name"
    missed=$((missed + 1))
  else
    echo "  caught $name"
    pass=$((pass + 1))
  fi
}

echo "Breaking one invariant at a time:"

attempt "a QML file that no longer parses" \
  "printf '\nItem { property int x: }\n' >> Service.qml"

attempt "a call to a Model function that does not exist" \
  "sed -i 's/Model\.formatBytes(/Model.formatBytesRenamed(/' Panel.qml"

attempt "a panel binding to a service property that does not exist" \
  "sed -i '0,/traffic\.loaded/s//traffic.isLoaded/' Panel.qml"

# The bug this one exists for cost two samplers and a race over the history
# file, and it is invisible to every check that reads a single file.
attempt "a Service built inside the panel, which the bar would build twice" \
  "sed -i '0,/  Loader {/s//  Service { id: rogue }\n\n  Loader {/' Panel.qml"

attempt "a panel that no longer asks the shell for the shared service" \
  "sed -i 's/serviceFor(\"wian47.siphon\")/serviceFor(\"wian47.something-else\")/' Panel.qml"

attempt "a manifest that stops declaring the service kind" \
  "node -e 'const f=\"manifest.json\";const m=require(\"./\"+f);m.kinds=[\"bar-widget\"];require(\"fs\").writeFileSync(f,JSON.stringify(m,null,2))'"

attempt "an entry point naming a file that is not in the plugin" \
  "node -e 'const f=\"manifest.json\";const m=require(\"./\"+f);m.entryPoints.service=\"Missing.qml\";require(\"fs\").writeFileSync(f,JSON.stringify(m,null,2))'"

attempt "a setting offered in the manifest that no code reads" \
  "node -e 'const f=\"manifest.json\";const m=require(\"./\"+f);m.barWidget.defaults.unusedKnob=1;m.barWidget.schema.push({key:\"unusedKnob\",type:\"boolean\",label:\"x\",defaultValue:true,description:\"x\"});require(\"fs\").writeFileSync(f,JSON.stringify(m,null,2))'"

attempt "a bar label mode the manifest offers and the model cannot render" \
  "node -e 'const f=\"manifest.json\";const m=require(\"./\"+f);m.barWidget.schema.find(e=>e.key===\"barLabel\").options.push(\"sideways\");require(\"fs\").writeFileSync(f,JSON.stringify(m,null,2))'"

attempt "a manifest id the panel does not register" \
  "sed -i 's/moduleName: \"wian47.siphon\"/moduleName: \"wian47.siphon-renamed\"/' Panel.qml"

# The scan reads the whole repository as text, so a sentence promising the
# plugin needs no privileges is itself enough to hold verification.
attempt "a privilege word in the shipped prose" \
  "printf '\nNo su%s required.\n' 'do' >> README.md"

# `#` opens a comment in sh. Unquoted, the markers never reach stdout and every
# sample parses as incomplete, which no check that reads the string can see.
attempt "sample markers the shell would swallow" \
  "sed -i \"s/echo '\\\" + UDP_MARK + \\\"'/echo \\\" + UDP_MARK + \\\"/\" Model.js"

attempt "a sample command that reads something it does not admit to" \
  "sed -i 's|cat /proc/net/dev|cat /proc/net/dev; cat /etc/hostname|' Model.js"

attempt "a README test count that no longer matches the suite" \
  "sed -i 's/# [0-9]* tests, no compositor/# 999 tests, no compositor/' README.md"

attempt "a history bucket that double counts at the retention boundary" \
  "sed -i 's/if (stale.indexOf(live) < 0) days\[live\] = history.days\[live\]/days[live] = history.days[live]/' History.js" \
  history

attempt "a day series that skips its last day" \
  "sed -i 's/if (key === toKey) break/if (key === shiftDays(toKey, -1)) break/' History.js" \
  history

attempt "a focus that reads every application instead of the one asked for" \
  "sed -i 's/  var found = bucket.apps\[app\]/  var found = null/' History.js" \
  history

attempt "a focused period totalled from days that no longer name their applications" \
  "sed -i 's/if (app) return focusOn(periodBucket/if (false) return focusOn(periodBucket/' History.js" \
  history

attempt "a period that claims a breakdown for days that lost one" \
  "sed -i 's/return totals.detailed || totals.rx + totals.tx === 0/return true/' History.js" \
  history

attempt "an ordinal that calls the thirteenth the thirteen-third" \
  "sed -i 's/teen >= 11 \&\& teen <= 13/false/' Model.js" \
  model

attempt "a colour scheme that hands two apps the same colour" \
  "sed -i 's/if (!taken\[candidate\]) {/if (true) {/' Model.js" \
  model

attempt "a bar label that stops holding its width" \
  "sed -i 's/while (out.length < width) out = out + PAD/out = out/' Model.js" \
  model

attempt "a README history count that no longer matches the suite" \
  "sed -i 's/# [0-9]* tests for the stored history/# 999 tests for the stored history/' README.md"

# The panel is only rendered where the Qt QML tools are installed, and a suite
# that skips cannot be watched failing.
if command -v qml6 >/dev/null 2>&1; then
  attempt "a strip that stops following the day being read" \
    "sed -i 's/readonly property bool isShown: root.scope === \"day\" \&\& cell.modelData.key === root.period.from/readonly property bool isShown: cell.modelData.key === root.reachable/' Panel.qml" \
    render

  attempt "a part of the calendar that has not happened offered as something to open" \
    "sed -i 's|readonly property bool readable: cell.modelData.key <= root.reachable|readonly property bool readable: true|' Panel.qml" \
    render

  attempt "a size button that does not change the size" \
    "sed -i 's/onClicked: root.selectScope(filter.modelData)/onClicked: root.selectScope(root.scope)/' Panel.qml" \
    render

  attempt "an arrow offering to step past today" \
    "sed -i 's/enabled: root.period.to < root.todayKey/enabled: true/' Panel.qml" \
    render

  attempt "a bar that no longer opens what it is a part of" \
    "sed -i 's/onClicked: root.openChild(cell.modelData.key)/onClicked: root.stepPeriod(0)/' Panel.qml" \
    render

  attempt "a legend row that does not narrow the period to its application" \
    "sed -i 's/onClicked: root.toggleFocus(entry.modelData.name)/onClicked: root.toggleFocus(\"\")/' Panel.qml" \
    render

  attempt "a focus dropped by stepping to the period next door" \
    "sed -i 's|function stepPeriod(count) {|function stepPeriod(count) { root.focusApp = \"\"|' Panel.qml" \
    render

  attempt "a flat strip left to pass for a quiet one" \
    "sed -i 's|visible: root.focusApp !== \"\" \&\& (root.period.partial |visible: false \&\& (root.period.partial |' Panel.qml" \
    render
else
  echo "  skip   the eight period and focus control breaks, qml6 is not installed"
fi

echo
if [ "$missed" -eq 0 ]; then
  echo "All $pass checks caught the break they exist for."
  exit 0
fi
echo "$missed of $((pass + missed)) breaks went unnoticed."
exit 1
