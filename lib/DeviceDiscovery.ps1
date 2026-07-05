<#
USB microphone discovery and USB to MMDevice endpoint mapping.
#>

Set-StrictMode -Version 2.0

function Get-PnpDevicePropertySafe {
    <# Reads one PnP device property and returns an empty string when unavailable. #>
    param(
        [Parameter(Mandatory=$true)][string]$InstanceId,
        [Parameter(Mandatory=$true)][string]$KeyName
    )

    try {
        if (Get-Command Get-PnpDeviceProperty -ErrorAction SilentlyContinue) {
            $prop = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $KeyName -ErrorAction Stop
            return ConvertTo-PlainString $prop.Data
        }
    }
    catch { }
    return ''
}

function Get-PnpDeviceSafe {
    <# Returns PnP devices using Get-PnpDevice when available, otherwise falls back to Win32_PnPEntity. #>
    param([scriptblock]$Logger)

    try {
        if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
            return @(Get-PnpDevice -PresentOnly:$false -ErrorAction Stop)
        }
    }
    catch {
        Write-AppLog -Message ("Get-PnpDevice failed, using CIM fallback: {0}" -f $_.Exception.Message) -Level WARN -Logger $Logger
    }

    try {
        return @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                InstanceId = $_.PNPDeviceID
                FriendlyName = $_.Name
                Class = $_.PNPClass
                Status = $_.Status
                Manufacturer = $_.Manufacturer
            }
        })
    }
    catch {
        Write-AppLog -Message ("CIM PnP enumeration failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $Logger
        return @()
    }
}

function Get-ParentDeviceId {
    <# Finds a likely parent USB device id for an audio endpoint or media interface instance id. #>
    param([string]$InstanceId)

    if ([string]::IsNullOrWhiteSpace($InstanceId)) { return '' }
    $parts = $InstanceId -split '\\'
    if ($parts.Count -ge 3) {
        return ($parts[0..($parts.Count - 2)] -join '\')
    }
    return ''
}

function Convert-PnpToMicrophoneRecord {
    <# Converts a raw PnP audio device into a normalized microphone record with extended USB metadata. #>
    param(
        [Parameter(Mandatory=$true)][object]$Device,
        [scriptblock]$Logger
    )

    $instanceId = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $Device -Name 'InstanceId' -Default (Get-ObjectPropertyValue -Object $Device -Name 'PNPDeviceID' -Default ''))
    $friendlyName = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $Device -Name 'FriendlyName' -Default (Get-ObjectPropertyValue -Object $Device -Name 'Name' -Default ''))
    $status = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $Device -Name 'Status' -Default '')
    $vidPid = Get-VidPidFromInstanceId -InstanceId $instanceId

    $containerId = Get-PnpDevicePropertySafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_ContainerId'
    $locationPaths = Get-PnpDevicePropertySafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_LocationPaths'
    $busRelations = Get-PnpDevicePropertySafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_BusRelations'
    $location = Get-PnpDevicePropertySafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_LocationInfo'
    $driver = Get-PnpDevicePropertySafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_DriverDesc'
    $parent = Get-PnpDevicePropertySafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_Parent'
    $busNumber = Get-PnpDevicePropertySafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_BusNumber'
    $address = Get-PnpDevicePropertySafe -InstanceId $instanceId -KeyName 'DEVPKEY_Device_Address'

    if ([string]::IsNullOrWhiteSpace($parent)) { $parent = Get-ParentDeviceId -InstanceId $instanceId }
    if ([string]::IsNullOrWhiteSpace($driver)) {
        $driver = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $Device -Name 'Manufacturer' -Default '')
    }

    New-MicrophoneRecord `
        -FriendlyName $friendlyName `
        -InstanceId $instanceId `
        -ContainerId $containerId `
        -VID $vidPid.VID `
        -PID $vidPid.PID `
        -LocationPath $locationPaths `
        -BusRelations $busRelations `
        -Status $status `
        -Driver $driver `
        -Location $location `
        -UsbPort (Get-UsbPortFromLocation -LocationPaths $locationPaths -Location $location) `
        -ParentDevice $parent `
        -BusNumber $busNumber `
        -Address $address
}

