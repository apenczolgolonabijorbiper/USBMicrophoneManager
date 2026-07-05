# USB Microphone Manager

USB Microphone Manager is a Windows PowerShell 5.1 application for discovering,
identifying, and managing multiple USB microphones—especially identical devices
that Windows displays with the same friendly name.

The WinForms interface combines USB/PnP information with Windows audio endpoint
data, lets you assign persistent aliases, monitors device changes, and provides
optional audio metering, Equalizer APO inspection, and VB-CABLE mixing.

## Features

- Discovers USB audio capture devices and maps them to Windows audio endpoints.
- Separates currently active devices from previously seen inactive devices.
- Displays hardware and endpoint details, including VID/PID, Instance ID,
  Container ID, endpoint GUID, USB location, driver, and status.
- Stores four aliases using identities with different scopes:
  - **Alias1:** shared by devices with the same VID/PID.
  - **Alias2:** tied to a specific PnP Instance ID.
  - **Alias3:** tied to a device Container ID.
  - **Alias4:** tied to a Windows audio endpoint GUID.
- Remembers microphone flags and the last-active time for known devices.
- Automatically refreshes after device connection, removal, or endpoint changes.
- Filters the inventory and exports it to CSV.
- Shows live input levels and highlights the loudest microphone.
- Opens Windows Device Manager and Sound Settings from the toolbar.
- Scans Equalizer APO configuration, includes, device selectors, and VST entries.
- Enables or disables Equalizer APO VST entries and saves reusable snapshots.
- Optionally mixes several microphones into a VB-CABLE output with per-channel
  gain, enable, mute, solo, metering, and master gain controls.

## Requirements

- Windows 10 or Windows 11.
- Windows PowerShell 5.1.
- USB microphones or other Windows audio capture devices.

The following integrations are optional:

- [Equalizer APO](https://sourceforge.net/projects/equalizerapo/) for APO and VST
  discovery, toggles, and snapshots.
- [VB-CABLE](https://vb-audio.com/Cable/) for the multi-microphone mixer output.

No compilation or package installation is required.

## Running the application

Clone or download the repository, open Windows PowerShell in its directory, and
run:

```powershell
.\USBMicrophoneManager.cmd
```

For startup diagnostics, run the script directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\USBMicrophoneManager.ps1
```

The application creates its required runtime files under `config/` when they do
not already exist.

## Basic usage

1. Connect the microphones and start the application.
2. Use **Refresh** if you want to rescan manually. Device changes are also
   monitored automatically.
3. Edit alias cells directly in either device grid.
4. Clear **Mic** for devices that should be excluded by the
   **Only microphones** filter.
5. Select **Save** to persist aliases and device metadata.
6. Use the filter box to search the displayed inventory.

Choose an alias scope based on what you want to identify:

| Alias | Identity | Useful for |
| --- | --- | --- |
| Alias1 | VID/PID | Naming every unit of the same hardware model |
| Alias2 | Instance ID | Naming one specific PnP device instance |
| Alias3 | Container ID | Following one physical device across its functions |
| Alias4 | Endpoint GUID | Naming one specific Windows capture endpoint |

The toolbar also supports copying selected identifiers, exporting the inventory
to CSV, opening Windows audio tools, enabling the level meter, and launching the
mixer.

## Audio level meter

Select **Meter Off** to enable live capture-endpoint levels. The level column is
updated approximately every 100 milliseconds, and the loudest detected
microphone is highlighted. Metering is disabled at startup and can be turned off
again from the same button.

## Equalizer APO and VST management

Select **Scan APO** or **Refresh APO** to inspect the Equalizer APO installation
and its main `config.txt`. The application:

- follows `Include` directives;
- associates global and device-scoped processing with discovered microphones;
- lists VST plugin commands and their enabled state;
- shows readable VST parameters when available, including common ReaEQ data;
- saves the current VST configuration as a named snapshot;
- applies a saved snapshot or the edited plugin toggles.

Before changing Equalizer APO configuration, the application creates a
timestamped backup of `config.txt`. Review the preview and endpoint association
carefully before applying changes.

## VB-CABLE mixer

The **Mixer** window routes selected microphones to the VB-CABLE playback
endpoint (`CABLE Input`). For each microphone you can:

- include or exclude it from the mix;
- adjust gain in decibels;
- mute or solo it;
- monitor its input level.

The mixer also provides a master gain. Start the mix, then select
`CABLE Output` as the microphone/input source in OBS or another recording
application. Mixer channel and master settings are saved for later sessions.

VB-CABLE must be installed and its endpoints must be available for this feature
to work.

## Local data

Runtime state is stored as JSON under `config/`, including aliases, known-device
metadata, mixer settings, and Equalizer APO snapshots. These files may contain
machine-specific device identifiers and personal aliases.

Do not commit generated `config/*.json` files, logs, exported inventories, or
other machine-specific data.

## Project structure

```text
USBMicrophoneManager.ps1   Application entry point
USBMicrophoneManager.cmd   Windows launcher
lib/
  DeviceDiscovery.ps1      USB/PnP discovery and endpoint mapping
  DeviceWatcher.ps1        Connection and endpoint change monitoring
  AudioEndpoint.ps1        Core Audio endpoint enumeration and peak levels
  AudioMeter.ps1           Meter updates and loudest-device selection
  AudioMixer.ps1           WinRT AudioGraph and VB-CABLE mixer interface
  EqualizerApo.ps1         Equalizer APO parsing and preset management
  Gui.ps1                  WinForms interface and event handling
  JsonStorage.ps1          Alias and device-state persistence
  Helpers.ps1              Shared records, logging, and utilities
config/                    Local runtime state (generated)
```

## Development validation

The project targets Windows PowerShell 5.1. Before committing a change, parse
all PowerShell scripts to catch syntax errors:

```powershell
Get-ChildItem . -Recurse -Filter *.ps1 | ForEach-Object {
    [void][scriptblock]::Create((Get-Content $_.FullName -Raw))
}
```

Then launch the application and manually verify discovery, alias persistence,
device refresh, metering, and any affected optional integrations.

## Troubleshooting

- **A microphone is missing:** confirm that Windows recognizes it, clear the
  filter, disable **Only microphones**, and select **Refresh**.
- **Aliases do not persist:** select **Save** after editing and confirm the
  repository directory is writable.
- **No level appears:** enable the meter and check that the device has an active
  Windows capture endpoint.
- **Equalizer APO is not found:** confirm it is installed in a standard Program
  Files location and configured for the relevant capture endpoint.
- **The mixer cannot start:** install VB-CABLE and confirm that `CABLE Input` and
  `CABLE Output` are enabled in Windows Sound settings.

