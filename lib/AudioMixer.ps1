<#
Multi-device AudioGraph mixer routed to a VB-Audio Virtual Cable render endpoint.
#>

Set-StrictMode -Version 2.0

$script:AudioMixerWindow = $null
$script:AudioMixerInputsChangedHandler = $null

function Set-AudioMixerInputsRefreshPending {
    <# Marks the open live mixer as needing an input reconciliation after the main inventory changes. #>
    if ($script:AudioMixerInputsChangedHandler) {
        & $script:AudioMixerInputsChangedHandler
    }
}

function Get-AudioMixerDeviceSignature {
    <# Builds a stable signature for active devices currently assigned to the mixer. #>
    param([AllowEmptyCollection()][object[]]$Devices)

    $parts = @()
    foreach ($device in @($Devices)) {
        if (-not [bool](Get-ObjectPropertyValue -Object $device -Name 'IsMicrophone' -Default $false)) { continue }
        if (-not (Test-DeviceRecordIsActive -Device $device)) { continue }
        $endpointGuid = Normalize-DeviceId (ConvertTo-PlainString $device.EndpointGuid)
        if ([string]::IsNullOrWhiteSpace($endpointGuid)) { continue }
        $parts += '{0}|{1}|{2}' -f (
            Normalize-DeviceId (ConvertTo-PlainString $device.InstanceId)
        ), $endpointGuid, (ConvertTo-PlainString $device.Status)
    }
    return (($parts | Sort-Object) -join ';')
}

function Initialize-AudioGraphRuntime {
    <# Loads Windows Runtime assemblies and audio types required by AudioGraph. #>
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
    $null = [Windows.Devices.Enumeration.DeviceInformation,Windows.Devices.Enumeration,ContentType=WindowsRuntime]
    $null = [Windows.Media.Devices.MediaDevice,Windows.Media.Devices,ContentType=WindowsRuntime]
    $null = [Windows.Media.Audio.AudioGraph,Windows.Media.Audio,ContentType=WindowsRuntime]
    $null = [Windows.Media.Audio.AudioGraphSettings,Windows.Media.Audio,ContentType=WindowsRuntime]
    $null = [Windows.Media.Render.AudioRenderCategory,Windows.Media,ContentType=WindowsRuntime]
    $null = [Windows.Media.Capture.MediaCategory,Windows.Media,ContentType=WindowsRuntime]
    $null = [Windows.Media.MediaProperties.AudioEncodingProperties,Windows.Media.MediaProperties,ContentType=WindowsRuntime]
}

function Get-WinRtAsyncResult {
    <# Waits for a WinRT IAsyncOperation and returns its strongly typed result. #>
    param(
        [Parameter(Mandatory=$true)][object]$Operation,
        [Parameter(Mandatory=$true)][Type]$ResultType
    )

    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object {
            $_.Name -eq 'AsTask' -and
            $_.IsGenericMethod -and
            $_.GetParameters().Count -eq 1
        } |
        Select-Object -First 1
    if ($null -eq $method) { throw 'System.WindowsRuntimeSystemExtensions.AsTask was not found.' }

    $task = $method.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $task.Wait()
    return $task.Result
}

function Close-WinRtAudioObject {
    <# Disposes a projected WinRT audio object when it implements IClosable/IDisposable. #>
    param([object]$Object)

    if ($null -eq $Object) { return }
    if ($Object -is [System.IDisposable]) {
        ([System.IDisposable]$Object).Dispose()
    }
}

function Get-AudioGraphDeviceInformation {
    <# Enumerates render or capture DeviceInformation objects through the Windows audio selector. #>
    param([Parameter(Mandatory=$true)][ValidateSet('Render','Capture')][string]$Flow)

    Initialize-AudioGraphRuntime
    $selector = if ($Flow -eq 'Render') {
        [Windows.Media.Devices.MediaDevice]::GetAudioRenderSelector()
    }
    else {
        [Windows.Media.Devices.MediaDevice]::GetAudioCaptureSelector()
    }

    $operation = [Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($selector)
    $resultType = [Windows.Devices.Enumeration.DeviceInformationCollection,Windows.Devices.Enumeration,ContentType=WindowsRuntime]
    return @(Get-WinRtAsyncResult -Operation $operation -ResultType $resultType)
}

function Get-AudioGraphEndpointGuid {
    <# Extracts the MMDevice endpoint GUID from a WinRT DeviceInformation identifier. #>
    param([string]$DeviceInformationId)

    if ([string]::IsNullOrWhiteSpace($DeviceInformationId)) { return '' }
    $match = [regex]::Match(
        $DeviceInformationId,
        '\{0\.0\.[01]\.00000000\}\.\{([0-9A-Fa-f-]{36})\}',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($match.Success) {
        return ('{' + $match.Groups[1].Value + '}').ToUpperInvariant()
    }
    return ''
}

function Get-VbCableRenderEndpoints {
    <# Returns installed VB-CABLE playback endpoints that can receive the mixed signal. #>
    param([scriptblock]$Logger)

    $result = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($device in @(Get-AudioGraphDeviceInformation -Flow Render)) {
            $name = ConvertTo-PlainString $device.Name
            if ($name -notmatch '^CABLE Input\b|^CABLE In \d+ch\b') { continue }
            $result.Add([pscustomobject]@{
                Name = $name
                Id = ConvertTo-PlainString $device.Id
                EndpointGuid = Get-AudioGraphEndpointGuid -DeviceInformationId $device.Id
                DeviceInformation = $device
            })
        }
    }
    catch {
        Write-AppLog -Message ("VB-CABLE endpoint enumeration failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $Logger
    }
    return $result.ToArray()
}

function Get-AudioMixerConfigPath {
    <# Returns the JSON path used for persistent channel and master mixer settings. #>
    param([Parameter(Mandatory=$true)][string]$ProjectRoot)
    return (Join-Path $ProjectRoot 'config\mixer.json')
}

function Read-AudioMixerConfig {
    <# Loads saved mixer gain, enable, mute, solo, and master settings. #>
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [scriptblock]$Logger
    )

    $config = @{
        MasterDb = 0.0
        LatencyMode = 'LowestLatency'
        Channels = @{}
    }
    $path = Get-AudioMixerConfigPath -ProjectRoot $ProjectRoot
    try {
        if (-not (Test-Path -LiteralPath $path)) { return $config }
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $config }
        $json = $raw | ConvertFrom-Json
        $config.MasterDb = [double](Get-ObjectPropertyValue -Object $json -Name 'MasterDb' -Default 0)
        $latencyMode = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $json -Name 'LatencyMode' -Default 'LowestLatency')
        if ($latencyMode -notin @('SystemDefault', 'LowestLatency')) {
            $latencyMode = 'LowestLatency'
        }
        $config.LatencyMode = $latencyMode
        $channels = Get-ObjectPropertyValue -Object $json -Name 'Channels' -Default $null
        if ($channels) {
            foreach ($property in $channels.PSObject.Properties) {
                $key = Normalize-DeviceId $property.Name
                $config.Channels[$key] = @{
                    Enabled = ConvertTo-StorageBoolean -Value (Get-ObjectPropertyValue -Object $property.Value -Name 'Enabled' -Default $true) -Default $true
                    GainDb = [double](Get-ObjectPropertyValue -Object $property.Value -Name 'GainDb' -Default 0)
                    Mute = ConvertTo-StorageBoolean -Value (Get-ObjectPropertyValue -Object $property.Value -Name 'Mute' -Default $false) -Default $false
                    Priority = ConvertTo-StorageBoolean -Value (Get-ObjectPropertyValue -Object $property.Value -Name 'Priority' -Default $false) -Default $false
                    Solo = ConvertTo-StorageBoolean -Value (Get-ObjectPropertyValue -Object $property.Value -Name 'Solo' -Default $false) -Default $false
                }
            }
        }
    }
    catch {
        Write-AppLog -Message ("Loading mixer configuration failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $Logger
    }
    return $config
}

