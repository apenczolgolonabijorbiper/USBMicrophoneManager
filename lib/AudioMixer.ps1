<#
Multi-device AudioGraph mixer routed to a VB-Audio Virtual Cable render endpoint.
#>

Set-StrictMode -Version 2.0

$script:AudioMixerWindow = $null

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
        Channels = @{}
    }
    $path = Get-AudioMixerConfigPath -ProjectRoot $ProjectRoot
    try {
        if (-not (Test-Path -LiteralPath $path)) { return $config }
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $config }
        $json = $raw | ConvertFrom-Json
        $config.MasterDb = [double](Get-ObjectPropertyValue -Object $json -Name 'MasterDb' -Default 0)
        $channels = Get-ObjectPropertyValue -Object $json -Name 'Channels' -Default $null
        if ($channels) {
            foreach ($property in $channels.PSObject.Properties) {
                $key = Normalize-DeviceId $property.Name
                $config.Channels[$key] = @{
                    Enabled = ConvertTo-StorageBoolean -Value (Get-ObjectPropertyValue -Object $property.Value -Name 'Enabled' -Default $true) -Default $true
                    GainDb = [double](Get-ObjectPropertyValue -Object $property.Value -Name 'GainDb' -Default 0)
                    Mute = ConvertTo-StorageBoolean -Value (Get-ObjectPropertyValue -Object $property.Value -Name 'Mute' -Default $false) -Default $false
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
        [scriptblock]$Logger
    )

    $path = Get-AudioMixerConfigPath -ProjectRoot $ProjectRoot
    $channelRoot = [ordered]@{}
    foreach ($channel in $Channels) {
        $key = Normalize-DeviceId (ConvertTo-PlainString $channel.Device.InstanceId)
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        $channelRoot[$key] = [ordered]@{
            Enabled = [bool]$channel.Enabled
            GainDb = [double]$channel.GainDb
            Mute = [bool]$channel.Mute
            Solo = [bool]$channel.Solo
        }
    }
    $root = [ordered]@{
        MasterDb = [double]$MasterDb
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
            Convert-DecibelsToLinearGain -Decibels ([double]$state.GainDb)
        }
        else {
            0.0
        }
    }
    $Runtime.MixNode.OutgoingGain = Convert-DecibelsToLinearGain -Decibels $MasterDb
}

function Start-AudioGraphMixer {
    <# Creates and starts a multi-input AudioGraph routed to the chosen VB-CABLE playback endpoint. #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Devices,
        [Parameter(Mandatory=$true)][object]$OutputEndpoint,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$ChannelStates,
        [double]$MasterDb,
        [scriptblock]$Logger
    )

    Initialize-AudioGraphRuntime
    $runtime = $null
    try {
        $settings = New-Object Windows.Media.Audio.AudioGraphSettings ([Windows.Media.Render.AudioRenderCategory]::Media)
        $settings.PrimaryRenderDevice = $OutputEndpoint.DeviceInformation
        $settings.QuantumSizeSelectionMode = [Windows.Media.Audio.QuantumSizeSelectionMode]::LowestLatency

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

        $captureByGuid = @{}
        foreach ($captureDevice in @(Get-AudioGraphDeviceInformation -Flow Capture)) {
            $guid = Normalize-DeviceId (Get-AudioGraphEndpointGuid -DeviceInformationId $captureDevice.Id)
            if (-not [string]::IsNullOrWhiteSpace($guid)) {
                $captureByGuid[$guid] = $captureDevice
            }
        }

        $inputResultType = [Windows.Media.Audio.CreateAudioDeviceInputNodeResult,Windows.Media.Audio,ContentType=WindowsRuntime]
        foreach ($device in $Devices) {
            $endpointGuid = Normalize-DeviceId (ConvertTo-PlainString $device.EndpointGuid)
            if ([string]::IsNullOrWhiteSpace($endpointGuid) -or -not $captureByGuid.ContainsKey($endpointGuid)) {
                Write-AppLog -Message ("Mixer skipped endpoint not available to AudioGraph: {0}" -f $device.FriendlyName) -Level WARN -Logger $Logger
                continue
            }

            $encoding = $null
            $operation = $runtime.Graph.CreateDeviceInputNodeAsync(
                [Windows.Media.Capture.MediaCategory]::Other,
                $encoding,
                $captureByGuid[$endpointGuid]
            )
            $inputResult = Get-WinRtAsyncResult -Operation $operation -ResultType $inputResultType
            if ($inputResult.Status.ToString() -ne 'Success' -or $null -eq $inputResult.DeviceInputNode) {
                Write-AppLog -Message ("Mixer input failed for {0}: {1}" -f $device.FriendlyName, $inputResult.Status) -Level ERROR -Logger $Logger
                continue
            }

            $inputResult.DeviceInputNode.AddOutgoingConnection($runtime.MixNode)
            $runtime.Channels += [pscustomobject]@{
                Key = Normalize-DeviceId (ConvertTo-PlainString $device.InstanceId)
                Device = $device
                Node = $inputResult.DeviceInputNode
            }
        }

        if ($runtime.Channels.Count -eq 0) { throw 'No selected microphone could be opened by AudioGraph.' }
        Update-AudioGraphMixerGains -Runtime $runtime -ChannelStates $ChannelStates -MasterDb $MasterDb
        $runtime.Graph.Start()
        Write-AppLog -Message ("Mixer started: {0} input(s) -> {1}." -f $runtime.Channels.Count, $OutputEndpoint.Name) -Level INFO -Logger $Logger
        return $runtime
    }
    catch {
        if ($runtime) { Stop-AudioGraphMixer -Runtime $runtime -Logger $Logger }
        throw
    }
}

