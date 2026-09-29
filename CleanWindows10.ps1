# Windows 10 Cleanup & Organizer
# Reliable, safer Windows maintenance utility
# Run: powershell -ExecutionPolicy Bypass -File .\CleanWindows10.ps1

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:AppRoot = Join-Path $env:APPDATA "Windows10CleanupScript"
$script:LogDir = Join-Path $script:AppRoot "Logs"
$script:BackupDir = Join-Path $script:AppRoot "Backups"
$script:SessionStamp = Get-Date -Format "yyyyMMdd_HHmmss"

function Initialize-CleanupPaths {
    foreach ($path in @($script:AppRoot, $script:LogDir, $script:BackupDir)) {
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

function Write-CleanupLog {
    param(
        [string]$Message,
        [string]$Type = "Info"
    )

    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logFile = Join-Path $script:LogDir ("cleanup_" + (Get-Date -Format "yyyy-MM-dd") + ".log")
        Add-Content -Path $logFile -Value "[$timestamp] [$Type] $Message" -ErrorAction SilentlyContinue
    }
    catch {
        # ignore logging failures
    }
}

function Get-SizeString {
    param([long]$Bytes)

    if ($Bytes -ge 1GB) { return "{0:F2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { return "{0:F2} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { return "{0:F2} KB" -f ($Bytes / 1KB) }
    else { return "$Bytes B" }
}

function Get-DirectorySize {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return [long]0 }

    try {
        $sum = (Get-ChildItem -Path $Path -Force -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        if ($null -eq $sum) { return [long]0 }
        return [long]$sum
    }
    catch {
        return [long]0
    }
}

function Enable-PreflightRestorePoint {
    $restoreCommand = Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue
    if ($null -eq $restoreCommand) {
        return $false
    }

    try {
        Checkpoint-Computer -Description "Windows 10 Cleanup Script" -RestorePointType "MODIFY_SETTINGS" -WarningAction SilentlyContinue | Out-Null
        return $true
    }
    catch {
        return $false
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
                Write-CleanupLog "Failed to process $($item.FullName): $($_.Exception.Message)" "Warning"
            }
        }
    }
    catch {
        Write-CleanupLog "Error scanning path $Path : $($_.Exception.Message)" "Warning"
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

    $paths = @(
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Microsoft\Windows\INetCache",
        "$env:APPDATA\Mozilla\Firefox\Profiles"
    )

    $totalCount = 0
    $totalSize = 0
    $details = @()

    foreach ($path in $paths) {
        if (Test-Path $path) {
            $result = Remove-PathContentsSafely -Path $path -Limit 500 -DryRun:$DryRun -BackupDeleted:$BackupDeleted -BackupRoot $BackupRoot
            $totalCount += $result.Count
            $totalSize += $result.Size
            $details += $result.Details
        }
    }

    return [pscustomobject]@{ Count = $totalCount; Size = $totalSize; Details = $details }
}

function Organize-FilesByExtension {
    param(
        [string]$RootFolder,
        [int]$Limit = 500,
        [switch]$DryRun
    )

    if (-not (Test-Path $RootFolder)) { return [pscustomobject]@{ Count = 0; Moved = @() } }

    $count = 0
    $moved = @()

    try {
        $items = Get-ChildItem -Path $RootFolder -File -Force -ErrorAction SilentlyContinue | Select-Object -First $Limit
        foreach ($item in $items) {
            try {
                $ext = $item.Extension.TrimStart('.')
                if ([string]::IsNullOrWhiteSpace($ext)) { $ext = "NoExtension" }

                $targetFolder = Join-Path $RootFolder $ext
                if (-not (Test-Path $targetFolder)) {
                    if (-not $DryRun) {
                        New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null
                    }
                }

                $destination = Join-Path $targetFolder $item.Name
                if (-not (Test-Path $destination)) {
                    $moved += [pscustomobject]@{ Name = $item.Name; From = $item.FullName; To = $destination }
                    if (-not $DryRun) {
                        Move-Item -Path $item.FullName -Destination $destination -Force -ErrorAction SilentlyContinue
                    }
                    $count++
                }
            }
            catch {
                Write-CleanupLog "Could not organize $($item.FullName): $($_.Exception.Message)" "Warning"
            }
        }
    }
    catch {
        Write-CleanupLog "Could not organize folder $RootFolder : $($_.Exception.Message)" "Warning"
    }

    return [pscustomobject]@{ Count = $count; Moved = $moved }
}

function Get-PreviewSummary {
    param(
        [hashtable]$Options,
        [bool]$BackupDeleted,
        [bool]$DryRun,
        [bool]$CreateRestorePoint
    )

    $summary = New-Object System.Collections.Generic.List[string]
    $summary.Add("Profile: " + $(if ($Options["Deep"]) { "Deep" } else { "Quick" }))
    $summary.Add("Dry Run: $DryRun")
    $summary.Add("Create Restore Point: $CreateRestorePoint")
    $summary.Add("Backup Deleted Items: $BackupDeleted")

    foreach ($name in @("TempFiles", "RecycleBin", "BrowserCache", "Prefetch", "Logs", "Downloads", "Desktop")) {
        if ($Options[$name]) {
            $summary.Add("- $name")
        }
    }

    return $summary
}

Initialize-CleanupPaths

# ---------- Dark Theme ----------
$DarkBg = [System.Windows.Media.Color]::FromArgb(255, 25, 30, 38)
$PanelBg = [System.Windows.Media.Color]::FromArgb(255, 38, 44, 54)
$Accent = [System.Windows.Media.Color]::FromArgb(255, 74, 144, 226)
$Green = [System.Windows.Media.Color]::FromArgb(255, 62, 179, 112)
$Red = [System.Windows.Media.Color]::FromArgb(255, 220, 88, 88)
$Text = [System.Windows.Media.Color]::FromArgb(255, 240, 240, 240)
$SubText = [System.Windows.Media.Color]::FromArgb(255, 180, 180, 180)

# ---------- Window ----------
$window = New-Object System.Windows.Window
$window.Title = "Windows 10 Cleanup & Organizer"
$window.Width = 780
$window.Height = 810
$window.WindowStartupLocation = "CenterScreen"
$window.ResizeMode = "CanResize"
$window.Background = New-Object System.Windows.Media.SolidColorBrush($DarkBg)
$window.Foreground = New-Object System.Windows.Media.SolidColorBrush($Text)

$grid = New-Object System.Windows.Controls.Grid
$grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) | Out-Null
$grid.RowDefinitions[0].Height = "Auto"
$grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) | Out-Null
$grid.RowDefinitions[1].Height = "*"
$grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) | Out-Null
$grid.RowDefinitions[2].Height = "Auto"