function Save-AudioMixerConfig {
    <# Persists the current master and per-device mixer settings. #>
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Channels,
        [double]$MasterDb,
        [ValidateSet('SystemDefault','LowestLatency')][string]$LatencyMode = 'LowestLatency',
        [scriptblock]$Logger
    )

    $path = Get-AudioMixerConfigPath -ProjectRoot $ProjectRoot
    $channelRoot = [ordered]@{}
    $existingConfig = Read-AudioMixerConfig -ProjectRoot $ProjectRoot -Logger $Logger
    foreach ($key in @($existingConfig.Channels.Keys)) {
        $saved = $existingConfig.Channels[$key]
        $channelRoot[$key] = [ordered]@{
            Enabled = [bool]$saved.Enabled
            GainDb = [double]$saved.GainDb
            Mute = [bool]$saved.Mute
            Priority = [bool]$saved.Priority
            Solo = [bool]$saved.Solo
        }
    }
    foreach ($channel in $Channels) {
        $key = Normalize-DeviceId (ConvertTo-PlainString $channel.Device.InstanceId)
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        $channelRoot[$key] = [ordered]@{
            Enabled = [bool]$channel.Enabled
            GainDb = [double]$channel.GainDb
            Mute = [bool]$channel.Mute
            Priority = [bool]$channel.Priority
            Solo = [bool]$channel.Solo
        }
    }
    $root = [ordered]@{
        MasterDb = [double]$MasterDb
        LatencyMode = $LatencyMode
        Channels = $channelRoot
    }

    try {
        ($root | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding UTF8
        return $true
    }
    catch {
        Write-AppLog -Message ("Saving mixer configuration failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $Logger
        return $false
    }
}

function Convert-DecibelsToLinearGain {
    <# Converts a decibel fader value into the linear multiplier required by AudioGraph. #>
    param([double]$Decibels)

    if ($Decibels -le -60) { return 0.0 }
    return [Math]::Pow(10.0, $Decibels / 20.0)
}

function Stop-AudioGraphMixer {
    <# Stops and releases an active AudioGraph mixer runtime without terminating the application. #>
    param(
        [object]$Runtime,
        [scriptblock]$Logger
    )

    if ($null -eq $Runtime) { return }
    try {
        if ($Runtime.Graph) { $Runtime.Graph.Stop() }
    }
    catch {
        Write-AppLog -Message ("Stopping mixer graph failed: {0}" -f $_.Exception.Message) -Level WARN -Logger $Logger
    }
    foreach ($channel in @($Runtime.Channels)) {
        try { Close-WinRtAudioObject -Object $channel.Node } catch { }
    }
    try { Close-WinRtAudioObject -Object $Runtime.MixNode } catch { }
    try { Close-WinRtAudioObject -Object $Runtime.OutputNode } catch { }
    try { Close-WinRtAudioObject -Object $Runtime.Graph } catch { }
}

function Update-AudioGraphMixerGains {
    <# Applies channel enable, mute, solo, fader, and master values to a running AudioGraph. #>
    param(
        [Parameter(Mandatory=$true)][object]$Runtime,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$ChannelStates,
        [double]$MasterDb
    )

    $hasSolo = @($ChannelStates | Where-Object { $_.Enabled -and $_.Solo }).Count -gt 0
    $hasPriority = @($ChannelStates | Where-Object {
        $_.Enabled -and
        $_.Priority -and
        -not $_.Mute -and
        (-not $hasSolo -or $_.Solo)
    }).Count -gt 0
    foreach ($runtimeChannel in @($Runtime.Channels)) {
        $state = $ChannelStates | Where-Object {
            (Normalize-DeviceId $_.Device.InstanceId) -eq $runtimeChannel.Key
        } | Select-Object -First 1
        if ($null -eq $state) {
            $runtimeChannel.Node.OutgoingGain = 0.0
            continue
        }

        $audible = [bool]$state.Enabled -and -not [bool]$state.Mute
        if ($hasSolo -and -not [bool]$state.Solo) { $audible = $false }
        $runtimeChannel.Node.OutgoingGain = if ($audible) {
            $effectiveGainDb = [double]$state.GainDb
            if ($hasPriority -and -not [bool]$state.Priority) {
                $effectiveGainDb -= 20.0
            }
            Convert-DecibelsToLinearGain -Decibels $effectiveGainDb
        }
        else {
            0.0
        }
    }
    $Runtime.MixNode.OutgoingGain = Convert-DecibelsToLinearGain -Decibels $MasterDb
}

function Get-AudioGraphCaptureDeviceMap {
    <# Maps capture endpoint GUIDs to WinRT DeviceInformation records. #>
    $captureByGuid = @{}
    foreach ($captureDevice in @(Get-AudioGraphDeviceInformation -Flow Capture)) {
        $guid = Normalize-DeviceId (Get-AudioGraphEndpointGuid -DeviceInformationId $captureDevice.Id)
        if (-not [string]::IsNullOrWhiteSpace($guid)) {
            $captureByGuid[$guid] = $captureDevice
        }
    }
    return $captureByGuid
}

function Add-AudioGraphMixerInput {
    <# Adds one microphone input node to an existing AudioGraph, including a graph that is already running. #>
    param(
        [Parameter(Mandatory=$true)][object]$Runtime,
        [Parameter(Mandatory=$true)][object]$Device,
        [Parameter(Mandatory=$true)][hashtable]$CaptureByGuid,
        [scriptblock]$Logger
    )

    $key = Normalize-DeviceId (ConvertTo-PlainString $Device.InstanceId)
    if (@($Runtime.Channels | Where-Object { $_.Key -eq $key }).Count -gt 0) { return $true }

    $endpointGuid = Normalize-DeviceId (ConvertTo-PlainString $Device.EndpointGuid)
    if ([string]::IsNullOrWhiteSpace($endpointGuid) -or -not $CaptureByGuid.ContainsKey($endpointGuid)) {
        Write-AppLog -Message ("Mixer skipped endpoint not available to AudioGraph: {0}" -f $Device.FriendlyName) -Level WARN -Logger $Logger
        return $false
    }

    $inputResultType = [Windows.Media.Audio.CreateAudioDeviceInputNodeResult,Windows.Media.Audio,ContentType=WindowsRuntime]
    $encoding = $null
    $operation = $Runtime.Graph.CreateDeviceInputNodeAsync(
        [Windows.Media.Capture.MediaCategory]::Other,
        $encoding,
        $CaptureByGuid[$endpointGuid]
    )
    $inputResult = Get-WinRtAsyncResult -Operation $operation -ResultType $inputResultType
    if ($inputResult.Status.ToString() -ne 'Success' -or $null -eq $inputResult.DeviceInputNode) {
        Write-AppLog -Message ("Mixer input failed for {0}: {1}" -f $Device.FriendlyName, $inputResult.Status) -Level ERROR -Logger $Logger
        return $false
    }

    $inputResult.DeviceInputNode.OutgoingGain = 0.0
    $inputResult.DeviceInputNode.AddOutgoingConnection($Runtime.MixNode)
    $Runtime.Channels += [pscustomobject]@{
        Key = $key
        Device = $Device
        Node = $inputResult.DeviceInputNode
    }
    Write-AppLog -Message ("Mixer input joined live: {0}." -f $Device.FriendlyName) -Level DEVICE -Logger $Logger
    return $true
}

function Remove-AudioGraphMixerInput {
    <# Disconnects and releases one microphone input node without stopping the AudioGraph. #>
    param(
        [Parameter(Mandatory=$true)][object]$Runtime,
        [Parameter(Mandatory=$true)][string]$Key,
        [scriptblock]$Logger
    )

    $normalizedKey = Normalize-DeviceId $Key
    $runtimeChannel = $Runtime.Channels | Where-Object { $_.Key -eq $normalizedKey } | Select-Object -First 1
    if ($null -eq $runtimeChannel) { return }

    try {
        $runtimeChannel.Node.OutgoingGain = 0.0
        $runtimeChannel.Node.RemoveOutgoingConnection($Runtime.MixNode)
    }
    catch {
        Write-AppLog -Message ("Disconnecting mixer input failed: {0}" -f $_.Exception.Message) -Level WARN -Logger $Logger
    }
    try { Close-WinRtAudioObject -Object $runtimeChannel.Node } catch { }
    $Runtime.Channels = @($Runtime.Channels | Where-Object { $_.Key -ne $normalizedKey })
    Write-AppLog -Message ("Mixer input left live: {0}." -f $runtimeChannel.Device.FriendlyName) -Level DEVICE -Logger $Logger
}

function Start-AudioGraphMixer {
    <# Creates and starts a multi-input AudioGraph routed to the chosen VB-CABLE playback endpoint. #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Devices,
        [Parameter(Mandatory=$true)][object]$OutputEndpoint,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$ChannelStates,
        [double]$MasterDb,
        [ValidateSet('SystemDefault','LowestLatency')][string]$LatencyMode = 'LowestLatency',
        [scriptblock]$Logger
    )

    Initialize-AudioGraphRuntime
    $runtime = $null
    try {
        $settings = New-Object Windows.Media.Audio.AudioGraphSettings ([Windows.Media.Render.AudioRenderCategory]::Media)
        $settings.PrimaryRenderDevice = $OutputEndpoint.DeviceInformation
        $settings.QuantumSizeSelectionMode = if ($LatencyMode -eq 'SystemDefault') {
            [Windows.Media.Audio.QuantumSizeSelectionMode]::SystemDefault
        }
        else {
            [Windows.Media.Audio.QuantumSizeSelectionMode]::LowestLatency
        }

        $graphResultType = [Windows.Media.Audio.CreateAudioGraphResult,Windows.Media.Audio,ContentType=WindowsRuntime]
        $graphResult = Get-WinRtAsyncResult -Operation ([Windows.Media.Audio.AudioGraph]::CreateAsync($settings)) -ResultType $graphResultType
        if ($graphResult.Status.ToString() -ne 'Success' -or $null -eq $graphResult.Graph) {
            throw "AudioGraph creation failed: $($graphResult.Status)"
        }

        $runtime = [pscustomobject]@{
            Graph = $graphResult.Graph
            OutputNode = $null
            MixNode = $null
            Channels = @()
            Output = $OutputEndpoint
        }

        $outputResultType = [Windows.Media.Audio.CreateAudioDeviceOutputNodeResult,Windows.Media.Audio,ContentType=WindowsRuntime]
        $outputResult = Get-WinRtAsyncResult -Operation $runtime.Graph.CreateDeviceOutputNodeAsync() -ResultType $outputResultType
        if ($outputResult.Status.ToString() -ne 'Success' -or $null -eq $outputResult.DeviceOutputNode) {
            throw "CABLE Input output node creation failed: $($outputResult.Status)"
        }
        $runtime.OutputNode = $outputResult.DeviceOutputNode
        $runtime.MixNode = $runtime.Graph.CreateSubmixNode()
        $runtime.MixNode.AddOutgoingConnection($runtime.OutputNode)

        $captureByGuid = Get-AudioGraphCaptureDeviceMap
        foreach ($device in $Devices) {
            [void](Add-AudioGraphMixerInput -Runtime $runtime -Device $device -CaptureByGuid $captureByGuid -Logger $Logger)
        }

        if ($runtime.Channels.Count -eq 0) { throw 'No selected microphone could be opened by AudioGraph.' }
        Update-AudioGraphMixerGains -Runtime $runtime -ChannelStates $ChannelStates -MasterDb $MasterDb
        $runtime.Graph.Start()
        Write-AppLog -Message ("Mixer started: {0} input(s) -> {1}; latency mode: {2}." -f $runtime.Channels.Count, $OutputEndpoint.Name, $LatencyMode) -Level INFO -Logger $Logger
        return $runtime
    }
    catch {
        if ($runtime) { Stop-AudioGraphMixer -Runtime $runtime -Logger $Logger }
        throw
    }
}

