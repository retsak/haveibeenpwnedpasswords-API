#requires -Version 7.0
<#!
.SYNOPSIS
    Graphical interface for Check-HIBPPassword.ps1.

.DESCRIPTION
    Provides a Windows Forms front-end that accepts manual passwords, text files, or Edge/Chrome
    exports and then delegates all checking to the existing Check-HIBPPassword.ps1 script so the
    standalone CLI remains unchanged.
#>

[CmdletBinding()]
param(
    [switch]
    $DebugLogging
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:EnableDebugLogging = $DebugLogging.IsPresent

function Write-DebugLog {
    param([string]$Message)

    if (-not $script:EnableDebugLogging) {
        return
    }

    $timestamp = (Get-Date).ToString('HH:mm:ss.fff')
    Write-Host "[$timestamp] $Message" -ForegroundColor DarkGray
}

function Get-ErrorMessage {
    param($InputObject)

    if ($null -eq $InputObject) {
        return 'An unknown error occurred.'
    }

    if ($InputObject -is [System.Management.Automation.ErrorRecord]) {
        if ($InputObject.Exception) {
            return Get-ErrorMessage -InputObject $InputObject.Exception
        }

        return $InputObject.ToString()
    }

    if ($InputObject -is [System.Exception]) {
        return $InputObject.Message
    }

    $psObject = $InputObject
    if ($psObject -and $psObject.PSObject) {
        $exceptionProp = $psObject.PSObject.Properties['Exception']
        if ($exceptionProp -and $exceptionProp.Value) {
            return Get-ErrorMessage -InputObject $exceptionProp.Value
        }

        $messageProp = $psObject.PSObject.Properties['Message']
        if ($messageProp -and $messageProp.Value) {
            return [string]$messageProp.Value
        }
    }

    return [string]$InputObject
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$scriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Check-HIBPPassword.ps1'
if (-not (Test-Path -Path $scriptPath -PathType Leaf)) {
    throw "Cannot locate 'Check-HIBPPassword.ps1' in $PSScriptRoot."
}

$script:MainForm = $null
$script:StatusLabelControl = $null
$script:ProgressBarControl = $null
$script:ResultsGrid = $null
$script:ManualPasswordBox = $null
$script:InputFileTextBox = $null
$script:BrowserListBox = $null
$script:IncludePlainCheckbox = $null
$script:DisablePaddingCheckbox = $null
$script:ThrottleControl = $null
$script:ExportButton = $null
$script:ClearResultsButton = $null
$script:LastResults = @()
$script:ActiveJob = $null
$script:JobMonitorTimer = $null
$script:JobProgressState = $null

function Show-ErrorDialog {
    param(
        [string]$Message,
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Error
    )

    if (-not $script:MainForm) {
        throw $Message
    }

    [System.Windows.Forms.MessageBox]::Show(
        $script:MainForm,
        $Message,
        'HIBP Password Checker',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $Icon
    ) | Out-Null
}

function Set-Status {
    param([string]$Message)

    if ($script:StatusLabelControl) {
        $script:StatusLabelControl.Text = $Message
    }
}

function Set-Progress {
    param(
        [int]$Percent,
        [string]$Activity
    )

    if (-not $script:ProgressBarControl) {
        return
    }

    $clamped = [Math]::Max(0, [Math]::Min(100, $Percent))
    $script:ProgressBarControl.Style = 'Continuous'
    $script:ProgressBarControl.Value = $clamped
    $script:ProgressBarControl.ToolTipText = $Activity
}

function Hide-ProgressBar {
    if ($script:ProgressBarControl) {
        $script:ProgressBarControl.Visible = $false
        $script:ProgressBarControl.Style = 'Continuous'
        $script:ProgressBarControl.MarqueeAnimationSpeed = 0
        $script:ProgressBarControl.Value = 0
        $script:ProgressBarControl.ToolTipText = ''
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'HIBP Password Checker (GUI)'
$form.Size = New-Object System.Drawing.Size(1024, 720)
$form.MinimumSize = New-Object System.Drawing.Size(900, 680)
$form.StartPosition = 'CenterScreen'
$form.Icon = [System.Drawing.SystemIcons]::Shield
$script:MainForm = $form

$lblManual = New-Object System.Windows.Forms.Label
$lblManual.Text = 'Manual passwords (one per line):'
$lblManual.Location = New-Object System.Drawing.Point(10, 15)
$lblManual.AutoSize = $true
$form.Controls.Add($lblManual)

$txtPasswords = New-Object System.Windows.Forms.TextBox
$txtPasswords.Multiline = $true
$txtPasswords.ScrollBars = 'Vertical'
$txtPasswords.Location = New-Object System.Drawing.Point(10, 35)
$txtPasswords.Size = New-Object System.Drawing.Size(470, 190)
$txtPasswords.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($txtPasswords)
$script:ManualPasswordBox = $txtPasswords

$lblInputFile = New-Object System.Windows.Forms.Label
$lblInputFile.Text = 'Input file (optional):'
$lblInputFile.Location = New-Object System.Drawing.Point(10, 233)
$lblInputFile.AutoSize = $true
$form.Controls.Add($lblInputFile)

$txtInputFile = New-Object System.Windows.Forms.TextBox
$txtInputFile.Location = New-Object System.Drawing.Point(10, 253)
$txtInputFile.Size = New-Object System.Drawing.Size(360, 23)
$txtInputFile.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($txtInputFile)
$script:InputFileTextBox = $txtInputFile

$btnBrowseInput = New-Object System.Windows.Forms.Button
$btnBrowseInput.Text = 'Browse...'
$btnBrowseInput.Location = New-Object System.Drawing.Point(380, 251)
$btnBrowseInput.Size = New-Object System.Drawing.Size(100, 27)
$btnBrowseInput.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Select password text file'
        $dialog.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
        $dialog.Multiselect = $false
        if ($dialog.ShowDialog() -eq 'OK') {
            $script:InputFileTextBox.Text = $dialog.FileName
        }
    })
$form.Controls.Add($btnBrowseInput)

$btnClearInput = New-Object System.Windows.Forms.Button
$btnClearInput.Text = 'Clear'
$btnClearInput.Location = New-Object System.Drawing.Point(490, 251)
$btnClearInput.Size = New-Object System.Drawing.Size(80, 27)
$btnClearInput.Add_Click({ $script:InputFileTextBox.Clear() })
$form.Controls.Add($btnClearInput)

$lblBrowser = New-Object System.Windows.Forms.Label
$lblBrowser.Text = 'Browser exports (Edge/Chrome CSV, optional):'
$lblBrowser.Location = New-Object System.Drawing.Point(10, 285)
$lblBrowser.AutoSize = $true
$form.Controls.Add($lblBrowser)

$lstBrowserFiles = New-Object System.Windows.Forms.ListBox
$lstBrowserFiles.Location = New-Object System.Drawing.Point(10, 307)
$lstBrowserFiles.Size = New-Object System.Drawing.Size(470, 130)
$lstBrowserFiles.HorizontalScrollbar = $true
$lstBrowserFiles.SelectionMode = 'MultiExtended'
$lstBrowserFiles.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($lstBrowserFiles)
$script:BrowserListBox = $lstBrowserFiles

$btnAddBrowser = New-Object System.Windows.Forms.Button
$btnAddBrowser.Text = 'Add CSV...'
$btnAddBrowser.Location = New-Object System.Drawing.Point(10, 445)
$btnAddBrowser.Size = New-Object System.Drawing.Size(140, 30)
$btnAddBrowser.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Select Edge/Chrome export'
        $dialog.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
        $dialog.Multiselect = $true
        if ($dialog.ShowDialog() -eq 'OK') {
            foreach ($file in $dialog.FileNames) {
                if (-not $script:BrowserListBox.Items.Contains($file)) {
                    [void]$script:BrowserListBox.Items.Add($file)
                }
            }
        }
    })
