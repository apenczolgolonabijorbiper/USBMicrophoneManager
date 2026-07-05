<#
JSON alias persistence.
#>

Set-StrictMode -Version 2.0

function Get-AliasFilePath {
    <# Returns the aliases.json path for the project. #>
    param([Parameter(Mandatory=$true)][string]$ProjectRoot)
    return (Join-Path $ProjectRoot 'config\aliases.json')
}

function Get-DeviceStateFilePath {
    <# Returns the device-state.json path for persisted last-active timestamps. #>
    param([Parameter(Mandatory=$true)][string]$ProjectRoot)
    return (Join-Path $ProjectRoot 'config\device-state.json')
}

function ConvertTo-StorageBoolean {
    <# Converts JSON-loaded bool-like values to a real boolean with a default. #>
    param(
        [object]$Value,
        [bool]$Default = $true
    )

    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return $Value }
    $text = ([string]$Value).Trim()
    if ($text -match '^(true|1|yes|y)$') { return $true }
    if ($text -match '^(false|0|no|n)$') { return $false }
    return $Default
}

function ConvertFrom-AliasJsonSection {
    <# Converts one named JSON alias section into a normalized lookup table. #>
    param(
        [object]$Section,
        [Parameter(Mandatory=$true)][string]$ValueName
    )

    $result = @{}
    if ($null -eq $Section) { return $result }
    foreach ($property in $Section.PSObject.Properties) {
        $key = Normalize-DeviceId $property.Name
        $value = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $property.Value -Name $ValueName -Default $property.Value)
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            $result[$key] = $value
        }
    }
    return $result
}

function ConvertTo-AliasJsonSection {
    <# Converts one alias lookup table into an ordered JSON-ready section. #>
    param(
        [Parameter(Mandatory=$true)][hashtable]$Map,
        [Parameter(Mandatory=$true)][string]$ValueName
    )

    $result = [ordered]@{}
    foreach ($key in @($Map.Keys | Sort-Object)) {
        $entry = [ordered]@{}
        $entry[$ValueName] = ConvertTo-PlainString $Map[$key]
        $result[$key] = $entry
    }
    return $result
}

function Read-AliasMap {
    <# Loads all four identity-based alias maps, including the legacy Alias format. #>
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [scriptblock]$Logger
    )

    $path = Get-AliasFilePath -ProjectRoot $ProjectRoot
    $map = @{
        Alias1ByVidPid = @{}
        Alias2ByInstanceId = @{}
        Alias3ByContainerId = @{}
        Alias4ByEndpointGuid = @{}
    }
    try {
        if (-not (Test-Path -LiteralPath $path)) {
            "{}" | Set-Content -LiteralPath $path -Encoding UTF8
            Write-AppLog -Message "Created config file: $path" -Level INFO -Logger $Logger
            return $map
        }

        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { $raw = '{}' }
        $json = $raw | ConvertFrom-Json

        $alias1Section = Get-ObjectPropertyValue -Object $json -Name 'Alias1ByVidPid' -Default $null
        $alias2Section = Get-ObjectPropertyValue -Object $json -Name 'Alias2ByInstanceId' -Default $null
        $alias3Section = Get-ObjectPropertyValue -Object $json -Name 'Alias3ByContainerId' -Default $null
        $alias4Section = Get-ObjectPropertyValue -Object $json -Name 'Alias4ByEndpointGuid' -Default $null

        if ($null -ne $alias1Section -or $null -ne $alias2Section -or $null -ne $alias3Section -or $null -ne $alias4Section) {
            $map.Alias1ByVidPid = ConvertFrom-AliasJsonSection -Section $alias1Section -ValueName 'Alias1'
            $map.Alias2ByInstanceId = ConvertFrom-AliasJsonSection -Section $alias2Section -ValueName 'Alias2'
            $map.Alias3ByContainerId = ConvertFrom-AliasJsonSection -Section $alias3Section -ValueName 'Alias3'
            $map.Alias4ByEndpointGuid = ConvertFrom-AliasJsonSection -Section $alias4Section -ValueName 'Alias4'
        }
        else {
            foreach ($property in $json.PSObject.Properties) {
                $instanceKey = Normalize-DeviceId $property.Name
                $ids = Get-VidPidFromInstanceId -InstanceId $property.Name
                $vidPidKey = Get-VidPidAliasKey -VID $ids.VID -PID $ids.PID
                $legacyAlias = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $property.Value -Name 'Alias' -Default '')
                $alias1 = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $property.Value -Name 'Alias1' -Default $legacyAlias)
                $alias2 = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $property.Value -Name 'Alias2' -Default '')

                if (-not [string]::IsNullOrWhiteSpace($vidPidKey)) {
                    if (-not $map.Alias1ByVidPid.ContainsKey($vidPidKey) -or -not [string]::IsNullOrWhiteSpace($alias1)) {
                        $map.Alias1ByVidPid[$vidPidKey] = $alias1
                    }
                }
                if (-not [string]::IsNullOrWhiteSpace($instanceKey)) {
                    $map.Alias2ByInstanceId[$instanceKey] = $alias2
                }
            }
        }
        Write-AppLog -Message "Loaded configuration: $path" -Level INFO -Logger $Logger
    }
    catch {
        Write-AppLog -Message ("Loading configuration failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $Logger
    }
    return $map
}

