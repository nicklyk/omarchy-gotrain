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
  moduleName: "nl.gotrain"
  ipcTarget: "nl.gotrain"
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

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool hasData: data && data.hasData === true
  readonly property int daysSince: data && data.daysSince !== null && data.daysSince !== undefined
    ? data.daysSince : -1
  readonly property bool stale: data ? data.stale === true : false
  readonly property var recent: data && data.recent ? data.recent : []
  readonly property var muscles: data && data.muscles ? data.muscles : []
  readonly property int pending: data && data.pending ? data.pending : 0

  readonly property int maxMuscleSets: {
    var m = 0
    for (var i = 0; i < muscles.length; i++) m = Math.max(m, muscles[i].sets)
    return m
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function refresh() {
    panelProc.running = false
    panelProc.running = true
  }

  function open() {
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
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
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
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
      }
    }
  }
}