$form.Controls.Add($btnAddBrowser)

$btnRemoveBrowser = New-Object System.Windows.Forms.Button
$btnRemoveBrowser.Text = 'Remove selected'
$btnRemoveBrowser.Location = New-Object System.Drawing.Point(160, 445)
$btnRemoveBrowser.Size = New-Object System.Drawing.Size(140, 30)
$btnRemoveBrowser.Add_Click({
        $selected = @($script:BrowserListBox.SelectedItems)
        foreach ($item in $selected) {
            $script:BrowserListBox.Items.Remove($item)
        }
    })
$form.Controls.Add($btnRemoveBrowser)

$btnClearBrowser = New-Object System.Windows.Forms.Button
$btnClearBrowser.Text = 'Clear list'
$btnClearBrowser.Location = New-Object System.Drawing.Point(310, 445)
$btnClearBrowser.Size = New-Object System.Drawing.Size(140, 30)
$btnClearBrowser.Add_Click({ $script:BrowserListBox.Items.Clear() })
$form.Controls.Add($btnClearBrowser)

$optionsGroup = New-Object System.Windows.Forms.GroupBox
$optionsGroup.Text = 'Options'
$optionsGroup.Location = New-Object System.Drawing.Point(520, 20)
$optionsGroup.Size = New-Object System.Drawing.Size(480, 160)
$optionsGroup.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($optionsGroup)

