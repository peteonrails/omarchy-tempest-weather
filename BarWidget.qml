import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "peteonrails.weather"

  property bool popupOpen: false
  property bool buttonHovered: false
  function closePopout() { popupOpen = false }

  Timer {
    id: closeDelay
    interval: 220
    onTriggered: {
      if (!root.buttonHovered && (!popup || !popup.containsMouse)) {
        root.popupOpen = false
      }
    }
  }

  function evaluateHover() {
    if (root.buttonHovered || (popup && popup.containsMouse)) {
      closeDelay.stop()
      root.popupOpen = true
      root.refresh()
    } else {
      closeDelay.restart()
    }
  }

  IpcHandler {
    target: "peteonrails.weather"
    function show(): void {
      root.popupOpen = true
      root.refresh()
      autoCloseTimer.start()
    }
  }

  Timer {
    id: autoCloseTimer
    interval: 5000
    onTriggered: root.popupOpen = false
  }

  // Station / token come from per-widget settings (shell.json layout entry).
  readonly property string stationId: String(setting("stationId", ""))
  readonly property string apiToken:  String(setting("token", ""))

  // Parsed Tempest better_forecast response. Kept on failure so stale data
  // stays visible.
  property var report: null

  readonly property var current: report && report.current_conditions ? report.current_conditions : null
  readonly property var forecastDays: report && report.forecast && Array.isArray(report.forecast.daily) ? report.forecast.daily.slice(0, 5) : []

  readonly property bool useImperial: {
    var override = setting("unit", "")
    if (override === "imperial") return true
    if (override === "metric") return false
    var name = String(Qt.locale().name || "")
    return /^en_US/.test(name) || /^en_LR/.test(name) || /^my/.test(name)
  }

  readonly property int refreshMinutes: Math.max(1, parseInt(setting("refreshMinutes", 15), 10) || 15)

  readonly property string reportLocation: {
    if (report && report.location_name) return String(report.location_name)
    if (current && current.station_name) return String(current.station_name)
    return ""
  }
  readonly property string reportCondition: current && current.conditions ? String(current.conditions) : ""
  readonly property string reportTempNum: current && current.air_temperature !== undefined
    ? String(Math.round(toDisplayTemp(current.air_temperature))) : ""
  readonly property string tempUnit: "°" + (useImperial ? "F" : "C")
  readonly property string reportFeels: current && current.feels_like !== undefined
    ? formatTemp(current.feels_like) : ""
  readonly property string reportWind: current && current.wind_avg !== undefined
    ? (useImperial
        ? (Math.round(current.wind_avg * 2.23694) + " mph")
        : (Math.round(current.wind_avg * 3.6)    + " km/h"))
    : ""
  readonly property string reportHumidity: current && current.relative_humidity !== undefined
    ? (Math.round(current.relative_humidity) + "%") : ""

  // The pill label is generated locally now rather than read from a shared
  // bar property. Icon + temperature, e.g. " 60°".
  readonly property string label: {
    if (!current) return ""
    var icon = iconForTempest(current.icon)
    var temp = reportTempNum ? (reportTempNum + "°") : ""
    if (!icon && !temp) return ""
    return icon + (icon && temp ? " " : "") + temp
  }
  readonly property string klass: current ? "active" : ""

  visible: label !== ""
  implicitWidth: button.implicitWidth + 8
  implicitHeight: button.implicitHeight

  function refresh() {
    if (!stationId || !apiToken) return
    if (!forecastProc.running) forecastProc.running = true
  }

  // One-line summary for the right-click notification.
  function notificationText() {
    if (!current) {
      if (!stationId || !apiToken) return "Tempest Weather: set stationId and token in settings"
      return "Tempest Weather: no data yet"
    }
    var parts = []
    if (reportLocation) parts.push(reportLocation)
    if (reportCondition) parts.push(reportCondition)
    if (reportTempNum) parts.push(reportTempNum + tempUnit)
    if (reportFeels) parts.push("feels " + reportFeels)
    if (reportWind) parts.push("wind " + reportWind)
    if (reportHumidity) parts.push("humidity " + reportHumidity)
    return parts.join("  ·  ")
  }

  function toDisplayTemp(celsius) {
    if (celsius === undefined || celsius === null) return NaN
    return useImperial ? (celsius * 9 / 5 + 32) : celsius
  }

  function formatTemp(celsius) {
    var v = toDisplayTemp(celsius)
    if (isNaN(v)) return ""
    return Math.round(v) + "°" + (useImperial ? "F" : "C")
  }

  function dayName(epochSeconds) {
    if (!epochSeconds) return ""
    var d = new Date(epochSeconds * 1000)
    if (isNaN(d.getTime())) return ""
    return Qt.formatDate(d, "ddd")
  }

  function bareTempForDay(day, kind) {
    if (!day) return ""
    var c = kind === "max" ? day.air_temp_high : day.air_temp_low
    var v = toDisplayTemp(c)
    if (isNaN(v)) return ""
    return Math.round(v) + "°"
  }

  function dayIcon(day) {
    if (!day) return ""
    return iconForTempest(day.icon)
  }

  // Tempest icon string → nerd-font glyph.
  function iconForTempest(icon) {
    var s = String(icon || "")
    if (s === "clear-day")             return ""
    if (s === "clear-night")           return ""
    if (s === "partly-cloudy-day")     return ""
    if (s === "partly-cloudy-night")   return ""
    if (s === "cloudy")                return ""
    if (s === "foggy")                 return ""
    if (s === "windy")                 return ""
    if (s === "rainy")                 return ""
    if (s === "possibly-rainy-day")    return ""
    if (s === "possibly-rainy-night")  return ""
    if (s === "snow")                  return ""
    if (s === "possibly-snow-day")     return ""
    if (s === "possibly-snow-night")   return ""
    if (s === "thunderstorm")          return ""
    return ""
  }

  // The token is handed over in the ENVIRONMENT, never in argv: /proc/<pid>/cmdline
  // is world-readable, so building the URL inline would leak the API token to
  // every user on the machine for the lifetime of the curl process.
  // /proc/<pid>/environ is owner-only.
  Process {
    id: forecastProc
    environment: ({
      "TEMPEST_STATION_ID": root.stationId,
      "TEMPEST_TOKEN": root.apiToken
    })
    command: ["bash", "-lc",
      "curl -fsS --max-time 5 -G " +
      "--data-urlencode \"station_id=$TEMPEST_STATION_ID\" " +
      "--data-urlencode \"token=$TEMPEST_TOKEN\" " +
      "https://swd.weatherflow.com/swd/rest/better_forecast 2>/dev/null"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        try {
          root.report = JSON.parse(raw)
        } catch (e) {
          // Keep last-good report on parse failure so the popup isn't blanked.
        }
      }
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshMinutes * 60 * 1000
    running: !!root.stationId && !!root.apiToken
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  WidgetButton {
    id: button
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: implicitWidth
    height: implicitHeight
    bar: root.bar
    text: root.label
    active: root.klass === "active"
    horizontalMargin: 1
    tooltipText: ""

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton) {
        // Summarise from OUR Tempest payload. The obvious-looking
        // `omarchy-weather-status` reports the BUILT-IN weather plugin, which
        // is a different provider and may be unconfigured entirely.
        root.bar.run("omarchy-notification-send " + Util.shellQuote(root.notificationText()))
      } else if (b === Qt.MiddleButton) {
        root.refresh()
      } else if (root.stationId) {
        root.bar.run("omarchy-launch-browser " + Util.shellQuote("https://tempestwx.com/station/" + root.stationId))
      }
    }

    HoverHandler {
      acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
      onHoveredChanged: {
        root.buttonHovered = hovered
        root.evaluateHover()
      }
    }
  }

  PopupCard {
    id: popup
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.popupOpen
    centerOnBar: true
    triggerMode: "hover"
    contentWidth: 480
    contentHeight: card.implicitHeight + 28

    onContainsMouseChanged: root.evaluateHover()

    Column {
      id: card
      anchors.fill: parent
      spacing: 14

      // ---- Hero row: big icon + temp on the left; location and stats stacked on the right.
      Item {
        width: parent.width
        height: Math.max(heroLeft.height, heroRight.height)

        Row {
          id: heroLeft
          anchors.left: parent.left
          anchors.leftMargin: 16
          anchors.verticalCenter: parent.verticalCenter
          spacing: 16

          Text {
            id: heroIcon
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 10
            text: root.current ? root.iconForTempest(root.current.icon) : (root.label || "—")
            color: root.bar ? root.bar.foreground : "white"
            font.family: root.bar ? root.bar.fontFamily : "monospace"
            font.pixelSize: 64
          }

          Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Text {
              id: tempBig
              text: root.reportTempNum || "—"
              color: root.bar ? root.bar.foreground : "white"
              font.family: root.bar ? root.bar.fontFamily : "monospace"
              font.pixelSize: 56
              font.bold: true
            }
            Text {
              text: root.current ? root.tempUnit : ""
              color: root.bar ? root.bar.foreground : "white"
              font.family: root.bar ? root.bar.fontFamily : "monospace"
              font.pixelSize: 22
              anchors.top: tempBig.top
              anchors.topMargin: 10
            }
          }
        }

        Column {
          id: heroRight
          anchors.right: parent.right
          anchors.rightMargin: 20
          anchors.verticalCenter: parent.verticalCenter
          spacing: 12

          Row {
            visible: root.reportLocation !== ""
            spacing: 6

            Text {
              text: ""
              color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "gray"
              font.family: root.bar ? root.bar.fontFamily : "monospace"
              font.pixelSize: 12
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: (root.reportLocation || "").toUpperCase()
              color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "gray"
              font.family: root.bar ? root.bar.fontFamily : "monospace"
              font.pixelSize: 12
              font.letterSpacing: 1
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Text {
            visible: root.reportCondition !== ""
            text: root.reportCondition
            color: root.bar ? Qt.darker(root.bar.foreground, 1.3) : "gray"
            font.family: root.bar ? root.bar.fontFamily : "monospace"
            font.pixelSize: 13
            font.italic: true
          }

          Row {
            visible: !!root.current
            spacing: 36

            Column {
              spacing: 5
              Text {
                text: "FEELS"
                color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"
                font.family: root.bar ? root.bar.fontFamily : "monospace"
                font.pixelSize: 11
                font.letterSpacing: 1
              }
              Text {
                text: root.reportFeels
                color: root.bar ? root.bar.foreground : "white"
                font.family: root.bar ? root.bar.fontFamily : "monospace"
                font.pixelSize: 15
              }
            }

            Column {
              spacing: 5
              Text {
                text: "WIND"
                color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"
                font.family: root.bar ? root.bar.fontFamily : "monospace"
                font.pixelSize: 11
                font.letterSpacing: 1
              }
              Text {
                text: root.reportWind
                color: root.bar ? root.bar.foreground : "white"
                font.family: root.bar ? root.bar.fontFamily : "monospace"
                font.pixelSize: 15
              }
            }

            Column {
              spacing: 5
              Text {
                text: "HUMID"
                color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"
                font.family: root.bar ? root.bar.fontFamily : "monospace"
                font.pixelSize: 11
                font.letterSpacing: 1
              }
              Text {
                text: root.reportHumidity
                color: root.bar ? root.bar.foreground : "white"
                font.family: root.bar ? root.bar.fontFamily : "monospace"
                font.pixelSize: 15
              }
            }
          }
        }
      }

      Text {
        visible: !root.current
        text: root.stationId && root.apiToken
          ? "Fetching forecast…"
          : "Set stationId + token in shell.json"
        color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"
        font.family: root.bar ? root.bar.fontFamily : "monospace"
        font.pixelSize: 11
        font.italic: true
      }

      Rectangle {
        visible: root.forecastDays.length > 0
        width: parent.width
        height: 1
        color: root.bar ? root.bar.foreground : "white"
        opacity: 0.12
      }

      Item {
        visible: root.forecastDays.length > 0
        width: parent.width
        height: forecastRow.height

        Row {
          id: forecastRow
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: 44

          Repeater {
            model: root.forecastDays

            Row {
              required property var modelData
              required property int index
              spacing: 10

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.dayIcon(modelData)
                color: root.bar ? root.bar.foreground : "white"
                font.family: root.bar ? root.bar.fontFamily : "monospace"
                font.pixelSize: 24
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                Text {
                  text: root.dayName(modelData.day_start_local).toUpperCase()
                  color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "gray"
                  font.family: root.bar ? root.bar.fontFamily : "monospace"
                  font.pixelSize: 10
                  font.letterSpacing: 1
                }

                Row {
                  spacing: 6

                  Text {
                    text: root.bareTempForDay(modelData, "max")
                    color: root.bar ? root.bar.foreground : "white"
                    font.family: root.bar ? root.bar.fontFamily : "monospace"
                    font.pixelSize: 12
                  }
                  Text {
                    text: root.bareTempForDay(modelData, "min")
                    color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"
                    font.family: root.bar ? root.bar.fontFamily : "monospace"
                    font.pixelSize: 12
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
