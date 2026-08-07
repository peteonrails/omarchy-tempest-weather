# Tempest Weather — an Omarchy bar widget

A bar pill showing current conditions from your own [WeatherFlow
Tempest](https://weatherflow.com/tempest-home-weather-system/) station, with a
hover popup carrying a current-conditions hero and a 5-day forecast.

This reads **your** station through the Tempest `better_forecast` API. It is not
a general geocoded weather widget — if you don't own a Tempest station (or have
access to someone else's), use Omarchy's built-in `omarchy.weather` instead.

## Install

```bash
omarchy plugin add https://github.com/peteonrails/omarchy-tempest-weather.git
omarchy plugin enable peteonrails.weather center
```

The widget renders **nothing** until both `stationId` and `token` are set. That
is deliberate: a fresh install should not fire network requests with empty
credentials.

## Settings

Configure via the shell settings UI, or by hand on the widget's entry in
`~/.config/omarchy/shell.json`:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `stationId` | string | `""` | Your station ID — tempestwx.com → Settings → Stations |
| `token` | string | `""` | Personal API token — tempestwx.com → Settings → Data Authorizations |
| `unit` | string | `"auto"` | `auto`, `imperial`, or `metric`. `auto` follows your locale |
| `refreshMinutes` | integer | `15` | Poll interval. The Tempest API is rate-limited; don't go below a few minutes |

```json
{
  "bar": {
    "layout": {
      "center": [
        {
          "id": "peteonrails.weather",
          "stationId": "12345",
          "unit": "imperial",
          "refreshMinutes": 15
        }
      ]
    }
  }
}
```

### About the token

Your Tempest token is a credential. Two things worth knowing:

- **It is stored in plaintext** in `~/.config/omarchy/shell.json`, like every
  other widget setting. Nothing here can change that — but the file is yours
  alone, so keep it out of any dotfiles repo you publish.
- **It is never passed on a command line.** `/proc/<pid>/cmdline` is
  world-readable on Linux, so putting the token in the `curl` invocation would
  expose it to every user on the machine. The widget hands it to `curl` through
  the process environment instead, and `/proc/<pid>/environ` is owner-only.

If a token leaks, revoke it under Settings → Data Authorizations.

## Mouse

| Action | Result |
|---|---|
| Hover | Opens the forecast popup |
| Left click | Opens your station page on tempestwx.com |
| Middle click | Forces an immediate refresh |
| Right click | Sends a desktop notification summarising current conditions |

There is also an IPC handler, so you can pop the forecast from a keybinding:

```bash
omarchy-shell peteonrails.weather show
```

It auto-closes after 5 seconds.

## Requirements

- Omarchy 4 (Quattro) or newer — uses the `omarchy-shell` plugin architecture
- `curl`
- `omarchy-launch-browser`, `omarchy-notification-send` (ship with Omarchy)

## Behaviour notes

- The last good response is retained on a failed fetch or malformed JSON, so a
  transient network blip won't blank the popup.
- Temperatures come from the API in Celsius and are converted for display;
  `auto` resolves to imperial for `en_US`, `en_LR`, and `my` locales.

## License

MIT — see [LICENSE](LICENSE).