$chkIncludePlain = New-Object System.Windows.Forms.CheckBox
$chkIncludePlain.Text = 'Include plaintext in results'
$chkIncludePlain.Location = New-Object System.Drawing.Point(15, 30)
$chkIncludePlain.AutoSize = $true
$optionsGroup.Controls.Add($chkIncludePlain)
$script:IncludePlainCheckbox = $chkIncludePlain

$chkDisablePadding = New-Object System.Windows.Forms.CheckBox
$chkDisablePadding.Text = 'Disable response padding'
$chkDisablePadding.Location = New-Object System.Drawing.Point(15, 60)
$chkDisablePadding.AutoSize = $true
$optionsGroup.Controls.Add($chkDisablePadding)
$script:DisablePaddingCheckbox = $chkDisablePadding

$lblThrottle = New-Object System.Windows.Forms.Label
$lblThrottle.Text = 'Throttle between prefix lookups (ms):'
$lblThrottle.Location = New-Object System.Drawing.Point(15, 95)
$lblThrottle.AutoSize = $true
$optionsGroup.Controls.Add($lblThrottle)

$numThrottle = New-Object System.Windows.Forms.NumericUpDown
$numThrottle.Minimum = 0
$numThrottle.Maximum = 10000
$numThrottle.Value = 1600
$numThrottle.Increment = 100
$numThrottle.Location = New-Object System.Drawing.Point(280, 92)
$numThrottle.Size = New-Object System.Drawing.Size(80, 23)
$optionsGroup.Controls.Add($numThrottle)
$script:ThrottleControl = $numThrottle

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = 'Run password check'
$btnRun.Location = New-Object System.Drawing.Point(520, 200)
$btnRun.Size = New-Object System.Drawing.Size(200, 40)
$btnRun.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($btnRun)
$script:RunButton = $btnRun

$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = 'Export results to CSV'
$btnExport.Location = New-Object System.Drawing.Point(730, 200)
$btnExport.Size = New-Object System.Drawing.Size(200, 40)
$btnExport.Enabled = $false
$btnExport.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($btnExport)
$script:ExportButton = $btnExport

