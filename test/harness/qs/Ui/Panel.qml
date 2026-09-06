import QtQuick
import qs.Commons

Item {
  id: root

  property var bar: null
  property string moduleName: ""
  property var settings: ({})
  property string ipcTarget: ""
  property bool manageIpc: true

  property bool opened: false
  readonly property color barForeground: bar ? bar.barForeground : Color.foreground

  function open() { root.opened = true }
  function close() { root.opened = false }
  function toggle() { root.opened = !root.opened }
  function switchPanel(direction) { return false }
  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }
}