$header = New-Object System.Windows.Controls.Border
$header.Background = New-Object System.Windows.Media.SolidColorBrush($PanelBg)
$header.BorderBrush = New-Object System.Windows.Media.SolidColorBrush($Accent)
$header.BorderThickness = "0,0,0,2"
$header.Padding = "18,12,18,12"

$title = New-Object System.Windows.Controls.TextBlock
$title.Text = "Windows 10 Cleanup & Organizer"
$title.FontSize = 28
$title.FontWeight = "Bold"
$title.Foreground = New-Object System.Windows.Media.SolidColorBrush($Accent)
$header.Child = $title
[System.Windows.Controls.Grid]::SetRow($header, 0)
$grid.Children.Add($header) | Out-Null

$body = New-Object System.Windows.Controls.StackPanel
$body.Margin = "20,20,20,10"

$checkItems = @(
    @{ Name = "TempFiles"; Text = "Clean Temp Files"; Checked = $true },
    @{ Name = "RecycleBin"; Text = "Empty Recycle Bin"; Checked = $true },
    @{ Name = "BrowserCache"; Text = "Clear Browser Cache"; Checked = $true },
    @{ Name = "Prefetch"; Text = "Remove Prefetch Files"; Checked = $true },
    @{ Name = "Logs"; Text = "Delete Old Log Files"; Checked = $true },
    @{ Name = "Downloads"; Text = "Organize Downloads Folder"; Checked = $true },
    @{ Name = "Desktop"; Text = "Organize Desktop Files"; Checked = $true },
    @{ Name = "Deep"; Text = "Deep Clean Mode"; Checked = $false }
)

