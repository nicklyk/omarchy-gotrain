import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Days since the last GoTrain workout, and the host for the detail popup.
//
// The pill reads a local SQLite archive through `gotrain status --json`; it
// never touches the network. Syncing is deliberately manual, so the only
// automatic work here is re-reading what is already on disk.
//
// Left click opens the popup, right click imports whatever LocalSend dropped,
// middle click just re-reads.
BarWidget {
  id: root
  moduleName: "nl.gotrain"

  // The bundled CLI, not whatever `gotrain` happens to be on PATH, so the
  // widget and its data layer are always the same version.
  readonly property string cli: Qt.resolvedUrl("bin/gotrain").toString().replace("file://", "")

  readonly property int staleDays: parseInt(setting("staleDays", 3)) || 3
  readonly property bool showDays: String(setting("showDays", true)) !== "false"

  property bool hasData: false
  property int daysSince: -1
  property bool stale: false
  property string lastPlan: ""
  property int weekCount: 0

  readonly property string glyph: "󱅝"              // nf-md-weight-lifter

  readonly property string dayLabel: {
    if (!hasData || daysSince < 0) return "—"
    if (daysSince === 0) return "today"
    return daysSince + "d"
  }

  readonly property string displayText: showDays ? glyph + "  " + dayLabel : glyph
  readonly property var verticalLines: showDays ? [glyph, dayLabel] : [glyph]

  readonly property string tooltip: {
    if (!hasData) return "GoTrain — no workouts imported yet"
    var when = daysSince === 0 ? "today"
      : daysSince === 1 ? "yesterday"
      : daysSince + " days ago"
    return "GoTrain — last: " + (lastPlan || "?") + " (" + when + ")"
      + "\nthis week: " + weekCount
  }

  function refresh() {
    statusProc.running = false
    statusProc.running = true
  }

  // shellQuote lives on the Util singleton, not on `bar` -- the bar README
  // says `bar.shellQuote`, but Bar.qml has no such method and calling it
  // throws before `run` is ever reached.
  function syncFromDrop() {
    if (bar) bar.run(Util.shellQuote(cli) + " sync")
  }

  // ---- Popup plumbing. Bar.findPanelWidget requires open/close/opened on the
  //      bar-widget root, and the popout coordinator identifies the panel by
  //      this widget, so the panel's shape is forwarded from here.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.openFromHotkey() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("cli" in target) target.cli = root.cli
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Component.onCompleted: refresh()

  Process {
    id: statusProc
    command: [root.cli, "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw === "") return
        try {
          var s = JSON.parse(raw)
          root.hasData = s.hasData === true
          root.daysSince = s.daysSince === null || s.daysSince === undefined ? -1 : s.daysSince
          root.lastPlan = s.lastPlan || ""
          root.weekCount = s.weekCount || 0
          // The CLI applies its own configured threshold; the widget setting
          // wins when the two disagree, since that is what the user edited.
          root.stale = root.hasData && root.daysSince >= root.staleDays
        } catch (e) {
          root.hasData = false
        }
      }
    }
  }

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

  IpcHandler {
    target: "nl.gotrain"

    // `gotrain import` calls this after a successful sync. A bar surface
    // exists per monitor, so relay to every instance rather than just the one
    // that owns the IPC target.
    function refresh(): void { root.broadcast("refresh") }
    function sync(): void { root.syncFromDrop() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: root.stale
    text: root.vertical ? "" : root.displayText
    labelVisible: !root.vertical
    hasVisualContent: true
    fixedHeight: root.vertical ? root.verticalLines.length * Style.bar.iconSlot : -1
    tooltipText: root.tooltip

    onPressed: function(b) {
      if (b === Qt.RightButton) root.syncFromDrop()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }

    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.verticalLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          // "today" is far too wide for a 28px bar; shrink long lines the way
          // the clock does rather than letting them clip.
          fontSize: modelData.length > 3 ? button.fontSize * 0.75
            : modelData.length > 2 ? button.fontSize * 0.9
            : button.fontSize
          color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        }
      }
    }
  }
}
