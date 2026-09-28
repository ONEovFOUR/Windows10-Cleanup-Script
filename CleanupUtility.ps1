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
$script:LogPath = "$env:APPDATA\CleanupUtility\logs"

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
        
        $logFile = "$($script:LogPath)\cleanup_$(Get-Date -Format 'yyyy-MM-dd').log"
        $logEntry = "[$timestamp] [$Type] $Message"
        
        Add-Content -Path $logFile -Value $logEntry -ErrorAction SilentlyContinue
    }
    catch {
        # Silent fail for logging
    }
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
                $items = Get-ChildItem -Path $path -Force -ErrorAction SilentlyContinue | Select-Object -First 500
                
                foreach ($item in $items) {
                    if ($script:CancelCleanup) { break }
                    
                    try {
                        if ($item.PSIsContainer) {
                            $size = (Get-ChildItem -Path $item.FullName -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum | Select-Object -ExpandProperty Sum)
                            if ($null -eq $size) { $size = 0 }
                            Remove-Item -Path $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
                        } else {
                            $size = $item.Length
                            Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
                        }
                        $totalSize += $size
                        $itemCount++
                        
                        if ($ThrottleMode) { Start-Sleep -Milliseconds 10 }
                    }
                    catch {
                        Write-CleanupLog "Error removing item $($item.FullName): $_" "Warning"
                    }
                }
            }
            catch {
                Write-CleanupLog "Error processing temp path $path : $_" "Warning"
            }
        }
    }
    
    $script:TotalSpaceFreed += $totalSize
    $script:TotalItemsProcessed += $itemCount
    Write-CleanupLog "Removed temp files: $itemCount items, $(Format-FileSize $totalSize) freed" "Success"
}

function Remove-RecycleBin {
    param([switch]$ThrottleMode)
    
    try {
        $recycleBin = New-Object -ComObject Shell.Application
        $recycleBinItems = $recycleBin.NameSpace(10)
        
        $itemCount = 0
        $totalSize = 0
        
        $items = $recycleBinItems.Items() | Select-Object -First 1000
        
        foreach ($item in $items) {
            if ($script:CancelCleanup) { break }
            
            try {
                $totalSize += $item.Size
                $item.InvokeVerb("delete")
                $itemCount++
                if ($ThrottleMode) { Start-Sleep -Milliseconds 5 }
            }
            catch {
                # Silent fail - some items may be locked
            }
        }
        
        $script:TotalSpaceFreed += $totalSize
        $script:TotalItemsProcessed += $itemCount
        Write-CleanupLog "Cleared Recycle Bin: $itemCount items, $(Format-FileSize $totalSize) freed" "Success"
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
                $items = Get-ChildItem -Path $path -Force -ErrorAction SilentlyContinue -Recurse | Select-Object -First 500
                
                foreach ($item in $items) {
                    if ($script:CancelCleanup) { break }
                    
                    try {
                        $size = if ($item.Length) { $item.Length } else { 0 }
                        Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
                        $totalSize += $size
                        $itemCount++
                        
                        if ($ThrottleMode) { Start-Sleep -Milliseconds 5 }
                    }
                    catch {
                        # Silent fail - browsers may lock cache files
                    }
                }
            }
            catch {
                Write-CleanupLog "Error cleaning $browser cache: $_" "Warning"
            }
        }
    }
    
    $script:TotalSpaceFreed += $totalSize
    $script:TotalItemsProcessed += $itemCount
    Write-CleanupLog "Cleared browser cache: $itemCount items, $(Format-FileSize $totalSize) freed" "Success"
}