$checkboxes = @{}
foreach ($item in $checkItems) {
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $item.Text
    $cb.IsChecked = $item.Checked
    $cb.FontSize = 16
    $cb.Margin = "0,8,0,8"
    $cb.Foreground = New-Object System.Windows.Media.SolidColorBrush($Text)
    $cb.Background = New-Object System.Windows.Media.SolidColorBrush($PanelBg)
    $checkboxes[$item.Name] = $cb
    $body.Children.Add($cb) | Out-Null
}

$optionsGrid = New-Object System.Windows.Controls.WrapPanel
$optionsGrid.Margin = "0,8,0,10"

$dryRunBox = New-Object System.Windows.Controls.CheckBox
$dryRunBox.Content = "Dry run (preview only)"
$dryRunBox.IsChecked = $false
$dryRunBox.Margin = "0,0,12,0"
$dryRunBox.Foreground = New-Object System.Windows.Media.SolidColorBrush($Text)
$optionsGrid.Children.Add($dryRunBox) | Out-Null

$restoreBox = New-Object System.Windows.Controls.CheckBox
$restoreBox.Content = "Create Restore Point"
$restoreBox.IsChecked = $true
$restoreBox.Margin = "0,0,12,0"
$restoreBox.Foreground = New-Object System.Windows.Media.SolidColorBrush($Text)
$optionsGrid.Children.Add($restoreBox) | Out-Null

$backupBox = New-Object System.Windows.Controls.CheckBox
$backupBox.Content = "Backup deleted files"
$backupBox.IsChecked = $true
$backupBox.Margin = "0,0,12,0"
$backupBox.Foreground = New-Object System.Windows.Media.SolidColorBrush($Text)
$optionsGrid.Children.Add($backupBox) | Out-Null

$body.Children.Add($optionsGrid) | Out-Null

$statusBlock = New-Object System.Windows.Controls.TextBlock
$statusBlock.Text = "Ready"
$statusBlock.FontSize = 14
$statusBlock.Foreground = New-Object System.Windows.Media.SolidColorBrush($Green)
$statusBlock.Margin = "0,15,0,8"
$body.Children.Add($statusBlock) | Out-Null

$progress = New-Object System.Windows.Controls.ProgressBar
$progress.Minimum = 0
$progress.Maximum = 100
$progress.Height = 12
$progress.Value = 0
$progress.Margin = "0,0,0,12"
$body.Children.Add($progress) | Out-Null

$resultsBlock = New-Object System.Windows.Controls.TextBlock
$resultsBlock.Text = ""
$resultsBlock.FontSize = 12
$resultsBlock.TextWrapping = "Wrap"
$resultsBlock.Foreground = New-Object System.Windows.Media.SolidColorBrush($SubText)
$resultsBlock.Margin = "0,0,0,10"
$body.Children.Add($resultsBlock) | Out-Null

[System.Windows.Controls.Grid]::SetRow($body, 1)
$grid.Children.Add($body) | Out-Null

$buttons = New-Object System.Windows.Controls.StackPanel
$buttons.Orientation = "Horizontal"
$buttons.HorizontalAlignment = "Center"
$buttons.Margin = "0,0,0,18"

