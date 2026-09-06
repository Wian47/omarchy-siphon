pragma Singleton
import QtQuick

// The shell's real Style resolves its scale from Hyprland and its family from
// fontconfig. The numbers here are what those resolve to unscaled, taken from
// the token defaults in /usr/share/omarchy/shell/Commons/Style.qml.
QtObject {
  readonly property int cornerRadius: 0

  function space(px) {
    return Math.round(px)
  }

  readonly property QtObject font: QtObject {
    readonly property string family: "monospace"
    readonly property int caption: 10
    readonly property int bodySmall: 11
    readonly property int body: 12
    readonly property int subtitle: 13
    readonly property int title: 14
    readonly property int display: 24
    readonly property int icon: 14
  }

  readonly property QtObject bar: QtObject {
    readonly property int sizeHorizontal: 26
  }
}
