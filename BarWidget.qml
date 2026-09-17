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

  // Where readings come from. A Tempest station is the good case -- it is the
  // weather in your garden -- but it needs an account, a station and a token,
  // which is a lot to ask before the widget will show anything at all. So a
  // location is offered as the alternative: public forecast data, no account.
  //
  // Blank means the user has not chosen, which is what raises the setup view.
  // An install that already carries a station and token predates this setting
  // and is taken as "tempest" rather than being asked again.
  readonly property string source: {
    var chosen = String(setting("source", ""))
    if (chosen === "tempest" || chosen === "location") return chosen
    return (stationId !== "" && apiToken !== "") ? "tempest" : ""
  }

  readonly property bool tempestReady: stationId !== "" && apiToken !== ""
  readonly property bool locationReady: locationName !== "" && isFinite(fetchLat) && isFinite(fetchLon)
  readonly property bool ready: source === "tempest" ? tempestReady
                              : source === "location" ? locationReady : false

  // The location lives where Omarchy already keeps it, so answering here also
  // answers for the built-in weather widget, and a location already configured
  // there needs no second answer. `omarchy-weather-location` owns the file; we
  // only ever read it.
  property var locationState: ({ name: "", latitude: null, longitude: null })
  readonly property string locationName: String(locationState.name || "")

  // A hand-written {"name": "Malibu"} is valid in that file and carries no
  // coordinates, which the forecast API needs. Geocoding fills them in rather
  // than declaring a configured location unusable.
  property real geocodedLat: NaN
  property real geocodedLon: NaN
  // Absent must not read as zero. Number(null) is 0 and isFinite(0) is true,
  // so a location stored as a bare name would otherwise look like latitude 0,
  // longitude 0 -- the Gulf of Guinea -- and report the weather there rather
  // than geocoding the name. NaN is the only honest answer for "not given",
  // and it leaves a genuine 0 (the equator) usable.
  function coord(value) {
    // Only a number or a numeric string counts. Number() is far too willing:
    // it turns null, "" and [] all into 0.
    if (typeof value !== "number" && typeof value !== "string") return NaN
    if (value === "") return NaN
    var v = Number(value)
    return isFinite(v) ? v : NaN
  }

  readonly property real fetchLat: {
    var v = coord(locationState.latitude)
    return isFinite(v) ? v : geocodedLat
  }
  readonly property real fetchLon: {
    var v = coord(locationState.longitude)
    return isFinite(v) ? v : geocodedLon
  }

  property FileView locationFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.locationState = root.parseLocationFile(text())
    onLoadFailed: root.locationState = root.parseLocationFile("")
  }

  // The first read can race shell startup, which would leave a stored location
  // unhonoured until the next write. A single delayed reload self-corrects, and
  // is a no-op when the first read was fine.
  Timer {
    interval: 1500
    running: true
    onTriggered: root.locationFile.reload()
  }

  function parseLocationFile(raw) {
    var empty = { name: "", latitude: null, longitude: null }
    if (!raw) return empty
    try {
      var parsed = JSON.parse(raw)
      if (!parsed || typeof parsed !== "object") return empty
      return {
        name: parsed.name ? String(parsed.name) : "",
        latitude: parsed.latitude === undefined ? null : parsed.latitude,
        longitude: parsed.longitude === undefined ? null : parsed.longitude
      }
    } catch (e) {
      return empty
    }
  }

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
    // Saying so beats vanishing. A widget that renders nothing is
    // indistinguishable from one that is broken, or from one the user failed to
    // add to the bar at all -- there is nothing to click and nothing to read.
    if (!ready) return "Weather: set up"
    if (!current) return "Weather: …"
    var icon = iconForTempest(current.icon)
    var temp = reportTempNum ? (reportTempNum + "°") : ""
    if (!icon && !temp) return "Weather: …"
    return icon + (icon && temp ? " " : "") + temp
  }
  readonly property string klass: current ? "active" : ""

  visible: true
  implicitWidth: button.implicitWidth + 8
  implicitHeight: button.implicitHeight

  function refresh() {
    if (root.source === "location") {
      if (locationName === "") return
      // A location with no coordinates cannot be fetched; resolve it, and the
      // resolver refreshes again once it lands.
      if (!isFinite(fetchLat) || !isFinite(fetchLon)) {
        startGeocode(locationName, "resolve")
        return
      }
      if (publicProc.running) return
      publicProc.command = ["curl", "-fsS", "--max-time", "6", openMeteoUrl(fetchLat, fetchLon)]
      publicProc.running = true
      return
    }
    if (!tempestReady) return
    if (!forecastProc.running) forecastProc.running = true
  }

  function openMeteoUrl(lat, lon) {
    return "https://api.open-meteo.com/v1/forecast"
      + "?latitude=" + encodeURIComponent(String(lat))
      + "&longitude=" + encodeURIComponent(String(lon))
      + "&daily=weather_code,temperature_2m_max,temperature_2m_min"
      + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day"
      + "&forecast_days=5"
      + "&timezone=auto"
  }

  // WMO code groupings copied from Omarchy's own weather model, so the two
  // widgets never disagree about what the sky is doing -- mapped onto the
  // Tempest icon vocabulary this widget already draws.
  function iconForWmo(code, isDay) {
    var c = parseInt(String(code === undefined || code === null ? 3 : code), 10)
    var part = isDay ? "day" : "night"
    if (c === 0) return "clear-" + part
    if (c === 1 || c === 2) return "partly-cloudy-" + part
    if (c === 45 || c === 48) return "foggy"
    if (c === 51 || c === 53 || c === 55 || c === 56 || c === 57 || c === 61)
      return "possibly-rainy-" + part
    if (c === 63 || c === 65 || c === 66 || c === 67 || c === 80 || c === 81 || c === 82)
      return "rainy"
    if (c === 71 || c === 73 || c === 75 || c === 77 || c === 85 || c === 86) return "snow"
    if (c === 95 || c === 96 || c === 99) return "thunderstorm"
    return "cloudy"
  }

  function conditionsForWmo(code) {
    var c = parseInt(String(code === undefined || code === null ? -1 : code), 10)
    if (c === 0) return "Clear"
    if (c === 1) return "Mainly clear"
    if (c === 2) return "Partly cloudy"
    if (c === 3) return "Overcast"
    if (c === 45 || c === 48) return "Fog"
    if (c >= 51 && c <= 57) return "Drizzle"
    if (c === 61 || c === 63 || c === 65) return "Rain"
    if (c === 66 || c === 67) return "Freezing rain"
    if (c >= 71 && c <= 77) return "Snow"
    if (c >= 80 && c <= 82) return "Rain showers"
    if (c === 85 || c === 86) return "Snow showers"
    if (c === 95) return "Thunderstorm"
    if (c === 96 || c === 99) return "Thunderstorm with hail"
    return ""
  }

  // Open-Meteo answers in a shape of its own. Normalizing it into the Tempest
  // better_forecast shape means the whole report view -- hero, stats, five-day
  // strip -- renders either source without knowing which one it got.
  // Open-Meteo reports °C and km/h; the view converts from °C and m/s.
  function reportFromOpenMeteo(payload) {
    if (!payload || !payload.current || payload.current.temperature_2m === undefined) return null
    var cur = payload.current
    var isDay = cur.is_day === undefined ? true : Number(cur.is_day) !== 0
    var out = {
      location_name: root.locationName,
      current_conditions: {
        air_temperature: cur.temperature_2m,
        feels_like: cur.apparent_temperature,
        relative_humidity: cur.relative_humidity_2m,
        wind_avg: cur.wind_speed_10m === undefined ? undefined : cur.wind_speed_10m / 3.6,
        conditions: conditionsForWmo(cur.weather_code),
        icon: iconForWmo(cur.weather_code, isDay)
      },
      forecast: { daily: [] }
    }

    var daily = payload.daily
    if (daily && Array.isArray(daily.time)) {
      for (var i = 0; i < daily.time.length; i++) {
        // Built as a LOCAL date: "2026-09-17" parsed as a date string is UTC
        // midnight, which formats as the previous day west of Greenwich.
        var parts = String(daily.time[i]).split("-")
        var when = new Date(parseInt(parts[0], 10), parseInt(parts[1], 10) - 1, parseInt(parts[2], 10))
        out.forecast.daily.push({
          day_start_local: Math.floor(when.getTime() / 1000),
          air_temp_high: daily.temperature_2m_max ? daily.temperature_2m_max[i] : undefined,
          air_temp_low: daily.temperature_2m_min ? daily.temperature_2m_min[i] : undefined,
          icon: iconForWmo(daily.weather_code ? daily.weather_code[i] : 3, true)
        })
      }
    }
    return out
  }

  Process {
    id: publicProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        try {
          var next = root.reportFromOpenMeteo(JSON.parse(raw))
          if (next) root.report = next
        } catch (e) {
          // Keep last-good report on parse failure so the popup isn't blanked.
        }
      }
    }
  }

  // ------------------------------------------------------------------
  // Setup
  // ------------------------------------------------------------------

  // Raised whenever there is no usable source, and openable afterwards so the
  // choice can be revisited without hand-editing shell.json.
  property bool setupOpen: false
  readonly property bool showSetup: !ready || setupOpen

  // Writes this widget's inline entry in shell.json. Applied locally first so
  // the view redraws on the click itself; the write comes back through the bar
  // as the same value, and patches the widget's twin on the other monitor.
  // With no writable entry -- the widget is not in the layout -- it stays a
  // session-only choice rather than doing nothing.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function saveTempest(station, token) {
    var s = String(station || "").trim()
    var t = String(token || "").trim()
    if (!s || !t) return
    persistSettings({ stationId: s, token: t, source: "tempest" })
    root.setupOpen = false
    Qt.callLater(root.refresh)
  }

  // The location file belongs to omarchy-weather-location, so the write goes
  // through it: the format stays right, and the answer is shared with the
  // built-in weather widget instead of duplicated.
  function saveLocation(name, lat, lon) {
    var n = String(name || "").trim()
    if (!n || !root.bar) return
    var cmd = "omarchy-weather-location --set " + Util.shellQuote(n)
    if (isFinite(lat) && isFinite(lon)) cmd += " " + Util.shellQuote(String(lat) + "," + String(lon))
    root.bar.run(cmd)
    root.geocodedLat = isFinite(lat) ? lat : NaN
    root.geocodedLon = isFinite(lon) ? lon : NaN
    persistSettings({ source: "location" })
    root.setupOpen = false
    locationSettleTimer.restart()
  }

  // The file may not exist yet, and a FileView cannot watch what is not there,
  // so the first write after choosing a location needs a nudge to be seen.
  Timer {
    id: locationSettleTimer
    interval: 600
    repeat: false
    onTriggered: {
      root.locationFile.reload()
      root.refresh()
    }
  }

  // One geocoder, two jobs: suggestions while the user types, and filling in
  // coordinates for a location that was stored as a bare name.
  property var locationSuggestions: []
  property int suggestionIndex: 0
  property string geocodeMode: "suggest"
  property string geocodePendingQuery: ""
  property string geocodeActiveQuery: ""

  function startGeocode(query, mode) {
    var q = String(query || "").trim()
    if (q.length < 2) {
      root.locationSuggestions = []
      return
    }
    root.geocodeMode = mode || "suggest"
    root.geocodePendingQuery = q
    if (!geocodeProc.running) runGeocode()
  }

  function runGeocode() {
    root.geocodeActiveQuery = root.geocodePendingQuery
    geocodeProc.command = ["curl", "-fsS", "--max-time", "6",
      "https://geocoding-api.open-meteo.com/v1/search?name="
        + encodeURIComponent(root.geocodeActiveQuery) + "&count=5&language=en&format=json"]
    geocodeProc.running = true
  }

  function suggestionLabel(hit) {
    if (!hit) return ""
    var bits = [String(hit.name || "")]
    if (hit.admin1) bits.push(String(hit.admin1))
    if (hit.country_code) bits.push(String(hit.country_code))
    return bits.join(", ")
  }

  Process {
    id: geocodeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var hits = []
        try {
          var parsed = JSON.parse(String(text || "").trim())
          if (parsed && Array.isArray(parsed.results)) hits = parsed.results
        } catch (e) {
          hits = []
        }

        if (root.geocodeMode === "resolve") {
          // Filling in coordinates for a stored bare name: take the best hit
          // and get on with the fetch. Nothing is persisted -- the name the
          // user chose stays the name of record.
          if (hits.length > 0) {
            root.geocodedLat = Number(hits[0].latitude)
            root.geocodedLon = Number(hits[0].longitude)
            Qt.callLater(root.refresh)
          }
        } else {
          root.locationSuggestions = hits.slice(0, 4)
          root.suggestionIndex = 0
        }
      }
    }
    onExited: {
      if (root.geocodePendingQuery !== root.geocodeActiveQuery) Qt.callLater(root.runGeocode)
    }
  }

  Timer {
    id: geocodeDebounce
    interval: 300
    repeat: false
    onTriggered: root.startGeocode(locationField.text, "suggest")
  }

  // One-line summary for the right-click notification.
  function notificationText() {
    if (!current) {
      if (!ready) return "Weather: not set up — click the widget to choose a source"
      return "Weather: no data yet"
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
    running: root.ready
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
    tooltipText: root.configured
      ? ""
      : "Set stationId and token in this widget's settings — tempestwx.com → Settings → Data Authorizations"

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton) {
        // Summarise from OUR Tempest payload. The obvious-looking
        // `omarchy-weather-status` reports the BUILT-IN weather plugin, which
        // is a different provider and may be unconfigured entirely.
        root.bar.run("omarchy-notification-send " + Util.shellQuote(root.notificationText()))
      } else if (b === Qt.MiddleButton) {
        root.refresh()
      } else if (!root.ready) {
        // Nothing to open yet -- the click that would have done nothing now
        // raises the setup view instead.
        root.setupOpen = true
        root.popupOpen = true
      } else if (root.source === "tempest" && root.stationId) {
        root.bar.run("omarchy-launch-browser " + Util.shellQuote("https://tempestwx.com/station/" + root.stationId))
      } else if (root.source === "location" && root.locationName) {
        root.bar.run("omarchy-launch-browser "
          + Util.shellQuote("https://wttr.in/" + encodeURIComponent(root.locationName)))
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
    // A hover popup dismisses itself the moment the pointer drifts, which is
    // fatal to a form: you cannot type into it. Setup is click-triggered, and
    // click mode also takes a focus grab, so the fields get keystrokes.
    triggerMode: root.showSetup ? "click" : "hover"
    contentWidth: 480
    contentHeight: (root.showSetup ? setupCard.implicitHeight : card.implicitHeight) + 28

    onContainsMouseChanged: root.evaluateHover()
    onOpenChanged: if (!open && root.ready) root.setupOpen = false

    Column {
      id: card
      visible: !root.showSetup
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

    // ---- Setup view. Raised while no source works, and reachable afterwards
    //      from its own footer so the choice can be changed without editing
    //      shell.json by hand.
    Column {
      id: setupCard
      visible: root.showSetup
      anchors.fill: parent
      spacing: 12

      Column {
        x: 16
        width: parent.width - 32
        spacing: 2

        Text {
          text: "Weather"
          color: root.bar ? root.bar.foreground : "white"
          font.family: root.bar ? root.bar.fontFamily : "monospace"
          font.pixelSize: 18
          font.bold: true
        }
        Text {
          text: "Choose where readings come from."
          color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "gray"
          font.family: root.bar ? root.bar.fontFamily : "monospace"
          font.pixelSize: 11
        }
      }

      Rectangle {
        x: 16
        width: parent.width - 32
        height: 1
        color: root.bar ? root.bar.foreground : "white"
        opacity: 0.12
      }

      // ---- Option one: the user's own Tempest hardware.
      Column {
        x: 16
        width: parent.width - 32
        spacing: 6

        Text {
          text: "YOUR TEMPEST STATION"
          color: root.bar ? Qt.darker(root.bar.foreground, 1.3) : "gray"
          font.family: root.bar ? root.bar.fontFamily : "monospace"
          font.pixelSize: 10
          font.letterSpacing: 1
        }

        Row {
          spacing: 6

          TextField {
            id: stationField
            width: 120
            placeholderText: "Station ID"
            foreground: root.bar ? root.bar.foreground : "white"
            font.family: root.bar ? root.bar.fontFamily : "monospace"
            text: root.stationId
            Keys.onReturnPressed: root.saveTempest(stationField.text, tokenField.text)
          }

          TextField {
            id: tokenField
            width: 212
            placeholderText: "API token"
            password: true
            foreground: root.bar ? root.bar.foreground : "white"
            font.family: root.bar ? root.bar.fontFamily : "monospace"
            text: root.apiToken
            Keys.onReturnPressed: root.saveTempest(stationField.text, tokenField.text)
          }

          Rectangle {
            id: saveButton
            width: 60
            height: tokenField.height
            radius: 4
            color: root.bar ? root.bar.foreground : "white"
            opacity: (stationField.text !== "" && tokenField.text !== "") ? (saveHover.hovered ? 1.0 : 0.82) : 0.25

            Text {
              anchors.centerIn: parent
              text: "Save"
              color: root.bar ? root.bar.background : "black"
              font.family: root.bar ? root.bar.fontFamily : "monospace"
              font.pixelSize: 12
              font.bold: true
            }

            HoverHandler { id: saveHover }
            TapHandler {
              enabled: stationField.text !== "" && tokenField.text !== ""
              onTapped: root.saveTempest(stationField.text, tokenField.text)
            }
          }
        }

        Text {
          text: "tempestwx.com → Settings → Data Authorizations → create a token"
          color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"
          font.family: root.bar ? root.bar.fontFamily : "monospace"
          font.pixelSize: 10
        }
      }

      Rectangle {
        x: 16
        width: parent.width - 32
        height: 1
        color: root.bar ? root.bar.foreground : "white"
        opacity: 0.12
      }

      // ---- Option two: a place name. No account, no hardware.
      Column {
        x: 16
        width: parent.width - 32
        spacing: 6

        Text {
          text: "OR ANY LOCATION — NO ACCOUNT NEEDED"
          color: root.bar ? Qt.darker(root.bar.foreground, 1.3) : "gray"
          font.family: root.bar ? root.bar.fontFamily : "monospace"
          font.pixelSize: 10
          font.letterSpacing: 1
        }

        TextField {
          id: locationField
          width: parent.width
          placeholderText: root.locationName !== "" ? root.locationName : "Search for a city"
          foreground: root.bar ? root.bar.foreground : "white"
          font.family: root.bar ? root.bar.fontFamily : "monospace"

          onTextChanged: geocodeDebounce.restart()

          Keys.onPressed: function (event) {
            if (event.key === Qt.Key_Down) {
              if (root.suggestionIndex < root.locationSuggestions.length - 1) root.suggestionIndex++
              event.accepted = true
            } else if (event.key === Qt.Key_Up) {
              if (root.suggestionIndex > 0) root.suggestionIndex--
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              var hit = root.locationSuggestions[root.suggestionIndex]
              if (hit) root.saveLocation(root.suggestionLabel(hit),
                                       root.coord(hit.latitude), root.coord(hit.longitude))
              event.accepted = true
            } else if (event.key === Qt.Key_Escape) {
              if (root.ready) root.setupOpen = false
              event.accepted = true
            }
          }
        }

        // Coordinates come from the picked suggestion, never from the raw
        // text: an exact lat/lon is what makes the forecast the right one.
        Repeater {
          model: root.locationSuggestions

          Rectangle {
            required property var modelData
            required property int index
            width: locationField.width
            height: 22
            radius: 3
            color: root.bar ? root.bar.foreground : "white"
            opacity: (index === root.suggestionIndex || rowHover.hovered) ? 0.14 : 0.0

            Text {
              anchors.left: parent.left
              anchors.leftMargin: 6
              anchors.verticalCenter: parent.verticalCenter
              text: root.suggestionLabel(modelData)
              color: root.bar ? root.bar.foreground : "white"
              font.family: root.bar ? root.bar.fontFamily : "monospace"
              font.pixelSize: 12
            }

            HoverHandler {
              id: rowHover
              onHoveredChanged: if (hovered) root.suggestionIndex = index
            }
            TapHandler {
              onTapped: root.saveLocation(root.suggestionLabel(modelData),
                                          root.coord(modelData.latitude), root.coord(modelData.longitude))
            }
          }
        }

        Text {
          text: root.locationName !== ""
            ? ("Omarchy's location is set to " + root.locationName + " — pick it to use that.")
            : "Shares Omarchy's weather location, so you only answer this once."
          color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"
          font.family: root.bar ? root.bar.fontFamily : "monospace"
          font.pixelSize: 10
          width: parent.width
          wrapMode: Text.WordWrap
        }

        // Only offered when a location is already on file: one click accepts
        // it, no typing and no geocoding.
        Rectangle {
          visible: root.locationName !== "" && root.source !== "location"
          width: parent.width
          height: 24
          radius: 4
          color: root.bar ? root.bar.foreground : "white"
          opacity: useHover.hovered ? 0.24 : 0.14

          Text {
            anchors.centerIn: parent
            text: "Use " + root.locationName
            color: root.bar ? root.bar.foreground : "white"
            font.family: root.bar ? root.bar.fontFamily : "monospace"
            font.pixelSize: 12
          }

          HoverHandler { id: useHover }
          TapHandler {
            onTapped: root.saveLocation(root.locationName,
                                        root.coord(root.locationState.latitude),
                                        root.coord(root.locationState.longitude))
          }
        }
      }

      // ---- Footer: only meaningful once something already works.
      Text {
        visible: root.ready
        x: 16
        text: "Keep current source"
        color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : "gray"
        font.family: root.bar ? root.bar.fontFamily : "monospace"
        font.pixelSize: 11
        font.underline: keepHover.hovered

        HoverHandler { id: keepHover }
        TapHandler { onTapped: root.setupOpen = false }
      }
    }
  }
}