function Test-IsUsbMicrophoneCandidate {
    <# Determines whether a PnP device is likely to be a USB microphone or USB capture audio endpoint. #>
    param([Parameter(Mandatory=$true)][object]$Device)

    $instanceId = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $Device -Name 'InstanceId' -Default (Get-ObjectPropertyValue -Object $Device -Name 'PNPDeviceID' -Default ''))
    $name = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $Device -Name 'FriendlyName' -Default (Get-ObjectPropertyValue -Object $Device -Name 'Name' -Default ''))
    $class = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $Device -Name 'Class' -Default (Get-ObjectPropertyValue -Object $Device -Name 'PNPClass' -Default ''))

    $isUsb = ($instanceId -match 'USB|SWD\\MMDEVAPI|HDAUDIO' -or $name -match 'USB')
    $isAudioClass = ($class -match 'AudioEndpoint|MEDIA|Sound|Audio')
    $looksLikeInput = ($name -match 'microphone|mic|input|audio device|trust|mico|usb audio' -or $instanceId -match 'MMDEVAPI')
    return ($isUsb -and ($isAudioClass -or $looksLikeInput))
}

function Get-UsbMicrophoneDevices {
    <# Discovers USB microphone candidates from Plug and Play and returns normalized records. #>
    param([scriptblock]$Logger)

    $raw = Get-PnpDeviceSafe -Logger $Logger
    $records = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    foreach ($device in $raw) {
        try {
            if (-not (Test-IsUsbMicrophoneCandidate -Device $device)) { continue }
            $record = Convert-PnpToMicrophoneRecord -Device $device -Logger $Logger
            if ([string]::IsNullOrWhiteSpace($record.InstanceId)) { continue }
            $key = Normalize-DeviceId $record.InstanceId
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $records.Add($record)
            }
        }
        catch {
            Write-AppLog -Message ("Device parsing failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $Logger
        }
    }

    return $records.ToArray()
}

function Set-EndpointMapping {
    <# Maps MMDevice capture endpoints to USB microphone records using ContainerId first, then name-based fallback. #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Devices,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Endpoints
    )

    $unusedEndpoints = New-Object System.Collections.Generic.List[object]
    foreach ($endpoint in $Endpoints) { $unusedEndpoints.Add($endpoint) }

    foreach ($device in $Devices) {
        $match = $null
        $container = (ConvertTo-PlainString $device.ContainerId).ToUpperInvariant()
        if (-not [string]::IsNullOrWhiteSpace($container)) {
            foreach ($endpoint in @($unusedEndpoints)) {
                if ((ConvertTo-PlainString $endpoint.ContainerId).ToUpperInvariant() -eq $container) {
                    $match = $endpoint
                    break
                }
            }
        }

        if ($null -eq $match) {
            $deviceName = (ConvertTo-PlainString $device.FriendlyName).ToLowerInvariant()
            foreach ($endpoint in @($unusedEndpoints)) {
                $endpointName = ((ConvertTo-PlainString $endpoint.Name) + ' ' + (ConvertTo-PlainString $endpoint.InterfaceFriendlyName)).ToLowerInvariant()
                if ($endpointName.Contains('microphone') -or $endpointName.Contains('usb')) {
                    if ($deviceName.Contains('usb') -or $endpointName.Contains($deviceName) -or $deviceName.Contains('audio')) {
                        $match = $endpoint
                        break
                    }
                }
            }
        }

        if ($null -ne $match) {
            $device.EndpointId = ConvertTo-PlainString $match.Id
            $device.EndpointGuid = ConvertTo-PlainString $match.Guid
            if ([string]::IsNullOrWhiteSpace($device.FriendlyName)) {
                $device.FriendlyName = ConvertTo-PlainString $match.Name
            }
            [void]$unusedEndpoints.Remove($match)
        }
    }

    return $Devices
}

