# =============================================================================
# Windows 10 Cleanup & Organization Utility with GUI
# Advanced cleanup tool with multiple settings and heavy-load optimization
# =============================================================================

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

# Global variables for thread management
$script:CleanupRunning = $false
$script:CancelCleanup = $false
$script:MaxParallelJobs = 4
$script:TotalItemsProcessed = 0
$script:TotalSpaceFreed = 0

# =============================================================================
# LOGGING FUNCTION
# =============================================================================
function Write-CleanupLog {
    param(
        [string]$Message,
        [ValidateSet("Info", "Warning", "Error", "Success")]
        [string]$Type = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logPath = "$env:APPDATA\CleanupUtility\logs"
    
    if (-not (Test-Path $logPath)) {
        New-Item -ItemType Directory -Path $logPath -Force | Out-Null
    }
    
    $logFile = "$logPath\cleanup_$(Get-Date -Format 'yyyy-MM-dd').log"
    $logEntry = "[$timestamp] [$Type] $Message"
    
    Add-Content -Path $logFile -Value $logEntry -ErrorAction SilentlyContinue
    
    return $logEntry
}

# =============================================================================
# CLEANUP FUNCTIONS
# =============================================================================

function Remove-TempFiles {
    param([switch]$ThrottleMode)
    
    $paths = @(
        "$env:TEMP",
        "$env:WINDIR\Temp",
        "$env:LOCALAPPDATA\Temp"
    )
    
    $totalSize = 0
    $itemCount = 0
    
    foreach ($path in $paths) {
        if (Test-Path $path) {
            try {
                $items = Get-ChildItem -Path $path -Force -ErrorAction SilentlyContinue
                
                foreach ($item in $items) {
                    if ($script:CancelCleanup) { break }
                    
                    try {
                        if ($item.PSIsContainer) {
                            $size = (Get-ChildItem -Path $item.FullName -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                            Remove-Item -Path $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
                        } else {
                            $size = $item.Length
                            Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
                        }
                        $totalSize += $size
                        $itemCount++
                        
                        if ($ThrottleMode) { Start-Sleep -Milliseconds 10 }
                    }
                    catch { }
                }
            }
            catch { }
        }
    }
    
    $script:TotalSpaceFreed += $totalSize
    $script:TotalItemsProcessed += $itemCount
    Write-CleanupLog "Removed temp files: $itemCount items, $(Format-FileSize $totalSize) freed"
}

function Remove-RecycleBin {
    param([switch]$ThrottleMode)
    
    try {
        $recycleBin = New-Object -ComObject Shell.Application
        $recycleBinItems = $recycleBin.NameSpace(10)
        
        $itemCount = $recycleBinItems.Items().Count
        $totalSize = 0
        
        foreach ($item in $recycleBinItems.Items()) {
            if ($script:CancelCleanup) { break }
            
            try {
                $totalSize += $item.Size
                $item.InvokeVerb("delete")
                if ($ThrottleMode) { Start-Sleep -Milliseconds 5 }
            }
            catch { }
        }
        
        $script:TotalSpaceFreed += $totalSize
        $script:TotalItemsProcessed += $itemCount
        Write-CleanupLog "Cleared Recycle Bin: $itemCount items, $(Format-FileSize $totalSize) freed"
    }
    catch {
        Write-CleanupLog "Failed to clear Recycle Bin: $_" "Warning"
    }
}

function Remove-BrowserCache {
    param([switch]$ThrottleMode)
    
    $browserCachePaths = @{
        "Chrome"   = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache"
        "Firefox"  = "$env:APPDATA\Mozilla\Firefox\Profiles"
        "Edge"     = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache"
        "Internet Explorer" = "$env:LOCALAPPDATA\Microsoft\Windows\INetCache"
    }
    
    $totalSize = 0
    $itemCount = 0
    
    foreach ($browser in $browserCachePaths.Keys) {
        $path = $browserCachePaths[$browser]
        
        if (Test-Path $path) {
            try {
                $items = Get-ChildItem -Path $path -Force -ErrorAction SilentlyContinue -Recurse
                
                foreach ($item in $items) {
                    if ($script:CancelCleanup) { break }
                    
                    try {
                        $totalSize += $item.Length
                        Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
                        $itemCount++
                        
                        if ($ThrottleMode) { Start-Sleep -Milliseconds 5 }
                    }
                    catch { }
                }
            }
            catch { }
        }
    }
    
    $script:TotalSpaceFreed += $totalSize
    $script:TotalItemsProcessed += $itemCount
    Write-CleanupLog "Cleared browser cache: $itemCount items, $(Format-FileSize $totalSize) freed"
}

function Remove-OldWindowsUpdates {
    param([switch]$ThrottleMode)
    
    $updatePath = "$env:WINDIR\SoftwareDistribution\Download"
    $totalSize = 0
    $itemCount = 0
    
    if (Test-Path $updatePath) {
        try {
            $items = Get-ChildItem -Path $updatePath -Force -ErrorAction SilentlyContinue -Recurse
            
            foreach ($item in $items) {
                if ($script:CancelCleanup) { break }
                
                try {
                    if ($item.PSIsContainer) {
                        $size = (Get-ChildItem -Path $item.FullName -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                        Remove-Item -Path $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    } else {
                        $size = $item.Length
                        Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
                    }
                    $totalSize += $size
                    $itemCount++
                    
                    if ($ThrottleMode) { Start-Sleep -Milliseconds 5 }
                }
                catch { }
            }
        }
        catch { }
    }
    
    $script:TotalSpaceFreed += $totalSize
    $script:TotalItemsProcessed += $itemCount
    Write-CleanupLog "Removed old Windows updates: $itemCount items, $(Format-FileSize $totalSize) freed"
}

function Remove-PrefetchFiles {
    param([switch]$ThrottleMode)
    
    $prefetchPath = "$env:WINDIR\Prefetch"
    $totalSize = 0
    $itemCount = 0
    
    if (Test-Path $prefetchPath) {
        try {
            $items = Get-ChildItem -Path $prefetchPath -Filter "*.pf" -Force -ErrorAction SilentlyContinue
            
            foreach ($item in $items) {
                if ($script:CancelCleanup) { break }
                
                try {
                    $totalSize += $item.Length
                    Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
                    $itemCount++
                    
                    if ($ThrottleMode) { Start-Sleep -Milliseconds 5 }
                }
                catch { }
            }
        }
        catch { }
    }
    
    $script:TotalSpaceFreed += $totalSize
    $script:TotalItemsProcessed += $itemCount
    Write-CleanupLog "Removed prefetch files: $itemCount items, $(Format-FileSize $totalSize) freed"
}

function Remove-LogFiles {
    param(
        [string]$LogPath = "$env:WINDIR\Logs",
        [switch]$ThrottleMode
    )
    
    $totalSize = 0
    $itemCount = 0
    
    if (Test-Path $LogPath) {
        try {
            $items = Get-ChildItem -Path $LogPath -Filter "*.log" -Force -ErrorAction SilentlyContinue -Recurse
            
            foreach ($item in $items) {
                if ($script:CancelCleanup) { break }
                
                try {
                    $totalSize += $item.Length
                    Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
                    $itemCount++
                    
                    if ($ThrottleMode) { Start-Sleep -Milliseconds 5 }
                }
                catch { }
            }
        }
        catch { }
    }
    
    $script:TotalSpaceFreed += $totalSize
    $script:TotalItemsProcessed += $itemCount
    Write-CleanupLog "Removed log files: $itemCount items, $(Format-FileSize $totalSize) freed"
}

function Organize-DownloadsFolder {
    param([switch]$ThrottleMode)
    
    $downloadsPath = [Environment]::GetFolderPath("Downloads")
    $itemCount = 0
    
    if (Test-Path $downloadsPath) {
        try {
            $items = Get-ChildItem -Path $downloadsPath -File -Force -ErrorAction SilentlyContinue
            
            foreach ($item in $items) {
                if ($script:CancelCleanup) { break }
                
                try {
                    $extension = $item.Extension.TrimStart('.')
                    if ([string]::IsNullOrEmpty($extension)) { $extension = "NoExtension" }
                    
                    $folderPath = Join-Path -Path $downloadsPath -ChildPath $extension
                    if (-not (Test-Path $folderPath)) {
                        New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
                    }
                    
                    Move-Item -Path $item.FullName -Destination $folderPath -Force -ErrorAction SilentlyContinue
                    $itemCount++
                    
                    if ($ThrottleMode) { Start-Sleep -Milliseconds 10 }
                }
                catch { }
            }
        }
        catch { }
    }
    
    $script:TotalItemsProcessed += $itemCount
    Write-CleanupLog "Organized Downloads folder: $itemCount items sorted by extension"
}

function Organize-DesktopFolder {
    param([switch]$ThrottleMode)
    
    $desktopPath = [Environment]::GetFolderPath("Desktop")
    $itemCount = 0
    
    if (Test-Path $desktopPath) {
        try {
            $items = Get-ChildItem -Path $desktopPath -Force -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer -eq $false }
            
            foreach ($item in $items) {
                if ($script:CancelCleanup) { break }
                
                try {
                    $extension = $item.Extension.TrimStart('.')
                    if ([string]::IsNullOrEmpty($extension)) { $extension = "Documents" }
                    
                    $folderPath = Join-Path -Path $desktopPath -ChildPath $extension
                    if (-not (Test-Path $folderPath)) {
                        New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
                    }
                    
                    Move-Item -Path $item.FullName -Destination $folderPath -Force -ErrorAction SilentlyContinue
                    $itemCount++
                    
                    if ($ThrottleMode) { Start-Sleep -Milliseconds 10 }
                }
                catch { }
            }
        }
        catch { }
    }
    
    $script:TotalItemsProcessed += $itemCount
    Write-CleanupLog "Organized Desktop folder: $itemCount items sorted by type"
}

function Format-FileSize {
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

# =============================================================================
# GUI CREATION
# =============================================================================

$window = New-Object System.Windows.Window
$window.Title = "Windows 10 Cleanup & Organization Utility"
$window.Width = 700
$window.Height = 900
$window.Background = [System.Windows.Media.Brushes]::White
$window.WindowStartupLocation = "CenterScreen"
$window.ResizeMode = "CanResize"

# Main Grid
$mainGrid = New-Object System.Windows.Controls.Grid
$mainGrid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition))
$mainGrid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition))
$mainGrid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition))
$mainGrid.RowDefinitions[0].Height = "Auto"
$mainGrid.RowDefinitions[1].Height = "*"
$mainGrid.RowDefinitions[2].Height = "Auto"