function New-AudioMixerChannelStrip {
    <# Builds one channel strip with aliases, mute, priority, solo, meter, and fader controls. #>
    param(
        [Parameter(Mandatory=$true)][object]$Device,
        [hashtable]$SavedSettings,
        [Parameter(Mandatory=$true)][scriptblock]$OnChanged,
        [Parameter(Mandatory=$true)][scriptblock]$OnPriority,
        [Parameter(Mandatory=$true)][scriptblock]$OnSolo
    )

    $gainDb = -12.0
    $mute = $false
    $priority = $false
    $solo = $false
    if ($SavedSettings) {
        $gainDb = [double]$SavedSettings.GainDb
        $mute = [bool]$SavedSettings.Mute
        $priority = [bool]$SavedSettings.Priority
        $solo = [bool]$SavedSettings.Solo
    }
    if ($gainDb -lt -60) { $gainDb = -60 }
    if ($gainDb -gt 12) { $gainDb = 12 }

    $state = [pscustomobject]@{
        Device = $Device
        Enabled = $true
        GainDb = $gainDb
        Mute = $mute
        Priority = $priority
        Solo = $solo
        Panel = $null
        Meter = $null
        GainLabel = $null
        MuteControl = $null
        PriorityControl = $null
        SoloControl = $null
        UpdateSwitchColors = $null
    }

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Size = New-Object System.Drawing.Size(235, 470)
    $panel.Margin = New-Object System.Windows.Forms.Padding(8)
    $panel.Padding = New-Object System.Windows.Forms.Padding(10)
    $panel.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'
    $layout.ColumnCount = 1
    $layout.RowCount = 6
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 34)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 42)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 38)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 26)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 28)))
    $panel.Controls.Add($layout)

    $alias2 = ConvertTo-PlainString $Device.Alias2
    $alias1 = ConvertTo-PlainString $Device.Alias1
    $titleText = if (-not [string]::IsNullOrWhiteSpace($alias1) -and -not [string]::IsNullOrWhiteSpace($alias2)) {
        '{0}: {1}' -f $alias1, $alias2
    } elseif (-not [string]::IsNullOrWhiteSpace($alias1)) {
        $alias1
    } elseif (-not [string]::IsNullOrWhiteSpace($alias2)) {
        $alias2
    } else {
        $Device.FriendlyName
    }

    $title = New-Object System.Windows.Forms.Label
    $title.Text = $titleText
    $title.Dock = 'Fill'
    $title.AutoEllipsis = $true
    $title.ForeColor = [System.Drawing.Color]::White
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $title.TextAlign = 'MiddleCenter'
    $layout.Controls.Add($title, 0, 0)

    $deviceLabel = New-Object System.Windows.Forms.Label
    $deviceLabel.Text = ConvertTo-PlainString $Device.FriendlyName
    $deviceLabel.Dock = 'Fill'
    $deviceLabel.AutoEllipsis = $true
    $deviceLabel.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
    $deviceLabel.TextAlign = 'MiddleCenter'
    $layout.Controls.Add($deviceLabel, 0, 1)

    $switches = New-Object System.Windows.Forms.TableLayoutPanel
    $switches.Dock = 'Fill'
    $switches.Margin = New-Object System.Windows.Forms.Padding(0)
    $switches.Padding = New-Object System.Windows.Forms.Padding(0)
    $switches.ColumnCount = 3
    $switches.RowCount = 1
    [void]$switches.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 33.333)))
    [void]$switches.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 33.334)))
    [void]$switches.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 33.333)))
    [void]$switches.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
    $muteControl = New-Object System.Windows.Forms.Button
    $muteControl.Text = 'MUTE'
    $muteControl.Dock = 'Fill'
    $muteControl.Margin = New-Object System.Windows.Forms.Padding(0, 2, 2, 2)
    $muteControl.FlatStyle = 'Flat'
    $priorityControl = New-Object System.Windows.Forms.Button
    $priorityControl.Text = 'PRIO'
    $priorityControl.Dock = 'Fill'
    $priorityControl.Margin = New-Object System.Windows.Forms.Padding(2, 2, 2, 2)
    $priorityControl.FlatStyle = 'Flat'
    $soloControl = New-Object System.Windows.Forms.Button
    $soloControl.Text = 'SOLO'
    $soloControl.Dock = 'Fill'
    $soloControl.Margin = New-Object System.Windows.Forms.Padding(2, 2, 0, 2)
    $soloControl.FlatStyle = 'Flat'
    $switches.Controls.Add($muteControl, 0, 0)
    $switches.Controls.Add($priorityControl, 1, 0)
    $switches.Controls.Add($soloControl, 2, 0)
    $layout.Controls.Add($switches, 0, 2)

    $meter = New-Object System.Windows.Forms.ProgressBar
    $meter.Dock = 'Fill'
    $meter.Minimum = 0
    $meter.Maximum = 100
    $meter.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $layout.Controls.Add($meter, 0, 3)

    $faderHost = New-Object System.Windows.Forms.Panel
    $faderHost.Dock = 'Fill'
    $faderHost.Margin = New-Object System.Windows.Forms.Padding(0)

    $fader = New-Object System.Windows.Forms.TrackBar
    $fader.Orientation = [System.Windows.Forms.Orientation]::Vertical
    $fader.Minimum = -60
    $fader.Maximum = 12
    $fader.Value = [int][Math]::Round($gainDb)
    $fader.TickFrequency = 6
    $fader.TickStyle = [System.Windows.Forms.TickStyle]::Both
    $fader.AutoSize = $false

    $zeroDbLabel = New-Object System.Windows.Forms.Label
    $zeroDbLabel.Text = '0 dB'
    $zeroDbLabel.AutoSize = $true
    $zeroDbLabel.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
    $zeroDbLabel.BackColor = $panel.BackColor

    $faderHost.Controls.Add($fader)
    $faderHost.Controls.Add($zeroDbLabel)
    $layout.Controls.Add($faderHost, 0, 4)

    $positionFader = {
        $faderWidth = 70
        $faderLeft = [Math]::Max(0, [int](($faderHost.ClientSize.Width - $faderWidth) / 2))
        $fader.SetBounds($faderLeft, 0, $faderWidth, $faderHost.ClientSize.Height)

        $trackPadding = 13
        $trackHeight = [Math]::Max(0, $fader.Height - (2 * $trackPadding))
        $zeroFraction = [double]($fader.Maximum - 0) / [double]($fader.Maximum - $fader.Minimum)
        $zeroTop = $trackPadding + [int][Math]::Round($trackHeight * $zeroFraction) - [int]($zeroDbLabel.Height / 2)
        $zeroLeft = $faderLeft + $faderWidth - 4
        $zeroDbLabel.Location = New-Object System.Drawing.Point($zeroLeft, [Math]::Max(0, $zeroTop))
        $zeroDbLabel.BringToFront()
    }.GetNewClosure()
    $faderHost.Add_Resize($positionFader)
    & $positionFader

    $gainLabel = New-Object System.Windows.Forms.Label
    $gainLabel.Text = ('{0:+0;-0;0} dB' -f $gainDb)
    $gainLabel.Dock = 'Fill'
    $gainLabel.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $gainLabel.TextAlign = 'MiddleCenter'
    $layout.Controls.Add($gainLabel, 0, 5)

    $state.Panel = $panel
    $state.Meter = $meter
    $state.GainLabel = $gainLabel
    $state.MuteControl = $muteControl
    $state.PriorityControl = $priorityControl
    $state.SoloControl = $soloControl

    $updateSwitchColors = {
        $muteControl.BackColor = if ($state.Mute) { [System.Drawing.Color]::FromArgb(220, 38, 38) } else { [System.Drawing.Color]::FromArgb(51, 65, 85) }
        $muteControl.ForeColor = [System.Drawing.Color]::White
        $priorityControl.BackColor = if ($state.Priority) { [System.Drawing.Color]::FromArgb(37, 99, 235) } else { [System.Drawing.Color]::FromArgb(51, 65, 85) }
        $priorityControl.ForeColor = [System.Drawing.Color]::White
        $soloControl.BackColor = if ($state.Solo) { [System.Drawing.Color]::FromArgb(234, 179, 8) } else { [System.Drawing.Color]::FromArgb(51, 65, 85) }
        $soloControl.ForeColor = [System.Drawing.Color]::White
    }.GetNewClosure()
    $state.UpdateSwitchColors = $updateSwitchColors
    & $updateSwitchColors

    $fader.Add_Scroll({
        $state.GainDb = [double]$fader.Value
        $gainLabel.Text = ('{0:+0;-0;0} dB' -f $state.GainDb)
        & $OnChanged
    }.GetNewClosure())
    $muteControl.Add_Click({
        $state.Mute = -not $state.Mute
        & $updateSwitchColors
        & $OnChanged
    }.GetNewClosure())
    $priorityControl.Add_Click({
        & $OnPriority $state
    }.GetNewClosure())
    $soloControl.Add_Click({
        & $OnSolo $state
    }.GetNewClosure())

    return $state
}

