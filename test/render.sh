#!/usr/bin/env bash
# Renders the shipped Panel.qml offscreen and checks the week strip: exactly
# one lit day and it is the one being read, today marked wherever the panel is,
# no day the week has not reached made clickable, and a click that actually
# moves the panel. Everything below the panel's own root is the real file; the
# `qs.Ui` and `qs.Commons` types in test/harness stand in for Omarchy's.
#
# The images are the other half of it. A day view is a layout, and a layout is
# something to look at rather than something to assert about.
#
# Run with: bash test/render.sh [output directory]
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$ROOT/.render}

if ! command -v qml6 >/dev/null 2>&1; then
  echo "  skip  qml6 not found, install the Qt QML tools to render the panel"
  exit 0
fi

mkdir -p "$OUT"
QT_QPA_PLATFORM=offscreen \
QT_QUICK_BACKEND=software \
QT_ASSUME_STDERR_HAS_CONSOLE=1 \
QT_FORCE_STDERR_LOGGING=1 \
  qml6 -I "$ROOT/test/harness" "$ROOT/test/harness/render.qml" -- "$OUT"
