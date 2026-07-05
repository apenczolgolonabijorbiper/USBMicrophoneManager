<#
Windows Forms user interface.
#>

Set-StrictMode -Version 2.0

function Add-GridColumn {
    <# Adds one configured DataGridView column. #>
    param(
        [Parameter(Mandatory=$true)][System.Windows.Forms.DataGridView]$Grid,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Header,
        [bool]$ReadOnly = $true,
        [int]$Width = 140
    )

    $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $column.Name = $Name
    $column.DataPropertyName = $Name
    $column.HeaderText = $Header
    $column.ReadOnly = $ReadOnly
    $column.Width = $Width
    $column.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::Automatic
    [void]$Grid.Columns.Add($column)
}

function Add-GridCheckBoxColumn {
    <# Adds one configured checkbox DataGridView column. #>
    param(
        [Parameter(Mandatory=$true)][System.Windows.Forms.DataGridView]$Grid,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Header,
        [bool]$ReadOnly = $false,
        [int]$Width = 60
    )

    $column = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $column.Name = $Name
    $column.DataPropertyName = $Name
    $column.HeaderText = $Header
    $column.ReadOnly = $ReadOnly
    $column.Width = $Width
    $column.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::Automatic
    [void]$Grid.Columns.Add($column)
}

function New-ToolbarButton {
    <# Creates a consistently styled toolbar button. #>
    param(
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)][string]$Icon
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = "$Icon  $Text"
    $button.AutoSize = $true
    $button.Height = 34
    $button.Margin = New-Object System.Windows.Forms.Padding(4)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(190, 198, 210)
    $button.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
    $button.ForeColor = [System.Drawing.Color]::FromArgb(22, 32, 45)
    return $button
}

function Convert-DevicesToDataTable {
    <# Converts microphone records to a DataTable suitable for filtering and sorting. #>
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Devices)

    $table = New-Object System.Data.DataTable
    [void]$table.Columns.Add('IsMicrophone', [bool])
    [void]$table.Columns.Add('IsDefault', [bool])
    [void]$table.Columns.Add('IsDefaultComm', [bool])
    foreach ($name in @('State','Alias1','Alias2','Alias3','Alias4','FriendlyName','VID','PID','InstanceId','ContainerId','EndpointGuid','UsbPort','Location','Driver','Status','Level','APO','Processing','LastActive','EndpointId','LocationPath','BusRelations','ParentDevice','BusNumber','Address')) {
        [void]$table.Columns.Add($name, [string])
    }

    foreach ($device in $Devices) {
        $row = $table.NewRow()
        foreach ($column in $table.Columns) {
            $name = $column.ColumnName
            if ($name -eq 'Level') {
                $row[$name] = ('{0:P0}' -f [double](Get-ObjectPropertyValue -Object $device -Name 'Level' -Default 0))
            }
            elseif ($name -eq 'IsMicrophone' -or $name -eq 'IsDefault' -or $name -eq 'IsDefaultComm') {
                $defaultValue = ($name -eq 'IsMicrophone')
                $row[$name] = [bool](Get-ObjectPropertyValue -Object $device -Name $name -Default $defaultValue)
            }
            elseif ($name -eq 'State') {
                $row[$name] = Convert-DeviceStatusToDisplayState -Status (ConvertTo-PlainString (Get-ObjectPropertyValue -Object $device -Name 'Status' -Default ''))
            }
            elseif ($name -eq 'LastActive') {
                $row[$name] = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $device -Name 'LastActive' -Default '')
            }
            elseif ($name -eq 'APO') {
                $row[$name] = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $device -Name 'Apo' -Default '')
            }
            elseif ($name -eq 'Processing') {
                $row[$name] = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $device -Name 'Processing' -Default '')
            }
            else {
                $row[$name] = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $device -Name $name -Default '')
            }
        }
        [void]$table.Rows.Add($row)
    }
    return ,$table
}

function Test-DeviceRecordIsActive {
    <# Returns true when a device record represents an active endpoint. #>
    param([Parameter(Mandatory=$true)][object]$Device)

    $status = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $Device -Name 'Status' -Default '')
    return ($status -match 'ACTIVE|OK')
}

function Configure-DeviceGrid {
    <# Applies common DataGridView styling and behavior. #>
    param([Parameter(Mandatory=$true)][System.Windows.Forms.DataGridView]$Grid)

    $Grid.Dock = 'Fill'
    $Grid.AllowUserToAddRows = $false
    $Grid.AllowUserToDeleteRows = $false
    $Grid.MultiSelect = $false
    $Grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $Grid.AutoGenerateColumns = $false
    $Grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::DisplayedCells
    $Grid.BackgroundColor = [System.Drawing.Color]::White
    $Grid.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $Grid.EnableHeadersVisualStyles = $false
    $Grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $Grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $Grid.RowHeadersVisible = $false
    $Grid.ReadOnly = $false

    $doubleBufferedFlags = [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic
    $doubleBufferedProperty = $Grid.GetType().GetProperty('DoubleBuffered', $doubleBufferedFlags)
    if ($doubleBufferedProperty) { $doubleBufferedProperty.SetValue($Grid, $true, $null) }
}

function Add-DeviceGridColumns {
    <# Adds the microphone columns to a device grid. #>
    param(
        [Parameter(Mandatory=$true)][System.Windows.Forms.DataGridView]$Grid,
        [bool]$IncludeLevel = $true,
        [bool]$IncludeLastActive = $false
    )

    Add-GridColumn -Grid $Grid -Name 'State' -Header 'State' -Width 120
    Add-GridCheckBoxColumn -Grid $Grid -Name 'IsMicrophone' -Header 'Mix' -ReadOnly $false -Width 55
    if ($IncludeLevel) {
        Add-GridColumn -Grid $Grid -Name 'Level' -Header 'Level' -Width 70
    }
    Add-GridCheckBoxColumn -Grid $Grid -Name 'IsDefault' -Header 'Default' -ReadOnly $true -Width 65
    Add-GridCheckBoxColumn -Grid $Grid -Name 'IsDefaultComm' -Header 'Comm' -ReadOnly $true -Width 55
    Add-GridColumn -Grid $Grid -Name 'Alias1' -Header 'Alias1 (VID/PID)' -ReadOnly $false -Width 150
    Add-GridColumn -Grid $Grid -Name 'Alias2' -Header 'Alias2 (InstanceId)' -ReadOnly $false -Width 160
    Add-GridColumn -Grid $Grid -Name 'Alias3' -Header 'Alias3 (ContainerId)' -ReadOnly $false -Width 160
    Add-GridColumn -Grid $Grid -Name 'Alias4' -Header 'Alias4 (Endpoint GUID)' -ReadOnly $false -Width 170
    Add-GridColumn -Grid $Grid -Name 'FriendlyName' -Header 'Friendly Name' -Width 180
    Add-GridColumn -Grid $Grid -Name 'VID' -Header 'VID' -Width 70
    Add-GridColumn -Grid $Grid -Name 'PID' -Header 'PID' -Width 70
    Add-GridColumn -Grid $Grid -Name 'InstanceId' -Header 'InstanceId' -Width 260
    Add-GridColumn -Grid $Grid -Name 'ContainerId' -Header 'ContainerId' -Width 180
    Add-GridColumn -Grid $Grid -Name 'EndpointGuid' -Header 'Endpoint GUID' -Width 170
    Add-GridColumn -Grid $Grid -Name 'Driver' -Header 'Driver' -Width 150
    Add-GridColumn -Grid $Grid -Name 'APO' -Header 'APO' -Width 130
    Add-GridColumn -Grid $Grid -Name 'Processing' -Header 'Processing' -Width 280
    if ($IncludeLastActive) {
        Add-GridColumn -Grid $Grid -Name 'LastActive' -Header 'Last Active' -Width 150
    }
}

function Sync-GridEditsToDevices {
    <# Copies edited aliases and microphone flags from grid data back to the in-memory device records. #>
    param(
        [Parameter(Mandatory=$true)][System.Data.DataTable]$Table,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Devices
    )

    $alias1ByVidPid = @{}
    $alias2ByInstanceId = @{}
    $alias3ByContainerId = @{}
    $alias4ByEndpointGuid = @{}
    $micFlags = @{}
    foreach ($row in $Table.Rows) {
        $id = Normalize-DeviceId (ConvertTo-PlainString $row['InstanceId'])
        $vidPidKey = Get-VidPidAliasKey -VID (ConvertTo-PlainString $row['VID']) -PID (ConvertTo-PlainString $row['PID'])
        $containerKey = Normalize-DeviceId (ConvertTo-PlainString $row['ContainerId'])
        $endpointGuidKey = Normalize-DeviceId (ConvertTo-PlainString $row['EndpointGuid'])
        if (-not [string]::IsNullOrWhiteSpace($vidPidKey)) {
            $alias1ByVidPid[$vidPidKey] = ConvertTo-PlainString $row['Alias1']
        }
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            $alias2ByInstanceId[$id] = ConvertTo-PlainString $row['Alias2']
            $micFlags[$id] = [bool]$row['IsMicrophone']
        }
        if (-not [string]::IsNullOrWhiteSpace($containerKey)) {
            $alias3ByContainerId[$containerKey] = ConvertTo-PlainString $row['Alias3']
        }
        if (-not [string]::IsNullOrWhiteSpace($endpointGuidKey)) {
            $alias4ByEndpointGuid[$endpointGuidKey] = ConvertTo-PlainString $row['Alias4']
        }
    }

    foreach ($device in $Devices) {
        $id = Normalize-DeviceId $device.InstanceId
        $vidPidKey = Get-VidPidAliasKey -VID $device.VID -PID $device.PID
        $containerKey = Normalize-DeviceId $device.ContainerId
        $endpointGuidKey = Normalize-DeviceId $device.EndpointGuid
        if ($alias1ByVidPid.ContainsKey($vidPidKey)) { $device.Alias1 = $alias1ByVidPid[$vidPidKey] }
        if ($alias2ByInstanceId.ContainsKey($id)) { $device.Alias2 = $alias2ByInstanceId[$id] }
        if ($alias3ByContainerId.ContainsKey($containerKey)) { $device.Alias3 = $alias3ByContainerId[$containerKey] }
        if ($alias4ByEndpointGuid.ContainsKey($endpointGuidKey)) { $device.Alias4 = $alias4ByEndpointGuid[$endpointGuidKey] }
        if ($micFlags.ContainsKey($id)) { $device.IsMicrophone = [bool]$micFlags[$id] }
    }
}

