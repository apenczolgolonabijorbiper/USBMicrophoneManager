<#
Device connection, disconnection, and state change watcher.
#>

Set-StrictMode -Version 2.0

function Start-DeviceWatcher {
    <# Registers WMI event watchers for PnP device creation, deletion, modification, and MMDevice registry changes. #>
    param(
        [Parameter(Mandatory=$true)][scriptblock]$OnChanged,
        [scriptblock]$Logger
    )

    Stop-DeviceWatcher -Logger $Logger

    $createdId = 'USBMicrophoneManager_DeviceCreated'
    $deletedId = 'USBMicrophoneManager_DeviceDeleted'
    $modifiedId = 'USBMicrophoneManager_DeviceModified'
    $audioRegistryId = 'USBMicrophoneManager_AudioCaptureRegistryChanged'

    try {
        Register-WmiEvent -Query "SELECT * FROM __InstanceCreationEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_PnPEntity'" -SourceIdentifier $createdId -Action {
            $target = $Event.SourceEventArgs.NewEvent.TargetInstance
            if ($target -and (($target.PNPDeviceID -match 'USB|MMDEVAPI') -or ($target.Name -match 'USB|Microphone|Mic|Audio'))) {
                & $Event.MessageData.OnChanged 'connected' $target.Name $target.PNPDeviceID
            }
        } -MessageData @{ OnChanged = $OnChanged } | Out-Null

        Register-WmiEvent -Query "SELECT * FROM __InstanceDeletionEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_PnPEntity'" -SourceIdentifier $deletedId -Action {
            $target = $Event.SourceEventArgs.NewEvent.TargetInstance
            if ($target -and (($target.PNPDeviceID -match 'USB|MMDEVAPI') -or ($target.Name -match 'USB|Microphone|Mic|Audio'))) {
                & $Event.MessageData.OnChanged 'disconnected' $target.Name $target.PNPDeviceID
            }
        } -MessageData @{ OnChanged = $OnChanged } | Out-Null

        Register-WmiEvent -Query "SELECT * FROM __InstanceModificationEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_PnPEntity'" -SourceIdentifier $modifiedId -Action {
            $target = $Event.SourceEventArgs.NewEvent.TargetInstance
            $previous = $Event.SourceEventArgs.NewEvent.PreviousInstance
            if ($target -and (($target.PNPDeviceID -match 'USB|MMDEVAPI') -or ($target.Name -match 'USB|Microphone|Mic|Audio'))) {
                $statusChanged = ($previous -and ($target.Status -ne $previous.Status))
                $nameChanged = ($previous -and ($target.Name -ne $previous.Name))
                $availabilityChanged = ($previous -and ($target.Availability -ne $previous.Availability))
                if ($statusChanged -or $nameChanged -or $availabilityChanged) {
                    & $Event.MessageData.OnChanged 'state changed' $target.Name $target.PNPDeviceID
                }
            }
        } -MessageData @{ OnChanged = $OnChanged } | Out-Null

        try {
            Register-WmiEvent `
                -Namespace 'root\default' `
                -Query "SELECT * FROM RegistryTreeChangeEvent WHERE Hive='HKEY_LOCAL_MACHINE' AND RootPath='SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\MMDevices\\Audio\\Capture'" `
                -SourceIdentifier $audioRegistryId `
                -Action {
                    & $Event.MessageData.OnChanged 'audio endpoint state changed' 'MMDevices Audio Capture' ''
                } `
                -MessageData @{ OnChanged = $OnChanged } | Out-Null
        }
        catch {
            Write-AppLog -Message ("Audio endpoint registry watcher failed: {0}" -f $_.Exception.Message) -Level WARN -Logger $Logger
        }

        Write-AppLog -Message 'Device watcher started.' -Level INFO -Logger $Logger
    }
    catch {
        Write-AppLog -Message ("Device watcher failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $Logger
    }
}

function Stop-DeviceWatcher {
    <# Unregisters WMI event watchers created by this application. #>
    param([scriptblock]$Logger)

    foreach ($id in @(
        'USBMicrophoneManager_DeviceCreated',
        'USBMicrophoneManager_DeviceDeleted',
        'USBMicrophoneManager_DeviceModified',
        'USBMicrophoneManager_AudioCaptureRegistryChanged'
    )) {
        try {
            Unregister-Event -SourceIdentifier $id -ErrorAction SilentlyContinue
            Get-EventSubscriber -SourceIdentifier $id -ErrorAction SilentlyContinue | Unregister-Event -ErrorAction SilentlyContinue
        }
        catch {
            Write-AppLog -Message ("Stopping watcher failed: {0}" -f $_.Exception.Message) -Level WARN -Logger $Logger
        }
    }
}