$btnClearResults = New-Object System.Windows.Forms.Button
$btnClearResults.Text = 'Clear results'
$btnClearResults.Location = New-Object System.Drawing.Point(730, 250)
$btnClearResults.Size = New-Object System.Drawing.Size(200, 35)
$btnClearResults.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($btnClearResults)
$script:ClearResultsButton = $btnClearResults

$gridResults = New-Object System.Windows.Forms.DataGridView
$gridResults.Location = New-Object System.Drawing.Point(10, 490)
$gridResults.Size = New-Object System.Drawing.Size(990, 150)
$gridResults.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$gridResults.ReadOnly = $true
$gridResults.AllowUserToAddRows = $false
$gridResults.AllowUserToDeleteRows = $false
$gridResults.RowHeadersVisible = $false
$gridResults.AutoGenerateColumns = $false
$gridResults.SelectionMode = 'FullRowSelect'
$form.Controls.Add($gridResults)
$script:ResultsGrid = $gridResults

$columnDefinitions = @(
    @{Property = 'PasswordPreview'; Header = 'Password'; Width = 120},
    @{Property = 'PlainText'; Header = 'Plaintext'; Width = 150},
    @{Property = 'IsPwned'; Header = 'Pwned'; Width = 60},
    @{Property = 'PwnedCount'; Header = 'Count'; Width = 70},
    @{Property = 'SiteName'; Header = 'Site'; Width = 140},
    @{Property = 'SiteUrl'; Header = 'URL'; Width = 180},
    @{Property = 'Username'; Header = 'Username'; Width = 120},
    @{Property = 'Note'; Header = 'Note'; Width = 150},
    @{Property = 'Sha1Hash'; Header = 'SHA-1 Hash'; Width = 200}
)

foreach ($columnDef in $columnDefinitions) {
    $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $column.DataPropertyName = $columnDef.Property
    $column.HeaderText = $columnDef.Header
    $column.Width = $columnDef.Width
    $column.DefaultCellStyle.WrapMode = 'False'
    [void]$gridResults.Columns.Add($column)
}

$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = 'Ready.'
$statusStrip.Items.Add($statusLabel) | Out-Null

$progressBar = New-Object System.Windows.Forms.ToolStripProgressBar
$progressBar.Visible = $false
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$progressBar.AutoSize = $false
$progressBar.Width = 180
$statusStrip.Items.Add($progressBar) | Out-Null
$form.Controls.Add($statusStrip)
$script:StatusLabelControl = $statusLabel
$script:ProgressBarControl = $progressBar

$script:JobMonitorTimer = New-Object System.Windows.Forms.Timer
$script:JobMonitorTimer.Interval = 300
$script:JobMonitorTimer.add_Tick({ Watch-ActiveJob })

