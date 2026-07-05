<#
Equalizer APO configuration discovery and lightweight processing parser.
#>

Set-StrictMode -Version 2.0

function Get-EqualizerApoInstallPath {
    <# Finds the Equalizer APO install directory in common Program Files locations. #>
    param()

    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $candidates = @($roots | ForEach-Object { Join-Path $_ 'EqualizerAPO' })

    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $path 'config\config.txt')) { return $path }
    }
    return ''
}

function Get-EqualizerApoConfigPath {
    <# Returns the main Equalizer APO config.txt path when available. #>
    param()

    $installPath = Get-EqualizerApoInstallPath
    if ([string]::IsNullOrWhiteSpace($installPath)) { return '' }
    return (Join-Path $installPath 'config\config.txt')
}

function Get-EqualizerApoInstalledEndpointGuids {
    <# Returns endpoint GUIDs whose FxProperties indicate Equalizer APO is installed. #>
    param([scriptblock]$Logger)

    $guids = New-Object System.Collections.Generic.List[string]
    foreach ($flow in @('Capture','Render')) {
        $basePath = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$flow"
        try {
            if (-not (Test-Path -LiteralPath $basePath)) { continue }
            foreach ($endpointKey in Get-ChildItem -LiteralPath $basePath -ErrorAction Stop) {
                $fxPath = Join-Path $endpointKey.PSPath 'FxProperties'
                if (-not (Test-Path -LiteralPath $fxPath)) { continue }

                $fxProps = Get-ItemProperty -LiteralPath $fxPath -ErrorAction SilentlyContinue
                $found = $false
                foreach ($property in $fxProps.PSObject.Properties) {
                    if ($property.Name -notlike '{*') { continue }
                    $valueText = ConvertTo-PlainString $property.Value
                    if ($valueText -match 'Equalizer\s*APO') {
                        $found = $true
                        break
                    }
                }

                if ($found) {
                    $guid = (ConvertTo-PlainString $endpointKey.PSChildName).ToUpperInvariant()
                    if (-not $guids.Contains($guid)) { $guids.Add($guid) }
                }
            }
        }
        catch {
            Write-AppLog -Message ("Equalizer APO endpoint scan failed for ${flow}: {0}" -f $_.Exception.Message) -Level WARN -Logger $Logger
        }
    }
    return $guids.ToArray()
}

function Resolve-EqualizerApoIncludePath {
    <# Resolves an Equalizer APO Include path relative to the current config file. #>
    param(
        [Parameter(Mandatory=$true)][string]$IncludePath,
        [Parameter(Mandatory=$true)][string]$CurrentFile
    )

    $clean = $IncludePath.Trim().Trim('"')
    if ([System.IO.Path]::IsPathRooted($clean)) { return $clean }
    return (Join-Path (Split-Path -Parent $CurrentFile) $clean)
}

function Read-EqualizerApoConfigLines {
    <# Reads config.txt and recursively follows Include commands while avoiding cycles. #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [hashtable]$Visited
    )

    if ($null -eq $Visited) { $Visited = @{} }
    $resolved = [System.IO.Path]::GetFullPath($Path)
    $key = $resolved.ToUpperInvariant()
    if ($Visited.ContainsKey($key)) { return @() }
    $Visited[$key] = $true

    $rows = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $resolved)) { return @() }

    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $resolved -Encoding UTF8) {
        $lineNumber++
        $trimmed = $line.Trim()
        $isComment = $trimmed.StartsWith('#')
        $effective = if ($isComment) { $trimmed.TrimStart('#').Trim() } else { $trimmed }

        $rows.Add([pscustomobject]@{
            File = $resolved
            LineNumber = $lineNumber
            Text = $line
            EffectiveText = $effective
            IsComment = $isComment
        })

        if (-not $isComment -and $effective -match '(?i)^Include\s*:\s*(.+)$') {
            $includePath = Resolve-EqualizerApoIncludePath -IncludePath $matches[1] -CurrentFile $resolved
            foreach ($included in Read-EqualizerApoConfigLines -Path $includePath -Visited $Visited) {
                $rows.Add($included)
            }
        }
    }
    return $rows.ToArray()
}