function Set-DeviceRecordEditsById {
    <# Applies one edited field set to every in-memory device record with the matching InstanceId. #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Devices,
        [Parameter(Mandatory=$true)][string]$InstanceId,
        [Parameter(Mandatory=$true)][hashtable]$Edits
    )

    $id = Normalize-DeviceId $InstanceId
    if ([string]::IsNullOrWhiteSpace($id)) { return }

    foreach ($device in $Devices) {
        if ((Normalize-DeviceId (ConvertTo-PlainString $device.InstanceId)) -ne $id) { continue }
        if ($Edits.ContainsKey('Alias2')) { $device.Alias2 = ConvertTo-PlainString $Edits['Alias2'] }
        if ($Edits.ContainsKey('IsMicrophone')) { $device.IsMicrophone = [bool]$Edits['IsMicrophone'] }
    }
}

function Set-DeviceRecordEditsByVidPid {
    <# Applies model-level edits to all in-memory records sharing the same VID and PID. #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Devices,
        [Parameter(Mandatory=$true)][string]$VidPidKey,
        [Parameter(Mandatory=$true)][hashtable]$Edits
    )

    if ([string]::IsNullOrWhiteSpace($VidPidKey)) { return }
    foreach ($device in $Devices) {
        $deviceKey = Get-VidPidAliasKey -VID $device.VID -PID $device.PID
        if ($deviceKey -ne $VidPidKey) { continue }
        if ($Edits.ContainsKey('Alias1')) { $device.Alias1 = ConvertTo-PlainString $Edits['Alias1'] }
    }
}

function Set-DeviceRecordAliasByIdentity {
    <# Applies one alias to all records sharing a normalized ContainerId or Endpoint GUID. #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Devices,
        [Parameter(Mandatory=$true)][ValidateSet('ContainerId','EndpointGuid')][string]$IdentityProperty,
        [Parameter(Mandatory=$true)][string]$IdentityValue,
        [Parameter(Mandatory=$true)][ValidateSet('Alias3','Alias4')][string]$AliasProperty,
        [string]$Value = ''
    )

    $key = Normalize-DeviceId $IdentityValue
    if ([string]::IsNullOrWhiteSpace($key)) { return }
    foreach ($device in $Devices) {
        $deviceKey = Normalize-DeviceId (ConvertTo-PlainString (Get-ObjectPropertyValue -Object $device -Name $IdentityProperty -Default ''))
        if ($deviceKey -eq $key) {
            $device.$AliasProperty = ConvertTo-PlainString $Value
        }
    }
}

function Convert-DeviceStatusToDisplayState {
    <# Converts raw endpoint status text to a short user-facing state. #>
    param([string]$Status)

    if ([string]::IsNullOrWhiteSpace($Status)) { return 'Unknown' }
    if ($Status -match 'ACTIVE|OK') { return 'Active' }
    if ($Status -match 'NOTPRESENT|UNPLUGGED|Disconnected|Missing') { return 'Disconnected' }
    if ($Status -match 'DISABLED') { return 'Disabled' }
    if ($Status -match 'Error|Problem|Failed|Degraded') { return 'Problem' }
    return $Status
}

function Set-GridStatusColors {
    <# Applies status and signal colors to DataGridView rows. #>
    param(
        [Parameter(Mandatory=$true)][System.Windows.Forms.DataGridView]$Grid,
        [bool]$MeterEnabled = $false
    )

    foreach ($row in $Grid.Rows) {
        if ($row.IsNewRow) { continue }
        Set-GridRowBaseStyle -Row $row
        if ($Grid.Columns.Contains('Level')) {
            Set-LevelCellStyle -Row $row -MeterEnabled $MeterEnabled
        }
    }
}

function Set-GridRowBaseStyle {
    <# Applies the non-meter status color to one DataGridView row. #>
    param([Parameter(Mandatory=$true)][System.Windows.Forms.DataGridViewRow]$Row)

    $status = ''
    if ($Row.Cells['State'].Value) { $status = [string]$Row.Cells['State'].Value }

    $Row.DefaultCellStyle.BackColor = [System.Drawing.Color]::White
    $Row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
    if ($status -match 'Problem') {
        $Row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(254, 202, 202)
        $Row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(127, 29, 29)
    }
    elseif ($status -match 'Disabled') {
        $Row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(254, 240, 138)
        $Row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(113, 63, 18)
    }
    elseif ($status -match 'Disconnected') {
        $Row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
        $Row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
    }
    elseif ($status -match 'Active') {
        $Row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(187, 247, 208)
        $Row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(20, 83, 45)
    }
    elseif ($status -match 'Unknown') {
        $Row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
        $Row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
    }
    $Row.Cells['State'].Style.Font = New-Object System.Drawing.Font($Row.DataGridView.Font, [System.Drawing.FontStyle]::Bold)
}

function Set-LevelCellStyle {
    <# Applies the meter color to only one row's Level cell. #>
    param(
        [Parameter(Mandatory=$true)][System.Windows.Forms.DataGridViewRow]$Row,
        [bool]$MeterEnabled = $false
    )

    $levelText = ''
    if ($Row.Cells['Level'].Value) { $levelText = [string]$Row.Cells['Level'].Value }

    if (-not $MeterEnabled) {
        $Row.Cells['Level'].Style.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
        return
    }

    $percent = 0
    if ($levelText -match '^(\d+)') {
        $percent = [Math]::Max(0, [Math]::Min(100, [int]$matches[1]))
    }

    $baseColor = $Row.DefaultCellStyle.BackColor
    $meterColor = [System.Drawing.Color]::FromArgb(34, 197, 94)
    $ratio = $percent / 100.0
    $red = [int][Math]::Round($baseColor.R + (($meterColor.R - $baseColor.R) * $ratio))
    $green = [int][Math]::Round($baseColor.G + (($meterColor.G - $baseColor.G) * $ratio))
    $blue = [int][Math]::Round($baseColor.B + (($meterColor.B - $baseColor.B) * $ratio))
    $Row.Cells['Level'].Style.BackColor = [System.Drawing.Color]::FromArgb($red, $green, $blue)
}

function Set-DeviceFilter {
    <# Applies a case-insensitive filter over major visible columns. #>
    param(
        [Parameter(Mandatory=$true)][System.Data.DataView]$View,
        [string]$FilterText,
        [bool]$OnlyMicrophones = $false
    )

    $filters = @()
    if ($OnlyMicrophones) {
        $filters += '[IsMicrophone] = true'
    }

    if ([string]::IsNullOrWhiteSpace($FilterText)) {
        $View.RowFilter = ($filters -join ' AND ')
        return
    }

    $safe = $FilterText.Replace("'", "''")
    $parts = @()
    foreach ($column in @('State','Alias1','Alias2','Alias3','Alias4','FriendlyName','VID','PID','InstanceId','ContainerId','EndpointGuid','UsbPort','Location','Driver','Status','APO','Processing')) {
        $parts += "CONVERT([$column], 'System.String') LIKE '%$safe%'"
    }
    $filters += '(' + ($parts -join ' OR ') + ')'
    $View.RowFilter = ($filters -join ' AND ')
}