$startButton = New-Object System.Windows.Controls.Button
$startButton.Content = "Start Cleanup"
$startButton.Width = 190
$startButton.Height = 44
$startButton.Margin = "10"
$startButton.FontSize = 16
$startButton.FontWeight = "Bold"
$startButton.Background = New-Object System.Windows.Media.SolidColorBrush($Green)
$startButton.Foreground = [System.Windows.Media.Brushes]::White
$buttons.Children.Add($startButton) | Out-Null

$exitButton = New-Object System.Windows.Controls.Button
$exitButton.Content = "Exit"
$exitButton.Width = 120
$exitButton.Height = 44
$exitButton.Margin = "10"
$exitButton.FontSize = 16
$exitButton.FontWeight = "Bold"
$exitButton.Background = New-Object System.Windows.Media.SolidColorBrush($Red)
$exitButton.Foreground = [System.Windows.Media.Brushes]::White
$buttons.Children.Add($exitButton) | Out-Null

[System.Windows.Controls.Grid]::SetRow($buttons, 2)
$grid.Children.Add($buttons) | Out-Null

$window.Content = $grid

$startButton.Add_Click({
    $statusBlock.Text = "Running cleanup..."
    $statusBlock.Foreground = New-Object System.Windows.Media.SolidColorBrush($Accent)
    $progress.Value = 0
    $resultsBlock.Text = ""
    $startButton.IsEnabled = $false

    try {
        $dryRun = $dryRunBox.IsChecked
        $backupItems = $backupBox.IsChecked
        $createRestorePoint = $restoreBox.IsChecked
        $selectedSteps = @{}

        foreach ($key in $checkboxes.Keys) {
            $selectedSteps[$key] = $checkboxes[$key].IsChecked
        }

        if ($createRestorePoint -and -not $dryRun) {
            $restoreResult = Enable-PreflightRestorePoint
            if ($restoreResult) {
                Write-CleanupLog "Restore point created successfully." "Success"
            }
            else {
                Write-CleanupLog "Restore point creation unavailable or failed." "Warning"
            }
        }

        $totalCount = 0
        $totalFreed = 0
        $steps = @(
            "TempFiles",
            "RecycleBin",
            "BrowserCache",
            "Prefetch",
            "Logs",
            "Downloads",
            "Desktop"
        )

        $selectedStepsCount = 0
        foreach ($step in $steps) {
            if ($selectedSteps[$step]) { $selectedStepsCount++ }
        }

        $stepIndex = 0

        if ($selectedSteps["TempFiles"]) {
            $stepIndex++
            $statusBlock.Text = "Cleaning temp files..."
            $progress.Value = [int](($stepIndex / [Math]::Max(1, $selectedStepsCount)) * 100)

            $r1 = Remove-PathContentsSafely -Path "$env:TEMP" -Limit 500 -DryRun:$dryRun -BackupDeleted:$backupItems -BackupRoot $script:BackupDir
            $r2 = Remove-PathContentsSafely -Path "$env:WINDIR\Temp" -Limit 500 -DryRun:$dryRun -BackupDeleted:$backupItems -BackupRoot $script:BackupDir
            $r3 = Remove-PathContentsSafely -Path "$env:LOCALAPPDATA\Temp" -Limit 500 -DryRun:$dryRun -BackupDeleted:$backupItems -BackupRoot $script:BackupDir
            $totalCount += $r1.Count + $r2.Count + $r3.Count
            $totalFreed += $r1.Size + $r2.Size + $r3.Size
        }

        if ($selectedSteps["RecycleBin"]) {
            $stepIndex++
            $statusBlock.Text = "Emptying Recycle Bin..."
            $progress.Value = [int](($stepIndex / [Math]::Max(1, $selectedStepsCount)) * 100)

            if (-not $dryRun) {
                $count = Empty-RecycleBinSafely
                $totalCount += $count
            }
            else {
                $totalCount += 0
            }
        }

        if ($selectedSteps["BrowserCache"]) {
            $stepIndex++
            $statusBlock.Text = "Clearing browser cache..."
            $progress.Value = [int](($stepIndex / [Math]::Max(1, $selectedStepsCount)) * 100)

            $result = Clean-BrowserCachesSafely -DryRun:$dryRun -BackupDeleted:$backupItems -BackupRoot $script:BackupDir
            $totalCount += $result.Count
            $totalFreed += $result.Size
        }

        if ($selectedSteps["Prefetch"]) {
            $stepIndex++
            $statusBlock.Text = "Removing prefetch files..."
            $progress.Value = [int](($stepIndex / [Math]::Max(1, $selectedStepsCount)) * 100)

            $result = Remove-PathContentsSafely -Path "$env:WINDIR\Prefetch" -Limit 250 -DryRun:$dryRun -BackupDeleted:$backupItems -BackupRoot $script:BackupDir
            $totalCount += $result.Count
            $totalFreed += $result.Size
        }

        if ($selectedSteps["Logs"]) {
            $stepIndex++
            $statusBlock.Text = "Deleting old logs..."
            $progress.Value = [int](($stepIndex / [Math]::Max(1, $selectedStepsCount)) * 100)

            $result = Remove-PathContentsSafely -Path "$env:WINDIR\Logs" -Limit 250 -DryRun:$dryRun -BackupDeleted:$backupItems -BackupRoot $script:BackupDir
            $totalCount += $result.Count
            $totalFreed += $result.Size
        }

        if ($selectedSteps["Downloads"]) {
            $stepIndex++
            $statusBlock.Text = "Organizing downloads..."
            $progress.Value = [int](($stepIndex / [Math]::Max(1, $selectedStepsCount)) * 100)

            $downloadsPath = Get-WindowsFolderPath -FolderName 'Downloads'
            if (-not [string]::IsNullOrWhiteSpace($downloadsPath)) {
                $downloadsMoved = Organize-FilesByExtension -RootFolder $downloadsPath -Limit 500 -DryRun:$dryRun
                $totalCount += $downloadsMoved.Count
            }
        }

        if ($selectedSteps["Desktop"]) {
            $stepIndex++
            $statusBlock.Text = "Organizing desktop..."
            $progress.Value = [int](($stepIndex / [Math]::Max(1, $selectedStepsCount)) * 100)

            $desktopPath = Get-WindowsFolderPath -FolderName 'Desktop'
            if (-not [string]::IsNullOrWhiteSpace($desktopPath)) {
                $desktopMoved = Organize-FilesByExtension -RootFolder $desktopPath -Limit 500 -DryRun:$dryRun
                $totalCount += $desktopMoved.Count
            }
        }

        $statusBlock.Text = if ($dryRun) { "Preview complete" } else { "Cleanup completed successfully" }
        $statusBlock.Foreground = New-Object System.Windows.Media.SolidColorBrush($Green)
        $progress.Value = 100

        $summaryText = "Total items affected: $totalCount`nEstimated space reclaimed: $(Get-SizeString $totalFreed)"
        if ($dryRun) {
            $summaryText += "`nThis was a preview-only run. No files were deleted."
        }
        if ($backupItems -and -not $dryRun) {
            $summaryText += "`nBackups saved to: $script:BackupDir"
        }

        $resultsBlock.Text = $summaryText

        Write-CleanupLog "Cleanup run complete. DryRun=$dryRun. TotalItems=$totalCount. SpaceFreed=$totalFreed" "Success"
    }
    catch {
        $statusBlock.Text = "Cleanup error"
        $statusBlock.Foreground = New-Object System.Windows.Media.SolidColorBrush($Red)
        $resultsBlock.Text = "Error: $($_.Exception.Message)"
        Write-CleanupLog "Cleanup error: $($_.Exception.Message)" "Error"
    }
    finally {
        $startButton.IsEnabled = $true
    }
})

$exitButton.Add_Click({
    $window.Close()
})

$window.ShowDialog() | Out-Null

# End of script