function Get-ManualPasswords {
    $values = @()
    if ($script:ManualPasswordBox) {
        $values = @($script:ManualPasswordBox.Lines | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    return $values
}

function Get-BrowserFileArray {
    if (-not $script:BrowserListBox) {
        return @()
    }

    return @($script:BrowserListBox.Items | ForEach-Object { [string]$_ })
}

function Update-ResultsGrid {
    param([object[]]$Items)

    $valid = New-Object System.Collections.Generic.List[object]
    foreach ($item in $Items) {
        if ($null -ne $item -and $item.PSObject.Properties['Sha1Hash']) {
            $valid.Add($item)
        }
    }

    $script:LastResults = $valid.ToArray()
    $script:ResultsGrid.DataSource = $null

    if ($valid.Count -gt 0) {
        $script:ResultsGrid.DataSource = $valid
        $script:ExportButton.Enabled = $true
    $pwnedCount = Get-CollectionCount -Value (@($valid | Where-Object { $_.IsPwned }))
        Set-Status ("Completed: {0} password(s) checked; {1} flagged as pwned." -f $valid.Count, $pwnedCount)
    }
    else {
        $script:ExportButton.Enabled = $false
        Set-Status 'Completed, but no results were returned. Provide at least one input next time.'
    }

    Hide-ProgressBar
}

function Clear-Results {
    $script:LastResults = @()

    if ($script:ResultsGrid) {
        $script:ResultsGrid.DataSource = $null
        try {
            $script:ResultsGrid.Rows.Clear()
        }
        catch {}

        $script:ResultsGrid.Refresh()
    }

    if ($script:ExportButton) {
        $script:ExportButton.Enabled = $false
    }

    Set-Status 'Results cleared. Ready for another run.'
}

function Get-CollectionCount {
    param($Value)

    if ($null -eq $Value) {
        return 0
    }

    if ($Value -is [System.Collections.ICollection]) {
        return $Value.Count
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value).Count
    }

    return 1
}

function Watch-ActiveJob {
    if (-not $script:ActiveJob) {
        return
    }

    $job = $script:ActiveJob
    $state = $job.JobStateInfo.State

    if ($state -eq 'Running' -or $state -eq 'NotStarted') {
        $childCount = Get-CollectionCount -Value $job.ChildJobs
        if ($childCount -gt 0) {
            $child = $job.ChildJobs[0]
            $progressRecords = @($child.Progress)
            $progressCount = Get-CollectionCount -Value $progressRecords
            if ($progressCount -gt 0) {
                $activity = $progressRecords[$progressCount - 1]
                $percent = $activity.PercentComplete
                $status = if ($activity.StatusDescription) { $activity.StatusDescription } else { $activity.Activity }
                Set-Progress -Percent $percent -Activity $status
                Set-Status $status
            }
        }
        return
    }

    $script:JobMonitorTimer.Stop()
    $script:ActiveJob = $null
    $script:RunButton.Enabled = $true
    Hide-ProgressBar

    try {
        if ($state -eq 'Completed') {
            $output = @()
            try {
                $output = @(Receive-Job -Job $job -ErrorAction Stop)
            }
            catch {
                $errorText = Get-ErrorMessage -InputObject $_
                Write-DebugLog ("Failed to receive job output: {0}" -f $errorText)
                Show-ErrorDialog $errorText
                return
            }

            Write-DebugLog ("Job completed with {0} output object(s)." -f (Get-CollectionCount -Value $output))
            Update-ResultsGrid -Items $output
            return
        }

        $reason = $job.JobStateInfo.Reason
        $childCount = Get-CollectionCount -Value $job.ChildJobs
        if (-not $reason -and $childCount -gt 0) {
            $reason = $job.ChildJobs[0].JobStateInfo.Reason
        }

        $errorMessage = Get-ErrorMessage -InputObject $reason
        if ([string]::IsNullOrWhiteSpace($errorMessage)) {
            $errorMessage = "Job ended in state '$state' without additional details."
        }

        Write-DebugLog ("Job ended in state {0}: {1}" -f $state, $errorMessage)
    Set-Status 'Run failed.'
        Show-ErrorDialog $errorMessage
    }
    finally {
        try {
            Receive-Job -Job $job -OutVariable _ -ErrorAction SilentlyContinue | Out-Null
        }
        catch {}

        try {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
        catch {}
    }
}

function Start-PasswordCheck {
    $manualPasswords = @(Get-ManualPasswords)
    $inputFile = $script:InputFileTextBox.Text.Trim()
    $browserFiles = @(Get-BrowserFileArray)

    $manualCount = Get-CollectionCount -Value $manualPasswords
    $browserCount = Get-CollectionCount -Value $browserFiles

    Write-DebugLog ("Start-PasswordCheck invoked. ManualCount={0}, InputFile='{1}', BrowserCount={2}" -f $manualCount, $inputFile, $browserCount)

    if ($manualCount -eq 0 -and [string]::IsNullOrWhiteSpace($inputFile) -and $browserCount -eq 0) {
        Show-ErrorDialog 'Provide at least one password, input file, or browser export before running.'
        return
    }

    if ($inputFile -and -not (Test-Path -Path $inputFile -PathType Leaf)) {
        Show-ErrorDialog "Input file '$inputFile' does not exist."
        return
    }

    foreach ($browserFile in $browserFiles) {
        if (-not (Test-Path -Path $browserFile -PathType Leaf)) {
            Show-ErrorDialog "Browser export file '$browserFile' does not exist."
            return
        }
    }

    if ($script:ActiveJob) {
        Show-ErrorDialog 'A password check is already running. Please wait for it to finish before starting another.'
        return
    }

    $script:RunButton.Enabled = $false
    $script:ExportButton.Enabled = $false
    Set-Status 'Running password checks…'
    Write-DebugLog 'UI disabled and status updated. Starting thread job.'
    if ($script:ProgressBarControl) {
        $script:ProgressBarControl.Style = 'Marquee'
        $script:ProgressBarControl.MarqueeAnimationSpeed = 35
        $script:ProgressBarControl.Visible = $true
        $script:ProgressBarControl.ToolTipText = 'Running password checks…'
    }

    $parameters = @{}
    if ($manualCount -gt 0) { $parameters.Password = $manualPasswords }
    if ($inputFile) { $parameters.InputFile = $inputFile }
    if ($browserCount -gt 0) { $parameters.BrowserExportFile = $browserFiles }
    if ($script:IncludePlainCheckbox.Checked) { $parameters.IncludePlainText = $true }
    if ($script:DisablePaddingCheckbox.Checked) { $parameters.DisablePadding = $true }
    $parameters.ThrottleMilliseconds = [int]$script:ThrottleControl.Value

    $jobArgs = [pscustomobject]@{
        ScriptPath = $scriptPath
        Parameters = $parameters
    }

    try {
        Import-Module ThreadJob -ErrorAction SilentlyContinue | Out-Null
        $script:ActiveJob = Start-ThreadJob -ArgumentList $jobArgs -ScriptBlock {
            param($task)
            $params = $task.Parameters

            $progressPreference = $ProgressPreference
            $ProgressPreference = 'Continue'
            try {
                & $task.ScriptPath @params
            }
            finally {
                $ProgressPreference = $progressPreference
            }
        }
        Write-DebugLog ("Thread job {0} started." -f $script:ActiveJob.Id)
        $script:JobMonitorTimer.Start()
    }
    catch {
        $script:RunButton.Enabled = $true
        Set-Status 'Run failed.'
        $message = Get-ErrorMessage -InputObject $_
        Write-DebugLog ("Failed to start thread job: {0}" -f $message)
        Show-ErrorDialog $message
        Hide-ProgressBar
    }
}

function Export-ResultsToCsv {
    if (-not $script:LastResults -or $script:LastResults.Count -eq 0) {
        Show-ErrorDialog 'No results are available to export.', [System.Windows.Forms.MessageBoxIcon]::Information
        return
    }

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = 'Export results to CSV'
    $dialog.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
    $dialog.FileName = 'hibp-results.csv'

    if ($dialog.ShowDialog() -ne 'OK') {
        return
    }

    try {
        $script:LastResults | Export-Csv -Path $dialog.FileName -NoTypeInformation -Encoding UTF8
        Show-ErrorDialog "Results exported to '$($dialog.FileName)'.", [System.Windows.Forms.MessageBoxIcon]::Information
    }
    catch {
        $exportMessage = Get-ErrorMessage -InputObject $_
        Show-ErrorDialog "Failed to export CSV: $exportMessage"
    }
}

$btnRun.Add_Click({
        Write-DebugLog 'Run button clicked.'
        Start-PasswordCheck
    })
$btnExport.Add_Click({ Export-ResultsToCsv })
$btnClearResults.Add_Click({ Clear-Results })

$form.Add_Shown({ $script:ManualPasswordBox.Focus() })

[System.Windows.Forms.Application]::Run($form)