function Remove-OldWindowsUpdates {
    param([switch]$ThrottleMode)
    
    $updatePath = "$env:WINDIR\SoftwareDistribution\Download"
    $totalSize = 0
    $itemCount = 0
    
    if (Test-Path $updatePath) {
        try {
            $items = Get-ChildItem -Path $updatePath -Force -ErrorAction SilentlyContinue -Recurse | Select-Object -First 500
            
            foreach ($item in $items) {
                if ($script:CancelCleanup) { break }
                
                try {
                    if ($item.PSIsContainer) {
                        $size = (Get-ChildItem -Path $item.FullName -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum | Select-Object -ExpandProperty Sum)
                        if ($null -eq $size) { $size = 0 }
                        Remove-Item -Path $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    } else {
                        $size = $item.Length
                        Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
                    }
                    $totalSize += $size
                    $itemCount++
                    
                    if ($ThrottleMode) { Start-Sleep -Milliseconds 5 }
                }
                catch {
                    Write-CleanupLog "Error removing update file: $_" "Warning"
                }
            }
        }
        catch {
            Write-CleanupLog "Error accessing Windows Updates folder: $_" "Warning"
        }
    }
    
    $script:TotalSpaceFreed += $totalSize
    $script:TotalItemsProcessed += $itemCount
    Write-CleanupLog "Removed old Windows updates: $itemCount items, $(Format-FileSize $totalSize) freed" "Success"
}

function Remove-PrefetchFiles {
    param([switch]$ThrottleMode)
    
    $prefetchPath = "$env:WINDIR\Prefetch"
    $totalSize = 0
    $itemCount = 0
    
    if (Test-Path $prefetchPath) {
        try {
            $items = Get-ChildItem -Path $prefetchPath -Filter "*.pf" -Force -ErrorAction SilentlyContinue | Select-Object -First 500
            
            foreach ($item in $items) {
                if ($script:CancelCleanup) { break }
                
                try {
                    $totalSize += $item.Length
                    Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
                    $itemCount++
                    
                    if ($ThrottleMode) { Start-Sleep -Milliseconds 5 }
                }
                catch {
                    Write-CleanupLog "Error removing prefetch file: $_" "Warning"
                }
            }
        }
        catch {
            Write-CleanupLog "Error accessing Prefetch folder: $_" "Warning"
        }
    }
    
    $script:TotalSpaceFreed += $totalSize
    $script:TotalItemsProcessed += $itemCount
    Write-CleanupLog "Removed prefetch files: $itemCount items, $(Format-FileSize $totalSize) freed" "Success"
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
            $items = Get-ChildItem -Path $LogPath -Filter "*.log" -Force -ErrorAction SilentlyContinue -Recurse | Select-Object -First 500
            
            foreach ($item in $items) {
                if ($script:CancelCleanup) { break }
                
                try {
                    $totalSize += $item.Length
                    Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
                    $itemCount++
                    
                    if ($ThrottleMode) { Start-Sleep -Milliseconds 5 }
                }
                catch {
                    Write-CleanupLog "Error removing log file: $_" "Warning"
                }
            }
        }
        catch {
            Write-CleanupLog "Error accessing Logs folder: $_" "Warning"
        }
    }
    
    $script:TotalSpaceFreed += $totalSize
    $script:TotalItemsProcessed += $itemCount
    Write-CleanupLog "Removed log files: $itemCount items, $(Format-FileSize $totalSize) freed" "Success"
}

function Organize-DownloadsFolder {
    param([switch]$ThrottleMode)
    
    $downloadsPath = [Environment]::GetFolderPath("Downloads")
    $itemCount = 0
    
    if (Test-Path $downloadsPath) {
        try {
            $items = Get-ChildItem -Path $downloadsPath -File -Force -ErrorAction SilentlyContinue | Select-Object -First 500
            
            foreach ($item in $items) {
                if ($script:CancelCleanup) { break }
                
                try {
                    $extension = $item.Extension.TrimStart('.')
                    if ([string]::IsNullOrEmpty($extension)) { $extension = "NoExtension" }
                    
                    $folderPath = Join-Path -Path $downloadsPath -ChildPath $extension
                    if (-not (Test-Path $folderPath)) {
                        New-Item -ItemType Directory -Path $folderPath -Force -ErrorAction SilentlyContinue | Out-Null
                    }
                    
                    Move-Item -Path $item.FullName -Destination $folderPath -Force -ErrorAction SilentlyContinue
                    $itemCount++
                    
                    if ($ThrottleMode) { Start-Sleep -Milliseconds 10 }
                }
                catch {
                    Write-CleanupLog "Error organizing Downloads item: $_" "Warning"
                }
            }
        }
        catch {
            Write-CleanupLog "Error accessing Downloads folder: $_" "Warning"
        }
    }
    
    $script:TotalItemsProcessed += $itemCount
    Write-CleanupLog "Organized Downloads folder: $itemCount items sorted by extension" "Success"
}

