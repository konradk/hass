# Home Assistant for Omarchy

View and control your Home Assistant devices from the Omarchy bar.

Quickshell plugin for **Omarchy 4**. Pick the devices and toggle lights, adjust climate, drive media, and open covers.

> Not affiliated with or endorsed by the Home Assistant project.

## Screenshots

| Tokyo Night | Catppuccin Latte |
|:---:|:---:|
| ![Home Assistant panel in demo mode using the Tokyo Night theme](docs/screenshots/demo-tokyo-night.png) | ![Home Assistant panel in demo mode using the Catppuccin Latte theme](docs/screenshots/demo-catppuccin-latte.png) |
| **Solitude** | **Nord** |
| ![Home Assistant panel in demo mode using the Solitude theme](docs/screenshots/demo-solitude.png) | ![Home Assistant panel in demo mode using the Nord theme](docs/screenshots/demo-nord.png) |

![Home Assistant demo device list and panel favorites using the Solitude theme](docs/screenshots/demo-devices-and-favorites.png)

## Keyboard

With the panel open, `j`/`k` or `↑`/`↓` traverse device rows and their
expanded controls. Inside expanded controls, `←`/`→` move between selectors
or history windows; otherwise they switch area tabs. `enter` activates the
selected row or opens the selected dropdown. `e` expands its controls, `s` opens settings, `r`
refreshes, `esc` closes, and `tab` moves to the next bar panel.

## What you can control

| Domain | Control |
|---|---|
| `light` | On/off, plus a brightness slider when the light is dimmable, colour swatches with hue and saturation when it renders colour, and a warmth slider when it does colour temperature |
| `switch`, `fan`, `input_boolean`, `humidifier` | On/off |
| `lock` | Lock/unlock switch |
| `scene`, `script` | Activate button |
| `media_player` | Previous / play-pause / next, volume slider |
| `cover` | Open / stop / close, plus a position slider when the cover reports one |
| `climate` | On/off when advertised, plus HVAC, fan, preset, swing, and target-temperature or low/high-band controls when advertised |
| `sensor` | State, plus a 1h / 3h / 6h / 12h / 1d history graph when the value is numeric |
| `binary_sensor`, everything else | State display only |

Cameras not yet.

## Scripting

The panel is reachable over the shell's IPC, so a device can go on a keybind:

```bash
omarchy-shell hass toggleEntity light.desk
omarchy-shell hass activate scene.movie_night
omarchy-shell hass expand climate.hallway   # opens the panel, unfolded
omarchy-shell hass favorite light.desk      # add to / remove from the panel
omarchy-shell hass status
omarchy-shell hass settings             # connection settings
omarchy-shell hass devices              # device picker
```

## Requirements

- Omarchy 4 (`schemaVersion: 1` plugin API)
- Python 3.11 or newer
- `secret-tool` (libsecret) with a running keyring daemon
- `nmcli` (NetworkManager), only if you use a local network URL

The pure-Python runtime of `websockets` 17.0.1 is bundled with the plugin and
loaded from `vendor/`. Users don't need `python-websockets`, `qt6-websockets`,
`pip`, a virtual environment, or a first-run download.

## Install

```bash
omarchy plugin add https://github.com/konradk/hass.git --enable
```

For local development, symlink the checkout instead:

```bash
ln -sfn "$PWD" ~/.config/omarchy/plugins/hass
omarchy restart shell
omarchy plugin enable hass
```

## Setup

Click the gear in the panel header, or press `s` with the panel open. From a
terminal: `omarchy-shell hass settings`, or `omarchy-shell hass devices`
to open device picker.

Paste your Home Assistant URL and a long-lived access token (Home Assistant →
your profile → Security), or flip on **Demo mode** to try the panel against a
built-in fake house with no instance at all. Then switch to **Devices** and
star the ones you want in the panel.

The **Room readings** category groups environmental sensors that belong to the
same physical Home Assistant device. Star one device there to add a compact
card for temperature, humidity, particulate matter, VOC, carbon dioxide and
other available readings. Individual sensor entities remain available in the
other categories and can still be starred separately.

Pins that keep expandable rows open are always available in **Devices** settings.
The optional **Show pin shortcut on hover** toggle in **General** also exposes
that action over the normal panel icon while a row is hovered. It is off by
default.