function Show-AudioMixerWindow {
    <# Opens the professional microphone mixer window and routes its AudioGraph to VB-CABLE. #>
    param(
        [Parameter(Mandatory=$true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory=$true)][hashtable]$ApplicationState,
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [scriptblock]$Logger
    )

    if ($script:AudioMixerWindow -and -not $script:AudioMixerWindow.IsDisposed) {
        $script:AudioMixerWindow.Activate()
        return
    }

    $form = New-Object System.Windows.Forms.Form
    $script:AudioMixerWindow = $form
    $form.Text = 'MicMaster - VB-CABLE Mixer'
    $form.StartPosition = 'CenterParent'
    $form.Size = New-Object System.Drawing.Size(1180, 700)
    $form.MinimumSize = New-Object System.Drawing.Size(900, 600)
    $form.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $form.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = 'Fill'
    $root.RowCount = 4
    $root.ColumnCount = 1
    $root.Padding = New-Object System.Windows.Forms.Padding(12)
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 58)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 58)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 52)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
    $form.Controls.Add($root)

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Fill'
    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'MICMASTER LIVE MIX'
    $title.Location = New-Object System.Drawing.Point(0, 0)
    $title.Size = New-Object System.Drawing.Size(400, 30)
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = [System.Drawing.Color]::White
    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = 'Microphones -> CABLE Input -> CABLE Output (select this in OBS)'
    $subtitle.Location = New-Object System.Drawing.Point(2, 31)
    $subtitle.Size = New-Object System.Drawing.Size(700, 22)
    $subtitle.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $header.Controls.Add($title)
    $header.Controls.Add($subtitle)
    $root.Controls.Add($header, 0, 0)

    $toolbar = New-Object System.Windows.Forms.FlowLayoutPanel
    $toolbar.Dock = 'Fill'
    $toolbar.WrapContents = $false
    $toolbar.AutoScroll = $true
    $toolbar.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 4)
    $outputLabel = New-Object System.Windows.Forms.Label
    $outputLabel.Text = 'OUTPUT'
    $outputLabel.AutoSize = $true
    $outputLabel.Margin = New-Object System.Windows.Forms.Padding(0, 10, 8, 0)
    $outputLabel.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $cmbOutput = New-Object System.Windows.Forms.ComboBox
    $cmbOutput.DropDownStyle = 'DropDownList'
    $cmbOutput.Width = 290
    $cmbOutput.DisplayMember = 'Name'
    $cmbOutput.Margin = New-Object System.Windows.Forms.Padding(0, 5, 10, 0)
    $latencyLabel = New-Object System.Windows.Forms.Label
    $latencyLabel.Text = 'LATENCY'
    $latencyLabel.AutoSize = $true
    $latencyLabel.Margin = New-Object System.Windows.Forms.Padding(0, 10, 8, 0)
    $latencyLabel.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $cmbLatency = New-Object System.Windows.Forms.ComboBox
    $cmbLatency.DropDownStyle = 'DropDownList'
    $cmbLatency.Width = 170
    $cmbLatency.DisplayMember = 'Name'
    $cmbLatency.Margin = New-Object System.Windows.Forms.Padding(0, 5, 12, 0)
    [void]$cmbLatency.Items.Add([pscustomobject]@{
        Name = 'Stable (system default)'
        Mode = 'SystemDefault'
    })
    [void]$cmbLatency.Items.Add([pscustomobject]@{
        Name = 'Lowest latency'
        Mode = 'LowestLatency'
    })
    $btnMix = New-Object System.Windows.Forms.Button
    $btnMix.Text = 'Start Mix'
    $btnMix.AutoSize = $true
    $btnMix.Height = 34
    $btnMix.Margin = New-Object System.Windows.Forms.Padding(4)
    $btnMix.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnMix.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(74, 222, 128)
    $btnMix.BackColor = [System.Drawing.Color]::FromArgb(22, 163, 74)
    $btnMix.ForeColor = [System.Drawing.Color]::White
    $btnRefresh = New-ToolbarButton -Text 'Refresh Inputs' -Icon 'R'
    $refreshButtonNormalColor = $btnRefresh.BackColor
    foreach ($control in @($outputLabel,$cmbOutput,$latencyLabel,$cmbLatency,$btnMix,$btnRefresh)) {
        [void]$toolbar.Controls.Add($control)
    }
    $root.Controls.Add($toolbar, 0, 1)

    $masterToolbar = New-Object System.Windows.Forms.FlowLayoutPanel
    $masterToolbar.Dock = 'Fill'
    $masterToolbar.WrapContents = $false
    $masterToolbar.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
    $masterLabel = New-Object System.Windows.Forms.Label
    $masterLabel.Text = 'MASTER GAIN'
    $masterLabel.AutoSize = $true
    $masterLabel.Margin = New-Object System.Windows.Forms.Padding(0, 10, 8, 0)
    $masterFader = New-Object System.Windows.Forms.TrackBar
    $masterFader.Minimum = -24
    $masterFader.Maximum = 6
    $masterFader.TickFrequency = 3
    $masterFader.Width = 260
    $masterFader.Margin = New-Object System.Windows.Forms.Padding(0, 0, 4, 0)
    $masterValue = New-Object System.Windows.Forms.Label
    $masterValue.AutoSize = $true
    $masterValue.Margin = New-Object System.Windows.Forms.Padding(0, 10, 18, 0)
    $masterMeterLabel = New-Object System.Windows.Forms.Label
    $masterMeterLabel.Text = 'MASTER LEVEL'
    $masterMeterLabel.AutoSize = $true
    $masterMeterLabel.Margin = New-Object System.Windows.Forms.Padding(0, 10, 8, 0)
    $masterMeterLabel.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $masterMeter = New-Object System.Windows.Forms.ProgressBar
    $masterMeter.Minimum = 0
    $masterMeter.Maximum = 100
    $masterMeter.Width = 260
    $masterMeter.Height = 20
    $masterMeter.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $masterMeter.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    foreach ($control in @($masterLabel,$masterFader,$masterValue,$masterMeterLabel,$masterMeter)) {
        [void]$masterToolbar.Controls.Add($control)
    }
    $root.Controls.Add($masterToolbar, 0, 2)

    $channelHost = New-Object System.Windows.Forms.FlowLayoutPanel
    $channelHost.Dock = 'Fill'
    $channelHost.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $channelHost.WrapContents = $false
    $channelHost.AutoScroll = $true
    $channelHost.Padding = New-Object System.Windows.Forms.Padding(4)
    $channelHost.BackColor = [System.Drawing.Color]::FromArgb(17, 24, 39)
    $root.Controls.Add($channelHost, 0, 3)

    $config = Read-AudioMixerConfig -ProjectRoot $ProjectRoot -Logger $Logger
    $masterDb = [double]$config.MasterDb
    if ($masterDb -lt -24) { $masterDb = -24 }
    if ($masterDb -gt 6) { $masterDb = 6 }
    $masterFader.Value = [int][Math]::Round($masterDb)
    $masterValue.Text = ('{0:+0;-0;0} dB' -f $masterDb)
    $cmbLatency.SelectedIndex = if ($config.LatencyMode -eq 'SystemDefault') { 0 } else { 1 }

    $mixerState = @{
        Runtime = $null
        Channels = @()
    }
    $script:AudioMixerInputsChangedHandler = {
        if ($mixerState.Runtime -and -not $btnRefresh.IsDisposed) {
            $btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(250, 204, 21)
            $btnRefresh.ForeColor = [System.Drawing.Color]::FromArgb(66, 32, 6)
        }
    }.GetNewClosure()
    $mixBlinkState = $false
    $mixBlinkTimer = New-Object System.Windows.Forms.Timer
    $mixBlinkTimer.Interval = 500
    $mixBlinkTimer.Add_Tick({
        $mixBlinkState = -not $mixBlinkState
        $btnMix.BackColor = if ($mixBlinkState) {
            [System.Drawing.Color]::FromArgb(220, 38, 38)
        }
        else {
            [System.Drawing.Color]::FromArgb(22, 163, 74)
        }
    }.GetNewClosure())

    $applyMix = {
        if ($mixerState.Runtime) {
            Update-AudioGraphMixerGains -Runtime $mixerState.Runtime -ChannelStates $mixerState.Channels -MasterDb ([double]$masterFader.Value)
        }
    }.GetNewClosure()

    $setPriority = {
        param([Parameter(Mandatory=$true)][object]$TargetState)

        $enablePriority = -not [bool]$TargetState.Priority
        $targetKey = Normalize-DeviceId (ConvertTo-PlainString $TargetState.Device.InstanceId)
        foreach ($channel in $mixerState.Channels) {
            $channelKey = Normalize-DeviceId (ConvertTo-PlainString $channel.Device.InstanceId)
            $channel.Priority = $enablePriority -and ($channelKey -eq $targetKey)
            $refreshColors = $channel.UpdateSwitchColors
            & $refreshColors
        }
        & $applyMix
    }.GetNewClosure()

    $setSolo = {
        param([Parameter(Mandatory=$true)][object]$TargetState)

        $enableSolo = -not [bool]$TargetState.Solo
        $targetKey = Normalize-DeviceId (ConvertTo-PlainString $TargetState.Device.InstanceId)
        foreach ($channel in $mixerState.Channels) {
            $channelKey = Normalize-DeviceId (ConvertTo-PlainString $channel.Device.InstanceId)
            $channel.Solo = $enableSolo -and ($channelKey -eq $targetKey)
            $refreshColors = $channel.UpdateSwitchColors
            & $refreshColors
        }
        & $applyMix
    }.GetNewClosure()

    $stopMix = {
        if ($mixerState.Runtime) {
            Stop-AudioGraphMixer -Runtime $mixerState.Runtime -Logger $Logger
            $mixerState.Runtime = $null
            $mixBlinkTimer.Stop()
            $mixBlinkState = $false
            $btnMix.Text = 'Start Mix'
            $btnMix.BackColor = [System.Drawing.Color]::FromArgb(22, 163, 74)
            $cmbOutput.Enabled = $true
            $cmbLatency.Enabled = $true
            $btnRefresh.BackColor = $refreshButtonNormalColor
            $btnRefresh.ForeColor = [System.Drawing.Color]::FromArgb(22, 32, 45)
            Write-AppLog -Message 'Mixer stopped.' -Level INFO -Logger $Logger
        }
    }.GetNewClosure()

    $loadOutputs = {
        $selectedId = ''
        if ($cmbOutput.SelectedItem) { $selectedId = ConvertTo-PlainString $cmbOutput.SelectedItem.Id }
        $cmbOutput.Items.Clear()
        $outputs = @(Get-VbCableRenderEndpoints -Logger $Logger | Sort-Object @{ Expression = { if ($_.Name -match '^CABLE Input \(') { 0 } else { 1 } } }, Name)
        foreach ($output in $outputs) { [void]$cmbOutput.Items.Add($output) }
        if ($cmbOutput.Items.Count -gt 0) {
            $selection = 0
            for ($i = 0; $i -lt $cmbOutput.Items.Count; $i++) {
                if ((ConvertTo-PlainString $cmbOutput.Items[$i].Id) -eq $selectedId) { $selection = $i; break }
            }
            $cmbOutput.SelectedIndex = $selection
        }
    }.GetNewClosure()

    $loadChannels = {
        param([bool]$RefreshInventory = $false)

        $currentSettings = @{}
        foreach ($channel in $mixerState.Channels) {
            $key = Normalize-DeviceId (ConvertTo-PlainString $channel.Device.InstanceId)
            if ([string]::IsNullOrWhiteSpace($key)) { continue }
            $currentSettings[$key] = @{
                Enabled = $true
                GainDb = [double]$channel.GainDb
                Mute = [bool]$channel.Mute
                Priority = [bool]$channel.Priority
                Solo = [bool]$channel.Solo
            }
        }
        foreach ($key in @($currentSettings.Keys)) {
            $config.Channels[$key] = $currentSettings[$key]
        }

        if ($RefreshInventory) {
            if ($ApplicationState.Devices -and $ApplicationState.Devices.Count -gt 0) {
                [void](Save-DeviceStateForDevices -ProjectRoot $ProjectRoot -Devices $ApplicationState.Devices -Logger $Logger)
            }
            $ApplicationState.Devices = @(Get-UsbMicrophoneInventory -ProjectRoot $ProjectRoot -Logger $Logger)
        }

        $providedDevices = @($ApplicationState.Devices)
        $devices = @($providedDevices | Where-Object {
            [bool](Get-ObjectPropertyValue -Object $_ -Name 'IsMicrophone' -Default $false) -and
            (Test-DeviceRecordIsActive -Device $_) -and
            -not [string]::IsNullOrWhiteSpace((ConvertTo-PlainString $_.EndpointGuid)) -and
            (ConvertTo-PlainString $_.FriendlyName) -notmatch '^CABLE Output\b'
        })

        $desiredByKey = @{}
        foreach ($device in $devices) {
            $key = Normalize-DeviceId (ConvertTo-PlainString $device.InstanceId)
            if (-not [string]::IsNullOrWhiteSpace($key) -and -not $desiredByKey.ContainsKey($key)) {
                $desiredByKey[$key] = $device
            }
        }

        if ($mixerState.Runtime) {
            foreach ($runtimeChannel in @($mixerState.Runtime.Channels)) {
                if (-not $desiredByKey.ContainsKey($runtimeChannel.Key)) {
                    Remove-AudioGraphMixerInput -Runtime $mixerState.Runtime -Key $runtimeChannel.Key -Logger $Logger
                }
            }

            $captureByGuid = Get-AudioGraphCaptureDeviceMap
            foreach ($key in @($desiredByKey.Keys)) {
                if (@($mixerState.Runtime.Channels | Where-Object { $_.Key -eq $key }).Count -gt 0) { continue }
                try {
                    [void](Add-AudioGraphMixerInput -Runtime $mixerState.Runtime -Device $desiredByKey[$key] -CaptureByGuid $captureByGuid -Logger $Logger)
                }
                catch {
                    Write-AppLog -Message ("Adding live mixer input failed for {0}: {1}" -f $desiredByKey[$key].FriendlyName, $_.Exception.Message) -Level ERROR -Logger $Logger
                }
            }
        }

        $channelHost.SuspendLayout()
        try {
            foreach ($control in @($channelHost.Controls)) {
                $control.Dispose()
            }
            $newChannels = @()
            $seen = @{}
            $priorityAssigned = $false
            $soloAssigned = $false

            foreach ($device in $devices) {
                $key = Normalize-DeviceId (ConvertTo-PlainString $device.InstanceId)
                if ([string]::IsNullOrWhiteSpace($key) -or $seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                $saved = $null
                if ($currentSettings.ContainsKey($key)) {
                    $saved = $currentSettings[$key]
                }
                elseif ($config.Channels.ContainsKey($key)) {
                    $saved = $config.Channels[$key]
                }
                $strip = New-AudioMixerChannelStrip -Device $device -SavedSettings $saved -OnChanged $applyMix -OnPriority $setPriority -OnSolo $setSolo
                if ($strip.Priority) {
                    if ($priorityAssigned) {
                        $strip.Priority = $false
                        $refreshColors = $strip.UpdateSwitchColors
                        & $refreshColors
                    }
                    else {
                        $priorityAssigned = $true
                    }
                }
                if ($strip.Solo) {
                    if ($soloAssigned) {
                        $strip.Solo = $false
                        $refreshColors = $strip.UpdateSwitchColors
                        & $refreshColors
                    }
                    else {
                        $soloAssigned = $true
                    }
                }
                $newChannels += $strip
                [void]$channelHost.Controls.Add($strip.Panel)
            }
            $mixerState.Channels = $newChannels
            & $applyMix
        }
        finally {
            $channelHost.ResumeLayout()
        }
    }.GetNewClosure()

    $btnMix.Add_Click({
        if ($mixerState.Runtime) {
            & $stopMix
            return
        }
        try {
            if ($null -eq $cmbOutput.SelectedItem) { throw 'CABLE Input playback endpoint was not found.' }
            if ($null -eq $cmbLatency.SelectedItem) { throw 'Select an audio latency mode.' }
            if ($mixerState.Channels.Count -eq 0) { throw 'No active microphones are available for mixing.' }
            $devices = @($mixerState.Channels | ForEach-Object { $_.Device })
            $mixerState.Runtime = Start-AudioGraphMixer `
                -Devices $devices `
                -OutputEndpoint $cmbOutput.SelectedItem `
                -ChannelStates $mixerState.Channels `
                -MasterDb ([double]$masterFader.Value) `
                -LatencyMode (ConvertTo-PlainString $cmbLatency.SelectedItem.Mode) `
                -Logger $Logger
            $btnMix.Text = 'Stop Mix'
            $mixBlinkState = $false
            $btnMix.BackColor = [System.Drawing.Color]::FromArgb(22, 163, 74)
            $mixBlinkTimer.Start()
            $cmbOutput.Enabled = $false
            $cmbLatency.Enabled = $false
            $btnRefresh.BackColor = $refreshButtonNormalColor
            $btnRefresh.ForeColor = [System.Drawing.Color]::FromArgb(22, 32, 45)
        }
        catch {
            $mixerState.Runtime = $null
            Write-AppLog -Message ("Mixer start failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $Logger
            [void][System.Windows.Forms.MessageBox]::Show(
                $form,
                $_.Exception.Message,
                'MicMaster Mixer',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    }.GetNewClosure())
    $btnRefresh.Add_Click({
        try {
            & $loadChannels $true
            $btnRefresh.BackColor = $refreshButtonNormalColor
            $btnRefresh.ForeColor = [System.Drawing.Color]::FromArgb(22, 32, 45)
        }
        catch {
            Write-AppLog -Message ("Refreshing live mixer inputs failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $Logger
            [void][System.Windows.Forms.MessageBox]::Show(
                $form,
                $_.Exception.Message,
                'Refresh Mixer Inputs',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    }.GetNewClosure())
    $masterFader.Add_Scroll({
        $masterValue.Text = ('{0:+0;-0;0} dB' -f [double]$masterFader.Value)
        & $applyMix
    }.GetNewClosure())

    $meterTimer = New-Object System.Windows.Forms.Timer
    $meterTimer.Interval = 100
    $meterTimer.Add_Tick({
        foreach ($channel in $mixerState.Channels) {
            try {
                $peak = Get-AudioEndpointPeak -EndpointId (ConvertTo-PlainString $channel.Device.EndpointId) -Logger $null -Quiet
                $value = [Math]::Max(0, [Math]::Min(100, [int][Math]::Round($peak * 100)))
                $channel.Meter.Value = $value
            }
            catch {
                $channel.Meter.Value = 0
            }
        }
        try {
            if ($mixerState.Runtime -and $cmbOutput.SelectedItem) {
                $renderEndpointId = '{0.0.0.00000000}.' + (ConvertTo-PlainString $cmbOutput.SelectedItem.EndpointGuid)
                $masterPeak = Get-AudioEndpointPeak -EndpointId $renderEndpointId -Logger $null -Quiet
                $masterMeter.Value = [Math]::Max(0, [Math]::Min(100, [int][Math]::Round($masterPeak * 100)))
            }
            else {
                $masterMeter.Value = 0
            }
        }
        catch {
            $masterMeter.Value = 0
        }
    }.GetNewClosure())

    $form.Add_Shown({
        & $loadOutputs
        & $loadChannels $false
        $meterTimer.Start()
    }.GetNewClosure())
    $form.Add_FormClosing({
        $meterTimer.Stop()
        $mixBlinkTimer.Stop()
        & $stopMix
        $latencyMode = if ($cmbLatency.SelectedItem) {
            ConvertTo-PlainString $cmbLatency.SelectedItem.Mode
        }
        else {
            'LowestLatency'
        }
        [void](Save-AudioMixerConfig -ProjectRoot $ProjectRoot -Channels $mixerState.Channels -MasterDb ([double]$masterFader.Value) -LatencyMode $latencyMode -Logger $Logger)
        $script:AudioMixerInputsChangedHandler = $null
        $script:AudioMixerWindow = $null
    }.GetNewClosure())

    $form.Show($Owner)
}