function Get-EqualizerApoPluginName {
    <# Extracts a friendly VST DLL name from a VSTPlugin command line. #>
    param([string]$Line)

    $library = ''
    if ($Line -match '(?i)\bLibrary\s+"([^"]+)"') { $library = $matches[1] }
    elseif ($Line -match '(?i)\bLibrary\s+([^\s]+)') { $library = $matches[1] }
    if ([string]::IsNullOrWhiteSpace($library)) { return 'VSTPlugin' }
    return [System.IO.Path]::GetFileNameWithoutExtension($library)
}

function Split-EqualizerApoCommandTokens {
    <# Splits an Equalizer APO command line into tokens while preserving quoted values. #>
    param([string]$Line)

    $tokens = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Line)) { return @() }

    $pattern = '"([^"]*)"|(\S+)'
    foreach ($match in [regex]::Matches($Line, $pattern)) {
        if ($match.Groups[1].Success) {
            $tokens.Add($match.Groups[1].Value)
        }
        else {
            $tokens.Add($match.Groups[2].Value)
        }
    }
    return $tokens.ToArray()
}

function Get-EqualizerApoChunkData {
    <# Extracts the Base64 ChunkData payload from an Equalizer APO command line. #>
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return '' }
    if ($Line -match '(?i)\bChunkData\s+"([^"]+)"') { return $matches[1] }
    if ($Line -match '(?i)\bChunkData\s+([^\s]+)') { return $matches[1] }
    return ''
}

function Convert-LinearGainToDecibels {
    <# Converts a positive linear VST gain value to decibels. #>
    param([double]$Gain)

    if ($Gain -le 0) { return [double]::NegativeInfinity }
    return (20.0 * [Math]::Log10($Gain))
}

function Format-EqualizerApoNumber {
    <# Formats a numeric value compactly for APO preview text. #>
    param(
        [double]$Value,
        [int]$Decimals = 2
    )

    if ([double]::IsNaN($Value)) { return 'n/a' }
    if ([double]::IsInfinity($Value)) { return '-inf' }
    return $Value.ToString(("0." + ('#' * $Decimals)), [Globalization.CultureInfo]::InvariantCulture)
}

function Format-EqualizerApoGain {
    <# Formats a gain value with sign and dB suffix. #>
    param([double]$GainDb)

    if ([double]::IsInfinity($GainDb)) { return '-inf dB' }
    $prefix = if ($GainDb -gt 0) { '+' } else { '' }
    return ('{0}{1} dB' -f $prefix, (Format-EqualizerApoNumber -Value $GainDb -Decimals 2))
}

function Resolve-EqualizerApoReaEqBandType {
    <# Provides a readable ReaEQ band type label from the decoded band position and values. #>
    param(
        [int]$Index,
        [int]$BandCount,
        [double]$Frequency,
        [double]$GainDb,
        [int]$RawType
    )

    if ($Index -eq 0 -and $Frequency -lt 150 -and [Math]::Abs($GainDb) -lt 0.1) {
        return 'High Pass'
    }
    if ($Index -eq ($BandCount - 1) -and $Frequency -ge 6000 -and $GainDb -gt 6) {
        return 'High Shelf'
    }
    return 'Band'
}

