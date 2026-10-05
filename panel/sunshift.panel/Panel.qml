import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Sunshift in the bar: the night-light icon, and under it a panel in the look of
// Omarchy's own display and battery panels with everything
// Sunshift needs: today's curve, pause timer, schedule, colors and location.
//
// Data and changes go through the sunshift command: `panel` (one JSON object with
// status, schedule and today's curve), `set '<json>'` (the validated save),
// `locate <text>` and the pause commands. The bar icon only reads
// Sunshift's status file, so a closed panel starts no process.
Panel {
  id: root
  moduleName: "sunshift.panel"
  ipcTarget: "sunshift"
  manageIpc: false

  readonly property string bin: Quickshell.env("HOME") + "/.local/bin/sunshift"
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/sunshift"

  property var info: ({})            // what `sunshift panel` said
  property int remaining: 0          // seconds of pause left, counted down here between reads
  property string barError: ""
  property bool barPaused: false
  property int barTemperature: 0
  property string barPhase: ""
  property string note: ""
  property bool noteError: false
  property bool editingLocation: false
  property bool searching: false
  property bool locating: false      // Wi-Fi lookup running after the user switched it on
  property var results: []
  property var queue: []             // sunshift commands waiting for the one running
  property bool refreshAgain: false

  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property var cfg: info.config || ({})
  readonly property var sched: info.schedule || ({})
  readonly property var located: info.located || ({})
  readonly property bool solar: cfg.mode === "solar"
  readonly property bool loaded: info.ok === true
  readonly property int temperature: info.temperature !== undefined && info.temperature !== null ? Number(info.temperature) : barTemperature

  // ------------------------------------------------------------ helpers
  function parse(text) { try { return JSON.parse(String(text || "").trim() || "null") } catch (e) { return null } }
  function pad(n) { return (n < 10 ? "0" : "") + n }
  function clock(seconds) {
    var s = Math.max(0, Math.round(seconds))
    return pad(Math.floor(s / 3600)) + ":" + pad(Math.floor(s % 3600 / 60)) + ":" + pad(s % 60)
  }
  function shiftTime(hhmm, minutes) {
    var p = String(hhmm || "00:00").split(":")
    var t = ((parseInt(p[0], 10) * 60 + parseInt(p[1], 10) + minutes) % 1440 + 1440) % 1440
    return pad(Math.floor(t / 60)) + ":" + pad(t % 60)
  }
  function offsetText(value) {
    var v = Number(value) || 0
    if (!v) return "no offset"
    return Math.abs(v) + " min " + (v > 0 ? "later" : "earlier")
  }
  function placeName() {
    var l = cfg.location
    return l && l.name ? String(l.name).split(",")[0] : ""
  }
  // Day, sunset (getting warmer), night and sunrise, as Sunshift reports them.
  function phaseIcon(phase) {
    if (phase === "day") return "\udb81\udda8"
    if (phase === "sunset") return "\udb81\udd9b"
    if (phase === "sunrise") return "\udb81\udd9c"
    return "\udb81\udd94"
  }
  function phaseName(phase) {
    return ({ day: "day", sunset: "evening fade", night: "night", sunrise: "morning fade" })[phase] || ""
  }
  function css(c, alpha) {
    return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + alpha + ")"
  }
  function say(text, isError) {
    root.note = String(text || "")
    root.noteError = !!isError
    if (isError) noteTimer.stop()
    else noteTimer.restart()
  }

  // ------------------------------------------------------------ reading
  // Sunshift's service writes status.json every second; older than 12 s means it
  // is not running (the same rule as `sunshift status`).
  function readStatus(text) {
    var s = root.parse(text) || {}
    var fresh = s.updated !== undefined && Date.now() / 1000 - Number(s.updated) <= 12
    root.barError = s.error ? String(s.error) : (fresh ? "" : "Sunshift is not running.")
    root.barPaused = fresh && !!s.paused
    root.barTemperature = fresh && s.temperature !== undefined ? Number(s.temperature) : 0
    root.barPhase = fresh && s.phase ? String(s.phase) : ""
  }

  function refresh() {
    if (infoProc.running) { root.refreshAgain = true; return }
    infoProc.command = [root.bin, "panel"]
    infoProc.running = true
  }

  FileView {
    id: statusFile
    path: root.stateDir + "/status.json"
    watchChanges: false
    printErrors: false
    onLoaded: root.readStatus(text())
    onLoadFailed: root.readStatus("")
  }

  Timer { interval: 2000; running: true; repeat: true; triggeredOnStart: true; onTriggered: statusFile.reload() }
  Timer { interval: 3000; running: root.opened; repeat: true; onTriggered: root.refresh() }
  Timer { interval: 1000; running: root.opened && root.remaining > 0; repeat: true; onTriggered: root.remaining = Math.max(0, root.remaining - 1) }
  Timer { id: noteTimer; interval: 6000; onTriggered: root.note = "" }

  Process {
    id: infoProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var d = root.parse(text)
        if (!d) return
        if (d.ok === false) { root.say(d.error, true); return }
        root.info = d
        root.remaining = Number(d.remaining) || 0
      }
    }
    onRunningChanged: if (!running && root.refreshAgain) { root.refreshAgain = false; root.refresh() }
  }

  // ------------------------------------------------------------ changing
  // One sunshift command at a time; the panel reads everything again after each.
  function run(args, okText) {
    root.queue = root.queue.concat([{ args: args, okText: okText || "" }])
    root.next()
  }

  function next() {
    if (actionProc.running || root.queue.length === 0) return
    var job = root.queue[0]
    root.queue = root.queue.slice(1)
    actionProc.okText = job.okText
    actionProc.command = [root.bin].concat(job.args)
    actionProc.running = true
  }

  // Shows the change at once; a rejected change comes back with the next read.
  function change(changes, okText) {
    root.info = Object.assign({}, root.info, { config: Object.assign({}, root.cfg, changes) })
    root.run(["set", JSON.stringify(changes)], okText)
  }

  function pause(minutes) { root.run(["pause", "--minutes", String(minutes)], "Paused · the filter fades out") }
  function chooseMode(mode) {
    if (mode === root.cfg.mode) return
    if (mode === "solar" && !root.cfg.location) {
      root.editingLocation = true
      root.say("Choose your location first, then sun times switch on.", false)
      return
    }
    root.change({ mode: mode }, mode === "solar" ? "Sun times on" : "Fixed times on · location and offsets kept")
  }

  function search(text) {
    if (searchProc.running) return
    root.searching = true
    root.results = []
    root.say("Searching …", false)
    searchProc.command = [root.bin, "locate", String(text || "")]
    searchProc.running = true
  }

  function setAutoLocate(on) {
    if (on === !!root.cfg.auto_locate || root.locating) return
    root.locating = on
    if (on) root.say("Finding this place via Wi-Fi …", false)
    root.change({ auto_locate: on }, on ? "Wi-Fi location on · sun times follow this place" : "Wi-Fi location off · saved location kept")
  }

  function locatedText() {
    if (root.locating) return "Finding this place via Wi-Fi …"
    if (!root.cfg.auto_locate) return "Off: nothing about your surroundings leaves this computer."
    var sent = "Nearby Wi-Fi router addresses and signal strengths go to BeaconDB when you log in and every 12 hours. Network names are not sent."
    if (!root.located.time) return sent
    var when = Qt.formatTime(new Date(root.located.time * 1000), "hh:mm")
    return sent + "\n" + (root.located.error ? "Last try " + when + ": " + root.located.error : "Last found " + when + ".")
  }

  function choose(location) {
    root.editingLocation = false
    root.results = []
    root.change({ location: location, mode: "solar" }, "Location saved · sun times on")
  }

  Process {
    id: actionProc
    property string okText: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var d = root.parse(text)
        if (d && d.ok === false) root.say(d.error, true)
        else if (actionProc.okText) root.say(actionProc.okText, false)
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").trim().split("\n")
        var last = lines[lines.length - 1]
        if (last) root.say(last.replace(/^\w+Error: /, ""), true)
      }
    }
    onRunningChanged: if (!running) { root.locating = false; root.refresh(); statusFile.reload(); root.next() }
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.searching = false
        var d = root.parse(text)
        if (!d) { root.say("Location search failed.", true); return }
        if (d.ok === false) { root.say(d.error, true); return }
        root.results = d.results || []
        root.say(root.results.length ? "Choose a result. Sun times are then calculated on this computer." : "No results. Try a city name or postal code.", false)
      }
    }
  }

  // ------------------------------------------------------------ ipc
  ShellIpc {
    target: "sunshift"

    function state(): string {
      return JSON.stringify({
        opened: root.opened,
        loaded: root.loaded,
        temperature: root.temperature,
        mode: root.cfg.mode,
        place: root.placeName(),
        curvePoints: (root.info.curve || []).length,
        paused: !!root.info.paused,
        remaining: root.remaining,
        barError: root.barError,
        barPaused: root.barPaused,
        note: root.note,
        panelHeight: panel.height,
        contentHeight: panelColumn.implicitHeight,
        eveningButtons: eveningRow.visible ? (eveningRow.today ? 2 : 1) : 0,
        untilText: String(root.info.until_text || ""),
        barPhase: root.barPhase,
        barIcon: button.text.codePointAt(0).toString(16),
        suggestion: root.info.suggestion ? String(root.info.suggestion.name) : "",
        suggestionShown: suggestionRow.visible,
        suggestionHeight: suggestionRow.height,
        wifiSwitch: wifiRow.visible,
        wifiSwitchHeight: wifiRow.height,
        wifiOn: !!root.cfg.auto_locate,
        locating: root.locating
      })
    }
    function pause(minutes: string): string { root.pause(parseInt(minutes, 10) || 60); return "ok" }
    function resume(): string { root.run(["resume"], "Filter returns gradually"); return "ok" }
    function evening(which: string): string { root.run([which === "tomorrow" ? "tomorrow" : "evening"], ""); return "ok" }
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function show() { root.open() }
    function hide() { root.close() }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) { root.refresh(); root.note = "" } else root.editingLocation = false
  onInfoChanged: curve.requestPaint()
  onFgChanged: curve.requestPaint()

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barError !== "" ? "\uf071" : (root.barPaused ? "\uf04c" : root.phaseIcon(root.barPhase))
    active: root.barError !== ""
    tooltipText: root.opened ? "" : "Sunshift · " + (root.barError !== "" ? root.barError : (root.barPaused ? "paused" : root.barTemperature + " K" + (root.barPhase ? " · " + root.phaseName(root.barPhase) : "")))
      + "\nRight-click: pause 1 hour / resume"
    onPressed: function(b) {
      if (b === Qt.RightButton) root.run(["toggle"], "")
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // No cap of our own: the panel grows to its content and only the screen limits it.
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(12)

          // ---------- Hero: moon or sun · title/status · Kelvin ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroKelvin.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: root.phaseIcon(root.info.phase || root.barPhase)
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              width: Style.space(28)
              horizontalAlignment: Text.AlignHCenter
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(12)
              anchors.right: heroKelvin.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Sunshift"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: String(root.info.error || root.barError || (root.loaded ? root.info.status : "Reading …")).toUpperCase()
                color: (root.info.error || root.barError) ? Color.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }

            Text {
              id: heroKelvin
              textFormat: Text.PlainText
              text: root.temperature > 0 ? root.temperature + "K" : "—"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              font.bold: true
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // ---------- Today's curve ----------
          Canvas {
            id: curve
            width: parent.width
            height: Style.space(76)
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()

            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              var pts = root.info.curve || []
              var labelHeight = Style.font.caption + Style.space(6)
              var left = Style.space(6), right = width - Style.space(6)
              var top = Style.space(6), bottom = height - labelHeight
              function x(minute) { return left + (right - left) * minute / 1440 }
              function y(kelvin) { return bottom - (kelvin - 1800) / 4700 * (bottom - top) }

              ctx.lineWidth = 1
              ctx.strokeStyle = root.css(root.fg, 0.12)
              ctx.beginPath()
              for (var m = 0; m <= 1440; m += 360) {
                ctx.moveTo(Math.round(x(m)) + 0.5, top)
                ctx.lineTo(Math.round(x(m)) + 0.5, bottom)
              }
              ctx.stroke()

              if (pts.length > 1) {
                ctx.beginPath()
                for (var i = 0; i < pts.length; i++) {
                  if (i === 0) ctx.moveTo(x(0), y(pts[0]))
                  else ctx.lineTo(x(i * 15), y(pts[i]))
                }
                ctx.lineWidth = 2
                ctx.strokeStyle = root.css(Color.accent, 1)
                ctx.stroke()
                ctx.lineTo(x(1440), bottom)
                ctx.lineTo(x(0), bottom)
                ctx.closePath()
                ctx.fillStyle = root.css(Color.accent, 0.10)
                ctx.fill()

                var now = Number(root.info.now_minute) || 0
                var at = Math.min(pts.length - 1, Math.floor(now / 15))
                var kelvin = at + 1 < pts.length ? pts[at] + (pts[at + 1] - pts[at]) * (now / 15 - at) : pts[at]
                ctx.fillStyle = root.css(root.fg, 1)
                ctx.beginPath()
                ctx.arc(x(now), y(kelvin), Style.space(4), 0, Math.PI * 2)
                ctx.fill()
              }

              ctx.fillStyle = root.css(root.fg, 0.55)
              ctx.font = Style.font.caption + "px \"" + root.fontFamily + "\""
              ctx.textBaseline = "bottom"
              var labels = ["00", "06", "12", "18", "24"]
              for (var j = 0; j < labels.length; j++) {
                ctx.textAlign = j === 0 ? "left" : (j === labels.length - 1 ? "right" : "center")
                ctx.fillText(labels[j], j === 0 ? left : (j === labels.length - 1 ? right : x(j * 360)), height)
              }
            }
          }

          // ---------- Pause ----------
          PanelSeparator { foreground: root.fg }

          Column {
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(pauseHeader.implicitHeight, pauseValue.implicitHeight)

              PanelSectionHeader {
                id: pauseHeader
                text: "PAUSE"
                foreground: root.fg
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: pauseValue
                textFormat: Text.PlainText
                text: root.info.paused
                  ? (Number(root.info.until) === -1 ? "UNTIL YOU RESUME" : root.clock(root.remaining) + " · " + String(root.info.until_text).toUpperCase())
                  : "FILTER ON"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Row {
              id: presetRow
              visible: !root.info.paused
              width: parent.width
              spacing: Style.space(6)
              readonly property real cellWidth: (width - spacing * 2) / 3

              PanelButton { width: presetRow.cellWidth; text: "15 min"; onClicked: root.pause(15) }
              PanelButton { width: presetRow.cellWidth; text: "1 hour"; onClicked: root.pause(60) }
              PanelButton { width: presetRow.cellWidth; text: "3 hours"; onClicked: root.pause(180) }
            }

            // Until the evening starts today, and until it starts tomorrow. After
            // today's evening has begun both mean tomorrow, so only one shows.
            Row {
              id: eveningRow
              visible: !root.info.paused && !!root.info.tomorrow_sunset
              width: parent.width
              spacing: Style.space(6)
              readonly property bool today: !!root.info.next_sunset_today
              readonly property real cellWidth: today ? (width - spacing) / 2 : width

              PanelButton {
                visible: eveningRow.today
                width: eveningRow.cellWidth
                text: "Until next sunset"
                tooltipText: "Pause until the evening starts today" + (root.info.next_sunset ? " (" + root.info.next_sunset + ")" : "")
                onClicked: root.run(["evening"], "Paused until the evening starts")
              }
              PanelButton {
                width: eveningRow.cellWidth
                text: eveningRow.today ? "Until tomorrow's sunset" : "Until next sunset"
                tooltipText: "Pause until the evening starts tomorrow" + (root.info.tomorrow_sunset ? " (" + root.info.tomorrow_sunset + ")" : "")
                onClicked: root.run(["tomorrow"], "Paused until tomorrow evening")
              }
            }

            Row {
              id: pausedRow
              visible: !!root.info.paused
              width: parent.width
              spacing: Style.space(6)
              readonly property real cellWidth: (width - spacing * 2) / 3
              readonly property bool timed: Number(root.info.until) !== -1

              PanelButton {
                width: pausedRow.cellWidth
                text: "+5 min"
                enabled: pausedRow.timed
                onClicked: root.run(["extend", "--minutes", "5"], "Pause extended")
              }
              PanelButton {
                width: pausedRow.cellWidth
                text: "+1 hour"
                enabled: pausedRow.timed
                onClicked: root.run(["extend", "--minutes", "60"], "Pause extended")
              }
              PanelButton {
                width: pausedRow.cellWidth
                text: "Resume"
                active: true
                onClicked: root.run(["resume"], "Filter returns gradually")
              }
            }
          }

          // ---------- Schedule ----------
          PanelSeparator { foreground: root.fg }

          Column {
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(scheduleHeader.implicitHeight, scheduleValue.implicitHeight)

              PanelSectionHeader {
                id: scheduleHeader
                text: "SCHEDULE"
                foreground: root.fg
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: scheduleValue
                textFormat: Text.PlainText
                text: root.solar ? root.placeName().toUpperCase() : "SAME TIMES EVERY DAY"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Row {
              id: modeRow
              width: parent.width
              spacing: Style.space(6)
              readonly property real cellWidth: (width - spacing) / 2

              PanelButton {
                width: modeRow.cellWidth
                text: "Fixed times"
                active: root.loaded && !root.solar
                onClicked: root.chooseMode("manual")
              }
              PanelButton {
                width: modeRow.cellWidth
                text: "Sun times"
                active: root.solar
                onClicked: root.chooseMode("solar")
              }
            }

            TimeRow {
              label: "Day starts"
              value: root.solar ? (root.sched.morning || "—") : (root.cfg.morning || "—")
              detail: root.solar
                ? (root.info.sun && root.info.sun.sunrise ? "sunrise " + root.info.sun.sunrise + " · " + root.offsetText(root.cfg.sunrise_offset) : "no sunrise today · fixed time used")
                : ""
              step: root.solar ? 30 : 15
              canDown: !root.solar || Number(root.cfg.sunrise_offset) - 30 >= -360
              canUp: !root.solar || Number(root.cfg.sunrise_offset) + 30 <= 360
              onMoved: function(delta) {
                if (root.solar) root.change({ sunrise_offset: Number(root.cfg.sunrise_offset) + delta, mode: "solar" }, "Morning offset saved")
                else root.change({ morning: root.shiftTime(root.cfg.morning, delta) }, "Day start saved")
              }
            }

            TimeRow {
              label: "Evening starts"
              value: root.solar ? (root.sched.evening || "—") : (root.cfg.evening || "—")
              detail: root.solar
                ? (root.info.sun && root.info.sun.sunset ? "sunset " + root.info.sun.sunset + " · " + root.offsetText(root.cfg.sunset_offset) : "no sunset today · fixed time used")
                : ""
              step: root.solar ? 30 : 15
              canDown: !root.solar || Number(root.cfg.sunset_offset) - 30 >= -360
              canUp: !root.solar || Number(root.cfg.sunset_offset) + 30 <= 360
              onMoved: function(delta) {
                if (root.solar) root.change({ sunset_offset: Number(root.cfg.sunset_offset) + delta, mode: "solar" }, "Evening offset saved")
                else root.change({ evening: root.shiftTime(root.cfg.evening, delta) }, "Evening start saved")
              }
            }
          }

          // ---------- Colors and fade ----------
          PanelSeparator { foreground: root.fg }

          SliderBlock {
            title: "DAYTIME"
            unit: "K"
            key: "day"
            minimum: 2500
            maximum: 6500
            step: 100
            value: Number(root.cfg.day) || 6500
          }

          SliderBlock {
            title: "EVENING"
            unit: "K"
            key: "night"
            minimum: 1800
            maximum: 6500
            step: 100
            value: Number(root.cfg.night) || 4000
          }

          SliderBlock {
            title: "FADE"
            unit: "min"
            key: "transition"
            minimum: 10
            maximum: 180
            step: 10
            value: Number(root.cfg.transition) || 60
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "Lower Kelvin means warmer light. Fade is how long the change takes."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // ---------- Location ----------
          PanelSeparator { foreground: root.fg }

          Column {
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              implicitHeight: Math.max(locationHeader.implicitHeight, changeButton.implicitHeight)

              PanelSectionHeader {
                id: locationHeader
                text: "LOCATION"
                foreground: root.fg
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              PanelButton {
                id: changeButton
                text: root.editingLocation ? "Cancel" : "Change"
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                onClicked: {
                  root.editingLocation = !root.editingLocation
                  root.results = []
                }
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.cfg.location ? root.cfg.location.name + " · " + root.cfg.location.timezone : "No location chosen. Sun times need one."
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Item {
              id: suggestionRow
              visible: !root.cfg.location && !!root.info.suggestion
              width: parent.width
              implicitHeight: Math.max(suggestionText.implicitHeight, useButton.implicitHeight)

              Text {
                id: suggestionText
                anchors.left: parent.left
                anchors.right: useButton.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.info.suggestion ? "Suggested from your time zone: " + root.info.suggestion.name : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              PanelButton {
                id: useButton
                text: "Use"
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.choose(root.info.suggestion)
              }
            }

            Item {
              visible: root.editingLocation
              width: parent.width
              implicitHeight: Math.max(locationField.implicitHeight, searchButton.implicitHeight)

              TextField {
                id: locationField
                anchors.left: parent.left
                anchors.right: searchButton.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                placeholderText: "City, district or postal code"
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                foreground: root.fg
                horizontalPadding: Style.spacing.controlGap
                verticalPadding: Style.spacing.controlPaddingY
                onAccepted: root.search(text)
                Keys.onEscapePressed: root.editingLocation = false
                onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
              }

              PanelButton {
                id: searchButton
                text: root.searching ? "…" : "Search"
                enabled: !root.searching
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.search(locationField.text)
              }
            }

            Text {
              visible: root.editingLocation
              width: parent.width
              textFormat: Text.PlainText
              text: "Only the typed text goes to OpenStreetMap and Open-Meteo. Place data © OpenStreetMap contributors."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.editingLocation ? root.results : []

              CursorSurface {
                id: resultRow
                required property var modelData
                width: panelColumn.width
                implicitHeight: resultText.implicitHeight + Style.spacing.lg
                foreground: root.fg
                hasCursor: resultMouse.containsMouse

                Text {
                  id: resultText
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: resultRow.modelData.name + "\n" + resultRow.modelData.timezone
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                MouseArea {
                  id: resultMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.choose(resultRow.modelData)
                }
              }
            }
          }

          Column {
            id: wifiRow
            visible: root.editingLocation || !!root.cfg.auto_locate
            width: parent.width
            spacing: Style.space(6)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "Find location via Wi-Fi"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Row {
              id: wifiButtons
              width: parent.width
              spacing: Style.space(6)
              readonly property real cellWidth: (width - spacing) / 2

              PanelButton {
                width: wifiButtons.cellWidth
                text: "Off"
                active: !root.cfg.auto_locate && !root.locating
                enabled: !root.locating
                onClicked: root.setAutoLocate(false)
              }
              PanelButton {
                width: wifiButtons.cellWidth
                text: root.locating ? "Finding …" : "On"
                active: !!root.cfg.auto_locate || root.locating
                enabled: !root.locating
                onClicked: root.setAutoLocate(true)
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.locatedText()
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- What just happened ----------
          Text {
            visible: root.note !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: root.note
            color: root.noteError ? Color.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            wrapMode: Text.WordWrap
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }

  component PanelButton: Button {
    fontSize: Style.font.bodySmall
    foreground: root.fg
    fontFamily: root.fontFamily
    horizontalPadding: Style.spacing.controlPaddingX
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true
    opacity: enabled ? 1 : 0.4
  }

  // A start time with − / + buttons: 15-minute steps for fixed times, 30-minute
  // offsets for sun times.
  component TimeRow: Item {
    id: timeRow
    property string label: ""
    property string value: ""
    property string detail: ""
    property int step: 15
    property bool canDown: true
    property bool canUp: true
    signal moved(int delta)

    width: parent ? parent.width : 0
    implicitHeight: Math.max(timeLabels.implicitHeight, upButton.implicitHeight)

    Column {
      id: timeLabels
      anchors.left: parent.left
      anchors.right: timeValue.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        text: timeRow.label
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        width: parent.width
      }

      Text {
        visible: timeRow.detail !== ""
        textFormat: Text.PlainText
        text: timeRow.detail
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        width: parent.width
      }
    }

    Text {
      id: timeValue
      textFormat: Text.PlainText
      text: timeRow.value
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
      anchors.right: downButton.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
    }

    PanelButton {
      id: downButton
      width: Style.space(48)
      text: "−" + timeRow.step
      tooltipText: timeRow.step + " minutes earlier"
      enabled: timeRow.canDown
      anchors.right: upButton.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      onClicked: timeRow.moved(-timeRow.step)
    }

    PanelButton {
      id: upButton
      width: Style.space(48)
      text: "+" + timeRow.step
      tooltipText: timeRow.step + " minutes later"
      enabled: timeRow.canUp
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      onClicked: timeRow.moved(timeRow.step)
    }
  }

  // A Kelvin or minutes slider like the display panel's brightness; saved on release.
  component SliderBlock: Column {
    id: block
    property string title: ""
    property string unit: ""
    property string key: ""
    property real minimum: 0
    property real maximum: 1
    property real step: 1
    property real value: 0

    width: parent ? parent.width : 0
    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(blockHeader.implicitHeight, blockValue.implicitHeight)

      PanelSectionHeader {
        id: blockHeader
        text: block.title
        foreground: root.fg
        fontFamily: root.fontFamily
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: blockValue
        textFormat: Text.PlainText
        text: Math.round((slider.dragging ? slider.liveValue : block.value) / block.step) * block.step + " " + block.unit
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Item {
      width: parent.width
      height: slider.implicitHeight + Style.spacing.controlGap

      PanelSlider {
        id: slider
        bar: root.bar
        anchors.fill: parent
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(6)
        minimum: block.minimum
        maximum: block.maximum
        step: block.step
        integer: true
        value: block.value
        onReleased: function(v) {
          var changes = {}
          changes[block.key] = Math.round(v / block.step) * block.step
          root.change(changes, block.title.charAt(0) + block.title.slice(1).toLowerCase() + " saved")
        }
      }
    }
  }
}
