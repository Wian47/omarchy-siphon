import QtQuick

Item {
  signal closeRequested()
  signal tabRequested(int direction)
  signal textKey(string text)
}
