<#
Shared helpers for USB Microphone Manager.
#>

Set-StrictMode -Version 2.0

function Ensure-ProjectFolders {
    <# Creates required project folders and the default aliases file when missing. #>
    param([Parameter(Mandatory=$true)][string]$RootPath)

    $configPath = Join-Path $RootPath 'config'
    $libPath = Join-Path $RootPath 'lib'

    foreach ($path in @($configPath, $libPath)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
        }
    }

    $aliasesPath = Join-Path $configPath 'aliases.json'
    if (-not (Test-Path -LiteralPath $aliasesPath)) {
        "{}" | Set-Content -LiteralPath $aliasesPath -Encoding UTF8
    }
}

function Invoke-Safely {
    <# Executes a script block and logs any non-terminating or terminating error without stopping the application. #>
    param(
        [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory=$true)][string]$Action,
        [scriptblock]$Logger
    )

    try {
        & $ScriptBlock
    }
    catch {
        $message = "{0}: {1}" -f $Action, $_.Exception.Message
        if ($Logger) { & $Logger $message 'ERROR' }
        else { Write-Warning $message }
        $null
    }
}

function Write-AppLog {
    <# Writes a timestamped message to a UI log callback or to the host when no callback exists. #>
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEVICE')][string]$Level = 'INFO',
        [scriptblock]$Logger
    )

    if ($Logger) {
        & $Logger $Message $Level
    }
    else {
        $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Write-Host $line
    }
}

function ConvertTo-PlainString {
    <# Converts nulls, arrays, and arbitrary objects to a readable single-line string. #>
    param([object]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [array]) {
        return (($Value | ForEach-Object { ConvertTo-PlainString $_ }) -join '; ')
    }
    return [string]$Value
}

function Get-ObjectPropertyValue {
    <# Reads a property from any PS object without throwing when it is missing. #>
    param(
        [Parameter(Mandatory=$true)][object]$Object,
        [Parameter(Mandatory=$true)][string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    if ($null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function Normalize-DeviceId {
    <# Normalizes a device instance id for stable hash keys and comparisons. #>
    param([string]$InstanceId)

    if ([string]::IsNullOrWhiteSpace($InstanceId)) { return '' }
    return $InstanceId.Trim().ToUpperInvariant()
}

function Get-VidPidFromInstanceId {
    <# Extracts USB VID and PID values from a Plug and Play instance id. #>
    param([string]$InstanceId)

    $result = [ordered]@{ VID = ''; PID = '' }
    if ([string]::IsNullOrWhiteSpace($InstanceId)) { return [pscustomobject]$result }

    $match = [regex]::Match($InstanceId, 'VID_([0-9A-Fa-f]{4}).*PID_([0-9A-Fa-f]{4})')
    if ($match.Success) {
        $result.VID = $match.Groups[1].Value.ToUpperInvariant()
        $result.PID = $match.Groups[2].Value.ToUpperInvariant()
    }
    return [pscustomobject]$result
}

function Get-VidPidAliasKey {
    <# Builds the stable key used to assign Alias1 to every device with the same VID and PID. #>
    param(
        [string]$VID,
        [Alias('PID')][string]$ProductId
    )

    $normalizedVid = (ConvertTo-PlainString $VID).Trim().ToUpperInvariant()
    $normalizedPid = (ConvertTo-PlainString $ProductId).Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($normalizedVid) -or [string]::IsNullOrWhiteSpace($normalizedPid)) {
        return ''
    }
    return ('VID_{0}&PID_{1}' -f $normalizedVid, $normalizedPid)
}

function Convert-EndpointGuidFromId {
    <# Extracts the trailing MMDevice endpoint GUID from a full endpoint id. #>
    param([string]$EndpointId)

    if ([string]::IsNullOrWhiteSpace($EndpointId)) { return '' }
    $match = [regex]::Match($EndpointId, '\{[0-9A-Fa-f\-]{36}\}\s*$')
    if ($match.Success) { return $match.Value.ToUpperInvariant() }
    return $EndpointId
}

function Get-UsbPortFromLocation {
    <# Builds a compact USB port label from location paths or location text. #>
    param(
        [string]$LocationPaths,
        [string]$Location
    )

    $source = @($LocationPaths, $Location) -join '; '
    if ([string]::IsNullOrWhiteSpace($source)) { return '' }

    $ports = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($source, 'USBROOT\([^)]+\)|#USB\([^)]+\)|Port_#\d+\.Hub_#\d+')) {
        if (-not $ports.Contains($m.Value)) { $ports.Add($m.Value) }
    }
    if ($ports.Count -gt 0) { return ($ports -join ' / ') }
    return $source
}

function New-MicrophoneRecord {
    <# Creates one normalized microphone record used by discovery, storage, metering, and the grid. #>
    param(
        [string]$Alias1 = '',
        [string]$Alias2 = '',
        [string]$Alias3 = '',
        [string]$Alias4 = '',
        [string]$FriendlyName = '',
        [string]$InstanceId = '',
        [string]$ContainerId = '',
        [string]$VID = '',
        [Alias('PID')][string]$ProductId = '',
        [string]$LocationPath = '',
        [string]$BusRelations = '',
        [string]$EndpointId = '',
        [string]$EndpointGuid = '',
        [string]$Status = '',
        [string]$Driver = '',
        [string]$Location = '',
        [string]$UsbPort = '',
        [string]$ParentDevice = '',
        [string]$BusNumber = '',
        [string]$Address = '',
        [double]$Level = 0,
        [string]$LastActive = '',
        [bool]$IsMicrophone = $true,
        [bool]$IsDefault = $false,
        [bool]$IsDefaultComm = $false,
        [string]$Apo = '',
        [string]$Processing = ''
    )

    [pscustomobject]([ordered]@{
        Alias1 = $Alias1
        Alias2 = $Alias2
        Alias3 = $Alias3
        Alias4 = $Alias4
        FriendlyName = $FriendlyName
        VID = $VID
        PID = $ProductId
        InstanceId = $InstanceId
        ContainerId = $ContainerId
        EndpointId = $EndpointId
        EndpointGuid = $EndpointGuid
        UsbPort = $UsbPort
        LocationPath = $LocationPath
        BusRelations = $BusRelations
        Location = $Location
        Driver = $Driver
        Status = $Status
        ParentDevice = $ParentDevice
        BusNumber = $BusNumber
        Address = $Address
        Level = $Level
        LastActive = $LastActive
        IsMicrophone = $IsMicrophone
        IsDefault = $IsDefault
        IsDefaultComm = $IsDefaultComm
        Apo = $Apo
        Processing = $Processing
    })
}
