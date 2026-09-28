import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.subjektivdk.omagtasks"

  // qs.Commons/qs.Ui bar widgets only get "bar" and "settings" injected by
  // the host; a plugin dir is only handed to service-kind plugins via
  // manifest.__sourceDir. Deriving it from this file's own URL keeps
  // AuthManager's script paths working without needing that kind.
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    // Qt.resolvedUrl percent-encodes the path (spaces, non-ASCII, ...); the
    // Process commands built from this need the literal filesystem path.
    var path = url.indexOf("file://") === 0 ? decodeURIComponent(url.substring(7)) : url
    return path.length > 1 && path.charAt(path.length - 1) === "/"
      ? path.substring(0, path.length - 1) : path
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("pluginDir" in target) target.pluginDir = root.pluginDir
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  readonly property int openCount: panelLoader.item ? panelLoader.item.openCount || 0 : 0
  readonly property bool loggedIn: panelLoader.item ? panelLoader.item.loggedIn === true : false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    foreground: root.bar ? root.bar.barForeground : Color.foreground
    // No built-in label: the checkbox glyph and count digit are drawn
    // below as plain QML shapes/text instead. Unicode's own checkbox
    // glyphs (☐/☑) render through a fixed-color emoji font regardless of
    // theme, so this draws the same shape from primitives — a border
    // Rectangle plus a "✓" (U+2713, an ordinary punctuation mark with no
    // emoji-color variant) — to keep it one flat glyph that follows
    // bar.barForeground like every other bar icon.
    text: ""
    hasVisualContent: true
    fixedWidth: vertical ? barSize : Math.ceil(content.implicitWidth + scaledHorizontalMargin * 2)
    tooltipText: root.loggedIn
      ? (root.openCount > 0 ? root.openCount + " åbne opgaver — klik for at se dem" : "Ingen åbne opgaver")
      : "OmagTasks — klik for at logge ind"

    onPressed: root.togglePanel()

    Row {
      id: content
      anchors.centerIn: parent
      spacing: Style.space(4)

      Rectangle {
        id: checkbox
        anchors.verticalCenter: parent.verticalCenter
        width: Style.bar.iconFont
        height: width
        radius: Math.max(2, width * 0.2)
        color: "transparent"
        border.width: Math.max(1, width * 0.12)
        border.color: button.foreground

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: "✓"
          font.bold: true
          font.pixelSize: checkbox.height * 0.7
          color: button.foreground
        }
      }

      Text {
        visible: root.loggedIn && root.openCount > 0
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: String(root.openCount)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        color: button.foreground
      }
    }
  }
}
