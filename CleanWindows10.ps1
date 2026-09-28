# Windows 10 Cleanup & Organizer
# Reliable GUI version with a cleaner dark theme and no hidden PowerShell side-window.
# Save as: CleanWindows10.ps1
# Run: powershell -ExecutionPolicy Bypass -File .\CleanWindows10.ps1

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ---------- Utility functions ----------
function Get-SizeString {
    param([long]$Bytes)

    if ($Bytes -ge 1GB) { return "{0:F2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { return "{0:F2} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { return "{0:F2} KB" -f ($Bytes / 1KB) }
    else { return "$Bytes B" }
}

function Remove-PathContentsSafely {
    param(
        [string]$Path,
        [int]$Limit = 500
    )

    if (-not (Test-Path $Path)) { return @{ Count = 0; Size = 0 } }

    $count = 0
    $totalSize = 0

    try {
        $items = Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue | Select-Object -First $Limit
        foreach ($item in $items) {
            try {
                if ($item.PSIsContainer) {
                    $childSize = (Get-ChildItem -Path $item.FullName -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                    if ($null -eq $childSize) { $childSize = 0 }
                    $totalSize += [long]$childSize
                    Remove-Item -Path $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
                else {
                    $totalSize += [long]$item.Length
                    Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
                }
                $count++
            }
            catch {
                # Ignore locked or protected items
            }
        }
    }
    catch {
        # Ignore path access problems
    }

    return @{ Count = $count; Size = $totalSize }
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
    $paths = @(
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Microsoft\Windows\INetCache",
        "$env:APPDATA\Mozilla\Firefox\Profiles"
    )

    $total = 0
    $count = 0
    foreach ($p in $paths) {
        if (Test-Path $p) {
            $result = Remove-PathContentsSafely -Path $p -Limit 500
            $count += $result.Count
            $total += $result.Size
        }
    }
    return @{ Count = $count; Size = $total }
}

function Organize-FilesByExtension {
    param(
        [string]$RootFolder,
        [int]$Limit = 500
    )

    if (-not (Test-Path $RootFolder)) { return 0 }

    $count = 0
    try {
        $items = Get-ChildItem -Path $RootFolder -File -Force -ErrorAction SilentlyContinue | Select-Object -First $Limit
        foreach ($item in $items) {
            try {
                $ext = $item.Extension.TrimStart('.')
                if ([string]::IsNullOrWhiteSpace($ext)) { $ext = "NoExtension" }

                $targetFolder = Join-Path $RootFolder $ext
                if (-not (Test-Path $targetFolder)) {
                    New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null
                }

                $destination = Join-Path $targetFolder $item.Name
                if (-not (Test-Path $destination)) {
                    Move-Item -Path $item.FullName -Destination $destination -Force -ErrorAction SilentlyContinue
                    $count++
                }
            }
            catch {
                # ignore move conflicts
            }
        }
    }
    catch {
        # ignore path access problems
    }

    return $count
}

# ---------- Dark theme colors ----------
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
$window.Width = 760
$window.Height = 760
$window.WindowStartupLocation = "CenterScreen"
$window.ResizeMode = "CanResize"
$window.Background = New-Object System.Windows.Media.SolidColorBrush($DarkBg)
$window.Foreground = New-Object System.Windows.Media.SolidColorBrush($Text)

# Main grid
$grid = New-Object System.Windows.Controls.Grid
$grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) | Out-Null
$grid.RowDefinitions[0].Height = "Auto"
$grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) | Out-Null
$grid.RowDefinitions[1].Height = "*"
$grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) | Out-Null
$grid.RowDefinitions[2].Height = "Auto"

# Header
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

# Content stack
$body = New-Object System.Windows.Controls.StackPanel
$body.Margin = "20,20,20,10"

