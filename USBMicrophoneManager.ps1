<#
USB Microphone Manager
PowerShell 5.1 / Windows Forms application for managing aliases for many identical USB microphones.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

$script:ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $script:ProjectRoot 'lib\Helpers.ps1')
. (Join-Path $script:ProjectRoot 'lib\JsonStorage.ps1')
. (Join-Path $script:ProjectRoot 'lib\AudioEndpoint.ps1')
. (Join-Path $script:ProjectRoot 'lib\DeviceDiscovery.ps1')
. (Join-Path $script:ProjectRoot 'lib\DeviceWatcher.ps1')
. (Join-Path $script:ProjectRoot 'lib\AudioMeter.ps1')
. (Join-Path $script:ProjectRoot 'lib\AudioMixer.ps1')
. (Join-Path $script:ProjectRoot 'lib\EqualizerApo.ps1')
. (Join-Path $script:ProjectRoot 'lib\Gui.ps1')

Ensure-ProjectFolders -RootPath $script:ProjectRoot
Start-USBMicrophoneManagerGui -ProjectRoot $script:ProjectRoot
