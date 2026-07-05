<#
Audio meter helpers.
#>

Set-StrictMode -Version 2.0

function Update-AudioLevels {
    <# Updates Level on every device record by reading IAudioMeterInformation for its endpoint. #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Devices,
        [scriptblock]$Logger
    )

    foreach ($device in $Devices) {
        try {
            $endpointId = ConvertTo-PlainString $device.EndpointId
            $status = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $device -Name 'Status' -Default '')
            if ([string]::IsNullOrWhiteSpace($endpointId) -or $status -notmatch 'ACTIVE|OK') {
                $device.Level = 0
            }
            else {
                $device.Level = Get-AudioEndpointPeak -EndpointId $endpointId -Logger $Logger
            }
        }
        catch {
            $device.Level = 0
            Write-AppLog -Message ("Audio level update failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $Logger
        }
    }
    return $Devices
}

function Get-LoudestMicrophone {
    <# Returns the microphone record with the highest current signal level. #>
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Devices)

    $best = $null
    $bestLevel = -1.0
    foreach ($device in $Devices) {
        $level = [double](Get-ObjectPropertyValue -Object $device -Name 'Level' -Default 0)
        if ($level -gt $bestLevel) {
            $bestLevel = $level
            $best = $device
        }
    }
    return $best
}