function Get-UsbMicrophoneInventory {
    <# Performs fast microphone discovery, endpoint mapping, and alias application. #>
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [scriptblock]$Logger
    )

    $aliases = Read-AliasMap -ProjectRoot $ProjectRoot -Logger $Logger
    $deviceStateMap = Read-DeviceStateMap -ProjectRoot $ProjectRoot -Logger $Logger
    $endpoints = @(Get-CaptureAudioEndpoints -Logger $Logger)
    $devices = @()

    if ($endpoints.Count -gt 0) {
        foreach ($endpoint in $endpoints) {
            $endpointSearchText = @(
                ConvertTo-PlainString $endpoint.Name
                ConvertTo-PlainString (Get-ObjectPropertyValue -Object $endpoint -Name 'InterfaceFriendlyName' -Default '')
                ConvertTo-PlainString (Get-ObjectPropertyValue -Object $endpoint -Name 'PnpInstanceId' -Default '')
            ) -join ' '
            if ($endpointSearchText -match 'microphone|mikrofon|usb|input|audio|mic') {
                $endpointInstanceId = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $endpoint -Name 'PnpInstanceId' -Default '')
                if ([string]::IsNullOrWhiteSpace($endpointInstanceId)) {
                    $endpointInstanceId = ConvertTo-PlainString $endpoint.Id
                }
                $vidPid = Get-VidPidFromInstanceId -InstanceId $endpointInstanceId
                $devices += New-MicrophoneRecord `
                    -FriendlyName (ConvertTo-PlainString $endpoint.Name) `
                    -InstanceId $endpointInstanceId `
                    -ContainerId (ConvertTo-PlainString $endpoint.ContainerId) `
                    -VID $vidPid.VID `
                    -PID $vidPid.PID `
                    -EndpointId (ConvertTo-PlainString $endpoint.Id) `
                    -EndpointGuid (ConvertTo-PlainString $endpoint.Guid) `
                    -Status (ConvertTo-PlainString $endpoint.State) `
                    -Driver 'MMDevice'
            }
        }
    }
    else {
        $devices = @(Get-UsbMicrophoneDevices -Logger $Logger)
        $devices = @(Set-EndpointMapping -Devices $devices -Endpoints $endpoints)
    }

    $defaultEndpointId = Normalize-DeviceId (Get-DefaultCaptureAudioEndpointId -Logger $Logger)
    $defaultCommEndpointId = Normalize-DeviceId (Get-DefaultCommunicationsCaptureAudioEndpointId -Logger $Logger)
    foreach ($device in $devices) {
        $deviceEndpointId = Normalize-DeviceId (ConvertTo-PlainString $device.EndpointId)
        $device.IsDefault = (
            -not [string]::IsNullOrWhiteSpace($defaultEndpointId) -and
            $deviceEndpointId -eq $defaultEndpointId
        )
        $device.IsDefaultComm = (
            -not [string]::IsNullOrWhiteSpace($defaultCommEndpointId) -and
            $deviceEndpointId -eq $defaultCommEndpointId
        )
    }

    $devices = @(Apply-AliasesToDevices -Devices $devices -AliasMap $aliases)
    $devices = @(Apply-DeviceStateToDevices -Devices $devices -StateMap $deviceStateMap)
    $deviceStateMap = Update-DeviceStateForDevices -Devices $devices -StateMap $deviceStateMap
    [void](Save-DeviceStateMap -ProjectRoot $ProjectRoot -StateMap $deviceStateMap -Logger $Logger)
    Write-AppLog -Message ("Detected {0} USB microphone record(s)." -f $devices.Count) -Level INFO -Logger $Logger
    return $devices
}