# Title
$titleBlock = New-Object System.Windows.Controls.TextBlock
$titleBlock.Text = "🧹 Windows 10 Cleanup & Organization Utility"
$titleBlock.FontSize = 18
$titleBlock.FontWeight = "Bold"
$titleBlock.Foreground = [System.Windows.Media.Brushes]::DarkBlue
$titleBlock.Padding = "15"
$titleBlock.Background = [System.Windows.Media.Brushes]::LightGray

[System.Windows.Controls.Grid]::SetRow($titleBlock, 0)
$mainGrid.Children.Add($titleBlock) | Out-Null

# Content Scroll Viewer
$scrollViewer = New-Object System.Windows.Controls.ScrollViewer
$scrollViewer.VerticalScrollBarVisibility = "Auto"

$contentGrid = New-Object System.Windows.Controls.Grid
$contentGrid.Margin = "15"

# Cleanup Options Section
$optionsStackPanel = New-Object System.Windows.Controls.StackPanel

$optionsTitle = New-Object System.Windows.Controls.TextBlock
$optionsTitle.Text = "Cleanup Options:"
$optionsTitle.FontSize = 14
$optionsTitle.FontWeight = "Bold"
$optionsTitle.Margin = "0,0,0,10"
$optionsStackPanel.Children.Add($optionsTitle) | Out-Null

