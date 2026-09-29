# =============================================================================
# Windows 10 Cleanup & Organization Utility with GUI
# Advanced cleanup tool with multiple settings and heavy-load optimization
# =============================================================================

# Load required assemblies
try {
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
}
catch {
    Write-Host "ERROR: Could not load required .NET assemblies"
    Write-Host $_
    exit 1
}

# Global variables for thread management
$script:CleanupRunning = $false
$script:CancelCleanup = $false
$script:MaxParallelJobs = 4
$script:TotalItemsProcessed = 0
$script:TotalSpaceFreed = 0
$script:AppRoot = Join-Path $env:APPDATA "Windows10CleanupUtility"
$script:LogPath = Join-Path $script:AppRoot "Logs"
$script:BackupDir = Join-Path $script:AppRoot "Backups"

function Initialize-CleanupPaths {
    foreach ($path in @($script:AppRoot, $script:LogPath, $script:BackupDir)) {
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
}

function Get-WindowsFolderPath {
    param(
        [ValidateSet('Desktop', 'Downloads')]
        [string]$FolderName
    )

    try {
        switch ($FolderName) {
            'Desktop' {
                $desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)
                if (-not [string]::IsNullOrWhiteSpace($desktop)) { return $desktop }
            }
            'Downloads' {
                $downloads = Join-Path $env:USERPROFILE 'Downloads'
                if (Test-Path $downloads) { return $downloads }

                try {
                    $shell = New-Object -ComObject Shell.Application
                    $folder = $shell.Namespace('shell:Downloads')
                    if ($folder -and $folder.Self -and $folder.Self.Path) { return $folder.Self.Path }
                }
                catch {}

                $fallback = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)
                if (-not [string]::IsNullOrWhiteSpace($fallback)) { return $fallback }
            }
        }
    }
    catch {
        Write-CleanupLog "Folder resolution failed for $FolderName: $($_.Exception.Message)" "Warning"
    }

    return $null
}

# =============================================================================
# LOGGING FUNCTION
# =============================================================================
function Write-CleanupLog {
    param(
        [string]$Message,
        [ValidateSet("Info", "Warning", "Error", "Success")]
        [string]$Type = "Info"
    )
    
    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        
        if (-not (Test-Path $script:LogPath)) {
            New-Item -ItemType Directory -Path $script:LogPath -Force -ErrorAction SilentlyContinue | Out-Null
        }
        
        $logFile = Join-Path $script:LogPath ("cleanup_" + (Get-Date -Format "yyyy-MM-dd") + ".log")
        $logEntry = "[$timestamp] [$Type] $Message"
        
        Add-Content -Path $logFile -Value $logEntry -ErrorAction SilentlyContinue
    }
    catch {
        # Silent fail for logging
    }
}

function Get-FileSizeString {
    param([long]$Size)

    if ($Size -ge 1GB) {
        return "{0:F2} GB" -f ($Size / 1GB)
    }
    elseif ($Size -ge 1MB) {
        return "{0:F2} MB" -f ($Size / 1MB)
    }
    elseif ($Size -ge 1KB) {
        return "{0:F2} KB" -f ($Size / 1KB)
    }
    else {
        return "$Size B"
    }
}

function Get-DirectorySize {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return [long]0 }

    try {
        $sum = (Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        if ($null -eq $sum) { return [long]0 }
        return [long]$sum
    }
    catch {
        return [long]0
    }
}

function Backup-ItemIfNeeded {
    param(
        [System.IO.FileSystemInfo]$Item,
        [string]$BackupFolder,
        [bool]$Enabled = $false
    )

    if (-not $Enabled) { return }
    if (-not (Test-Path $BackupFolder)) { New-Item -ItemType Directory -Path $BackupFolder -Force | Out-Null }

    $destPath = Join-Path $BackupFolder $Item.Name
    if (Test-Path $destPath) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $destPath = Join-Path $BackupFolder ($Item.Name + "_" + $timestamp)
    }

    try {
        if ($Item.PSIsContainer) {
            Copy-Item -Path $Item.FullName -Destination $destPath -Recurse -Force -ErrorAction Stop
        }
        else {
            Copy-Item -Path $Item.FullName -Destination $destPath -Force -ErrorAction Stop
        }
    }
    catch {
        Write-CleanupLog "Could not back up $($Item.FullName): $($_.Exception.Message)" "Warning"
    }
}

