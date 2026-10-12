



https://github.com/user-attachments/assets/eb96a0ba-7550-4c71-9b00-d8be866330ad



# lamp-bar

Lamp Bar is a Mac menu bar app that switches the five office lamps. It shows the lamps in 3D, standing where they are in the office, and lights each lamp that is on.

- Lamps 1, 3, 4 and 5 are plugged into Kasa smart plugs.
- Lamp 2 is a Govee light bar.

Lamp Bar talks to the plugs and the light bar on the local network only. It uses no cloud service and no account.

## Requirements

- macOS 15 or later.
- Xcode 16 or later (Swift 6 toolchain).
- The Mac, the Kasa plugs and the Govee light bar on the same Wi-Fi network.

## Build and run

1. Build the app bundle:

   ```sh
   ./scripts/build-app.sh
   ```

   The script makes a release build, draws the app icon (`scripts/make-icon.swift`) into `AppIcon.icns`, and writes `dist/LampBar.app`, signed ad hoc.
2. Start the app:

   ```sh
   open dist/LampBar.app
   ```

3. If macOS asks to let Lamp Bar find devices on your local network, click **Allow**. If you do not, Lamp Bar cannot reach the lamps.
4. Click the lightbulb icon in the menu bar. The icon is filled when any lamp is on.

To keep the app, copy `dist/LampBar.app` to `/Applications`. To start it at login, add it in **System Settings > General > Login Items**.

For development, `swift run LampBar` starts the menu bar app from the source tree. `swift test` runs the unit tests.

## The panel

- **Header:** the number of lamps that are on, and the power button. The power button switches all five lamps off when any lamp is on. Otherwise it switches all five on.
- **3D stage:** click a lamp to switch it. Drag left or right to turn the room (up to 50 degrees each way), and drag up or down to look from higher or lower (18 to 60 degrees above the plate). Double-click empty space to return to the default view. The camera always keeps all five lamps in the frame.
- **Lamp buttons:** one button for each lamp, with its drawing, its name and ON or OFF. Click a button to switch the lamp.
- **Status line:** shows `Syncing…` while a command or a poll runs, `In sync` when every lamp answered, and the number of lamps that do not answer. The gear menu opens **Setup**, refreshes the state now, or quits the app.

Lamp Bar reads the real state of every lamp when the panel opens and after each command. While the panel is open, it polls every 10 seconds. While the panel is closed, it polls every 60 seconds, to keep the menu bar icon correct. A lamp that does not answer shows `OFFLINE`.

## Map the plugs (one time)

The first time, Lamp Bar does not know which Kasa plug drives which lamp. The lamps show `NO PLUG`, and the header shows **Choose plugs**.

1. Click **Choose plugs**, or open the gear menu and click **Setup…**.
2. For each lamp (1, 3, 4 and 5), select its plug in the menu next to it. A power strip shows one entry for each socket.
3. If you are not sure which plug drives a lamp, click **Flash** next to the plug. The plug switches off and on again, so you can see which lamp it drives.

Lamp Bar saves the mapping. One plug can drive only one lamp; if you select a plug that another lamp uses, Lamp Bar removes it from the other lamp.

You can also map the plugs from Terminal. Use the plug IDs that `--probe` prints:

```sh
dist/LampBar.app/Contents/MacOS/LampBar --probe
dist/LampBar.app/Contents/MacOS/LampBar --map 1 <plug id>
```

## Turn on LAN Control for the Govee light bar

Lamp Bar controls the light bar through Govee's LAN API. The light bar answers on the LAN only when LAN Control is on.

1. Open the Govee Home app on your phone.
2. Open the light bar.
3. Tap the gear icon.
4. Switch on **LAN Control**.

If the light bar does not answer, the status line shows `Light bar not answering · turn on LAN Control`, and **Setup** shows the same steps. Lamp Bar finds the light bar again by itself if its address changes.

## Kasa plugs: native protocol, and the optional login helper

Lamp Bar controls Kasa plugs natively, in Swift, with the Kasa local protocol (JSON on port 9999, UDP for discovery and state, TCP for commands). It sends small requests only. Some plugs (for example the HS103 with firmware 1.0.3) do not answer the larger combined requests that other tools send.

Kasa plugs with newer firmware accept local commands only after a login with the TP-Link account. Lamp Bar handles these plugs through a small helper that uses [python-kasa](https://github.com/python-kasa/python-kasa), because that protocol (KLAP) is not implemented natively. The plugs in this office now use that newer firmware and need the helper.

If a plug needs the login:

1. Install the helper:

   ```sh
   ./scripts/install-kasa-helper.sh
   ```

   The script makes a Python environment with python-kasa in `~/Library/Application Support/LampBar`.
2. Open **Setup**, enter the TP-Link account email and password, and click **Save to Keychain**.

Lamp Bar stores the login only in the macOS Keychain. It sends the login to the helper on standard input, never as a command argument, and never writes it to a log. To remove the login, click **Remove login** in **Setup**.

Because the app is signed ad hoc, macOS can ask again for Keychain access after each new build.

## Command line

The app binary also has a few Terminal commands, for checks without the panel:

| Command | What it does |
| --- | --- |
| `LampBar --probe` | Lists the Kasa plugs and the Govee light bar on the network. Changes nothing. |
| `LampBar --status` | Shows the five lamps as the app sees them. |
| `LampBar --map <1-5> <plug id or none>` | Selects the plug for a lamp. |
| `LampBar --switch <1-5 or all> <on or off>` | Switches lamps. |
| `LampBar --window` | Shows the panel in a normal window instead of the menu bar. |
| `LampBar --snapshot <file.png>` | Shows the panel, saves a picture of it after the first poll, and quits. |
| `LampBar --snapshot <file.png> --drag <dx,dy> [--reset]` | Drags on the 3D stage with real mouse events first (points, y down), and with `--reset` double-clicks empty space after it. |

## Source layout

- `Sources/LampBar/Net/` — the Kasa client (`Kasa.swift`), the Govee LAN client (`Govee.swift`), the login helper bridge (`KasaHelper.swift`) and the socket helpers.
- `Sources/LampBar/LampStore.swift` — the lamp state, the plug mapping, polling and commands.
- `Sources/LampBar/Views/` — the panel (`PanelView.swift`), the 3D stage (`LampStage.swift`, SceneKit), the lamp drawings (`LampArt.swift`) and **Setup**.
- `scripts/` — the app bundle build, the app icon drawing, and the optional python-kasa helper.