# Create checkboxes for cleanup options
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
    $checkbox.Add_Checked({ $script:SelectedOptions[$checkbox.Name] = $true })
    $checkbox.Add_Unchecked({ $script:SelectedOptions[$checkbox.Name] = $false })
    $checkbox.Name = $key
    $script:SelectedOptions[$key] = $true
    
    $optionsStackPanel.Children.Add($checkbox) | Out-Null
}

$contentGrid.Children.Add($optionsStackPanel) | Out-Null

# Advanced Settings Section
$settingsExpander = New-Object System.Windows.Controls.Expander
$settingsExpander.Header = "⚙️ Advanced Settings"
$settingsExpander.Margin = "0,20,0,0"
$settingsExpander.IsExpanded = $false

$settingsPanel = New-Object System.Windows.Controls.StackPanel

# Throttle Mode
$throttleCheckbox = New-Object System.Windows.Controls.CheckBox
$throttleCheckbox.Content = "Enable Throttle Mode (Lighter on system resources)"
$throttleCheckbox.IsChecked = $true
$throttleCheckbox.Margin = "10,10,0,5"
$throttleCheckbox.FontSize = 11
$settingsPanel.Children.Add($throttleCheckbox) | Out-Null

# Parallel Jobs
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

# Delete with Confirmation
$confirmCheckbox = New-Object System.Windows.Controls.CheckBox
$confirmCheckbox.Content = "Ask for confirmation before deletion"
$confirmCheckbox.IsChecked = $true
$confirmCheckbox.Margin = "10,10,0,5"
$confirmCheckbox.FontSize = 11
$settingsPanel.Children.Add($confirmCheckbox) | Out-Null