function Remove-PathContentsSafely {
    param(
        [string]$Path,
        [int]$Limit = 500,
        [switch]$DryRun,
        [switch]$BackupDeleted,
        [string]$BackupRoot = ""
    )

    if (-not (Test-Path $Path)) {
        return [pscustomobject]@{ Count = 0; Size = 0; Details = @() }
    }

    $count = 0
    $totalSize = 0
    $details = @()

    try {
        $items = Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue | Select-Object -First $Limit
        foreach ($item in $items) {
            try {
                $itemSize = if ($item.PSIsContainer) { Get-DirectorySize -Path $item.FullName } else { [long]$item.Length }
                $totalSize += [long]$itemSize
                $details += [pscustomobject]@{ Name = $item.Name; Path = $item.FullName; Size = $itemSize }

                if ($BackupDeleted -and -not $DryRun) {
                    Backup-ItemIfNeeded -Item $item -BackupFolder $BackupRoot -Enabled $true
                }

                if (-not $DryRun) {
                    if ($item.PSIsContainer) {
                        Remove-Item -Path $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    else {
                        Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
                    }
                }

                $count++
            }
            catch {
                Write-CleanupLog "Error processing item $($item.FullName): $($_.Exception.Message)" "Warning"
            }
        }
    }
    catch {
        Write-CleanupLog "Error processing path $Path : $($_.Exception.Message)" "Warning"
    }

    return [pscustomobject]@{ Count = $count; Size = $totalSize; Details = $details }
}

function Empty-RecycleBinSafely {
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.NameSpace(0xA)
        $items = @($folder.Items())
        foreach ($item in $items) {
            try { $item.InvokeVerb("Delete") } catch { }
        }
        return $items.Count
    }
    catch {
        return 0
    }
}

function Clean-BrowserCachesSafely {
    param([switch]$DryRun,[switch]$BackupDeleted,[string]$BackupRoot = "")

    $browserCachePaths = @{
        "Chrome"   = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache"
        "Firefox"  = "$env:APPDATA\Mozilla\Firefox\Profiles"
        "Edge"     = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache"
        "Internet Explorer" = "$env:LOCALAPPDATA\Microsoft\Windows\INetCache"
    }

    $totalSize = 0
    $itemCount = 0
    $details = @()

    foreach ($browser in $browserCachePaths.Keys) {
        $path = $browserCachePaths[$browser]

        if (Test-Path $path) {
            try {
                $result = Remove-PathContentsSafely -Path $path -Limit 500 -DryRun:$DryRun -BackupDeleted:$BackupDeleted -BackupRoot $BackupRoot
                $itemCount += $result.Count
                $totalSize += $result.Size
                $details += $result.Details
            }
            catch {
                Write-CleanupLog "Error cleaning $browser cache: $($_.Exception.Message)" "Warning"
            }
        }
    }

    return [pscustomobject]@{ Count = $itemCount; Size = $totalSize; Details = $details }
}

function Organize-FilesByExtension {
    param(
        [string]$RootFolder,
        [int]$Limit = 500,
        [switch]$DryRun
    )

    if (-not (Test-Path $RootFolder)) {
        return [pscustomobject]@{ Count = 0; Moved = @() }
    }

    $count = 0
    $moved = @()

    try {
        $items = Get-ChildItem -Path $RootFolder -File -Force -ErrorAction SilentlyContinue | Select-Object -First $Limit
        foreach ($item in $items) {
            try {
                $extension = $item.Extension.TrimStart('.')
                if ([string]::IsNullOrWhiteSpace($extension)) { $extension = "NoExtension" }

                $folderPath = Join-Path -Path $RootFolder -ChildPath $extension
                if (-not (Test-Path $folderPath)) {
                    if (-not $DryRun) { New-Item -ItemType Directory -Path $folderPath -Force -ErrorAction SilentlyContinue | Out-Null }
                }

                $dest = Join-Path -Path $folderPath -ChildPath $item.Name
                if (-not (Test-Path $dest)) {
                    $moved += [pscustomobject]@{ Name = $item.Name; From = $item.FullName; To = $dest }
                    if (-not $DryRun) {
                        Move-Item -Path $item.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
                    }
                    $count++
                }
            }
            catch {
                Write-CleanupLog "Error organizing $($item.FullName): $($_.Exception.Message)" "Warning"
            }
        }
    }
    catch {
        Write-CleanupLog "Error accessing $RootFolder : $($_.Exception.Message)" "Warning"
    }

    return [pscustomobject]@{ Count = $count; Moved = $moved }
}