function Organize-DesktopFolder {
    param([switch]$ThrottleMode)
    
    $desktopPath = [Environment]::GetFolderPath("Desktop")
    $itemCount = 0
    
    if (Test-Path $desktopPath) {
        try {
            $items = Get-ChildItem -Path $desktopPath -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer } | Select-Object -First 500
            
            foreach ($item in $items) {
                if ($script:CancelCleanup) { break }
                
                try {
                    $extension = $item.Extension.TrimStart('.')
                    if ([string]::IsNullOrEmpty($extension)) { $extension = "Documents" }
                    
                    $folderPath = Join-Path -Path $desktopPath -ChildPath $extension
                    if (-not (Test-Path $folderPath)) {
                        New-Item -ItemType Directory -Path $folderPath -Force -ErrorAction SilentlyContinue | Out-Null
                    }
                    
                    Move-Item -Path $item.FullName -Destination $folderPath -Force -ErrorAction SilentlyContinue
                    $itemCount++
                    
                    if ($ThrottleMode) { Start-Sleep -Milliseconds 10 }
                }
                catch {
                    Write-CleanupLog "Error organizing Desktop item: $_" "Warning"
                }
            }
        }
        catch {
            Write-CleanupLog "Error accessing Desktop folder: $_" "Warning"
        }
    }
    
    $script:TotalItemsProcessed += $itemCount
    Write-CleanupLog "Organized Desktop folder: $itemCount items sorted by type" "Success"
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