$settingsExpander.Content = $settingsPanel
$contentGrid.Children.Add($settingsExpander) | Out-Null

# Status Section
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

# Progress Bar
$progressBar = New-Object System.Windows.Controls.ProgressBar
$progressBar.Height = 25
$progressBar.Margin = "0,0,0,10"
$progressBar.IsIndeterminate = $false
$statusPanel.Children.Add($progressBar) | Out-Null

# Results
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

# Bottom Button Panel
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

# =============================================================================
# EVENT HANDLERS
# =============================================================================

$startButton.Add_Click({
    if ($script:CleanupRunning) { return }
    
    if ($confirmCheckbox.IsChecked) {
        $result = [System.Windows.MessageBox]::Show(
            "Are you sure you want to start cleanup? This cannot be undone.",
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
    
    $throttleMode = $throttleCheckbox.IsChecked
    
    # Run cleanup in background job
    $cleanupJob = Start-Job -ScriptBlock {
        param($options, $throttleMode, $maxJobs)
        
        $progressCount = 0
        $totalSteps = ($options.Keys | Where-Object { $options[$_] }).Count
        
        if ($options["TempFiles"]) {
            Write-Host "Cleaning temp files..."
            & $using:Remove-TempFiles -ThrottleMode:$throttleMode
            $progressCount++
            Write-Progress -Activity "Cleanup Running" -Status "Processing..." -PercentComplete (($progressCount / $totalSteps) * 100)
        }
        
        if ($options["RecycleBin"]) {
            Write-Host "Emptying Recycle Bin..."
            & $using:Remove-RecycleBin -ThrottleMode:$throttleMode
            $progressCount++
            Write-Progress -Activity "Cleanup Running" -Status "Processing..." -PercentComplete (($progressCount / $totalSteps) * 100)
        }
        
        if ($options["BrowserCache"]) {
            Write-Host "Clearing browser cache..."
            & $using:Remove-BrowserCache -ThrottleMode:$throttleMode
            $progressCount++
            Write-Progress -Activity "Cleanup Running" -Status "Processing..." -PercentComplete (($progressCount / $totalSteps) * 100)
        }
        
        if ($options["WindowsUpdates"]) {
            Write-Host "Removing old Windows updates..."
            & $using:Remove-OldWindowsUpdates -ThrottleMode:$throttleMode
            $progressCount++
            Write-Progress -Activity "Cleanup Running" -Status "Processing..." -PercentComplete (($progressCount / $totalSteps) * 100)
        }
        
        if ($options["Prefetch"]) {
            Write-Host "Removing prefetch files..."
            & $using:Remove-PrefetchFiles -ThrottleMode:$throttleMode
            $progressCount++
            Write-Progress -Activity "Cleanup Running" -Status "Processing..." -PercentComplete (($progressCount / $totalSteps) * 100)
        }
        
        if ($options["LogFiles"]) {
            Write-Host "Cleaning log files..."
            & $using:Remove-LogFiles -LogPath "$env:WINDIR\Logs" -ThrottleMode:$throttleMode
            $progressCount++
            Write-Progress -Activity "Cleanup Running" -Status "Processing..." -PercentComplete (($progressCount / $totalSteps) * 100)
        }
        
        if ($options["OrganizeDownloads"]) {
            Write-Host "Organizing Downloads folder..."
            & $using:Organize-DownloadsFolder -ThrottleMode:$throttleMode
            $progressCount++
            Write-Progress -Activity "Cleanup Running" -Status "Processing..." -PercentComplete (($progressCount / $totalSteps) * 100)
        }
        
        if ($options["OrganizeDesktop"]) {
            Write-Host "Organizing Desktop folder..."
            & $using:Organize-DesktopFolder -ThrottleMode:$throttleMode
            $progressCount++
            Write-Progress -Activity "Cleanup Running" -Status "Processing..." -PercentComplete (($progressCount / $totalSteps) * 100)
        }
        
        Write-Host "Cleanup completed!"
    } -ArgumentList $script:SelectedOptions, $throttleMode, $script:MaxParallelJobs
    
    # Monitor job
    $monitorTimer = New-Object System.Windows.Forms.Timer
    $monitorTimer.Interval = 500
    
    $monitorTimer.Add_Tick({
        if ($cleanupJob.State -eq "Completed") {
            $output = Receive-Job -Job $cleanupJob
            
            $statusTextBlock.Text = "✅ Cleanup completed successfully!"
            $statusTextBlock.Foreground = [System.Windows.Media.Brushes]::DarkGreen
            $progressBar.Value = 100
            $resultsBlock.Text = "📊 Results:`n" +
                "Total Items Processed: $($script:TotalItemsProcessed)`n" +
                "Total Space Freed: $(Format-FileSize $script:TotalSpaceFreed)`n`n" +
                "Check logs at: $env:APPDATA\CleanupUtility\logs"
            
            $script:CleanupRunning = $false
            $startButton.IsEnabled = $true
            $cancelButton.IsEnabled = $false
            $monitorTimer.Stop()
            $monitorTimer.Dispose()
            
            Remove-Job -Job $cleanupJob
        }
    })
    
    $monitorTimer.Start()
})

$cancelButton.Add_Click({
    $script:CancelCleanup = $true
    $statusTextBlock.Text = "❌ Cleanup cancelled by user"
    $statusTextBlock.Foreground = [System.Windows.Media.Brushes]::Red
    
    $script:CleanupRunning = $false
    $startButton.IsEnabled = $true
    $cancelButton.IsEnabled = $false
})

$exitButton.Add_Click({
    $script:CancelCleanup = $true
    $window.Close()
})

$window.Add_Closed({
    if ($script:CleanupRunning) {
        $script:CancelCleanup = $true
    }
})

# Show window
$window.ShowDialog() | Out-Null