function Save-AliasMap {
    <# Saves aliases by VID/PID, InstanceId, ContainerId, and Endpoint GUID. #>
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][object[]]$Devices,
        [scriptblock]$Logger
    )

    $path = Get-AliasFilePath -ProjectRoot $ProjectRoot
    $map = Read-AliasMap -ProjectRoot $ProjectRoot -Logger $Logger

    foreach ($device in $Devices) {
        $instanceId = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $device -Name 'InstanceId' -Default '')
        $vid = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $device -Name 'VID' -Default '')
        $productId = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $device -Name 'PID' -Default '')
        $vidPidKey = Get-VidPidAliasKey -VID $vid -PID $productId
        $containerKey = Normalize-DeviceId (ConvertTo-PlainString (Get-ObjectPropertyValue -Object $device -Name 'ContainerId' -Default ''))
        $endpointGuidKey = Normalize-DeviceId (ConvertTo-PlainString (Get-ObjectPropertyValue -Object $device -Name 'EndpointGuid' -Default ''))

        if (-not [string]::IsNullOrWhiteSpace($vidPidKey)) {
            $map.Alias1ByVidPid[$vidPidKey] = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $device -Name 'Alias1' -Default '')
        }
        if (-not [string]::IsNullOrWhiteSpace($instanceId)) {
            $instanceKey = Normalize-DeviceId $instanceId
            $map.Alias2ByInstanceId[$instanceKey] = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $device -Name 'Alias2' -Default '')
        }
        if (-not [string]::IsNullOrWhiteSpace($containerKey)) {
            $map.Alias3ByContainerId[$containerKey] = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $device -Name 'Alias3' -Default '')
        }
        if (-not [string]::IsNullOrWhiteSpace($endpointGuidKey)) {
            $map.Alias4ByEndpointGuid[$endpointGuidKey] = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $device -Name 'Alias4' -Default '')
        }
    }

    $root = [ordered]@{
        Alias1ByVidPid = ConvertTo-AliasJsonSection -Map $map.Alias1ByVidPid -ValueName 'Alias1'
        Alias2ByInstanceId = ConvertTo-AliasJsonSection -Map $map.Alias2ByInstanceId -ValueName 'Alias2'
        Alias3ByContainerId = ConvertTo-AliasJsonSection -Map $map.Alias3ByContainerId -ValueName 'Alias3'
        Alias4ByEndpointGuid = ConvertTo-AliasJsonSection -Map $map.Alias4ByEndpointGuid -ValueName 'Alias4'
    }

    try {
        $json = $root | ConvertTo-Json -Depth 6
        $json | Set-Content -LiteralPath $path -Encoding UTF8
        Write-AppLog -Message "Saved configuration: $path" -Level INFO -Logger $Logger
        return $true
    }
    catch {
        Write-AppLog -Message ("Saving configuration failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $Logger
        return $false
    }
}

function Apply-AliasesToDevices {
    <# Applies all aliases to devices by their corresponding stable identifiers. #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Devices,
        [Parameter(Mandatory=$true)][hashtable]$AliasMap
    )

    foreach ($device in $Devices) {
        $vidPidKey = Get-VidPidAliasKey `
            -VID (ConvertTo-PlainString (Get-ObjectPropertyValue -Object $device -Name 'VID' -Default '')) `
            -PID (ConvertTo-PlainString (Get-ObjectPropertyValue -Object $device -Name 'PID' -Default ''))
        $instanceKey = Normalize-DeviceId (ConvertTo-PlainString $device.InstanceId)
        $containerKey = Normalize-DeviceId (ConvertTo-PlainString $device.ContainerId)
        $endpointGuidKey = Normalize-DeviceId (ConvertTo-PlainString $device.EndpointGuid)

        if (-not [string]::IsNullOrWhiteSpace($vidPidKey) -and $AliasMap.Alias1ByVidPid.ContainsKey($vidPidKey)) {
            $device.Alias1 = ConvertTo-PlainString $AliasMap.Alias1ByVidPid[$vidPidKey]
        }
        if (-not [string]::IsNullOrWhiteSpace($instanceKey) -and $AliasMap.Alias2ByInstanceId.ContainsKey($instanceKey)) {
            $device.Alias2 = ConvertTo-PlainString $AliasMap.Alias2ByInstanceId[$instanceKey]
        }
        if (-not [string]::IsNullOrWhiteSpace($containerKey) -and $AliasMap.Alias3ByContainerId.ContainsKey($containerKey)) {
            $device.Alias3 = ConvertTo-PlainString $AliasMap.Alias3ByContainerId[$containerKey]
        }
        if (-not [string]::IsNullOrWhiteSpace($endpointGuidKey) -and $AliasMap.Alias4ByEndpointGuid.ContainsKey($endpointGuidKey)) {
            $device.Alias4 = ConvertTo-PlainString $AliasMap.Alias4ByEndpointGuid[$endpointGuidKey]
        }
    }
    return $Devices
}