function Export-GridToCsv {
    <# Exports the current table to a CSV file chosen by the user. #>
    param(
        [Parameter(Mandatory=$true)][System.Data.DataTable]$Table,
        [scriptblock]$Logger
    )

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
    $dialog.FileName = 'usb-microphones.csv'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $Table | Export-Csv -LiteralPath $dialog.FileName -NoTypeInformation -Encoding UTF8
            Write-AppLog -Message ("Exported CSV: {0}" -f $dialog.FileName) -Level INFO -Logger $Logger
        }
        catch {
            Write-AppLog -Message ("CSV export failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $Logger
        }
    }
}

function Get-SelectedGridValue {
    <# Gets a named cell value from the selected row. #>
    param(
        [Parameter(Mandatory=$true)][System.Windows.Forms.DataGridView]$Grid,
        [Parameter(Mandatory=$true)][string]$ColumnName
    )

    if ($Grid.SelectedRows.Count -eq 0) { return '' }
    return ConvertTo-PlainString $Grid.SelectedRows[0].Cells[$ColumnName].Value
}

function Commit-DeviceGridEdits {
    <# Forces pending DataGridView edits, especially checkbox edits, into the bound DataTable. #>
    param([Parameter(Mandatory=$true)][System.Windows.Forms.DataGridView]$Grid)

    if ($null -eq $Grid -or $Grid.IsDisposed) { return }

    try {
        if ($Grid.IsCurrentCellDirty) {
            [void]$Grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
        [void]$Grid.EndEdit()
        if ($Grid.DataSource) {
            $manager = $Grid.BindingContext[$Grid.DataSource]
            if ($manager) { [void]$manager.EndCurrentEdit() }
        }
    }
    catch {
        throw
    }
}

function Get-AudioEndpointStateSignature {
    <# Builds a compact signature of capture endpoint IDs and states for polling change detection. #>
    param([scriptblock]$Logger)

    $endpoints = @(Get-CaptureAudioEndpointsFromRegistry -Logger $Logger -Quiet)
    $parts = @()
    foreach ($endpoint in ($endpoints | Sort-Object Id)) {
        $parts += ('{0}|{1}|{2}' -f `
            (ConvertTo-PlainString $endpoint.Id), `
            (ConvertTo-PlainString $endpoint.State), `
            (ConvertTo-PlainString (Get-ObjectPropertyValue -Object $endpoint -Name 'PnpInstanceId' -Default '')))
    }
    $parts += ('DEFAULT|{0}' -f (Get-DefaultCaptureAudioEndpointId -Logger $Logger -Quiet))
    $parts += ('COMM|{0}' -f (Get-DefaultCommunicationsCaptureAudioEndpointId -Logger $Logger -Quiet))
    return ($parts -join "`n")
}

function New-ApoPluginDataTable {
    <# Creates a DataTable for Equalizer APO VST plugin state editing. #>
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Entries)

    $table = New-Object System.Data.DataTable
    [void]$table.Columns.Add('Enabled', [bool])
    foreach ($name in @('Plugin','Line')) {
        [void]$table.Columns.Add($name, [string])
    }

    foreach ($entry in $Entries) {
        $row = $table.NewRow()
        $row['Enabled'] = [bool]$entry.Enabled
        $row['Plugin'] = ConvertTo-PlainString $entry.Name
        $row['Line'] = ConvertTo-PlainString $entry.EffectiveLine
        [void]$table.Rows.Add($row)
    }
    return ,$table
}

function Add-ApoPluginGridColumns {
    <# Adds columns to the Equalizer APO VST plugin grid. #>
    param([Parameter(Mandatory=$true)][System.Windows.Forms.DataGridView]$Grid)

    Add-GridCheckBoxColumn -Grid $Grid -Name 'Enabled' -Header 'On' -ReadOnly $false -Width 42
    Add-GridColumn -Grid $Grid -Name 'Plugin' -Header 'Plugin' -Width 145
    Add-GridColumn -Grid $Grid -Name 'Line' -Header 'APO command' -Width 260
}

function Start-USBMicrophoneManagerGui {
    <# Starts the Windows Forms application and wires discovery, watcher, persistence, filtering, and metering together. #>
    param([Parameter(Mandatory=$true)][string]$ProjectRoot)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Data
    [System.Windows.Forms.Application]::EnableVisualStyles()
    try {
        [System.Windows.Forms.Application]::SetUnhandledExceptionMode(
            [System.Windows.Forms.UnhandledExceptionMode]::CatchException
        )
    }
    catch [System.InvalidOperationException] {
        # A reused PowerShell session may already have created WinForms controls.
    }

    $state = @{
        ProjectRoot = $ProjectRoot
        Devices = @()
        Table = $null
        View = $null
        ActiveTable = $null
        InactiveTable = $null
        ActiveView = $null
        InactiveView = $null
        CurrentGrid = $null
        OnlyMicrophones = $false
        RefreshPending = $false
        TestMode = $false
        MeterEnabled = $false
        LastLoudestId = ''
        LastTimerError = ''
        LastTimerErrorAt = [datetime]::MinValue
        LastEndpointSignature = ''
        ApoInfo = $null
        ApoScanEnabled = $false
        ApoPresets = @()
        PendingMicFlags = @{}
        PendingAlias1ByVidPid = @{}
        PendingAlias2ByInstanceId = @{}
        PendingAlias3ByContainerId = @{}
        PendingAlias4ByEndpointGuid = @{}
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'USB Microphone Manager'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(1280, 780)
    $form.MinimumSize = New-Object System.Drawing.Size(980, 620)
    $form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
    $form.Font = New-Object System.Drawing.Font('Segoe UI Emoji', 9)

    $main = New-Object System.Windows.Forms.TableLayoutPanel
    $main.Dock = 'Fill'
    $main.RowCount = 4
    $main.ColumnCount = 1
    $main.Padding = New-Object System.Windows.Forms.Padding(10)
    $toolbarRowStyle = New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 46)
    [void]$main.RowStyles.Add($toolbarRowStyle)
    [void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 38)))
    [void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 140)))

    $rootSplit = New-Object System.Windows.Forms.SplitContainer
    $rootSplit.Dock = 'Fill'
    $rootSplit.Orientation = [System.Windows.Forms.Orientation]::Vertical
    $rootSplit.Panel1MinSize = 1
    $rootSplit.Panel2MinSize = 1
    $form.Controls.Add($rootSplit)
    $rootSplit.Panel1.Controls.Add($main)

    $toolbar = New-Object System.Windows.Forms.FlowLayoutPanel
    $toolbar.Dock = 'Fill'
    $toolbar.WrapContents = $true
    $toolbar.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight

    $btnSave = New-ToolbarButton -Text 'Save' -Icon ([char]::ConvertFromUtf32(0x1F4BE))
    $btnRefresh = New-ToolbarButton -Text 'Refresh' -Icon ([char]::ConvertFromUtf32(0x1F504))
    $btnExport = New-ToolbarButton -Text 'Export CSV' -Icon ([char]::ConvertFromUtf32(0x1F4C4))
    $btnDeviceManager = New-ToolbarButton -Text 'Devices' -Icon ([char]0x2699)
    $btnSound = New-ToolbarButton -Text 'Settings' -Icon ([char]::ConvertFromUtf32(0x1F50A))
    $btnApo = New-ToolbarButton -Text 'Scan APO' -Icon ([char]::ConvertFromUtf32(0x1F50D))
    $btnMixer = New-ToolbarButton -Text 'Mixer' -Icon ([char]::ConvertFromUtf32(0x1F39A))
    $btnMeter = New-ToolbarButton -Text 'Meter Off' -Icon ([char]::ConvertFromUtf32(0x1F4CA))
    $btnTest = New-ToolbarButton -Text 'Test' -Icon ([char]0x25B6)

    foreach ($button in @($btnSave,$btnRefresh,$btnExport,$btnDeviceManager,$btnSound,$btnApo,$btnMixer,$btnMeter,$btnTest)) {
        [void]$toolbar.Controls.Add($button)
    }
    $main.Controls.Add($toolbar, 0, 0)

    $updateToolbarLayout = {
        <# Wraps toolbar buttons and reserves enough height for every resulting row. #>
        $availableWidth = $rootSplit.Panel1.ClientSize.Width - $main.Padding.Horizontal
        if ($availableWidth -le 0 -or $toolbar.Controls.Count -eq 0) { return }

        $rowCount = 1
        $usedWidth = 0
        $rowHeight = 42
        foreach ($control in $toolbar.Controls) {
            $controlWidth = $control.PreferredSize.Width + $control.Margin.Horizontal
            $controlHeight = $control.PreferredSize.Height + $control.Margin.Vertical
            if ($controlHeight -gt $rowHeight) { $rowHeight = $controlHeight }

            if ($usedWidth -gt 0 -and ($usedWidth + $controlWidth) -gt $availableWidth) {
                $rowCount++
                $usedWidth = 0
            }
            $usedWidth += $controlWidth
        }

        $requiredHeight = [Math]::Max(46, ($rowCount * $rowHeight) + 4)
        if ([Math]::Abs($toolbarRowStyle.Height - $requiredHeight) -gt 0.5) {
            $toolbarRowStyle.Height = $requiredHeight
            $main.PerformLayout()
        }
    }
    $rootSplit.Panel1.Add_Resize({ & $updateToolbarLayout })

    $filterPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $filterPanel.Dock = 'Fill'
    $filterPanel.ColumnCount = 4
    [void]$filterPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 60)))
    [void]$filterPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$filterPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 150)))
    [void]$filterPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 170)))
    $lblFilter = New-Object System.Windows.Forms.Label
    $lblFilter.Text = 'Filter'
    $lblFilter.Dock = 'Fill'
    $lblFilter.TextAlign = 'MiddleLeft'
    $txtFilter = New-Object System.Windows.Forms.TextBox
    $txtFilter.Dock = 'Fill'
    $txtFilter.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $chkOnlyMicrophones = New-Object System.Windows.Forms.CheckBox
    $chkOnlyMicrophones.Text = 'Only microphones'
    $chkOnlyMicrophones.Dock = 'Fill'
    $chkOnlyMicrophones.TextAlign = 'MiddleLeft'
    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Dock = 'Fill'
    $lblCount.TextAlign = 'MiddleRight'
    $filterPanel.Controls.Add($lblFilter, 0, 0)
    $filterPanel.Controls.Add($txtFilter, 1, 0)
    $filterPanel.Controls.Add($chkOnlyMicrophones, 2, 0)
    $filterPanel.Controls.Add($lblCount, 3, 0)
    $main.Controls.Add($filterPanel, 0, 1)

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'
    $split.Orientation = [System.Windows.Forms.Orientation]::Horizontal
    $split.SplitterDistance = 285
    $split.Panel1MinSize = 150
    $split.Panel2MinSize = 150

    $activePanel = New-Object System.Windows.Forms.TableLayoutPanel
    $activePanel.Dock = 'Fill'
    $activePanel.RowCount = 2
    $activePanel.ColumnCount = 1
    [void]$activePanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 28)))
    [void]$activePanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $lblActive = New-Object System.Windows.Forms.Label
    $lblActive.Text = 'Active devices'
    $lblActive.Dock = 'Fill'
    $lblActive.TextAlign = 'MiddleLeft'
    $lblActive.Font = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Bold)
    $activeGrid = New-Object System.Windows.Forms.DataGridView
    Configure-DeviceGrid -Grid $activeGrid
    Add-DeviceGridColumns -Grid $activeGrid -IncludeLastActive $false
    $activePanel.Controls.Add($lblActive, 0, 0)
    $activePanel.Controls.Add($activeGrid, 0, 1)

    $inactivePanel = New-Object System.Windows.Forms.TableLayoutPanel
    $inactivePanel.Dock = 'Fill'
    $inactivePanel.RowCount = 2
    $inactivePanel.ColumnCount = 1
    [void]$inactivePanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 28)))
    [void]$inactivePanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $lblInactive = New-Object System.Windows.Forms.Label
    $lblInactive.Text = 'Inactive devices'
    $lblInactive.Dock = 'Fill'
    $lblInactive.TextAlign = 'MiddleLeft'
    $lblInactive.Font = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Bold)
    $inactiveGrid = New-Object System.Windows.Forms.DataGridView
    Configure-DeviceGrid -Grid $inactiveGrid
    Add-DeviceGridColumns -Grid $inactiveGrid -IncludeLevel $false -IncludeLastActive $true
    $inactivePanel.Controls.Add($lblInactive, 0, 0)
    $inactivePanel.Controls.Add($inactiveGrid, 0, 1)

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miCopyInstance = $menu.Items.Add('Copy InstanceId')
    $miCopyEndpoint = $menu.Items.Add('Copy Endpoint GUID')
    $miCopyRow = $menu.Items.Add('Copy Row')
    $activeGrid.ContextMenuStrip = $menu
    $inactiveGrid.ContextMenuStrip = $menu
    $state.CurrentGrid = $activeGrid
    $activeGrid.Add_Enter({ $state.CurrentGrid = $activeGrid })
    $inactiveGrid.Add_Enter({ $state.CurrentGrid = $inactiveGrid })
    $activeGrid.Add_MouseDown({ $state.CurrentGrid = $activeGrid })
    $inactiveGrid.Add_MouseDown({ $state.CurrentGrid = $inactiveGrid })
    $split.Panel1.Controls.Add($activePanel)
    $split.Panel2.Controls.Add($inactivePanel)
    $main.Controls.Add($split, 0, 2)

    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Dock = 'Fill'
    $txtLog.Multiline = $true
    $txtLog.ScrollBars = 'Vertical'
    $txtLog.ReadOnly = $true
    $txtLog.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $txtLog.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    $txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
    $main.Controls.Add($txtLog, 0, 3)

    $apoPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $apoPanel.Dock = 'Fill'
    $apoPanel.Padding = New-Object System.Windows.Forms.Padding(10)
    $apoPanel.RowCount = 8
    $apoPanel.ColumnCount = 1
    [void]$apoPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30)))
    [void]$apoPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 54)))
    [void]$apoPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 48)))
    [void]$apoPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 24)))
    [void]$apoPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 32)))
    [void]$apoPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30)))
    [void]$apoPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 74)))
    [void]$apoPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 20)))
    $apoPanel.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
    $rootSplit.Panel2.Controls.Add($apoPanel)

    $lblApoTitle = New-Object System.Windows.Forms.Label
    $lblApoTitle.Text = 'Equalizer APO / VST'
    $lblApoTitle.Dock = 'Fill'
    $lblApoTitle.Font = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Bold)
    $lblApoTitle.TextAlign = 'MiddleLeft'
    $apoPanel.Controls.Add($lblApoTitle, 0, 0)

    $lblApoStatus = New-Object System.Windows.Forms.Label
    $lblApoStatus.Text = 'APO not scanned yet.'
    $lblApoStatus.Dock = 'Fill'
    $lblApoStatus.AutoEllipsis = $true
    $lblApoStatus.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
    $apoPanel.Controls.Add($lblApoStatus, 0, 1)

    $apoPluginGrid = New-Object System.Windows.Forms.DataGridView
    Configure-DeviceGrid -Grid $apoPluginGrid
    $apoPluginGrid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    Add-ApoPluginGridColumns -Grid $apoPluginGrid
    $apoPanel.Controls.Add($apoPluginGrid, 0, 2)

    $lblApoPresets = New-Object System.Windows.Forms.Label
    $lblApoPresets.Text = 'Saved configurations'
    $lblApoPresets.Dock = 'Fill'
    $lblApoPresets.TextAlign = 'MiddleLeft'
    $lblApoPresets.Font = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Bold)
    $apoPanel.Controls.Add($lblApoPresets, 0, 3)

    $lstApoPresets = New-Object System.Windows.Forms.ListBox
    $lstApoPresets.Dock = 'Fill'
    $lstApoPresets.IntegralHeight = $false
    $lstApoPresets.BackColor = [System.Drawing.Color]::White
    $apoPanel.Controls.Add($lstApoPresets, 0, 4)

    $txtApoPresetName = New-Object System.Windows.Forms.TextBox
    $txtApoPresetName.Dock = 'Fill'
    $txtApoPresetName.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $apoPanel.Controls.Add($txtApoPresetName, 0, 5)

    $apoButtons = New-Object System.Windows.Forms.FlowLayoutPanel
    $apoButtons.Dock = 'Fill'
    $apoButtons.WrapContents = $true
    $btnApoRefreshPanel = New-ToolbarButton -Text 'Refresh APO' -Icon ([char]::ConvertFromUtf32(0x1F504))
    $btnApoSnapshot = New-ToolbarButton -Text 'Save Snapshot' -Icon ([char]::ConvertFromUtf32(0x1F4BE))
    $btnApoApplyPreset = New-ToolbarButton -Text 'Apply Preset' -Icon ([char]::ConvertFromUtf32(0x1F4C2))
    $btnApoApplyToggles = New-ToolbarButton -Text 'Apply Toggles' -Icon ([char]0x2714)
    foreach ($button in @($btnApoRefreshPanel,$btnApoSnapshot,$btnApoApplyPreset,$btnApoApplyToggles)) {
        [void]$apoButtons.Controls.Add($button)
    }
    $apoPanel.Controls.Add($apoButtons, 0, 6)

    $txtApoPreview = New-Object System.Windows.Forms.TextBox
    $txtApoPreview.Dock = 'Fill'
    $txtApoPreview.Multiline = $true
    $txtApoPreview.ScrollBars = 'Vertical'
    $txtApoPreview.ReadOnly = $true
    $txtApoPreview.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
    $txtApoPreview.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $txtApoPreview.Font = New-Object System.Drawing.Font('Consolas', 8)
    $apoPanel.Controls.Add($txtApoPreview, 0, 7)

    $logger = {
        param([string]$Message, [string]$Level)
        $line = "[{0}] [{1}] {2}{3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message, [Environment]::NewLine
        if ($txtLog.InvokeRequired) {
            [void]$txtLog.BeginInvoke([Action[string]]{ param($text) $txtLog.AppendText($text) }, $line)
        }
        else {
            $txtLog.AppendText($line)
        }
    }

    $configureRootSplit = {
        <# Sets the right APO panel width after the SplitContainer has a real client size. #>
        try {
            if ($rootSplit.Width -lt 900) { return }
            $rootSplit.Panel1MinSize = 620
            $rootSplit.Panel2MinSize = 240
            $targetRightWidth = 340
            $distance = $rootSplit.Width - $targetRightWidth
            if ($distance -lt $rootSplit.Panel1MinSize) { $distance = $rootSplit.Panel1MinSize }
            $maxDistance = $rootSplit.Width - $rootSplit.Panel2MinSize
            if ($distance -gt $maxDistance) { $distance = $maxDistance }
            if ($distance -gt 0) { $rootSplit.SplitterDistance = $distance }
        }
        catch {
            Write-AppLog -Message ("APO panel layout failed: {0}" -f $_.Exception.Message) -Level WARN -Logger $logger
        }
    }

    [System.Windows.Forms.Application]::add_ThreadException({
        param($sender, $eventArgs)
        $message = 'Unhandled UI error'
        if ($eventArgs -and $eventArgs.Exception) {
            $message = "{0}: {1}" -f $message, $eventArgs.Exception.Message
        }
        Write-AppLog -Message $message -Level ERROR -Logger $logger
    })

    $rememberDeviceGridEdit = {
        param(
            [System.Windows.Forms.DataGridView]$Grid,
            [int]$RowIndex,
            [int]$ColumnIndex
        )

        if ($RowIndex -lt 0 -or $ColumnIndex -lt 0) { return }
        if ($null -eq $Grid -or $Grid.IsDisposed) { return }
        if ($RowIndex -ge $Grid.Rows.Count -or $ColumnIndex -ge $Grid.Columns.Count) { return }

        $row = $Grid.Rows[$RowIndex]
        if ($row.IsNewRow) { return }
        $columnName = $Grid.Columns[$ColumnIndex].Name
        if ($columnName -notin @('IsMicrophone','Alias1','Alias2','Alias3','Alias4')) { return }

        $id = Normalize-DeviceId (ConvertTo-PlainString $row.Cells['InstanceId'].Value)
        $vidPidKey = Get-VidPidAliasKey `
            -VID (ConvertTo-PlainString $row.Cells['VID'].Value) `
            -PID (ConvertTo-PlainString $row.Cells['PID'].Value)
        $containerKey = Normalize-DeviceId (ConvertTo-PlainString $row.Cells['ContainerId'].Value)
        $endpointGuidKey = Normalize-DeviceId (ConvertTo-PlainString $row.Cells['EndpointGuid'].Value)

        if ($columnName -eq 'IsMicrophone' -and -not [string]::IsNullOrWhiteSpace($id)) {
            $value = [bool]$row.Cells['IsMicrophone'].Value
            $state.PendingMicFlags[$id] = $value
            Set-DeviceRecordEditsById -Devices $state.Devices -InstanceId $id -Edits @{ IsMicrophone = $value }
            Set-AudioMixerInputsRefreshPending
        }
        elseif ($columnName -eq 'Alias1' -and -not [string]::IsNullOrWhiteSpace($vidPidKey)) {
            $value = ConvertTo-PlainString $row.Cells['Alias1'].Value
            $state.PendingAlias1ByVidPid[$vidPidKey] = $value
            Set-DeviceRecordEditsByVidPid -Devices $state.Devices -VidPidKey $vidPidKey -Edits @{ Alias1 = $value }
        }
        elseif ($columnName -eq 'Alias2' -and -not [string]::IsNullOrWhiteSpace($id)) {
            $value = ConvertTo-PlainString $row.Cells['Alias2'].Value
            $state.PendingAlias2ByInstanceId[$id] = $value
            Set-DeviceRecordEditsById -Devices $state.Devices -InstanceId $id -Edits @{ Alias2 = $value }
        }
        elseif ($columnName -eq 'Alias3' -and -not [string]::IsNullOrWhiteSpace($containerKey)) {
            $value = ConvertTo-PlainString $row.Cells['Alias3'].Value
            $state.PendingAlias3ByContainerId[$containerKey] = $value
            Set-DeviceRecordAliasByIdentity -Devices $state.Devices -IdentityProperty 'ContainerId' -IdentityValue $containerKey -AliasProperty 'Alias3' -Value $value
        }
        elseif ($columnName -eq 'Alias4' -and -not [string]::IsNullOrWhiteSpace($endpointGuidKey)) {
            $value = ConvertTo-PlainString $row.Cells['Alias4'].Value
            $state.PendingAlias4ByEndpointGuid[$endpointGuidKey] = $value
            Set-DeviceRecordAliasByIdentity -Devices $state.Devices -IdentityProperty 'EndpointGuid' -IdentityValue $endpointGuidKey -AliasProperty 'Alias4' -Value $value
        }
    }

    $applyPendingDeviceGridEdits = {
        foreach ($id in @($state.PendingMicFlags.Keys)) {
            Set-DeviceRecordEditsById -Devices $state.Devices -InstanceId $id -Edits @{ IsMicrophone = [bool]$state.PendingMicFlags[$id] }
        }
        foreach ($vidPidKey in @($state.PendingAlias1ByVidPid.Keys)) {
            Set-DeviceRecordEditsByVidPid -Devices $state.Devices -VidPidKey $vidPidKey -Edits @{ Alias1 = (ConvertTo-PlainString $state.PendingAlias1ByVidPid[$vidPidKey]) }
        }
        foreach ($id in @($state.PendingAlias2ByInstanceId.Keys)) {
            Set-DeviceRecordEditsById -Devices $state.Devices -InstanceId $id -Edits @{ Alias2 = (ConvertTo-PlainString $state.PendingAlias2ByInstanceId[$id]) }
        }
        foreach ($containerKey in @($state.PendingAlias3ByContainerId.Keys)) {
            Set-DeviceRecordAliasByIdentity -Devices $state.Devices -IdentityProperty 'ContainerId' -IdentityValue $containerKey -AliasProperty 'Alias3' -Value (ConvertTo-PlainString $state.PendingAlias3ByContainerId[$containerKey])
        }
        foreach ($endpointGuidKey in @($state.PendingAlias4ByEndpointGuid.Keys)) {
            Set-DeviceRecordAliasByIdentity -Devices $state.Devices -IdentityProperty 'EndpointGuid' -IdentityValue $endpointGuidKey -AliasProperty 'Alias4' -Value (ConvertTo-PlainString $state.PendingAlias4ByEndpointGuid[$endpointGuidKey])
        }
    }

    $refreshGrid = {
        param([bool]$Rediscover)

        if ($Rediscover) {
            Commit-DeviceGridEdits -Grid $activeGrid
            Commit-DeviceGridEdits -Grid $inactiveGrid
            if ($state.ActiveTable -is [System.Data.DataTable]) {
                Sync-GridEditsToDevices -Table $state.ActiveTable -Devices $state.Devices
            }
            if ($state.InactiveTable -is [System.Data.DataTable]) {
                Sync-GridEditsToDevices -Table $state.InactiveTable -Devices $state.Devices
            }
            & $applyPendingDeviceGridEdits
            $previousMixerSignature = Get-AudioMixerDeviceSignature -Devices $state.Devices
            if ($state.Devices -and $state.Devices.Count -gt 0) {
                [void](Save-DeviceStateForDevices -ProjectRoot $state.ProjectRoot -Devices $state.Devices -Logger $logger)
            }
            $state.Devices = @(Get-UsbMicrophoneInventory -ProjectRoot $state.ProjectRoot -Logger $logger)
            & $applyPendingDeviceGridEdits
            $currentMixerSignature = Get-AudioMixerDeviceSignature -Devices $state.Devices
            if ($currentMixerSignature -ne $previousMixerSignature) {
                Set-AudioMixerInputsRefreshPending
            }
        }

        if ($state.ApoScanEnabled -and $state.ApoInfo) {
            $state.Devices = @(Apply-EqualizerApoInfoToDevices -Devices $state.Devices -ApoInfo $state.ApoInfo)
        }

        $state.Table = Convert-DevicesToDataTable -Devices $state.Devices
        $activeDevices = @($state.Devices | Where-Object { Test-DeviceRecordIsActive -Device $_ })
        $inactiveDevices = @($state.Devices | Where-Object { -not (Test-DeviceRecordIsActive -Device $_) })
        $state.ActiveTable = Convert-DevicesToDataTable -Devices $activeDevices
        $state.InactiveTable = Convert-DevicesToDataTable -Devices $inactiveDevices
        $state.ActiveView = New-Object System.Data.DataView -ArgumentList (,$state.ActiveTable)
        $state.InactiveView = New-Object System.Data.DataView -ArgumentList (,$state.InactiveTable)
        $activeGrid.DataSource = $state.ActiveView
        $inactiveGrid.DataSource = $state.InactiveView
        Set-DeviceFilter -View $state.ActiveView -FilterText $txtFilter.Text -OnlyMicrophones $state.OnlyMicrophones
        Set-DeviceFilter -View $state.InactiveView -FilterText $txtFilter.Text -OnlyMicrophones $state.OnlyMicrophones
        $lblActive.Text = ("Active devices ({0})" -f $activeDevices.Count)
        $lblInactive.Text = ("Inactive devices ({0})" -f $inactiveDevices.Count)
        $lblCount.Text = ("{0} total" -f $state.Devices.Count)
        Set-GridStatusColors -Grid $activeGrid -MeterEnabled $state.MeterEnabled
        Set-GridStatusColors -Grid $inactiveGrid -MeterEnabled $state.MeterEnabled
    }

    $setApoPanelAvailable = {
        param([bool]$Available)

        foreach ($control in @($apoPluginGrid,$lstApoPresets,$txtApoPresetName,$btnApoSnapshot,$btnApoApplyPreset,$btnApoApplyToggles)) {
            $control.Enabled = $Available
        }
    }

    $refreshApoPreview = {
        $txtApoPreview.Clear()
        if ($lstApoPresets.SelectedItem) {
            $presetName = ConvertTo-PlainString $lstApoPresets.SelectedItem
            $preset = $null
            foreach ($candidate in @($state.ApoPresets)) {
                if ((ConvertTo-PlainString $candidate.Name) -eq $presetName) {
                    $preset = $candidate
                    break
                }
            }
            if ($preset) {
                $lines = New-Object System.Collections.Generic.List[string]
                $lines.Add(("Preset: {0}" -f (Get-ObjectPropertyValue -Object $preset -Name 'Name' -Default $presetName)))
                $lines.Add(("Saved:  {0}" -f (Get-ObjectPropertyValue -Object $preset -Name 'CreatedAt' -Default '')))
                foreach ($plugin in @(Get-ObjectPropertyValue -Object $preset -Name 'Plugins' -Default @())) {
                    $enabled = [bool](Get-ObjectPropertyValue -Object $plugin -Name 'Enabled' -Default $false)
                    $pluginName = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $plugin -Name 'Name' -Default '')
                    $pluginLine = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $plugin -Name 'Line' -Default '')
                    $prefix = if ($enabled) { '[on] ' } else { '[off]' }
                    $lines.Add(("{0} {1}" -f $prefix, $pluginName))
                    if ($enabled) {
                        foreach ($parameter in @(Get-EqualizerApoVstParameterSummary -Line $pluginLine)) {
                            $lines.Add(("      {0}" -f $parameter))
                        }
                    }
                }
                $txtApoPreview.Text = ($lines.ToArray() -join [Environment]::NewLine)
            }
        }
    }

    $refreshApoPanel = {
        param([bool]$UpdateDeviceGrid)

        try {
            $state.ApoInfo = Get-EqualizerApoConfigInfo -Logger $logger
            $state.ApoScanEnabled = $true
            $entries = @(Get-EqualizerApoVstEntries -Logger $logger)
            $state.ApoPresets = @(Read-EqualizerApoPresets -ProjectRoot $state.ProjectRoot -Logger $logger)

            $apoPluginTable = New-ApoPluginDataTable -Entries $entries
            $apoPluginGrid.DataSource = $apoPluginTable
            foreach ($column in $apoPluginGrid.Columns) {
                if ($column.Name -eq 'Line') { $column.ReadOnly = $true }
                if ($column.Name -eq 'Plugin') { $column.ReadOnly = $true }
            }

            $lstApoPresets.Items.Clear()
            foreach ($preset in @($state.ApoPresets | Sort-Object Name)) {
                $presetName = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $preset -Name 'Name' -Default '')
                if (-not [string]::IsNullOrWhiteSpace($presetName)) {
                    [void]$lstApoPresets.Items.Add($presetName)
                }
            }

            $endpointCount = 0
            if ($state.ApoInfo -and $state.ApoInfo.InstalledEndpointGuids) {
                $endpointCount = @($state.ApoInfo.InstalledEndpointGuids).Count
            }
            $available = ($state.ApoInfo -and $state.ApoInfo.Installed -and $endpointCount -gt 0)
            & $setApoPanelAvailable $available

            if (-not $state.ApoInfo -or -not $state.ApoInfo.Installed) {
                $lblApoStatus.Text = 'Equalizer APO config.txt was not found.'
            }
            elseif ($endpointCount -eq 0) {
                $lblApoStatus.Text = 'APO found, but no APO-enabled audio endpoint was detected.'
            }
            else {
                $lblApoStatus.Text = ("APO endpoints: {0}; VST entries: {1}; presets: {2}" -f $endpointCount, $entries.Count, @($state.ApoPresets).Count)
            }

            & $refreshApoPreview
            if ($UpdateDeviceGrid) {
                $state.Devices = @(Apply-EqualizerApoInfoToDevices -Devices $state.Devices -ApoInfo $state.ApoInfo)
                & $refreshGrid $false
            }
        }
        catch {
            & $setApoPanelAvailable $false
            Write-AppLog -Message ("APO panel refresh failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $logger
        }
    }

    $getSelectedApoPreset = {
        if (-not $lstApoPresets.SelectedItem) { return $null }
        $name = ConvertTo-PlainString $lstApoPresets.SelectedItem
        foreach ($preset in @($state.ApoPresets)) {
            if ((ConvertTo-PlainString (Get-ObjectPropertyValue -Object $preset -Name 'Name' -Default '')) -eq $name) { return $preset }
        }
        return $null
    }

    $getSelectedGrid = {
        if ($state.CurrentGrid -is [System.Windows.Forms.DataGridView]) { return $state.CurrentGrid }
        return $activeGrid
    }

    $copyValue = {
        param([string]$ColumnName)
        $selectedGrid = & $getSelectedGrid
        $value = Get-SelectedGridValue -Grid $selectedGrid -ColumnName $ColumnName
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            [System.Windows.Forms.Clipboard]::SetText($value)
            Write-AppLog -Message ("Copied {0}." -f $ColumnName) -Level INFO -Logger $logger
        }
    }

    & $setApoPanelAvailable $false

    $setMeterEnabled = {
        param([bool]$Enabled, [string]$Reason)

        $state.MeterEnabled = $Enabled
        if ($Enabled) {
            $btnMeter.Text = 'LVL  Meter On'
            $btnMeter.BackColor = [System.Drawing.Color]::FromArgb(187, 247, 208)
            if (-not $meterTimer.Enabled) { $meterTimer.Start() }
            Set-GridStatusColors -Grid $activeGrid -MeterEnabled $true
            Write-AppLog -Message ("Audio meter enabled{0}." -f $Reason) -Level INFO -Logger $logger
        }
        else {
            $btnMeter.Text = 'LVL  Meter Off'
            $btnMeter.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
            if ($meterTimer.Enabled) { $meterTimer.Stop() }
            $state.TestMode = $false
            $btnTest.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
            foreach ($device in $state.Devices) { $device.Level = 0 }
            if ($state.Table -is [System.Data.DataTable]) {
                foreach ($dataRow in $state.Table.Rows) { $dataRow['Level'] = '0%' }
            }
            if ($state.ActiveTable -is [System.Data.DataTable]) {
                foreach ($dataRow in $state.ActiveTable.Rows) { $dataRow['Level'] = '0%' }
            }
            if ($state.InactiveTable -is [System.Data.DataTable]) {
                foreach ($dataRow in $state.InactiveTable.Rows) { $dataRow['Level'] = '0%' }
            }
            Set-GridStatusColors -Grid $activeGrid -MeterEnabled $false
            Set-GridStatusColors -Grid $inactiveGrid -MeterEnabled $false
            Write-AppLog -Message 'Audio meter disabled.' -Level INFO -Logger $logger
        }
    }

    $btnSave.Add_Click({
        Commit-DeviceGridEdits -Grid $activeGrid
        Commit-DeviceGridEdits -Grid $inactiveGrid
        if ($state.ActiveTable -is [System.Data.DataTable]) {
            Sync-GridEditsToDevices -Table $state.ActiveTable -Devices $state.Devices
        }
        if ($state.InactiveTable -is [System.Data.DataTable]) {
            Sync-GridEditsToDevices -Table $state.InactiveTable -Devices $state.Devices
        }
        & $applyPendingDeviceGridEdits
        $aliasesSaved = Save-AliasMap -ProjectRoot $state.ProjectRoot -Devices $state.Devices -Logger $logger
        if ($aliasesSaved) {
            $state.PendingAlias1ByVidPid.Clear()
            $state.PendingAlias2ByInstanceId.Clear()
            $state.PendingAlias3ByContainerId.Clear()
            $state.PendingAlias4ByEndpointGuid.Clear()
        }
        [void](Save-DeviceStateForDevices -ProjectRoot $state.ProjectRoot -Devices $state.Devices -Logger $logger)
        & $refreshGrid $false
    })

    $btnRefresh.Add_Click({
        & $refreshGrid $true
    })

    $btnExport.Add_Click({
        Commit-DeviceGridEdits -Grid $activeGrid
        Commit-DeviceGridEdits -Grid $inactiveGrid
        if ($state.ActiveTable -is [System.Data.DataTable]) {
            Sync-GridEditsToDevices -Table $state.ActiveTable -Devices $state.Devices
        }
        if ($state.InactiveTable -is [System.Data.DataTable]) {
            Sync-GridEditsToDevices -Table $state.InactiveTable -Devices $state.Devices
        }
        & $applyPendingDeviceGridEdits
        $exportTable = Convert-DevicesToDataTable -Devices $state.Devices
        Export-GridToCsv -Table $exportTable -Logger $logger
    })

    $miCopyInstance.Add_Click({ & $copyValue 'InstanceId' })
    $miCopyEndpoint.Add_Click({ & $copyValue 'EndpointGuid' })
    $miCopyRow.Add_Click({
        $selectedGrid = & $getSelectedGrid
        if ($selectedGrid.SelectedRows.Count -gt 0) {
            $values = @()
            foreach ($cell in $selectedGrid.SelectedRows[0].Cells) { $values += (ConvertTo-PlainString $cell.Value) }
            [System.Windows.Forms.Clipboard]::SetText(($values -join "`t"))
            Write-AppLog -Message 'Copied row.' -Level INFO -Logger $logger
        }
    })

    $btnDeviceManager.Add_Click({
        try { Start-Process 'devmgmt.msc' }
        catch { Write-AppLog -Message ("Opening Device Manager failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $logger }
    })

    $btnSound.Add_Click({
        try { Start-Process 'mmsys.cpl' }
        catch { Write-AppLog -Message ("Opening sound settings failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $logger }
    })

    $btnMixer.Add_Click({
        try {
            Commit-DeviceGridEdits -Grid $activeGrid
            Commit-DeviceGridEdits -Grid $inactiveGrid
            if ($state.ActiveTable -is [System.Data.DataTable]) {
                Sync-GridEditsToDevices -Table $state.ActiveTable -Devices $state.Devices
            }
            if ($state.InactiveTable -is [System.Data.DataTable]) {
                Sync-GridEditsToDevices -Table $state.InactiveTable -Devices $state.Devices
            }
            & $applyPendingDeviceGridEdits
            Show-AudioMixerWindow -Owner $form -ApplicationState $state -ProjectRoot $state.ProjectRoot -Logger $logger
        }
        catch {
            Write-AppLog -Message ("Opening mixer failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $logger
        }
    })

    $btnApo.Add_Click({
        $btnApo.BackColor = [System.Drawing.Color]::FromArgb(219, 234, 254)
        & $refreshApoPanel $true
    })

    $btnApoRefreshPanel.Add_Click({
        $btnApo.BackColor = [System.Drawing.Color]::FromArgb(219, 234, 254)
        & $refreshApoPanel $true
    })

    $btnApoSnapshot.Add_Click({
        try {
            $name = $txtApoPresetName.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($name) -and $lstApoPresets.SelectedItem) {
                $name = ConvertTo-PlainString $lstApoPresets.SelectedItem
            }
            if ([string]::IsNullOrWhiteSpace($name)) {
                Write-AppLog -Message 'APO snapshot skipped: enter a configuration name first.' -Level WARN -Logger $logger
                return
            }

            $preset = New-EqualizerApoPreset -Name $name -Logger $logger
            $presets = New-Object System.Collections.Generic.List[object]
            foreach ($existing in @($state.ApoPresets)) {
                if ((ConvertTo-PlainString (Get-ObjectPropertyValue -Object $existing -Name 'Name' -Default '')) -ne $name) { $presets.Add($existing) }
            }
            $presets.Add($preset)
            if (Save-EqualizerApoPresets -ProjectRoot $state.ProjectRoot -Presets $presets.ToArray() -Logger $logger) {
                Write-AppLog -Message ("Saved APO VST snapshot: {0}" -f $name) -Level INFO -Logger $logger
                & $refreshApoPanel $false
                $lstApoPresets.SelectedItem = $name
            }
        }
        catch {
            Write-AppLog -Message ("Saving APO snapshot failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $logger
        }
    })

    $btnApoApplyPreset.Add_Click({
        try {
            $preset = & $getSelectedApoPreset
            if (-not $preset) {
                Write-AppLog -Message 'APO preset apply skipped: select a saved configuration first.' -Level WARN -Logger $logger
                return
            }
            Apply-EqualizerApoPreset -Preset $preset -Logger $logger
            & $refreshApoPanel $true
        }
        catch {
            Write-AppLog -Message ("Applying APO preset failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $logger
        }
    })

    $btnApoApplyToggles.Add_Click({
        try {
            Commit-DeviceGridEdits -Grid $apoPluginGrid
            $states = @{}
            $data = $apoPluginGrid.DataSource
            if ($data -is [System.Data.DataTable]) {
                foreach ($row in $data.Rows) {
                    $name = ConvertTo-PlainString $row['Plugin']
                    if (-not [string]::IsNullOrWhiteSpace($name)) {
                        $states[$name] = [bool]$row['Enabled']
                    }
                }
            }
            if ($states.Count -eq 0) {
                Write-AppLog -Message 'APO toggle apply skipped: no VST plugins are listed.' -Level WARN -Logger $logger
                return
            }
            Set-EqualizerApoVstPluginStates -StatesByName $states -Logger $logger
            & $refreshApoPanel $true
        }
        catch {
            Write-AppLog -Message ("Applying APO VST toggles failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $logger
        }
    })

    $btnMeter.Add_Click({
        & $setMeterEnabled (-not $state.MeterEnabled) ''
    })

    $btnTest.Add_Click({
        if (-not $state.MeterEnabled) {
            & $setMeterEnabled $true ' for test mode'
        }
        $state.TestMode = -not $state.TestMode
        if ($state.TestMode) {
            $btnTest.BackColor = [System.Drawing.Color]::FromArgb(187, 247, 208)
            Write-AppLog -Message 'Test mode enabled. The loudest microphone will be highlighted.' -Level INFO -Logger $logger
        }
        else {
            $btnTest.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
            $state.LastLoudestId = ''
            Set-GridStatusColors -Grid $activeGrid -MeterEnabled $state.MeterEnabled
            Set-GridStatusColors -Grid $inactiveGrid -MeterEnabled $state.MeterEnabled
            Write-AppLog -Message 'Test mode disabled.' -Level INFO -Logger $logger
        }
    })

    $txtFilter.Add_TextChanged({
        if ($state.ActiveView) {
            Set-DeviceFilter -View $state.ActiveView -FilterText $txtFilter.Text -OnlyMicrophones $state.OnlyMicrophones
            Set-GridStatusColors -Grid $activeGrid -MeterEnabled $state.MeterEnabled
        }
        if ($state.InactiveView) {
            Set-DeviceFilter -View $state.InactiveView -FilterText $txtFilter.Text -OnlyMicrophones $state.OnlyMicrophones
            Set-GridStatusColors -Grid $inactiveGrid -MeterEnabled $state.MeterEnabled
        }
    })

    $chkOnlyMicrophones.Add_CheckedChanged({
        $state.OnlyMicrophones = [bool]$chkOnlyMicrophones.Checked
        if ($state.ActiveView) {
            Set-DeviceFilter -View $state.ActiveView -FilterText $txtFilter.Text -OnlyMicrophones $state.OnlyMicrophones
            Set-GridStatusColors -Grid $activeGrid -MeterEnabled $state.MeterEnabled
        }
        if ($state.InactiveView) {
            Set-DeviceFilter -View $state.InactiveView -FilterText $txtFilter.Text -OnlyMicrophones $state.OnlyMicrophones
            Set-GridStatusColors -Grid $inactiveGrid -MeterEnabled $state.MeterEnabled
        }
    })

    $lstApoPresets.Add_SelectedIndexChanged({
        if ($lstApoPresets.SelectedItem) {
            $txtApoPresetName.Text = ConvertTo-PlainString $lstApoPresets.SelectedItem
        }
        & $refreshApoPreview
    })

    $apoPluginGrid.Add_CurrentCellDirtyStateChanged({
        if ($apoPluginGrid.IsCurrentCellDirty) {
            $apoPluginGrid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    })

    $setGridRowAsDefault = {
        param(
            [System.Windows.Forms.DataGridView]$Grid,
            [int]$RowIndex,
            [int]$ColumnIndex
        )

        if ($RowIndex -lt 0 -or $ColumnIndex -lt 0) { return }
        $columnName = $Grid.Columns[$ColumnIndex].Name
        if ($columnName -ne 'IsDefault' -and $columnName -ne 'IsDefaultComm') { return }
        $row = $Grid.Rows[$RowIndex]
        if ([bool]$row.Cells[$columnName].Value) { return }

        $endpointId = ''
        if ($row.DataBoundItem -is [System.Data.DataRowView]) {
            $endpointId = ConvertTo-PlainString $row.DataBoundItem['EndpointId']
        }
        if ([string]::IsNullOrWhiteSpace($endpointId)) {
            Write-AppLog -Message 'This device has no Windows audio endpoint and cannot be made the default.' -Level WARN -Logger $logger
            return
        }

        $changed = if ($columnName -eq 'IsDefaultComm') {
            Set-DefaultCommunicationsCaptureAudioEndpoint -EndpointId $endpointId -Logger $logger
        }
        else {
            Set-DefaultCaptureAudioEndpoint -EndpointId $endpointId -Logger $logger
        }
        if ($changed) {
            $state.LastEndpointSignature = Get-AudioEndpointStateSignature -Logger $logger
            & $refreshGrid $true
        }
    }

    $activeGrid.Add_CellFormatting({
        param($sender, $e)
        if ($activeGrid.Columns[$e.ColumnIndex].Name -eq 'Level') {
            $e.CellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleRight
        }
    })
    $activeGrid.Add_CurrentCellDirtyStateChanged({
        if ($activeGrid.IsCurrentCellDirty) { $activeGrid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) }
    })
    $activeGrid.Add_CellValueChanged({
        param($sender, $e)
        & $rememberDeviceGridEdit $activeGrid $e.RowIndex $e.ColumnIndex
    })
    $activeGrid.Add_CellDoubleClick({
        param($sender, $e)
        & $setGridRowAsDefault $activeGrid $e.RowIndex $e.ColumnIndex
    })
    $inactiveGrid.Add_CellFormatting({
        param($sender, $e)
        if ($inactiveGrid.Columns[$e.ColumnIndex].Name -eq 'Level') {
            $e.CellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleRight
        }
    })
    $inactiveGrid.Add_CurrentCellDirtyStateChanged({
        if ($inactiveGrid.IsCurrentCellDirty) { $inactiveGrid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) }
    })
    $inactiveGrid.Add_CellValueChanged({
        param($sender, $e)
        & $rememberDeviceGridEdit $inactiveGrid $e.RowIndex $e.ColumnIndex
    })
    $inactiveGrid.Add_CellDoubleClick({
        param($sender, $e)
        & $setGridRowAsDefault $inactiveGrid $e.RowIndex $e.ColumnIndex
    })

    $meterTimer = New-Object System.Windows.Forms.Timer
    $meterTimer.Interval = 100
    $meterTimer.Add_Tick({
        try {
            if (-not $state.MeterEnabled) { return }
            if ($null -eq $state.Devices -or $state.Devices.Count -eq 0) { return }
            if ($null -eq $state.ActiveTable -or -not ($state.ActiveTable -is [System.Data.DataTable])) { return }
            if ($null -eq $activeGrid -or -not ($activeGrid -is [System.Windows.Forms.DataGridView]) -or $activeGrid.IsDisposed) { return }

            [void](Update-AudioLevels -Devices $state.Devices -Logger $logger)

            $levelById = @{}
            foreach ($device in $state.Devices) {
                $levelById[(Normalize-DeviceId $device.InstanceId)] = [double]$device.Level
            }
            foreach ($gridRow in $activeGrid.Rows) {
                if ($gridRow.IsNewRow) { continue }
                $id = Normalize-DeviceId (ConvertTo-PlainString $gridRow.Cells['InstanceId'].Value)
                if (-not $levelById.ContainsKey($id)) { continue }

                $newLevelText = ('{0:P0}' -f $levelById[$id])
                if ((ConvertTo-PlainString $gridRow.Cells['Level'].Value) -ne $newLevelText) {
                    $gridRow.Cells['Level'].Value = $newLevelText
                    Set-LevelCellStyle -Row $gridRow -MeterEnabled $true
                }
            }

            if ($state.TestMode) {
                $best = Get-LoudestMicrophone -Devices $state.Devices
                $bestId = ''
                if ($best) { $bestId = Normalize-DeviceId $best.InstanceId }
                if ($bestId -ne $state.LastLoudestId) {
                    foreach ($gridRow in $activeGrid.Rows) {
                        if ($gridRow.IsNewRow) { continue }
                        $gridRow.DefaultCellStyle.Font = $activeGrid.Font
                        Set-GridRowBaseStyle -Row $gridRow
                        if ((Normalize-DeviceId (ConvertTo-PlainString $gridRow.Cells['InstanceId'].Value)) -eq $bestId) {
                            $gridRow.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(254, 249, 195)
                            $gridRow.DefaultCellStyle.Font = New-Object System.Drawing.Font($activeGrid.Font, [System.Drawing.FontStyle]::Bold)
                        }
                    }
                }
                if ($bestId -and $bestId -ne $state.LastLoudestId) {
                    $label = if ($best.Alias4) { $best.Alias4 } elseif ($best.Alias2) { $best.Alias2 } elseif ($best.Alias3) { $best.Alias3 } elseif ($best.Alias1) { $best.Alias1 } else { $best.FriendlyName }
                    Write-AppLog -Message ("Loudest microphone: {0} ({1:P0})" -f $label, [double]$best.Level) -Level DEVICE -Logger $logger
                }
                $state.LastLoudestId = $bestId
            }
        }
        catch {
            $message = $_.Exception.Message
            $now = Get-Date
            if ($message -ne $state.LastTimerError -or (($now - $state.LastTimerErrorAt).TotalSeconds -ge 10)) {
                Write-AppLog -Message ("Audio meter timer error: {0}" -f $message) -Level ERROR -Logger $logger
                $state.LastTimerError = $message
                $state.LastTimerErrorAt = $now
            }
        }
    })

    $refreshDebounce = New-Object System.Windows.Forms.Timer
    $refreshDebounce.Interval = 900
    $refreshDebounce.Add_Tick({
        $refreshDebounce.Stop()
        if ($state.RefreshPending) {
            $state.RefreshPending = $false
            & $refreshGrid $true
        }
    })

    $endpointPollTimer = New-Object System.Windows.Forms.Timer
    $endpointPollTimer.Interval = 2000
    $endpointPollTimer.Add_Tick({
        try {
            $signature = Get-AudioEndpointStateSignature -Logger $logger
            if ([string]::IsNullOrWhiteSpace($state.LastEndpointSignature)) {
                $state.LastEndpointSignature = $signature
                return
            }
            if ($signature -ne $state.LastEndpointSignature) {
                $state.LastEndpointSignature = $signature
                Write-AppLog -Message 'Audio endpoint list changed; refreshing.' -Level DEVICE -Logger $logger
                $state.RefreshPending = $true
                $refreshDebounce.Stop()
                $refreshDebounce.Start()
            }
        }
        catch {
            Write-AppLog -Message ("Endpoint polling failed: {0}" -f $_.Exception.Message) -Level WARN -Logger $logger
        }
    })

    $watchCallback = {
        param([string]$Kind, [string]$Name, [string]$InstanceId)
        $message = "{0}: {1} {2}" -f $Kind, $Name, $InstanceId
        Write-AppLog -Message $message -Level DEVICE -Logger $logger
        $state.RefreshPending = $true
        if ($form -and -not $form.IsDisposed) {
            [void]$form.BeginInvoke([Action]{ $refreshDebounce.Stop(); $refreshDebounce.Start() })
        }
    }

    $form.Add_Shown({
        Write-AppLog -Message 'Application started.' -Level INFO -Logger $logger
        & $configureRootSplit
        & $updateToolbarLayout
        $state.Devices = @(Get-UsbMicrophoneInventory -ProjectRoot $state.ProjectRoot -Logger $logger)
        & $refreshGrid $false
        & $refreshApoPanel $true
        $state.LastEndpointSignature = Get-AudioEndpointStateSignature -Logger $logger
        $endpointPollTimer.Start()
        Write-AppLog -Message 'Audio meter is disabled on startup.' -Level INFO -Logger $logger
        Start-DeviceWatcher -OnChanged $watchCallback -Logger $logger
    })

    $form.Add_FormClosing({
        $meterTimer.Stop()
        $refreshDebounce.Stop()
        $endpointPollTimer.Stop()
        Stop-DeviceWatcher -Logger $logger
    })

    [void][System.Windows.Forms.Application]::Run($form)
}