function New-AudioMixerChannelStrip {
    <# Builds one channel strip with aliases, meter, fader, enable, mute, and solo controls. #>
    param(
        [Parameter(Mandatory=$true)][object]$Device,
        [hashtable]$SavedSettings,
        [Parameter(Mandatory=$true)][scriptblock]$OnChanged
    )

    $enabled = $true
    $gainDb = -12.0
    $mute = $false
    $solo = $false
    if ($SavedSettings) {
        $enabled = [bool]$SavedSettings.Enabled
        $gainDb = [double]$SavedSettings.GainDb
        $mute = [bool]$SavedSettings.Mute
        $solo = [bool]$SavedSettings.Solo
    }
    if ($gainDb -lt -60) { $gainDb = -60 }
    if ($gainDb -gt 12) { $gainDb = 12 }

    $state = [pscustomobject]@{
        Device = $Device
        Enabled = $enabled
        GainDb = $gainDb
        Mute = $mute
        Solo = $solo
        Panel = $null
        Meter = $null
        GainLabel = $null
        EnableControl = $null
        MuteControl = $null
        SoloControl = $null
    }

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Size = New-Object System.Drawing.Size(176, 470)
    $panel.Margin = New-Object System.Windows.Forms.Padding(8)
    $panel.Padding = New-Object System.Windows.Forms.Padding(10)
    $panel.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'
    $layout.ColumnCount = 1
    $layout.RowCount = 10
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 34)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 24)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 42)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 30)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 26)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 28)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 38)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 26)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 22)))
    $panel.Controls.Add($layout)

    $alias2 = ConvertTo-PlainString $Device.Alias2
    $alias1 = ConvertTo-PlainString $Device.Alias1
    $titleText = if (-not [string]::IsNullOrWhiteSpace($alias2)) { $alias2 } elseif (-not [string]::IsNullOrWhiteSpace($alias1)) { $alias1 } else { $Device.FriendlyName }

    $title = New-Object System.Windows.Forms.Label
    $title.Text = $titleText
    $title.Dock = 'Fill'
    $title.AutoEllipsis = $true
    $title.ForeColor = [System.Drawing.Color]::White
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $title.TextAlign = 'MiddleCenter'
    $layout.Controls.Add($title, 0, 0)

    $aliasLabel = New-Object System.Windows.Forms.Label
    $aliasLabel.Text = ("A1: {0}   A2: {1}" -f $alias1, $alias2)
    $aliasLabel.Dock = 'Fill'
    $aliasLabel.AutoEllipsis = $true
    $aliasLabel.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $aliasLabel.TextAlign = 'MiddleCenter'
    $layout.Controls.Add($aliasLabel, 0, 1)

    $deviceLabel = New-Object System.Windows.Forms.Label
    $deviceLabel.Text = ConvertTo-PlainString $Device.FriendlyName
    $deviceLabel.Dock = 'Fill'
    $deviceLabel.AutoEllipsis = $true
    $deviceLabel.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
    $deviceLabel.TextAlign = 'MiddleCenter'
    $layout.Controls.Add($deviceLabel, 0, 2)

    $enableControl = New-Object System.Windows.Forms.CheckBox
    $enableControl.Text = 'IN MIX'
    $enableControl.Checked = $enabled
    $enableControl.Dock = 'Fill'
    $enableControl.TextAlign = 'MiddleCenter'
    $enableControl.CheckAlign = 'MiddleLeft'
    $enableControl.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $layout.Controls.Add($enableControl, 0, 3)

    $meter = New-Object System.Windows.Forms.ProgressBar
    $meter.Dock = 'Fill'
    $meter.Minimum = 0
    $meter.Maximum = 100
    $meter.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $layout.Controls.Add($meter, 0, 4)

    $fader = New-Object System.Windows.Forms.TrackBar
    $fader.Orientation = [System.Windows.Forms.Orientation]::Vertical
    $fader.Minimum = -60
    $fader.Maximum = 12
    $fader.Value = [int][Math]::Round($gainDb)
    $fader.TickFrequency = 6
    $fader.TickStyle = [System.Windows.Forms.TickStyle]::Both
    $fader.Dock = 'Fill'
    $layout.Controls.Add($fader, 0, 5)

    $gainLabel = New-Object System.Windows.Forms.Label
    $gainLabel.Text = ('{0:+0;-0;0} dB' -f $gainDb)
    $gainLabel.Dock = 'Fill'
    $gainLabel.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $gainLabel.TextAlign = 'MiddleCenter'
    $layout.Controls.Add($gainLabel, 0, 6)

    $switches = New-Object System.Windows.Forms.TableLayoutPanel
    $switches.Dock = 'Fill'
    $switches.ColumnCount = 2
    [void]$switches.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 50)))
    [void]$switches.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 50)))
    $muteControl = New-Object System.Windows.Forms.Button
    $muteControl.Text = 'MUTE'
    $muteControl.Dock = 'Fill'
    $muteControl.FlatStyle = 'Flat'
    $soloControl = New-Object System.Windows.Forms.Button
    $soloControl.Text = 'SOLO'
    $soloControl.Dock = 'Fill'
    $soloControl.FlatStyle = 'Flat'
    $switches.Controls.Add($muteControl, 0, 0)
    $switches.Controls.Add($soloControl, 1, 0)
    $layout.Controls.Add($switches, 0, 7)

    $identity = New-Object System.Windows.Forms.Label
    $identity.Text = ConvertTo-PlainString $Device.EndpointGuid
    $identity.Dock = 'Fill'
    $identity.AutoEllipsis = $true
    $identity.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
    $identity.TextAlign = 'MiddleCenter'
    $layout.Controls.Add($identity, 0, 8)

    $status = New-Object System.Windows.Forms.Label
    $status.Text = 'READY'
    $status.Dock = 'Fill'
    $status.ForeColor = [System.Drawing.Color]::FromArgb(74, 222, 128)
    $status.TextAlign = 'MiddleCenter'
    $layout.Controls.Add($status, 0, 9)

    $state.Panel = $panel
    $state.Meter = $meter
    $state.GainLabel = $gainLabel
    $state.EnableControl = $enableControl
    $state.MuteControl = $muteControl
    $state.SoloControl = $soloControl

    $updateSwitchColors = {
        $muteControl.BackColor = if ($state.Mute) { [System.Drawing.Color]::FromArgb(220, 38, 38) } else { [System.Drawing.Color]::FromArgb(51, 65, 85) }
        $muteControl.ForeColor = [System.Drawing.Color]::White
        $soloControl.BackColor = if ($state.Solo) { [System.Drawing.Color]::FromArgb(234, 179, 8) } else { [System.Drawing.Color]::FromArgb(51, 65, 85) }
        $soloControl.ForeColor = [System.Drawing.Color]::White
    }.GetNewClosure()
    & $updateSwitchColors

    $enableControl.Add_CheckedChanged({
        $state.Enabled = $enableControl.Checked
        & $OnChanged
    }.GetNewClosure())
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
    $soloControl.Add_Click({
        $state.Solo = -not $state.Solo
        & $updateSwitchColors
        & $OnChanged
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
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 66)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 34)))
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
    $cmbOutput.Margin = New-Object System.Windows.Forms.Padding(0, 5, 12, 0)
    $btnStart = New-ToolbarButton -Text 'Start Mix' -Icon 'ON'
    $btnStop = New-ToolbarButton -Text 'Stop' -Icon 'OFF'
    $btnStop.Enabled = $false
    $btnRefresh = New-ToolbarButton -Text 'Refresh Inputs' -Icon 'R'
    $masterLabel = New-Object System.Windows.Forms.Label
    $masterLabel.Text = 'MASTER'
    $masterLabel.AutoSize = $true
    $masterLabel.Margin = New-Object System.Windows.Forms.Padding(16, 10, 4, 0)
    $masterFader = New-Object System.Windows.Forms.TrackBar
    $masterFader.Minimum = -24
    $masterFader.Maximum = 6
    $masterFader.TickFrequency = 3
    $masterFader.Width = 160
    $masterFader.Margin = New-Object System.Windows.Forms.Padding(0, 0, 4, 0)
    $masterValue = New-Object System.Windows.Forms.Label
    $masterValue.AutoSize = $true
    $masterValue.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
    $masterMeter = New-Object System.Windows.Forms.ProgressBar
    $masterMeter.Minimum = 0
    $masterMeter.Maximum = 100
    $masterMeter.Width = 110
    $masterMeter.Height = 20
    $masterMeter.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $masterMeter.Margin = New-Object System.Windows.Forms.Padding(10, 9, 0, 0)
    foreach ($control in @($outputLabel,$cmbOutput,$btnStart,$btnStop,$btnRefresh,$masterLabel,$masterFader,$masterValue,$masterMeter)) {
        [void]$toolbar.Controls.Add($control)
    }
    $root.Controls.Add($toolbar, 0, 1)

    $channelHost = New-Object System.Windows.Forms.FlowLayoutPanel
    $channelHost.Dock = 'Fill'
    $channelHost.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $channelHost.WrapContents = $false
    $channelHost.AutoScroll = $true
    $channelHost.Padding = New-Object System.Windows.Forms.Padding(4)
    $channelHost.BackColor = [System.Drawing.Color]::FromArgb(17, 24, 39)
    $root.Controls.Add($channelHost, 0, 2)

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Dock = 'Fill'
    $statusLabel.TextAlign = 'MiddleLeft'
    $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $root.Controls.Add($statusLabel, 0, 3)

    $config = Read-AudioMixerConfig -ProjectRoot $ProjectRoot -Logger $Logger
    $masterDb = [double]$config.MasterDb
    if ($masterDb -lt -24) { $masterDb = -24 }
    if ($masterDb -gt 6) { $masterDb = 6 }
    $masterFader.Value = [int][Math]::Round($masterDb)
    $masterValue.Text = ('{0:+0;-0;0} dB' -f $masterDb)

    $mixerState = @{
        Runtime = $null
        Channels = @()
    }

    $applyMix = {
        if ($mixerState.Runtime) {
            Update-AudioGraphMixerGains -Runtime $mixerState.Runtime -ChannelStates $mixerState.Channels -MasterDb ([double]$masterFader.Value)
        }
    }.GetNewClosure()

    $stopMix = {
        if ($mixerState.Runtime) {
            Stop-AudioGraphMixer -Runtime $mixerState.Runtime -Logger $Logger
            $mixerState.Runtime = $null
            $btnStart.Enabled = $true
            $btnStop.Enabled = $false
            $cmbOutput.Enabled = $true
            $statusLabel.Text = 'Mix stopped. CABLE Output is no longer receiving MicMaster audio.'
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
        & $stopMix
        $channelHost.SuspendLayout()
        try {
            $channelHost.Controls.Clear()
            $mixerState.Channels = @()
            $seen = @{}
            $providedDevices = @($ApplicationState.Devices)
            $devices = @($providedDevices | Where-Object {
                [bool](Get-ObjectPropertyValue -Object $_ -Name 'IsMicrophone' -Default $false) -and
                (Test-DeviceRecordIsActive -Device $_) -and
                -not [string]::IsNullOrWhiteSpace((ConvertTo-PlainString $_.EndpointGuid)) -and
                (ConvertTo-PlainString $_.FriendlyName) -notmatch '^CABLE Output\b'
            })

            foreach ($device in $devices) {
                $key = Normalize-DeviceId (ConvertTo-PlainString $device.InstanceId)
                if ([string]::IsNullOrWhiteSpace($key) -or $seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                $saved = $null
                if ($config.Channels.ContainsKey($key)) { $saved = $config.Channels[$key] }
                $strip = New-AudioMixerChannelStrip -Device $device -SavedSettings $saved -OnChanged $applyMix
                $mixerState.Channels += $strip
                [void]$channelHost.Controls.Add($strip.Panel)
            }
            $statusLabel.Text = if ($mixerState.Channels.Count -gt 0) {
                "{0} active microphone(s) ready. Output is silent until Start Mix is pressed." -f $mixerState.Channels.Count
            }
            else {
                'No active devices marked as microphones are available.'
            }
        }
        finally {
            $channelHost.ResumeLayout()
        }
    }.GetNewClosure()

    $btnStart.Add_Click({
        try {
            if ($mixerState.Runtime) { return }
            if ($null -eq $cmbOutput.SelectedItem) { throw 'CABLE Input playback endpoint was not found.' }
            if ($mixerState.Channels.Count -eq 0) { throw 'No active microphones are available for mixing.' }
            $devices = @($mixerState.Channels | ForEach-Object { $_.Device })
            $mixerState.Runtime = Start-AudioGraphMixer `
                -Devices $devices `
                -OutputEndpoint $cmbOutput.SelectedItem `
                -ChannelStates $mixerState.Channels `
                -MasterDb ([double]$masterFader.Value) `
                -Logger $Logger
            $btnStart.Enabled = $false
            $btnStop.Enabled = $true
            $cmbOutput.Enabled = $false
            $statusLabel.Text = ("LIVE: {0} microphone(s) -> {1}. Select CABLE Output in OBS." -f $mixerState.Runtime.Channels.Count, $cmbOutput.SelectedItem.Name)
        }
        catch {
            $mixerState.Runtime = $null
            $statusLabel.Text = "Mixer start failed: $($_.Exception.Message)"
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
    $btnStop.Add_Click({ & $stopMix }.GetNewClosure())
    $btnRefresh.Add_Click({
        & $loadOutputs
        & $loadChannels
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
        & $loadChannels
        $meterTimer.Start()
        if ($cmbOutput.Items.Count -eq 0) {
            $statusLabel.Text = 'VB-CABLE playback endpoint CABLE Input was not found.'
        }
    }.GetNewClosure())
    $form.Add_FormClosing({
        $meterTimer.Stop()
        & $stopMix
        [void](Save-AudioMixerConfig -ProjectRoot $ProjectRoot -Channels $mixerState.Channels -MasterDb ([double]$masterFader.Value) -Logger $Logger)
        $script:AudioMixerWindow = $null
    }.GetNewClosure())

    $form.Show($Owner)
}
