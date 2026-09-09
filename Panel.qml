import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Detail popup for the GoTrain bar widget: recent sessions, this week's
// count, an eight-week muscle balance, and the three ways to get data across
// from the phone.
//
// Everything rendered here comes from one `gotrain panel` call against the
// local SQLite archive. Nothing in this file reaches the network.
Panel {
  id: root
  moduleName: "nicklyk.gotrain"
  ipcTarget: "nicklyk.gotrain"
  // The bar widget owns the IPC target; a second handler on the same name
  // would collide with it.
  manageIpc: false

  property var anchorItem: null
  property string cli: "gotrain"

  // The bar tracks the widget mounted in its slot, not this nested panel, so
  // the popout coordinator has to identify the panel by that widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property var data: null
  property string loadError: ""

  property string activeTab: "overview"
  readonly property var config: data && data.config ? data.config : null
  // True while any field owns the keyboard, so PanelKeyCatcher stands down --
  // it runs at Keys.BeforeItem and would otherwise eat every keystroke before
  // the field saw it. NumberField exposes no activeFocus on its root, so go
  // through its `field` alias to the spin box.
  readonly property bool editing: watchField.activeFocus
    || staleField.field.activeFocus
    || portField.field.activeFocus
    || timeoutField.field.activeFocus

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  // Alpha over the surface, never Qt.darker: on a light theme darkening the
  // foreground *raises* contrast, so "muted" text would come out bolder than
  // the body text above it. Alpha recedes identically on any ground.
  readonly property color dim: Util.alpha(foreground, 0.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool hasData: data && data.hasData === true
  readonly property int daysSince: data && data.daysSince !== null && data.daysSince !== undefined
    ? data.daysSince : -1
  readonly property bool stale: data ? data.stale === true : false
  readonly property var recent: data && data.recent ? data.recent : []
  readonly property var muscles: data && data.muscles ? data.muscles : []
  readonly property int pending: data && data.pending ? data.pending : 0
  readonly property var progress: data && data.progress ? data.progress : []

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  function loadText(value, unit) {
    return (Math.round(value * 10) / 10) + (unit || "kg")
  }

  // Gain / loss is carried by the arrow and the sign, not by the colour. On
  // the `white` theme accent and urgent are both pure greys (chroma 0), so a
  // colour-only encoding would say nothing at all there.
  function changeGlyph(v) { return v > 0 ? "\u2191" : (v < 0 ? "\u2193" : "\u00b7") }
  function changeText(v, unit) {
    if (v === 0) return "\u00b7 no change"
    return changeGlyph(v) + " " + (v > 0 ? "+" : "") + loadText(v, unit)
  }
  // Color.accent, not bar.accent: the bar api exposes foreground, background
  // and urgent only -- there is no accent on it, and reading one yields
  // undefined. The singleton is theme-driven either way.
  readonly property color gain: Color.accent

  function changeColor(v) {
    return v > 0 ? root.gain : (v < 0 ? root.urgent : root.dim)
  }

  function progressTooltip(row) {
    return row.name + " \u00b7 " + row.sessions + " sessions\n"
      + loadText(row.first, row.unit) + " \u2192 " + loadText(row.current, row.unit)
      + "  (best " + loadText(row.best, row.unit) + ")"
      + (row.atBest && row.change > 0 ? "\nat personal best" : "")
  }

  readonly property int maxMuscleSets: {
    var m = 0
    for (var i = 0; i < muscles.length; i++) m = Math.max(m, muscles[i].sets)
    return m
  }

  readonly property bool showDays: String(setting("showDays", false)) === "true"

  function cfgValue(key, fallback) {
    return config && config[key] ? config[key].value : fallback
  }

  function cfgLabel(key, fallback) {
    return config && config[key] ? config[key].label : fallback
  }

  // shell.json write-through for presentation settings. updateEntryInline
  // REPLACES the entry rather than merging, so the whole thing is rebuilt or
  // other keys would be silently dropped. Applying locally first (and to the
  // host widget) makes the pill change on the click and stops a stale copy
  // being written straight back out. Mirrors clock/Panel.qml persistSettings.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // Behaviour settings live in the CLI config so a terminal `gotrain status`
  // agrees with the pill. Written through the CLI, which owns validation.
  function saveConfig(key, value) {
    configProc.running = false
    configProc.command = [root.cli, "config", "set", key, String(value)]
    configProc.running = true
  }

  // NumberField leaves the SpinBox's default locale formatting in place, which
  // renders a port as "8,765". Ports and second counts are plain integers, so
  // strip the grouping separator through the `field` alias.
  function plainDigits(spin) {
    if (!spin) return
    spin.locale = Qt.locale("C")
    spin.textFromValue = function(value, locale) { return String(value) }
    spin.valueFromText = function(text, locale) { return parseInt(text, 10) || 0 }
  }

  // Hand the keyboard back, or the catcher stays dead after the first edit.
  function endEditing() {
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  // Widgets are handed a bar *api* object, not the Bar itself, and on that api
  // centerHoverRevealSuppressed is a bound -- therefore read-only -- property.
  // Assigning to it throws. The function is the supported write path; the
  // assignment stays only as a fallback for a bar that lacks it.
  function setCenterHoverRevealSuppressed(value) {
    if (!root.bar) return
    if (typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if ("centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function refresh() {
    panelProc.running = false
    panelProc.running = true
  }

  function open() {
    root.controller.show()
    setCenterHoverRevealSuppressed(false)
    refresh()
  }

  function openFromHotkey() {
    root.controller.show()
    refresh()
    // Set after showing: showing hands over the popout coordinator, which
    // closes whichever panel was open, and that close clears the shared flag.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    // Hide first. A throw anywhere after this must not be able to leave the
    // panel stuck open -- which is exactly what a read-only property
    // assignment on the first line used to do.
    root.controller.hide()
    setCenterHoverRevealSuppressed(false)
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function toggleDays() {
    root.persistSettings({ showDays: !root.showDays })
  }

  // Jump straight to one tab, for a keybinding or `omarchy-shell nicklyk.gotrain
  // settings`.
  readonly property var tabs: ["overview", "progress", "settings"]

  function openTab(tab) {
    root.activeTab = root.tabs.indexOf(tab) >= 0 ? tab : "overview"
    if (!root.opened) root.openFromHotkey()
    else root.refresh()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function run(command) {
    if (root.bar) root.bar.run(command)
  }

  // shellQuote lives on the Util singleton, not on `bar` -- the bar README
  // says `bar.shellQuote`, but Bar.qml has no such method and calling it
  // throws before `run` is ever reached.
  function quotedCli() {
    return Util.shellQuote(root.cli)
  }

  // ---- Actions -------------------------------------------------------------

  function importFromDrop() {
    run(quotedCli() + " sync")
    close()
  }

  // `pair` prints a QR and blocks, so it needs somewhere visible to run.
  function pairPhone() {
    run("omarchy-launch-floating-terminal-with-presentation "
        + Util.shellQuote(root.cli + " pair"))
    close()
  }

  function openApp() {
    var url = data && data.appUrl ? data.appUrl : "https://niclick.org/GoTrain"
    run("omarchy-launch-webapp " + Util.shellQuote(url))
    close()
  }

  // ---- Formatting ----------------------------------------------------------

  function relativeDay(iso) {
    if (!iso) return "—"
    var d = new Date(iso)
    if (isNaN(d.getTime())) return "—"
    var today = new Date()
    var days = Math.floor((new Date(today.getFullYear(), today.getMonth(), today.getDate())
                           - new Date(d.getFullYear(), d.getMonth(), d.getDate())) / 86400000)
    if (days === 0) return "today"
    if (days === 1) return "yesterday"
    if (days < 7) return days + " days ago"
    return Qt.formatDateTime(d, "d MMM")
  }

  readonly property string headline: {
    if (loadError !== "") return "!"
    if (!hasData) return "—"
    if (daysSince === 0) return "0"
    return String(daysSince)
  }

  readonly property string subhead: {
    if (loadError !== "") return "could not read the archive"
    if (!hasData) return "no workouts imported yet"
    if (daysSince === 0) return "trained today"
    if (daysSince === 1) return "day since your last workout"
    return "days since your last workout"
  }

  Process {
    id: panelProc
    command: [root.cli, "panel", "-n", "8"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw === "") return
        try {
          root.data = JSON.parse(raw)
          root.loadError = ""
        } catch (e) {
          root.loadError = "unreadable output"
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err !== "" && !root.data) root.loadError = err
      }
    }
  }

  Process {
    id: configProc
    // Re-read after the write lands; bar.run is fire-and-forget and would
    // leave the form showing the previous value.
    onExited: function(code) {
      if (code !== 0) root.loadError = "could not save that setting"
      root.refresh()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Keys.BeforeItem means this catcher sees every keystroke first, so a
      // focused field would receive nothing without standing down here.
      blocked: root.editing
      onCloseRequested: root.close()
      onReturnRequested: root.importFromDrop()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroll.width
          spacing: Style.space(14)

          // Two sibling columns with exclusive `visible` rather than a
          // StackLayout: Column drops invisible children from implicitHeight,
          // so the popup fits the tab on show instead of the taller of the two.
          Connections {
            target: root
            function onActiveTabChanged() { scroll.contentY = 0 }
          }

          ButtonGroup {
            options: [{ value: "overview", label: "Overview" },
                      { value: "progress", label: "Progress" },
                      { value: "settings", label: "Settings" }]
            value: root.activeTab
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function(v) { root.activeTab = v }
          }

          // ================= OVERVIEW =================
          Column {
            width: parent.width
            spacing: Style.space(14)
            visible: root.activeTab === "overview"

          // ---- Hero: the one number this widget exists to show.
          Row {
            width: parent.width
            spacing: Style.space(14)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.headline
              color: root.stale ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge * 1.6
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Text {
                text: root.subhead
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                visible: root.hasData
                text: (root.data && root.data.lastPlan ? root.data.lastPlan : "?")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
              }

              Text {
                visible: root.hasData
                text: "this week: " + (root.data ? root.data.weekCount : 0)
                      + "   ·   total: " + (root.data ? root.data.totalWorkouts : 0)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---- A waiting LocalSend drop is the most likely reason the
          //      numbers above look stale, so say so instead of leaving the
          //      user to guess.
          Rectangle {
            visible: root.pending > 0
            width: parent.width
            height: pendingText.implicitHeight + Style.space(14)
            radius: Style.space(4)
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)

            Text {
              id: pendingText
              anchors.centerIn: parent
              width: parent.width - Style.space(16)
              wrapMode: Text.WordWrap
              text: root.pending + " export" + (root.pending === 1 ? "" : "s")
                    + " waiting in your drop folder — press Enter to import"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator { width: parent.width; visible: root.recent.length > 0 }

          PanelSectionHeader {
            visible: root.recent.length > 0
            text: "RECENT"
            foreground: root.dim
            fontFamily: root.fontFamily
          }

          Column {
            width: parent.width
            spacing: Style.space(5)
            visible: root.recent.length > 0

            Repeater {
              model: root.recent

              Item {
                required property var modelData
                width: column.width
                height: Style.space(18)

                Text {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width * 0.42
                  elide: Text.ElideRight
                  text: modelData.plan || "?"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  anchors.right: countText.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.relativeDay(modelData.ts)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  id: countText
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: (modelData.done || 0) + "/" + (modelData.total || 0)
                  color: (modelData.done || 0) >= (modelData.total || 0)
                    ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          PanelSeparator { width: parent.width; visible: root.muscles.length > 0 }

          PanelSectionHeader {
            visible: root.muscles.length > 0
            text: "LAST 8 WEEKS"
            foreground: root.dim
            fontFamily: root.fontFamily
          }

          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.muscles.length > 0

            Repeater {
              model: root.muscles

              Item {
                required property var modelData
                width: column.width
                height: Style.space(15)

                Text {
                  id: muscleName
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width * 0.32
                  elide: Text.ElideRight
                  text: modelData.muscle
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Rectangle {
                  anchors.left: muscleName.right
                  anchors.leftMargin: Style.space(6)
                  anchors.right: setsCount.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  height: Style.space(5)
                  radius: height / 2
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)

                  Rectangle {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    height: parent.height
                    radius: parent.radius
                    width: root.maxMuscleSets > 0
                      ? parent.width * (modelData.sets / root.maxMuscleSets) : 0
                    color: root.foreground
                    opacity: 0.65
                  }
                }

                Text {
                  id: setsCount
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.sets
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          PanelSeparator { width: parent.width }

          // ---- The three ways data gets here.
          Row {
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: [
                { icon: "󰇚", tip: "Import from your drop folder", act: "sync" },
                { icon: "󰐲", tip: "Pair phone with a QR code",    act: "pair" },
                { icon: "󰏌", tip: "Open GoTrain",                 act: "app"  }
              ]

              PanelActionButton {
                required property var modelData
                iconText: modelData.icon
                tooltipText: modelData.tip
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                onClicked: {
                  if (modelData.act === "sync") root.importFromDrop()
                  else if (modelData.act === "pair") root.pairPhone()
                  else root.openApp()
                }
              }
            }
          }
          }
          // =============== end OVERVIEW ===============

          // ================= PROGRESS =================
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.activeTab === "progress"

            PanelSectionHeader {
              text: "LOAD PER EXERCISE"
              foreground: root.dim
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              visible: root.progress.length === 0
              text: "No weights recorded yet. GoTrain stores the load you set "
                    + "for each exercise, so this fills in as you train."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: root.progress

              Item {
                id: progressRow
                required property var modelData
                width: column.width
                height: Style.space(24)

                readonly property real lo: Math.min.apply(null, modelData.series)
                readonly property real hi: Math.max.apply(null, modelData.series)

                Text {
                  id: exName
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width * 0.34
                  elide: Text.ElideRight
                  text: progressRow.modelData.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                // Sparkline. Bars rather than a line because load moves in
                // discrete plate-sized steps; a smoothed line would imply
                // values that were never lifted. One series, so one colour --
                // height already encodes magnitude and a ramp would say it twice.
                Row {
                  id: sparkline
                  anchors.left: exName.right
                  anchors.leftMargin: Style.space(8)
                  anchors.right: valueText.left
                  anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  height: Style.space(16)
                  spacing: Style.space(2)
                  layoutDirection: Qt.RightToLeft   // newest pinned to the right

                  readonly property int slot: Style.space(3) + spacing
                  readonly property int shown:
                    Math.max(1, Math.min(progressRow.modelData.series.length,
                                         Math.floor((width + spacing) / slot)))

                  Repeater {
                    model: sparkline.shown

                    Rectangle {
                      required property int index
                      // Right-to-left: index 0 is the newest reading.
                      readonly property int pos:
                        progressRow.modelData.series.length - 1 - index
                      readonly property real value: progressRow.modelData.series[pos]
                      readonly property real span: progressRow.hi - progressRow.lo

                      width: Style.space(3)
                      radius: Style.cornerRadius > 0 ? width / 2 : 0
                      // The floor is a third of the height, not a hairline: the
                      // lowest reading is still a lift, and a 3px stub reads as
                      // dirt on the screen rather than data. A flat series sits
                      // mid-height rather than collapsing.
                      readonly property real floorHeight: sparkline.height * 0.34
                      height: span > 0
                        ? floorHeight + (value - progressRow.lo) / span * (sparkline.height - floorHeight)
                        : sparkline.height * 0.5
                      anchors.bottom: parent.bottom
                      color: index === 0 ? root.foreground : Util.alpha(root.foreground, 0.45)
                    }
                  }
                }

                Text {
                  id: valueText
                  anchors.right: changeChip.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.loadText(progressRow.modelData.current, progressRow.modelData.unit)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  id: changeChip
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(72)
                  horizontalAlignment: Text.AlignRight
                  elide: Text.ElideRight
                  text: root.changeText(progressRow.modelData.change, progressRow.modelData.unit)
                  color: root.changeColor(progressRow.modelData.change)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  id: rowHover
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.NoButton
                }

                PanelToolTip {
                  visible: rowHover.containsMouse
                  text: root.progressTooltip(progressRow.modelData)
                  fontFamily: root.fontFamily
                }
              }
            }
          }
          // =============== end PROGRESS ===============

          // ================= SETTINGS =================
          Column {
            width: parent.width
            spacing: Style.space(12)
            visible: root.activeTab === "settings"

            PanelSectionHeader {
              text: "APPEARANCE"
              foreground: root.dim
              fontFamily: root.fontFamily
            }

            Toggle {
              width: parent.width
              label: "Show day count"
              description: "Put the number of days beside the icon in the bar"
              foreground: root.foreground
              fontFamily: root.fontFamily
              checked: root.showDays
              // Presentation lives on the bar entry, so this one writes
              // shell.json and the pill changes on the click.
              onClicked: root.toggleDays()
            }

            PanelSeparator { width: parent.width }

            PanelSectionHeader {
              text: "SYNC"
              foreground: root.dim
              fontFamily: root.fontFamily
            }

            NumberField {
              id: staleField
              Component.onCompleted: root.plainDigits(field)
              label: root.cfgLabel("staleDays", "Overdue after (days)")
              from: 1
              to: 365
              value: root.cfgValue("staleDays", 3)
              foreground: root.foreground
              fontFamily: root.fontFamily
              onModified: function(v) { root.saveConfig("staleDays", v) }
            }

            NumberField {
              id: portField
              Component.onCompleted: root.plainDigits(field)
              label: root.cfgLabel("port", "Pairing port")
              from: 1024
              to: 65535
              value: root.cfgValue("port", 8765)
              foreground: root.foreground
              fontFamily: root.fontFamily
              onModified: function(v) { root.saveConfig("port", v) }
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              visible: root.cfgValue("port", 8765) !== 8765
              text: "Changing the port needs a matching firewall rule: "
                    + "sudo ufw allow " + root.cfgValue("port", 8765) + "/tcp"
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            NumberField {
              id: timeoutField
              Component.onCompleted: root.plainDigits(field)
              label: root.cfgLabel("pairTimeout", "Pairing window (seconds)")
              from: 30
              to: 3600
              stepSize: 30
              value: root.cfgValue("pairTimeout", 300)
              foreground: root.foreground
              fontFamily: root.fontFamily
              onModified: function(v) { root.saveConfig("pairTimeout", v) }
            }

            Column {
              width: parent.width
              spacing: Style.space(4)

              Text {
                text: root.cfgLabel("watchDir", "Drop folder")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              TextField {
                id: watchField
                width: parent.width
                text: root.cfgValue("watchDir", "~/Downloads")
                foreground: root.foreground
                font.family: root.fontFamily
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) {
                    text = root.cfgValue("watchDir", "~/Downloads")
                    root.endEditing()
                    event.accepted = true
                  } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.saveConfig("watchDir", text)
                    root.endEditing()
                    event.accepted = true
                  }
                }
              }
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              visible: root.loadError !== ""
              text: root.loadError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
          // =============== end SETTINGS ===============
        }
      }
    }
  }
}