function Read-DeviceStateMap {
    <# Loads persisted device state metadata keyed by InstanceId. #>
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [scriptblock]$Logger
    )

    $path = Get-DeviceStateFilePath -ProjectRoot $ProjectRoot
    $map = @{}
    try {
        if (-not (Test-Path -LiteralPath $path)) {
            "{}" | Set-Content -LiteralPath $path -Encoding UTF8
            return $map
        }

        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { $raw = '{}' }
        $json = $raw | ConvertFrom-Json

        foreach ($property in $json.PSObject.Properties) {
            $key = Normalize-DeviceId $property.Name
            $lastActive = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $property.Value -Name 'LastActive' -Default '')
            $isMicrophone = Get-ObjectPropertyValue -Object $property.Value -Name 'IsMicrophone' -Default $true
            if (-not [string]::IsNullOrWhiteSpace($key)) {
                $map[$key] = @{
                    LastActive = $lastActive
                    IsMicrophone = ConvertTo-StorageBoolean -Value $isMicrophone -Default $true
                }
            }
        }
    }
    catch {
        Write-AppLog -Message ("Loading device state failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $Logger
    }
    return $map
}

function Save-DeviceStateMap {
    <# Saves persisted device state metadata keyed by InstanceId. #>
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][hashtable]$StateMap,
        [scriptblock]$Logger
    )

    $path = Get-DeviceStateFilePath -ProjectRoot $ProjectRoot
    $root = [ordered]@{}
    foreach ($key in ($StateMap.Keys | Sort-Object)) {
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        $root[$key] = [ordered]@{
            LastActive = ConvertTo-PlainString $StateMap[$key]['LastActive']
            IsMicrophone = ConvertTo-StorageBoolean -Value $StateMap[$key]['IsMicrophone'] -Default $true
        }
    }

    try {
        ($root | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding UTF8
        return $true
    }
    catch {
        Write-AppLog -Message ("Saving device state failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $Logger
        return $false
    }
}

function Apply-DeviceStateToDevices {
    <# Applies persisted last-active and microphone flags to device records. #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Devices,
        [Parameter(Mandatory=$true)][hashtable]$StateMap
    )

    foreach ($device in $Devices) {
        $key = Normalize-DeviceId (ConvertTo-PlainString $device.InstanceId)
        if ($StateMap.ContainsKey($key)) {
            $device.LastActive = ConvertTo-PlainString $StateMap[$key]['LastActive']
            $device.IsMicrophone = ConvertTo-StorageBoolean -Value $StateMap[$key]['IsMicrophone'] -Default $true
        }
        else {
            $device.IsMicrophone = $true
        }
    }
    return $Devices
}

function Update-DeviceStateForDevices {
    <# Updates persisted device state for currently discovered devices and returns the updated state map. #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Devices,
        [Parameter(Mandatory=$true)][hashtable]$StateMap
    )

    $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    foreach ($device in $Devices) {
        $key = Normalize-DeviceId (ConvertTo-PlainString $device.InstanceId)
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if (-not $StateMap.ContainsKey($key)) { $StateMap[$key] = @{} }

        $StateMap[$key]['IsMicrophone'] = ConvertTo-StorageBoolean -Value (Get-ObjectPropertyValue -Object $device -Name 'IsMicrophone' -Default $true) -Default $true
        $status = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $device -Name 'Status' -Default '')
        if ($status -match 'ACTIVE|OK') {
            $StateMap[$key]['LastActive'] = $now
            $device.LastActive = $now
        }
        else {
            $device.LastActive = ConvertTo-PlainString $StateMap[$key]['LastActive']
        }
    }
    return $StateMap
}

function Save-DeviceStateForDevices {
    <# Persists microphone flags and last-active timestamps for the supplied devices. #>
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Devices,
        [scriptblock]$Logger
    )

    $stateMap = Read-DeviceStateMap -ProjectRoot $ProjectRoot -Logger $Logger
    $stateMap = Update-DeviceStateForDevices -Devices $Devices -StateMap $stateMap
    return (Save-DeviceStateMap -ProjectRoot $ProjectRoot -StateMap $stateMap -Logger $Logger)
}