try {
    $window = New-Object System.Windows.Window
    $window.Title = "Windows 10 Cleanup & Organization Utility"
    $window.Width = 700
    $window.Height = 900
    $window.Background = [System.Windows.Media.Brushes]::White
    $window.WindowStartupLocation = "CenterScreen"
    $window.ResizeMode = "CanResize"

    # Main Grid
    $mainGrid = New-Object System.Windows.Controls.Grid
    
    for ($i = 0; $i -lt 3; $i++) {
        $mainGrid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition))
    }
    $mainGrid.RowDefinitions[0].Height = "Auto"
    $mainGrid.RowDefinitions[1].Height = "*"
    $mainGrid.RowDefinitions[2].Height = "Auto"

    # Title
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
        $checkbox.Name = $key
        $script:SelectedOptions[$key] = $true
        
        $checkbox.Add_Checked({ $script:SelectedOptions[$this.Name] = $true })
        $checkbox.Add_Unchecked({ $script:SelectedOptions[$this.Name] = $false })
        
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
        $selectedOpts = $script:SelectedOptions.Clone()
        
        # Run cleanup operations
        try {
            $stepCount = 0
            $totalSteps = ($selectedOpts.Keys | Where-Object { $selectedOpts[$_] }).Count
            
            if ($selectedOpts["TempFiles"]) {
                $statusTextBlock.Text = "Cleaning temp files..."
                $window.Dispatcher.Invoke([action]{$window.UpdateLayout()})
                Remove-TempFiles -ThrottleMode:$throttleMode
                $stepCount++
                $progressBar.Value = (($stepCount / $totalSteps) * 100)
            }
            
            if ($selectedOpts["RecycleBin"] -and -not $script:CancelCleanup) {
                $statusTextBlock.Text = "Emptying Recycle Bin..."
                $window.Dispatcher.Invoke([action]{$window.UpdateLayout()})
                Remove-RecycleBin -ThrottleMode:$throttleMode
                $stepCount++
                $progressBar.Value = (($stepCount / $totalSteps) * 100)
            }
            
            if ($selectedOpts["BrowserCache"] -and -not $script:CancelCleanup) {
                $statusTextBlock.Text = "Clearing browser cache..."
                $window.Dispatcher.Invoke([action]{$window.UpdateLayout()})
                Remove-BrowserCache -ThrottleMode:$throttleMode
                $stepCount++
                $progressBar.Value = (($stepCount / $totalSteps) * 100)
            }
            
            if ($selectedOpts["WindowsUpdates"] -and -not $script:CancelCleanup) {
                $statusTextBlock.Text = "Removing old Windows updates..."
                $window.Dispatcher.Invoke([action]{$window.UpdateLayout()})
                Remove-OldWindowsUpdates -ThrottleMode:$throttleMode
                $stepCount++
                $progressBar.Value = (($stepCount / $totalSteps) * 100)
            }
            
            if ($selectedOpts["Prefetch"] -and -not $script:CancelCleanup) {
                $statusTextBlock.Text = "Removing prefetch files..."
                $window.Dispatcher.Invoke([action]{$window.UpdateLayout()})
                Remove-PrefetchFiles -ThrottleMode:$throttleMode
                $stepCount++
                $progressBar.Value = (($stepCount / $totalSteps) * 100)
            }
            
            if ($selectedOpts["LogFiles"] -and -not $script:CancelCleanup) {
                $statusTextBlock.Text = "Cleaning log files..."
                $window.Dispatcher.Invoke([action]{$window.UpdateLayout()})
                Remove-LogFiles -LogPath "$env:WINDIR\Logs" -ThrottleMode:$throttleMode
                $stepCount++
                $progressBar.Value = (($stepCount / $totalSteps) * 100)
            }
            
            if ($selectedOpts["OrganizeDownloads"] -and -not $script:CancelCleanup) {
                $statusTextBlock.Text = "Organizing Downloads folder..."
                $window.Dispatcher.Invoke([action]{$window.UpdateLayout()})
                Organize-DownloadsFolder -ThrottleMode:$throttleMode
                $stepCount++
                $progressBar.Value = (($stepCount / $totalSteps) * 100)
            }
            
            if ($selectedOpts["OrganizeDesktop"] -and -not $script:CancelCleanup) {
                $statusTextBlock.Text = "Organizing Desktop folder..."
                $window.Dispatcher.Invoke([action]{$window.UpdateLayout()})
                Organize-DesktopFolder -ThrottleMode:$throttleMode
                $stepCount++
                $progressBar.Value = (($stepCount / $totalSteps) * 100)
            }
            
            if ($script:CancelCleanup) {
                $statusTextBlock.Text = "❌ Cleanup cancelled by user"
                $statusTextBlock.Foreground = [System.Windows.Media.Brushes]::Red
            }
            else {
                $statusTextBlock.Text = "✅ Cleanup completed successfully!"
                $statusTextBlock.Foreground = [System.Windows.Media.Brushes]::DarkGreen
                $progressBar.Value = 100
                $resultsBlock.Text = "📊 Results:`n" +
                    "Total Items Processed: $($script:TotalItemsProcessed)`n" +
                    "Total Space Freed: $(Format-FileSize $script:TotalSpaceFreed)`n`n" +
                    "Logs saved to: $script:LogPath"
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
        $script:CleanupRunning = $false
        $startButton.IsEnabled = $true
        $cancelButton.IsEnabled = $false
    })

    $exitButton.Add_Click({
        $script:CancelCleanup = $true
        $window.Close()
    })

    # Show window
    $null = $window.ShowDialog()
}
catch {
    Write-Host "ERROR: Failed to create GUI"
    Write-Host $_
    Write-Host "Press Enter to exit..."
    Read-Host
    exit 1
}