Classification follows Home Assistant's documented
[`SensorDeviceClass`](https://developers.home-assistant.io/docs/core/entity/sensor/)
metadata first. A classless sensor is included only when both its entity name
and unit identify the same environmental measurement, so generic percentage
sensors such as CPU, memory and storage are not mistaken for humidity. Quality
bands are display policy rather than Home Assistant metadata and are applied
only to compatible units. The IKEA VINDSTYRKA's unitless VOC Index uses the
1–150, 150–250, 250–400 and 400–500 purifier levels documented for its
[Sensirion sensor](https://sensirion.com/media/documents/ACD82D45/6294DFC0/Info_Note_Integration_VOC_NOx_Sensor.pdf);
other unitless VOC indices remain neutral.

Hover a room card header to add the whole group to the bar, or hover one of
its reading tiles to add only that reading. Both can coexist as independent
bar widgets. Values use the active Omarchy theme and air quality readings carry
the same quality colours as the room card. Sensor and climate rows expose the
same action; a climate widget shows the live room temperature and target.
The IKEA VINDSTYRKA VOC index uses its device-specific relative bands at 150,
250 and 400. Other unitless VOC index sensors stay neutral because their scale
cannot safely be inferred from the entity name alone.
Once added, the plus becomes a minus that removes that exact widget. Left click
a climate widget for its compact controls, or a sensor and room widget for a
synchronized history graph with 1h, 3h, 6h, 12h and 1d windows. The panel and
bar popup share the same themed, filled step renderer; unavailable recorder
periods remain visible gaps. Right click removes that exact widget from the
bar. Each
child has an independent bar identity, so it can be moved between sections
without moving or replacing the main Home Assistant icon.

Expandable panel rows have a pin that preserves their expanded state whenever
the Home Assistant panel opens. Every row reserves the same fixed action slots:
pin, reading or switch, chevron, then bar add or remove. Hovering never moves an
action into a different coordinate.

Optionally, turn on **Local network URL** to add your instance's LAN address.
It's the same Home Assistant instance reached by a different address, so it
reuses the one access token above rather than needing its own. It also asks
for the name of your trusted Wi-Fi network (comma-separate more than one, for
example if your router has separate 2.4GHz/5GHz names): the local URL is only
ever tried while connected to one of those, and the URL above is used
everywhere else. If that field is empty, it'll offer the network you're
currently on as a one-click suggestion.
This matters because the local URL is plaintext-friendly on the assumption
that your home network is trustworthy — without the network-name check, a
laptop that later joins some other Wi-Fi with something answering on that
same address would send it your token.

## Debugging

```bash
omarchy-shell hass status     # what the widget sees
omarchy-shell hass toggle     # open/close the panel
omarchy plugin validate .     # check the manifest before committing
```

## Tests

```bash
python3 tests/test_bridge.py     # bridge, against a fake Home Assistant
python3 tests/test_vendor.py     # pinned dependency, license and offline import
python3 tests/test_service_contract.py
node    tests/test_connection.js # URL/origin and generation rules
node    tests/test_config.js     # config normalization and secret exclusion
node    tests/test_store.js      # state and registry projections
node    tests/test_model.js      # entity formatting and classification
node    tests/test_row_model.js  # ListModel row projection
node    tests/test_panel_state.js # pinned and temporary expansion state
node    tests/test_bar_data.js   # repeated bar widget identity and placement
python3 tests/test_qml_style.py  # UI house style (fonts, palette, tokens)
```

## Security

Your long-lived access token is stored in the system keyring via `secret-tool`.
Use an `https://` Home Assistant URL whenever possible. If you explicitly use
`http://`, the token is sent without transport encryption; reserve that for a
trusted local network where you understand the risk.

When the checkout is symlinked for local development, runtime settings are
written to `config.json` in the checkout. That file is ignored because it can
contain private instance URLs, area names, entity IDs, and display-name
overrides. The access token is never stored there.

## Bundled dependency maintenance

`websockets` 17.0.1 is redistributed under BSD-3-Clause; provenance, the sdist
SHA-256 and omitted files are recorded in [`vendor/README.md`](vendor/README.md),
with legal notices in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## License

MIT — see [`LICENSE`](LICENSE).