function Get-SelectedOptions {
    param([hashtable]$Selected) 

    $list = @()
    foreach ($key in @("TempFiles", "RecycleBin", "BrowserCache", "WindowsUpdates", "Prefetch", "LogFiles", "OrganizeDownloads", "OrganizeDesktop")) {
        if ($Selected[$key]) { $list += $key }
    }
    return $list
}

function Enable-PreflightRestorePoint {
    $restoreCommand = Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue
    if ($null -eq $restoreCommand) {
        return $false
    }

    try {
        Checkpoint-Computer -Description "Windows 10 Cleanup Utility" -RestorePointType "MODIFY_SETTINGS" -WarningAction SilentlyContinue | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

Initialize-CleanupPaths

# ---------- Visual Layout ----------
try {
    $window = New-Object System.Windows.Window
    $window.Title = "Windows 10 Cleanup & Organization Utility"
    $window.Width = 760
    $window.Height = 940
    $window.Background = [System.Windows.Media.Brushes]::White
    $window.WindowStartupLocation = "CenterScreen"
    $window.ResizeMode = "CanResize"

    $mainGrid = New-Object System.Windows.Controls.Grid
    for ($i = 0; $i -lt 3; $i++) { $mainGrid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) }
    $mainGrid.RowDefinitions[0].Height = "Auto"
    $mainGrid.RowDefinitions[1].Height = "*"
    $mainGrid.RowDefinitions[2].Height = "Auto"

    $titleBlock = New-Object System.Windows.Controls.TextBlock
    $titleBlock.Text = "🧹 Windows 10 Cleanup & Organization Utility"
    $titleBlock.FontSize = 16
    $titleBlock.FontWeight = "Bold"
    $titleBlock.Foreground = [System.Windows.Media.Brushes]::DarkBlue
    $titleBlock.Padding = "15"
    $titleBlock.Background = [System.Windows.Media.Brushes]::LightGray
    $titleBlock.TextWrapping = "Wrap"
    [System.Windows.Controls.Grid]::SetRow($titleBlock, 0)
    $mainGrid.Children.Add($titleBlock) | Out-Null

    $scrollViewer = New-Object System.Windows.Controls.ScrollViewer
    $scrollViewer.VerticalScrollBarVisibility = "Auto"

    $contentGrid = New-Object System.Windows.Controls.Grid
    $contentGrid.Margin = "15"

    $optionsStackPanel = New-Object System.Windows.Controls.StackPanel

    $optionsTitle = New-Object System.Windows.Controls.TextBlock
    $optionsTitle.Text = "Cleanup Options:"
    $optionsTitle.FontSize = 14
    $optionsTitle.FontWeight = "Bold"
    $optionsTitle.Margin = "0,0,0,10"
    $optionsStackPanel.Children.Add($optionsTitle) | Out-Null

    $checkboxes = @{
        "TempFiles" = "Remove Temporary Files"
        "RecycleBin" = "Empty Recycle Bin"
        "BrowserCache" = "Clear Browser Cache"
        "WindowsUpdates" = "Remove Old Windows Updates"
        "Prefetch" = "Remove Prefetch Files"
        "LogFiles" = "Clean System Log Files"
        "OrganizeDownloads" = "Organize Downloads Folder"
        "OrganizeDesktop" = "Organize Desktop Folder"
    }

    $script:SelectedOptions = @{}
    foreach ($key in $checkboxes.Keys) {
        $checkbox = New-Object System.Windows.Controls.CheckBox
        $checkbox.Content = $checkboxes[$key]
        $checkbox.IsChecked = $true
        $checkbox.Margin = "0,5,0,5"
        $checkbox.FontSize = 11
        $checkbox.Name = $key
        $script:SelectedOptions[$key] = $true
        $checkbox.Add_Checked({ $script:SelectedOptions[$this.Name] = $true })
        $checkbox.Add_Unchecked({ $script:SelectedOptions[$this.Name] = $false })
        $optionsStackPanel.Children.Add($checkbox) | Out-Null
    }

    $contentGrid.Children.Add($optionsStackPanel) | Out-Null

    $settingsExpander = New-Object System.Windows.Controls.Expander
    $settingsExpander.Header = "⚙️ Advanced Settings"
    $settingsExpander.Margin = "0,20,0,0"
    $settingsExpander.IsExpanded = $false

    $settingsPanel = New-Object System.Windows.Controls.StackPanel

    $throttleCheckbox = New-Object System.Windows.Controls.CheckBox
    $throttleCheckbox.Content = "Enable Throttle Mode (Lighter on system resources)"
    $throttleCheckbox.IsChecked = $true
    $throttleCheckbox.Margin = "10,10,0,5"
    $throttleCheckbox.FontSize = 11
    $settingsPanel.Children.Add($throttleCheckbox) | Out-Null

    $jobsPanel = New-Object System.Windows.Controls.StackPanel
    $jobsPanel.Orientation = "Horizontal"
    $jobsPanel.Margin = "10,10,0,5"
    $jobsLabel = New-Object System.Windows.Controls.TextBlock
    $jobsLabel.Text = "Max Parallel Jobs:"
    $jobsLabel.Margin = "0,0,10,0"
    $jobsLabel.VerticalAlignment = "Center"
    $jobsPanel.Children.Add($jobsLabel) | Out-Null

    $jobsSlider = New-Object System.Windows.Controls.Slider
    $jobsSlider.Minimum = 1
    $jobsSlider.Maximum = 8
    $jobsSlider.Value = 4
    $jobsSlider.Width = 150
    $jobsSlider.IsSnapToTickEnabled = $true
    $jobsSlider.TickPlacement = "BottomRight"
    $jobsSlider.TickFrequency = 1
    $jobsPanel.Children.Add($jobsSlider) | Out-Null

    $jobsValue = New-Object System.Windows.Controls.TextBlock
    $jobsValue.Text = "4"
    $jobsValue.Margin = "10,0,0,0"
    $jobsValue.VerticalAlignment = "Center"
    $jobsValue.FontWeight = "Bold"
    $jobsPanel.Children.Add($jobsValue) | Out-Null

    $jobsSlider.Add_ValueChanged({
        $jobsValue.Text = [int]$jobsSlider.Value
        $script:MaxParallelJobs = [int]$jobsSlider.Value
    })

    $settingsPanel.Children.Add($jobsPanel) | Out-Null

    $confirmCheckbox = New-Object System.Windows.Controls.CheckBox
    $confirmCheckbox.Content = "Ask for confirmation before deletion"
    $confirmCheckbox.IsChecked = $true
    $confirmCheckbox.Margin = "10,10,0,5"
    $confirmCheckbox.FontSize = 11
    $settingsPanel.Children.Add($confirmCheckbox) | Out-Null

    $dryRunCheckbox = New-Object System.Windows.Controls.CheckBox
    $dryRunCheckbox.Content = "Dry run mode (preview only)"
    $dryRunCheckbox.IsChecked = $false
    $dryRunCheckbox.Margin = "10,10,0,5"
    $dryRunCheckbox.FontSize = 11
    $settingsPanel.Children.Add($dryRunCheckbox) | Out-Null

    $backupCheckbox = New-Object System.Windows.Controls.CheckBox
    $backupCheckbox.Content = "Back up deleted items before removal"
    $backupCheckbox.IsChecked = $true
    $backupCheckbox.Margin = "10,10,0,5"
    $backupCheckbox.FontSize = 11
    $settingsPanel.Children.Add($backupCheckbox) | Out-Null

    $restorePointCheckbox = New-Object System.Windows.Controls.CheckBox
    $restorePointCheckbox.Content = "Create restore point before cleanup"
    $restorePointCheckbox.IsChecked = $true
    $restorePointCheckbox.Margin = "10,10,0,5"
    $restorePointCheckbox.FontSize = 11
    $settingsPanel.Children.Add($restorePointCheckbox) | Out-Null

    $settingsExpander.Content = $settingsPanel
    $contentGrid.Children.Add($settingsExpander) | Out-Null

    $statusPanel = New-Object System.Windows.Controls.StackPanel
    $statusPanel.Margin = "0,20,0,0"

    $statusTitle = New-Object System.Windows.Controls.TextBlock
    $statusTitle.Text = "Status:"
    $statusTitle.FontSize = 12
    $statusTitle.FontWeight = "Bold"
    $statusTitle.Margin = "0,0,0,10"
    $statusPanel.Children.Add($statusTitle) | Out-Null

    $statusTextBlock = New-Object System.Windows.Controls.TextBlock
    $statusTextBlock.Text = "Ready to start cleanup..."
    $statusTextBlock.Margin = "0,0,0,10"
    $statusTextBlock.TextWrapping = "Wrap"
    $statusTextBlock.FontSize = 10
    $statusTextBlock.Foreground = [System.Windows.Media.Brushes]::DarkGreen
    $statusPanel.Children.Add($statusTextBlock) | Out-Null

    $progressBar = New-Object System.Windows.Controls.ProgressBar
    $progressBar.Height = 25
    $progressBar.Margin = "0,0,0,10"
    $progressBar.IsIndeterminate = $false
    $statusPanel.Children.Add($progressBar) | Out-Null

    $resultsBlock = New-Object System.Windows.Controls.TextBlock
    $resultsBlock.Text = ""
    $resultsBlock.TextWrapping = "Wrap"
    $resultsBlock.FontSize = 10
    $resultsBlock.Foreground = [System.Windows.Media.Brushes]::DarkOrange
    $statusPanel.Children.Add($resultsBlock) | Out-Null

    $contentGrid.Children.Add($statusPanel) | Out-Null

    $scrollViewer.Content = $contentGrid
    [System.Windows.Controls.Grid]::SetRow($scrollViewer, 1)
    $mainGrid.Children.Add($scrollViewer) | Out-Null

    $buttonPanel = New-Object System.Windows.Controls.StackPanel
    $buttonPanel.Orientation = "Horizontal"
    $buttonPanel.HorizontalAlignment = "Center"
    $buttonPanel.Margin = "0,10,0,10"

    $startButton = New-Object System.Windows.Controls.Button
    $startButton.Content = "▶️ Start Cleanup"
    $startButton.Width = 150
    $startButton.Height = 40
    $startButton.Margin = "5"
    $startButton.FontSize = 12
    $startButton.FontWeight = "Bold"
    $startButton.Background = [System.Windows.Media.Brushes]::LimeGreen
    $startButton.Foreground = [System.Windows.Media.Brushes]::White

    $cancelButton = New-Object System.Windows.Controls.Button
    $cancelButton.Content = "⏹️ Cancel"
    $cancelButton.Width = 150
    $cancelButton.Height = 40
    $cancelButton.Margin = "5"
    $cancelButton.FontSize = 12
    $cancelButton.FontWeight = "Bold"
    $cancelButton.Background = [System.Windows.Media.Brushes]::Red
    $cancelButton.Foreground = [System.Windows.Media.Brushes]::White
    $cancelButton.IsEnabled = $false

    $exitButton = New-Object System.Windows.Controls.Button
    $exitButton.Content = "❌ Exit"
    $exitButton.Width = 150
    $exitButton.Height = 40
    $exitButton.Margin = "5"
    $exitButton.FontSize = 12
    $exitButton.FontWeight = "Bold"
    $exitButton.Background = [System.Windows.Media.Brushes]::Gray
    $exitButton.Foreground = [System.Windows.Media.Brushes]::White

    $buttonPanel.Children.Add($startButton) | Out-Null
    $buttonPanel.Children.Add($cancelButton) | Out-Null
    $buttonPanel.Children.Add($exitButton) | Out-Null

    [System.Windows.Controls.Grid]::SetRow($buttonPanel, 2)
    $mainGrid.Children.Add($buttonPanel) | Out-Null

    $window.Content = $mainGrid

    $startButton.Add_Click({
        if ($script:CleanupRunning) { return }
        
        if ($confirmCheckbox.IsChecked) {
            $result = [System.Windows.MessageBox]::Show(
                "Are you sure you want to start cleanup? This cannot be undone without backup.",
                "Confirm Cleanup",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Question
            )
            if ($result -eq [System.Windows.MessageBoxResult]::No) { return }
        }
        
        $script:CleanupRunning = $true
        $script:CancelCleanup = $false
        $script:TotalSpaceFreed = 0
        $script:TotalItemsProcessed = 0
        
        $startButton.IsEnabled = $false
        $cancelButton.IsEnabled = $true
        $statusTextBlock.Text = "Starting cleanup process..."
        $statusTextBlock.Foreground = [System.Windows.Media.Brushes]::DarkBlue
        $progressBar.Value = 0
        $resultsBlock.Text = ""
        
        $dryRunMode = $dryRunCheckbox.IsChecked
        $backupEnabled = $backupCheckbox.IsChecked
        $restorePointEnabled = $restorePointCheckbox.IsChecked
        $throttleMode = $throttleCheckbox.IsChecked

        if ($restorePointEnabled -and -not $dryRunMode) {
            $restoreCreated = Enable-PreflightRestorePoint
            if ($restoreCreated) { Write-CleanupLog "Restore point created successfully." "Success" }
            else { Write-CleanupLog "Restore point creation was unavailable." "Warning" }
        }

        try {
            $selectedOpts = $script:SelectedOptions.Clone()
            $stepCount = 0
            $totalSteps = ($selectedOpts.Keys | Where-Object { $selectedOpts[$_] }).Count

            if ($selectedOpts["TempFiles"]) {
                $statusTextBlock.Text = "Cleaning temp files..."
                $window.Dispatcher.Invoke([action]{$window.UpdateLayout()})
                $r1 = Remove-PathContentsSafely -Path "$env:TEMP" -Limit 500 -DryRun:$dryRunMode -BackupDeleted:$backupEnabled -BackupRoot $script:BackupDir
                $r2 = Remove-PathContentsSafely -Path "$env:WINDIR\Temp" -Limit 500 -DryRun:$dryRunMode -BackupDeleted:$backupEnabled -BackupRoot $script:BackupDir
                $r3 = Remove-PathContentsSafely -Path "$env:LOCALAPPDATA\Temp" -Limit 500 -DryRun:$dryRunMode -BackupDeleted:$backupEnabled -BackupRoot $script:BackupDir
                $script:TotalItemsProcessed += ($r1.Count + $r2.Count + $r3.Count)
                $script:TotalSpaceFreed += ($r1.Size + $r2.Size + $r3.Size)
                $stepCount++
                $progressBar.Value = (($stepCount / [Math]::Max(1, $totalSteps)) * 100)
            }

            if ($selectedOpts["RecycleBin"] -and -not $script:CancelCleanup) {
                $statusTextBlock.Text = "Emptying Recycle Bin..."
                $window.Dispatcher.Invoke([action]{$window.UpdateLayout()})
                if (-not $dryRunMode) {
                    $count = Empty-RecycleBinSafely
                    $script:TotalItemsProcessed += $count
                }
                $stepCount++
                $progressBar.Value = (($stepCount / [Math]::Max(1, $totalSteps)) * 100)
            }

            if ($selectedOpts["BrowserCache"] -and -not $script:CancelCleanup) {
                $statusTextBlock.Text = "Clearing browser cache..."
                $window.Dispatcher.Invoke([action]{$window.UpdateLayout()})
                $result = Clean-BrowserCachesSafely -DryRun:$dryRunMode -BackupDeleted:$backupEnabled -BackupRoot $script:BackupDir
                $script:TotalItemsProcessed += $result.Count
                $script:TotalSpaceFreed += $result.Size
                $stepCount++
                $progressBar.Value = (($stepCount / [Math]::Max(1, $totalSteps)) * 100)
            }

            if ($selectedOpts["WindowsUpdates"] -and -not $script:CancelCleanup) {
                $statusTextBlock.Text = "Removing old Windows updates..."
                $window.Dispatcher.Invoke([action]{$window.UpdateLayout()})
                $result = Remove-PathContentsSafely -Path "$env:WINDIR\SoftwareDistribution\Download" -Limit 500 -DryRun:$dryRunMode -BackupDeleted:$backupEnabled -BackupRoot $script:BackupDir
                $script:TotalItemsProcessed += $result.Count
                $script:TotalSpaceFreed += $result.Size
                $stepCount++
                $progressBar.Value = (($stepCount / [Math]::Max(1, $totalSteps)) * 100)
            }

            if ($selectedOpts["Prefetch"] -and -not $script:CancelCleanup) {
                $statusTextBlock.Text = "Removing prefetch files..."
                $window.Dispatcher.Invoke([action]{$window.UpdateLayout()})
                $result = Remove-PathContentsSafely -Path "$env:WINDIR\Prefetch" -Limit 250 -DryRun:$dryRunMode -BackupDeleted:$backupEnabled -BackupRoot $script:BackupDir
                $script:TotalItemsProcessed += $result.Count
                $script:TotalSpaceFreed += $result.Size
                $stepCount++
                $progressBar.Value = (($stepCount / [Math]::Max(1, $totalSteps)) * 100)
            }

            if ($selectedOpts["LogFiles"] -and -not $script:CancelCleanup) {
                $statusTextBlock.Text = "Cleaning log files..."
                $window.Dispatcher.Invoke([action]{$window.UpdateLayout()})
                $result = Remove-PathContentsSafely -Path "$env:WINDIR\Logs" -Limit 250 -DryRun:$dryRunMode -BackupDeleted:$backupEnabled -BackupRoot $script:BackupDir
                $script:TotalItemsProcessed += $result.Count
                $script:TotalSpaceFreed += $result.Size
                $stepCount++
                $progressBar.Value = (($stepCount / [Math]::Max(1, $totalSteps)) * 100)
            }

            if ($selectedOpts["OrganizeDownloads"] -and -not $script:CancelCleanup) {
                $statusTextBlock.Text = "Organizing Downloads folder..."
                $window.Dispatcher.Invoke([action]{$window.UpdateLayout()})
                $downloadsPath = Get-WindowsFolderPath -FolderName 'Downloads'
                if (-not [string]::IsNullOrWhiteSpace($downloadsPath)) {
                    $result = Organize-FilesByExtension -RootFolder $downloadsPath -Limit 500 -DryRun:$dryRunMode
                    $script:TotalItemsProcessed += $result.Count
                }
                $stepCount++
                $progressBar.Value = (($stepCount / [Math]::Max(1, $totalSteps)) * 100)
            }

            if ($selectedOpts["OrganizeDesktop"] -and -not $script:CancelCleanup) {
                $statusTextBlock.Text = "Organizing Desktop folder..."
                $window.Dispatcher.Invoke([action]{$window.UpdateLayout()})
                $desktopPath = Get-WindowsFolderPath -FolderName 'Desktop'
                if (-not [string]::IsNullOrWhiteSpace($desktopPath)) {
                    $result = Organize-FilesByExtension -RootFolder $desktopPath -Limit 500 -DryRun:$dryRunMode
                    $script:TotalItemsProcessed += $result.Count
                }
                $stepCount++
                $progressBar.Value = (($stepCount / [Math]::Max(1, $totalSteps)) * 100)
            }

            if ($script:CancelCleanup) {
                $statusTextBlock.Text = "❌ Cleanup cancelled by user"
                $statusTextBlock.Foreground = [System.Windows.Media.Brushes]::Red
            }
            else {
                $statusTextBlock.Text = if ($dryRunMode) { "✅ Preview complete. No files were deleted." } else { "✅ Cleanup completed successfully!" }
                $statusTextBlock.Foreground = [System.Windows.Media.Brushes]::DarkGreen
                $progressBar.Value = 100
                $resultsBlock.Text = "📊 Results:`n" +
                    "Total Items Processed: $($script:TotalItemsProcessed)`n" +
                    "Total Space Freed: $(Get-FileSizeString $script:TotalSpaceFreed)`n`n" +
                    if ($backupEnabled -and -not $dryRunMode) { "Backups saved to: $script:BackupDir`n" } else { "" } +
                    if ($dryRunMode) { "Dry-run preview only. No data was removed." } else { "Logs saved to: $script:LogPath" }
            }
        }
        catch {
            $statusTextBlock.Text = "❌ Error during cleanup: $_"
            $statusTextBlock.Foreground = [System.Windows.Media.Brushes]::Red
            Write-CleanupLog "Cleanup error: $_" "Error"
        }
        finally {
            $script:CleanupRunning = $false
            $startButton.IsEnabled = $true
            $cancelButton.IsEnabled = $false
        }
    })

    $cancelButton.Add_Click({
        $script:CancelCleanup = $true
        $statusTextBlock.Text = "❌ Cleanup cancelled by user"
        $statusTextBlock.Foreground = [System.Windows.Media.Brushes]::Red
        $startButton.IsEnabled = $true
        $cancelButton.IsEnabled = $false
    })

    $exitButton.Add_Click({
        $script:CancelCleanup = $true
        $window.Close()
    })

    $null = $window.ShowDialog()
}
catch {
    Write-Host "ERROR: Failed to create GUI"
    Write-Host $_
    Write-Host "Press Enter to exit..."
    Read-Host
    exit 1
}