# Checkboxes
$checkItems = @(
    @{ Name = "TempFiles"; Text = "Clean Temp Files"; Checked = $true },
    @{ Name = "RecycleBin"; Text = "Empty Recycle Bin"; Checked = $true },
    @{ Name = "BrowserCache"; Text = "Clear Browser Cache"; Checked = $true },
    @{ Name = "Prefetch"; Text = "Remove Prefetch Files"; Checked = $true },
    @{ Name = "Logs"; Text = "Delete Old Log Files"; Checked = $true },
    @{ Name = "Downloads"; Text = "Organize Downloads Folder"; Checked = $true },
    @{ Name = "Desktop"; Text = "Organize Desktop Files"; Checked = $true }
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

# Status section
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

# Footer buttons
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

# ---------- Event handlers ----------
$startButton.Add_Click({
    $statusBlock.Text = "Running cleanup..."
    $statusBlock.Foreground = New-Object System.Windows.Media.SolidColorBrush($Accent)
    $progress.Value = 0
    $resultsBlock.Text = ""
    $startButton.IsEnabled = $false

    try {
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
        $selectedSteps = 0
        foreach ($step in $steps) {
            if ($checkboxes[$step].IsChecked) { $selectedSteps++ }
        }
        $stepIndex = 0

        # Temp files
        if ($checkboxes["TempFiles"].IsChecked) {
            $stepIndex++
            $statusBlock.Text = "Cleaning temp files..."
            $progress.Value = [int](($stepIndex / $selectedSteps) * 100)
            $r1 = Remove-PathContentsSafely -Path "$env:TEMP" -Limit 500
            $r2 = Remove-PathContentsSafely -Path "$env:WINDIR\Temp" -Limit 500
            $r3 = Remove-PathContentsSafely -Path "$env:LOCALAPPDATA\Temp" -Limit 500
            $totalCount += $r1.Count + $r2.Count + $r3.Count
            $totalFreed += $r1.Size + $r2.Size + $r3.Size
        }

        # Recycle Bin
        if ($checkboxes["RecycleBin"].IsChecked) {
            $stepIndex++
            $statusBlock.Text = "Emptying Recycle Bin..."
            $progress.Value = [int](($stepIndex / $selectedSteps) * 100)
            $count = Empty-RecycleBinSafely
            $totalCount += $count
        }

        # Browser cache
        if ($checkboxes["BrowserCache"].IsChecked) {
            $stepIndex++
            $statusBlock.Text = "Clearing browser cache..."
            $progress.Value = [int](($stepIndex / $selectedSteps) * 100)
            $result = Clean-BrowserCachesSafely
            $totalCount += $result.Count
            $totalFreed += $result.Size
        }

        # Prefetch
        if ($checkboxes["Prefetch"].IsChecked) {
            $stepIndex++
            $statusBlock.Text = "Removing prefetch files..."
            $progress.Value = [int](($stepIndex / $selectedSteps) * 100)
            $result = Remove-PathContentsSafely -Path "$env:WINDIR\Prefetch" -Limit 250
            $totalCount += $result.Count
            $totalFreed += $result.Size
        }

        # Logs
        if ($checkboxes["Logs"].IsChecked) {
            $stepIndex++
            $statusBlock.Text = "Deleting old logs..."
            $progress.Value = [int](($stepIndex / $selectedSteps) * 100)
            $result = Remove-PathContentsSafely -Path "$env:WINDIR\Logs" -Limit 250
            $totalCount += $result.Count
            $totalFreed += $result.Size
        }

        # Downloads
        if ($checkboxes["Downloads"].IsChecked) {
            $stepIndex++
            $statusBlock.Text = "Organizing Downloads..."
            $progress.Value = [int](($stepIndex / $selectedSteps) * 100)
            $downloadsPath = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Downloads)
            $downloadsMoved = Organize-FilesByExtension -RootFolder $downloadsPath -Limit 500
            $totalCount += $downloadsMoved
        }

        # Desktop
        if ($checkboxes["Desktop"].IsChecked) {
            $stepIndex++
            $statusBlock.Text = "Organizing Desktop..."
            $progress.Value = [int](($stepIndex / $selectedSteps) * 100)
            $desktopPath = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Desktop)
            $desktopMoved = Organize-FilesByExtension -RootFolder $desktopPath -Limit 500
            $totalCount += $desktopMoved
        }

        $statusBlock.Text = "Cleanup completed successfully"
        $statusBlock.Foreground = New-Object System.Windows.Media.SolidColorBrush($Green)
        $progress.Value = 100
        $resultsBlock.Text = "Total items processed: $totalCount`nEstimated space reclaimed: $(Get-SizeString $totalFreed)"
    }
    catch {
        $statusBlock.Text = "Cleanup error"
        $statusBlock.Foreground = New-Object System.Windows.Media.SolidColorBrush($Red)
        $resultsBlock.Text = "Error: $($_.Exception.Message)"
    }
    finally {
        $startButton.IsEnabled = $true
    }
})

$exitButton.Add_Click({
    $window.Close()
})

# Show the window
$window.ShowDialog() | Out-Null