function Get-EqualizerApoReaEqParameterSummary {
    <# Decodes the common ReaEQ standalone VST ChunkData layout into readable band parameters. #>
    param([string]$Line)

    $chunk = Get-EqualizerApoChunkData -Line $Line
    if ([string]::IsNullOrWhiteSpace($chunk)) { return @() }

    try {
        $bytes = [Convert]::FromBase64String($chunk)
    }
    catch {
        return @('ReaEQ ChunkData: invalid Base64 payload.')
    }

    if ($bytes.Length -lt 16) { return @('ReaEQ ChunkData: too short to decode.') }

    $bandCount = [BitConverter]::ToInt32($bytes, 4)
    $bandStart = 16
    $bandSize = 33
    if ($bandCount -lt 0 -or $bandCount -gt 64) {
        return @("ReaEQ ChunkData: unsupported band count $bandCount.")
    }
    if ($bytes.Length -lt ($bandStart + ($bandCount * $bandSize))) {
        return @("ReaEQ ChunkData: present ({0} chars), layout not recognized." -f $chunk.Length)
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $activeCount = 0
    $bandLines = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $bandCount; $i++) {
        $offset = $bandStart + ($i * $bandSize)
        $frequency = [BitConverter]::ToDouble($bytes, $offset)
        $linearGain = [BitConverter]::ToDouble($bytes, $offset + 8)
        $bandwidth = [BitConverter]::ToDouble($bytes, $offset + 16)
        $enabled = ([int]$bytes[$offset + 24] -ne 0)
        $filterType = [BitConverter]::ToInt32($bytes, $offset + 25)

        if ($enabled) { $activeCount++ }
        $state = if ($enabled) { 'on' } else { 'off' }
        $gainDb = Convert-LinearGainToDecibels -Gain $linearGain
        $filterName = Resolve-EqualizerApoReaEqBandType -Index $i -BandCount $bandCount -Frequency $frequency -GainDb $gainDb -RawType $filterType
        $bandLines.Add((
            'Band {0}: {1}, {2} Hz, {3}, BW {4}, {5}' -f `
            ($i + 1),
            $filterName,
            (Format-EqualizerApoNumber -Value $frequency -Decimals 2),
            (Format-EqualizerApoGain -GainDb $gainDb),
            (Format-EqualizerApoNumber -Value $bandwidth -Decimals 2),
            $state
        ))
    }

    $lines.Add(("ReaEQ active bands: {0}/{1}" -f $activeCount, $bandCount))
    foreach ($bandLine in $bandLines) { $lines.Add($bandLine) }

    $outputOffset = $bandStart + ($bandCount * $bandSize)
    if (($outputOffset + 8) -le $bytes.Length) {
        $outputGain = [BitConverter]::ToDouble($bytes, $outputOffset)
        if ($outputGain -gt 0 -and $outputGain -lt 100) {
            $lines.Add(("Output gain: {0}" -f (Format-EqualizerApoGain -GainDb (Convert-LinearGainToDecibels -Gain $outputGain))))
        }
    }

    return $lines.ToArray()
}

function Get-EqualizerApoVstParameterSummary {
    <# Builds readable parameter lines for one VSTPlugin command without dumping huge ChunkData blobs. #>
    param([string]$Line)

    $result = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Line)) { return @() }

    $pluginName = Get-EqualizerApoPluginName -Line $Line
    if ($pluginName -match '(?i)^reaeq') {
        $reaEqLines = @(Get-EqualizerApoReaEqParameterSummary -Line $Line)
        if ($reaEqLines.Count -gt 0) { return $reaEqLines }
    }

    $effective = $Line.Trim()
    if ($effective -match '(?i)^VSTPlugin\s*:\s*(.*)$') {
        $effective = $matches[1].Trim()
    }

    $tokens = @(Split-EqualizerApoCommandTokens -Line $effective)
    $i = 0
    while ($i -lt $tokens.Count) {
        $name = ConvertTo-PlainString $tokens[$i]
        if ([string]::IsNullOrWhiteSpace($name)) {
            $i++
            continue
        }

        if ($name -ieq 'Library') {
            $i += 2
            continue
        }

        if ($name -ieq 'ChunkData') {
            $chunk = ''
            if (($i + 1) -lt $tokens.Count) { $chunk = ConvertTo-PlainString $tokens[$i + 1] }
            if (-not [string]::IsNullOrWhiteSpace($chunk)) {
                $result.Add(("ChunkData: present ({0} chars)" -f $chunk.Length))
            }
            else {
                $result.Add('ChunkData: present')
            }
            $i += 2
            continue
        }

        $value = ''
        if (($i + 1) -lt $tokens.Count) {
            $value = ConvertTo-PlainString $tokens[$i + 1]
            $i += 2
        }
        else {
            $i++
        }

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $result.Add(("{0}: {1}" -f $name, $value))
        }
        else {
            $result.Add($name)
        }
    }

    if ($result.Count -eq 0) {
        $result.Add('No readable parameters found.')
    }
    return $result.ToArray()
}

function Get-EqualizerApoPresetFilePath {
    <# Returns the MicMaster Equalizer APO preset store path. #>
    param([Parameter(Mandatory=$true)][string]$ProjectRoot)
    return (Join-Path $ProjectRoot 'config\apo-presets.json')
}

function Get-EqualizerApoVstEntries {
    <# Reads VSTPlugin lines from the main Equalizer APO config.txt, preserving enabled/commented state. #>
    param([scriptblock]$Logger)

    $configPath = Get-EqualizerApoConfigPath
    $entries = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($configPath) -or -not (Test-Path -LiteralPath $configPath)) { return @() }

    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $configPath -Encoding UTF8) {
        $lineNumber++
        $trimmed = $line.Trim()
        $enabled = -not $trimmed.StartsWith('#')
        $effective = if ($enabled) { $trimmed } else { $trimmed.TrimStart('#').Trim() }
        if ($effective -match '(?i)^VSTPlugin\s*:') {
            $entries.Add([pscustomobject]@{
                LineNumber = $lineNumber
                Name = Get-EqualizerApoPluginName -Line $effective
                Enabled = $enabled
                RawLine = $line
                EffectiveLine = $effective
            })
        }
    }
    return $entries.ToArray()
}

function Read-EqualizerApoPresets {
    <# Loads saved Equalizer APO VST presets from MicMaster config. #>
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [scriptblock]$Logger
    )

    $path = Get-EqualizerApoPresetFilePath -ProjectRoot $ProjectRoot
    try {
        if (-not (Test-Path -LiteralPath $path)) {
            '{"Presets":[]}' | Set-Content -LiteralPath $path -Encoding UTF8
        }
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { $raw = '{"Presets":[]}' }
        $json = $raw | ConvertFrom-Json
        return @($json.Presets)
    }
    catch {
        Write-AppLog -Message ("Loading APO presets failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $Logger
        return @()
    }
}

function Save-EqualizerApoPresets {
    <# Saves Equalizer APO VST presets to MicMaster config. #>
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Presets,
        [scriptblock]$Logger
    )

    $path = Get-EqualizerApoPresetFilePath -ProjectRoot $ProjectRoot
    try {
        $root = [ordered]@{ Presets = @($Presets) }
        ($root | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $path -Encoding UTF8
        return $true
    }
    catch {
        Write-AppLog -Message ("Saving APO presets failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $Logger
        return $false
    }
}

function New-EqualizerApoPreset {
    <# Creates a preset object from current VSTPlugin config lines. #>
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [scriptblock]$Logger
    )

    $entries = @(Get-EqualizerApoVstEntries -Logger $Logger)
    $plugins = @($entries | ForEach-Object {
        [ordered]@{
            Name = $_.Name
            Enabled = [bool]$_.Enabled
            Line = $_.EffectiveLine
        }
    })

    [pscustomobject]([ordered]@{
        Name = $Name
        CreatedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        ConfigPath = Get-EqualizerApoConfigPath
        Plugins = $plugins
    })
}

function Backup-EqualizerApoConfig {
    <# Creates a timestamped backup of Equalizer APO config.txt before modifying it. #>
    param([scriptblock]$Logger)

    $configPath = Get-EqualizerApoConfigPath
    if ([string]::IsNullOrWhiteSpace($configPath) -or -not (Test-Path -LiteralPath $configPath)) {
        throw 'Equalizer APO config.txt was not found.'
    }
    $backupPath = ('{0}.MicMaster.{1}.bak' -f $configPath, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
    Write-AppLog -Message ("Created APO config backup: {0}" -f $backupPath) -Level INFO -Logger $Logger
    return $backupPath
}

function Set-EqualizerApoVstPluginStates {
    <# Comments or uncomments VSTPlugin lines in config.txt according to plugin name states. #>
    param(
        [Parameter(Mandatory=$true)][hashtable]$StatesByName,
        [scriptblock]$Logger
    )

    $configPath = Get-EqualizerApoConfigPath
    if ([string]::IsNullOrWhiteSpace($configPath) -or -not (Test-Path -LiteralPath $configPath)) {
        throw 'Equalizer APO config.txt was not found.'
    }

    [void](Backup-EqualizerApoConfig -Logger $Logger)
    $lines = @(Get-Content -LiteralPath $configPath -Encoding UTF8)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $trimmed = $lines[$i].Trim()
        $effective = if ($trimmed.StartsWith('#')) { $trimmed.TrimStart('#').Trim() } else { $trimmed }
        if ($effective -notmatch '(?i)^VSTPlugin\s*:') { continue }

        $name = Get-EqualizerApoPluginName -Line $effective
        if (-not $StatesByName.ContainsKey($name)) { continue }

        if ([bool]$StatesByName[$name]) {
            $lines[$i] = $effective
        }
        else {
            $lines[$i] = '# ' + $effective
        }
    }
    $lines | Set-Content -LiteralPath $configPath -Encoding UTF8
    Write-AppLog -Message 'Applied APO VST enabled/disabled states.' -Level INFO -Logger $Logger
}

function Apply-EqualizerApoPreset {
    <# Replaces current VSTPlugin lines in config.txt with the saved preset lines. #>
    param(
        [Parameter(Mandatory=$true)][object]$Preset,
        [scriptblock]$Logger
    )

    $configPath = Get-EqualizerApoConfigPath
    if ([string]::IsNullOrWhiteSpace($configPath) -or -not (Test-Path -LiteralPath $configPath)) {
        throw 'Equalizer APO config.txt was not found.'
    }

    [void](Backup-EqualizerApoConfig -Logger $Logger)
    $lines = @(Get-Content -LiteralPath $configPath -Encoding UTF8)
    $newLines = New-Object System.Collections.Generic.List[string]
    $inserted = $false
    $insertIndexSeen = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $trimmed = $lines[$i].Trim()
        $effective = if ($trimmed.StartsWith('#')) { $trimmed.TrimStart('#').Trim() } else { $trimmed }
        if ($effective -match '(?i)^VSTPlugin\s*:') {
            if (-not $insertIndexSeen) {
                foreach ($plugin in @($Preset.Plugins)) {
                    $line = ConvertTo-PlainString $plugin.Line
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    if ([bool]$plugin.Enabled) { $newLines.Add($line) }
                    else { $newLines.Add('# ' + $line) }
                }
                $inserted = $true
                $insertIndexSeen = $true
            }
            continue
        }
        $newLines.Add($lines[$i])
    }

    if (-not $inserted) {
        foreach ($plugin in @($Preset.Plugins)) {
            $line = ConvertTo-PlainString $plugin.Line
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ([bool]$plugin.Enabled) { $newLines.Add($line) }
            else { $newLines.Add('# ' + $line) }
        }
    }

    $newLines.ToArray() | Set-Content -LiteralPath $configPath -Encoding UTF8
    Write-AppLog -Message ("Applied APO preset: {0}" -f $Preset.Name) -Level INFO -Logger $Logger
}

function Get-EqualizerApoCommandSummary {
    <# Converts one active Equalizer APO command line to a compact display token. #>
    param([string]$Line)

    if ($Line -match '(?i)^VSTPlugin\s*:') { return ('VST:{0}' -f (Get-EqualizerApoPluginName -Line $Line)) }
    if ($Line -match '(?i)^Preamp\s*:\s*(.+)$') { return ('Preamp:{0}' -f $matches[1].Trim()) }
    if ($Line -match '(?i)^Filter\s*:') { return 'Filter' }
    if ($Line -match '(?i)^GraphicEQ\s*:') { return 'GraphicEQ' }
    if ($Line -match '(?i)^Convolution\s*:') { return 'Convolution' }
    if ($Line -match '(?i)^Copy\s*:') { return 'Copy' }
    if ($Line -match '(?i)^Channel\s*:') { return 'Channel' }
    if ($Line -match '(?i)^Delay\s*:') { return 'Delay' }
    if ($Line -match '(?i)^Include\s*:\s*(.+)$') { return ('Include:{0}' -f ([System.IO.Path]::GetFileName($matches[1].Trim().Trim('"')))) }
    if ($Line -match '^([^:]+):') { return $matches[1].Trim() }
    return ''
}

function Get-EqualizerApoConfigInfo {
    <# Parses Equalizer APO config files into global and device-scoped processing entries. #>
    param([scriptblock]$Logger)

    $configPath = Get-EqualizerApoConfigPath
    if ([string]::IsNullOrWhiteSpace($configPath)) {
        Write-AppLog -Message 'Equalizer APO config.txt was not found.' -Level WARN -Logger $Logger
        return [pscustomobject]@{
            Installed = $false
            ConfigPath = ''
            InstalledEndpointGuids = @()
            HasDeviceSelectors = $false
            GlobalCommands = @()
            DeviceBlocks = @()
            CommentedCommands = @()
        }
    }

    $globalCommands = New-Object System.Collections.Generic.List[object]
    $commentedCommands = New-Object System.Collections.Generic.List[object]
    $deviceBlocks = New-Object System.Collections.Generic.List[object]
    $currentDevice = ''
    $currentCommands = New-Object System.Collections.Generic.List[object]

    foreach ($row in Read-EqualizerApoConfigLines -Path $configPath) {
        $line = $row.EffectiveText
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line -match '(?i)^Device\s*:\s*(.+)$') {
            if (-not [string]::IsNullOrWhiteSpace($currentDevice)) {
                $deviceBlocks.Add([pscustomobject]@{ DeviceSelector = $currentDevice; Commands = $currentCommands.ToArray() })
            }
            $currentDevice = $matches[1].Trim()
            $currentCommands = New-Object System.Collections.Generic.List[object]
            continue
        }

        $summary = Get-EqualizerApoCommandSummary -Line $line
        if ([string]::IsNullOrWhiteSpace($summary)) { continue }

        $command = [pscustomobject]@{
            Summary = $summary
            Line = $line
            File = $row.File
            LineNumber = $row.LineNumber
            IsComment = [bool]$row.IsComment
        }

        if ($row.IsComment) {
            $commentedCommands.Add($command)
        }
        elseif (-not [string]::IsNullOrWhiteSpace($currentDevice)) {
            $currentCommands.Add($command)
        }
        else {
            $globalCommands.Add($command)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($currentDevice)) {
        $deviceBlocks.Add([pscustomobject]@{ DeviceSelector = $currentDevice; Commands = $currentCommands.ToArray() })
    }

    $installedEndpointGuids = @(Get-EqualizerApoInstalledEndpointGuids -Logger $Logger)
    Write-AppLog -Message ("Equalizer APO scan: {0} global command(s), {1} device block(s), {2} APO endpoint(s)." -f $globalCommands.Count, $deviceBlocks.Count, $installedEndpointGuids.Count) -Level INFO -Logger $Logger

    return [pscustomobject]@{
        Installed = $true
        ConfigPath = $configPath
        InstalledEndpointGuids = $installedEndpointGuids
        HasDeviceSelectors = ($deviceBlocks.Count -gt 0)
        GlobalCommands = $globalCommands.ToArray()
        DeviceBlocks = $deviceBlocks.ToArray()
        CommentedCommands = $commentedCommands.ToArray()
    }
}

function Test-EqualizerApoSelectorMatchesDevice {
    <# Checks whether a Device selector appears to target a discovered microphone record. #>
    param(
        [Parameter(Mandatory=$true)][string]$Selector,
        [Parameter(Mandatory=$true)][object]$Device
    )

    $haystack = @(
        ConvertTo-PlainString $Device.InstanceId
        ConvertTo-PlainString $Device.EndpointGuid
        ConvertTo-PlainString $Device.EndpointId
        ConvertTo-PlainString $Device.FriendlyName
        ConvertTo-PlainString $Device.Alias1
        ConvertTo-PlainString $Device.Alias2
        ConvertTo-PlainString $Device.Alias3
        ConvertTo-PlainString $Device.Alias4
        ConvertTo-PlainString $Device.VID
        ConvertTo-PlainString $Device.PID
    ) -join ' '

    $selectorText = $Selector.Trim()
    if ([string]::IsNullOrWhiteSpace($selectorText)) { return $false }
    if ($haystack.ToLowerInvariant().Contains($selectorText.ToLowerInvariant())) { return $true }

    $guid = ConvertTo-PlainString $Device.EndpointGuid
    if (-not [string]::IsNullOrWhiteSpace($guid)) {
        $plainGuid = $guid.Trim('{','}')
        if ($selectorText.ToLowerInvariant().Contains($plainGuid.ToLowerInvariant())) { return $true }
    }
    return $false
}

function Get-EqualizerApoSummaryForDevice {
    <# Builds a display summary of Equalizer APO processing for one device. #>
    param(
        [Parameter(Mandatory=$true)][object]$Device,
        [Parameter(Mandatory=$true)][object]$ApoInfo
    )

    if (-not $ApoInfo.Installed) {
        return [pscustomobject]@{ Apo = 'Not found'; Processing = '' }
    }

    $commands = @()
    $scope = ''
    $endpointGuid = (ConvertTo-PlainString $Device.EndpointGuid).ToUpperInvariant()
    $isApoInstalledOnEndpoint = @($ApoInfo.InstalledEndpointGuids) -contains $endpointGuid

    foreach ($block in $ApoInfo.DeviceBlocks) {
        if (Test-EqualizerApoSelectorMatchesDevice -Selector $block.DeviceSelector -Device $Device) {
            $commands += @($block.Commands)
            $scope = 'Device'
        }
    }

    if ($commands.Count -eq 0 -and -not $ApoInfo.HasDeviceSelectors -and $isApoInstalledOnEndpoint) {
        $commands = @($ApoInfo.GlobalCommands)
        $scope = 'Endpoint'
    }

    if ($commands.Count -eq 0) {
        if ($isApoInstalledOnEndpoint) {
            return [pscustomobject]@{ Apo = 'APO installed'; Processing = '' }
        }
        return [pscustomobject]@{ Apo = ''; Processing = '' }
    }

    $tokens = @($commands | ForEach-Object { $_.Summary } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $vstCount = @($tokens | Where-Object { $_ -like 'VST:*' }).Count
    $prefix = if ($scope -eq 'Endpoint') { 'APO endpoint' } else { 'Device config' }
    $apoText = if ($vstCount -gt 0) { "$prefix, $vstCount VST" } else { $prefix }
    return [pscustomobject]@{
        Apo = $apoText
        Processing = (($tokens | Select-Object -First 8) -join ' -> ')
    }
}

function Apply-EqualizerApoInfoToDevices {
    <# Applies Equalizer APO display fields to discovered microphone records. #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Devices,
        [Parameter(Mandatory=$true)][object]$ApoInfo
    )

    foreach ($device in $Devices) {
        $summary = Get-EqualizerApoSummaryForDevice -Device $device -ApoInfo $ApoInfo
        $device.Apo = $summary.Apo
        $device.Processing = $summary.Processing
    }
    return $Devices
}

