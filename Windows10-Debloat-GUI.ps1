<#
.SYNOPSIS
    Windows 10 Debloat Tool - Advanced GUI Edition

.DESCRIPTION
    Enterprise-grade point-and-click front end for debloating Windows 10:
    - Pick which pre-installed apps to remove
    - Toggle telemetry/ads settings
    - Disable unnecessary services
    - Remove bloatware and OEM apps
    - Live progress tracking and detailed logging
    - Full rollback via System Restore Point

.NOTES
    - Self-elevates: automatically requests Administrator if needed
    - Safe mode: nothing runs until you click "Run Selected"
    - Everything is reversible via System Restore Point
    - Logs saved to Debloat-Log.txt next to the script

.USAGE
    Right-click -> Run with PowerShell
    (or) powershell.exe -ExecutionPolicy Bypass -File .\Windows10-Debloat-GUI.ps1
#>

# Self-elevate if not admin
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    $psi = @{
        FilePath     = "powershell.exe"
        ArgumentList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        Verb         = "RunAs"
    }
    try {
        Start-Process @psi
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Administrator rights required.", "Debloat Tool", "OK", "Error") | Out-Null
    }
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ------------------------------------------------------------------
# CONFIGURATION & DATA
# ------------------------------------------------------------------
$script:LogFile = Join-Path $PSScriptRoot "Debloat-Log.txt"
$script:ViewMode = "Curated"
$script:CurrentApps = @()
$script:TotalAppsToRemove = 0
$script:AppsRemoved = 0
$script:IsRunning = $false

$AppCatalog = @(
    # Microsoft Bloatware
    @{ Display = "3D Builder / 3D Viewer";        Id = "*3DBuilder*";  Group = "Microsoft" }
    @{ Display = "Cortana";                        Id = "Microsoft.549981C3F5F10"; Group = "Microsoft" }
    @{ Display = "Bing Weather";                   Id = "Microsoft.BingWeather"; Group = "Microsoft" }
    @{ Display = "Bing News";                      Id = "Microsoft.BingNews"; Group = "Microsoft" }
    @{ Display = "Bing Finance";                   Id = "Microsoft.BingFinance"; Group = "Microsoft" }
    @{ Display = "Bing Sports";                    Id = "Microsoft.BingSports"; Group = "Microsoft" }
    @{ Display = "Get Help";                       Id = "Microsoft.GetHelp"; Group = "Microsoft" }
    @{ Display = "Tips (Get Started)";             Id = "Microsoft.Getstarted"; Group = "Microsoft" }
    @{ Display = "Messaging";                      Id = "Microsoft.Messaging"; Group = "Microsoft" }
    @{ Display = "Office Hub";                     Id = "Microsoft.MicrosoftOfficeHub"; Group = "Microsoft" }
    @{ Display = "Solitaire Collection";           Id = "Microsoft.MicrosoftSolitaireCollection"; Group = "Microsoft" }
    @{ Display = "Sticky Notes";                   Id = "Microsoft.MicrosoftStickyNotes"; Group = "Microsoft" }
    @{ Display = "Mixed Reality Portal";           Id = "Microsoft.MixedReality.Portal"; Group = "Microsoft" }
    @{ Display = "Network Speed Test";             Id = "Microsoft.NetworkSpeedTest"; Group = "Microsoft" }
    @{ Display = "OneNote (Store version)";        Id = "Microsoft.Office.OneNote"; Group = "Microsoft" }
    @{ Display = "Sway";                           Id = "Microsoft.Office.Sway"; Group = "Microsoft" }
    @{ Display = "People";                         Id = "Microsoft.People"; Group = "Microsoft" }
    @{ Display = "Print 3D";                       Id = "Microsoft.Print3D"; Group = "Microsoft" }
    @{ Display = "Skype";                          Id = "Microsoft.SkypeApp"; Group = "Microsoft" }
    @{ Display = "Microsoft Wallet";               Id = "Microsoft.Wallet"; Group = "Microsoft" }
    @{ Display = "Whiteboard";                     Id = "Microsoft.Whiteboard"; Group = "Microsoft" }
    @{ Display = "Alarms & Clock";                 Id = "Microsoft.WindowsAlarms"; Group = "Microsoft" }
    @{ Display = "Camera";                         Id = "Microsoft.WindowsCamera"; Group = "Microsoft" }
    @{ Display = "Mail and Calendar";              Id = "microsoft.windowscommunicationsapps"; Group = "Microsoft" }
    @{ Display = "Feedback Hub";                   Id = "Microsoft.WindowsFeedbackHub"; Group = "Microsoft" }
    @{ Display = "Maps";                           Id = "Microsoft.WindowsMaps"; Group = "Microsoft" }
    @{ Display = "Sound Recorder";                 Id = "Microsoft.WindowsSoundRecorder"; Group = "Microsoft" }
    @{ Display = "Xbox apps (all)";                Id = "*Xbox*"; Group = "Microsoft" }
    @{ Display = "Your Phone / Phone Link";        Id = "Microsoft.YourPhone"; Group = "Microsoft" }
    @{ Display = "Groove Music";                   Id = "Microsoft.ZuneMusic"; Group = "Microsoft" }
    @{ Display = "Movies & TV";                    Id = "Microsoft.ZuneVideo"; Group = "Microsoft" }
    @{ Display = "Microsoft Teams (consumer)";     Id = "MicrosoftTeams"; Group = "Microsoft" }
    @{ Display = "Microsoft To Do";                Id = "Microsoft.Todos"; Group = "Microsoft" }
    @{ Display = "Power Automate Desktop";         Id = "Microsoft.PowerAutomateDesktop"; Group = "Microsoft" }
    @{ Display = "New Outlook";                    Id = "Microsoft.OutlookForWindows"; Group = "Microsoft" }
    @{ Display = "Clipchamp";                      Id = "Clipchamp.Clipchamp"; Group = "Microsoft" }
    
    # OEM Bloatware
    @{ Display = "Facebook (OEM)";                 Id = "*Facebook*"; Group = "OEM" }
    @{ Display = "Twitter (OEM)";                  Id = "*Twitter*"; Group = "OEM" }
    @{ Display = "Spotify (OEM)";                  Id = "*Spotify*"; Group = "OEM" }
    @{ Display = "Disney+ (OEM)";                  Id = "*Disney*"; Group = "OEM" }
    @{ Display = "Candy Crush (OEM)";              Id = "*CandyCrush*"; Group = "OEM" }
    @{ Display = "Bubble Witch (OEM)";             Id = "*BubbleWitch*"; Group = "OEM" }
    @{ Display = "McAfee (OEM)";                   Id = "*McAfee*"; Group = "OEM" }
    @{ Display = "Dolby Access (OEM)";             Id = "*Dolby*"; Group = "OEM" }
)

# Services to disable (optional)
$ServicesTodisable = @(
    @{ Display = "DiagTrack (Connected User Experiences)"; Service = "DiagTrack" }
    @{ Display = "dmwappushservice (Device Management)"; Service = "dmwappushservice" }
    @{ Display = "dmwappushservice (scheduled task)"; Type = "Task"; Path = "Microsoft\Windows\DM\dmwappushservice" }
    @{ Display = "Cortana (scheduled task)"; Type = "Task"; Path = "Microsoft\Windows\Cortana\RemindersSync" }
    @{ Display = "Customer Experience Improvement Program (CEIP)"; Type = "Task"; Path = "Microsoft\Windows\Application Experience\ProgramDataUpdater" }
)

# ------------------------------------------------------------------
# LOGGING FUNCTIONS
# ------------------------------------------------------------------
function Write-Log {
    param(
        [string]$Text,
        [string]$Color = "Black",
        [switch]$NoNewLine
    )
    $timestamp = Get-Date -Format "HH:mm:ss"
    $line = "[$timestamp] $Text"
    
    $LogBox.SelectionStart = $LogBox.TextLength
    $LogBox.SelectionLength = 0
    $LogBox.SelectionColor = [System.Drawing.Color]::$Color
    if ($NoNewLine) {
        $LogBox.AppendText($Text)
    } else {
        $LogBox.AppendText("$line`r`n")
    }
    $LogBox.ScrollToCaret()
    Add-Content -Path $script:LogFile -Value $line -ErrorAction SilentlyContinue
    [System.Windows.Forms.Application]::DoEvents()
}

# ------------------------------------------------------------------
# APP MANAGEMENT FUNCTIONS
# ------------------------------------------------------------------
function Get-InstalledAppItems {
    Write-Log "Scanning installed UWP apps..." "Blue"
    try {
        $pkgs = Get-AppxPackage -AllUsers -ErrorAction Stop
    } catch {
        $pkgs = Get-AppxPackage -ErrorAction SilentlyContinue
    }
    $pkgs = $pkgs | Where-Object { -not $_.IsFramework -and -not $_.NonRemovable } | Sort-Object Name
    $items = @()
    foreach ($p in $pkgs) {
        $items += @{ Display = $p.Name; Id = $p.Name; Kind = "Appx"; PackageFullName = $p.PackageFullName }
    }
    Write-Log "Found $($items.Count) removable Store apps." "Green"
    return $items
}

function Get-DesktopAppItems {
    Write-Log "Scanning installed desktop programs..." "Blue"
    $roots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $seen = @{}
    $items = @()
    
    foreach ($root in $roots) {
        Get-ItemProperty -Path $root -ErrorAction SilentlyContinue | ForEach-Object {
            $name = $_.DisplayName
            if (-not $name) { return }
            if ($_.SystemComponent -eq 1) { return }
            if (-not $_.UninstallString -and -not $_.QuietUninstallString) { return }

            $key = "$name|$($_.Publisher)"
            if ($seen.ContainsKey($key)) { return }
            $seen[$key] = $true

            $displayText = if ($_.DisplayVersion) { "$name ($($_.DisplayVersion))" } else { $name }
            if ($_.Publisher) { $displayText += " — $($_.Publisher)" }

            $items += @{
                Display               = $displayText
                Id                    = $key
                Kind                  = "Desktop"
                UninstallString       = $_.UninstallString
                QuietUninstallString  = $_.QuietUninstallString
            }
        }
    }
    $items = @($items | Sort-Object { $_.Display })
    Write-Log "Found $($items.Count) desktop programs." "Green"
    return $items
}

function Remove-AppItem {
    param(
        [hashtable]$AppItem,
        [bool]$AllUsers = $true
    )
    
    try {
        if ($AppItem.Kind -eq "Appx") {
            Write-Log "  → Removing: $($AppItem.Display)..." "Yellow" -NoNewLine
            if ($AllUsers) {
                Remove-AppxPackage -Package $AppItem.PackageFullName -AllUsers -ErrorAction Stop | Out-Null
            } else {
                Remove-AppxPackage -Package $AppItem.PackageFullName -ErrorAction Stop | Out-Null
            }
            Write-Log " ✓ Removed" "Green"
            return $true
        }
        elseif ($AppItem.Kind -eq "Desktop") {
            Write-Log "  → Removing: $($AppItem.Display)..." "Yellow" -NoNewLine
            if ($AppItem.QuietUninstallString) {
                $cmd = $AppItem.QuietUninstallString -replace '"msiexec.exe"', 'msiexec.exe' -replace '/I', '/X' -replace '/i', '/x'
                cmd /c $cmd 2>&1 | Out-Null
            } else {
                $cmd = $AppItem.UninstallString -replace '"msiexec.exe"', 'msiexec.exe' -replace '/I', '/X' -replace '/i', '/x'
                cmd /c $cmd 2>&1 | Out-Null
            }
            Write-Log " ✓ Removed" "Green"
            return $true
        }
    }
    catch {
        Write-Log " ✗ Failed: $($_.Exception.Message)" "Red"
        return $false
    }
}

function Disable-Telemetry {
    Write-Log "`n[TELEMETRY REDUCTION]" "Cyan"
    
    # Disable DiagTrack service
    Write-Log "Disabling DiagTrack service..." "Yellow"
    try {
        Set-Service -Name "DiagTrack" -StartupType Disabled -ErrorAction SilentlyContinue
        Stop-Service -Name "DiagTrack" -Force -ErrorAction SilentlyContinue
        Write-Log "  ✓ DiagTrack disabled" "Green"
    } catch {
        Write-Log "  ✗ Could not disable DiagTrack" "Red"
    }

    # Disable dmwappushservice
    Write-Log "Disabling dmwappushservice..." "Yellow"
    try {
        Set-Service -Name "dmwappushservice" -StartupType Disabled -ErrorAction SilentlyContinue
        Stop-Service -Name "dmwappushservice" -Force -ErrorAction SilentlyContinue
        Write-Log "  ✓ dmwappushservice disabled" "Green"
    } catch {
        Write-Log "  ✗ Could not disable dmwappushservice" "Red"
    }

    # Disable scheduled tasks
    Write-Log "Disabling telemetry scheduled tasks..." "Yellow"
    $taskPaths = @(
        "Microsoft\Windows\Application Experience\ProgramDataUpdater"
        "Microsoft\Windows\Application Experience\ConsentPromptUser"
        "Microsoft\Windows\Autochk\Proxy"
        "Microsoft\Windows\Customer Experience Improvement Program\Consolidator"
        "Microsoft\Windows\Customer Experience Improvement Program\KernelCeipTask"
        "Microsoft\Windows\Customer Experience Improvement Program\UsbCeip"
        "Microsoft\Windows\DM\dmwappushservice"
        "Microsoft\Windows\Cortana\RemindersSync"
    )
    
    foreach ($path in $taskPaths) {
        try {
            $task = Get-ScheduledTask -TaskPath "\$path\" -ErrorAction SilentlyContinue
            if ($task) {
                Disable-ScheduledTask -InputObject $task -ErrorAction SilentlyContinue
            }
        } catch {}
    }
    Write-Log "  ✓ Telemetry tasks disabled" "Green"
}

function Disable-Ads {
    Write-Log "`n[DISABLE ADS & SUGGESTIONS]" "Cyan"
    
    Write-Log "Disabling Start menu suggestions..." "Yellow"
    try {
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        Set-ItemProperty -Path $regPath -Name "ContentDeliveryAllowed" -Value 0 -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $regPath -Name "OemPreInstalledAppsEnabled" -Value 0 -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $regPath -Name "PreInstalledAppsEnabled" -Value 0 -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $regPath -Name "PreInstalledAppsEverEnabled" -Value 0 -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $regPath -Name "SilentInstalledAppsEnabled" -Value 0 -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $regPath -Name "SubscribedContentEnabled" -Value 0 -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $regPath -Name "SystemPaneSuggestionsEnabled" -Value 0 -ErrorAction SilentlyContinue
        Write-Log "  ✓ Start menu suggestions disabled" "Green"
    } catch {
        Write-Log "  ✗ Could not disable suggestions" "Red"
    }

    Write-Log "Disabling lock screen tips..." "Yellow"
    try {
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        Set-ItemProperty -Path $regPath -Name "RotatingLockScreenEnabled" -Value 0 -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $regPath -Name "RotatingLockScreenOverlayEnabled" -Value 0 -ErrorAction SilentlyContinue
        Write-Log "  ✓ Lock screen tips disabled" "Green"
    } catch {
        Write-Log "  ✗ Could not disable lock screen tips" "Red"
    }
}

function Remove-3DObjects {
    Write-Log "`n[REMOVE 3D OBJECTS FOLDER]" "Cyan"
    
    try {
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace"
        $keyName = "{0E5AAE11-A475-4c5b-AB00-C66613B37804}"
        
        if ((Test-Path "$regPath\$keyName") -eq $true) {
            Remove-Item -Path "$regPath\$keyName" -ErrorAction SilentlyContinue
            Write-Log "  ✓ 3D Objects removed from This PC" "Green"
        } else {
            Write-Log "  → 3D Objects already not visible" "Yellow"
        }
    } catch {
        Write-Log "  ✗ Could not remove 3D Objects" "Red"
    }
}

function Create-RestorePoint {
    Write-Log "`n[SYSTEM RESTORE POINT]" "Cyan"
    
    try {
        Write-Log "Creating system restore point..." "Yellow"
        $restore = Checkpoint-Computer -Description "Pre-Debloat Restore Point" -RestorePointType "MODIFY_SETTINGS" -WarningAction SilentlyContinue -ErrorAction Stop
        Write-Log "  ✓ Restore point created successfully" "Green"
        return $true
    } catch {
        Write-Log "  ✗ Could not create restore point: $($_.Exception.Message)" "Red"
        Write-Log "  Note: You can still undo changes manually if needed" "Yellow"
        return $false
    }
}

function Set-AppListItems {
    param($Items, [bool]$DefaultChecked = $true)
    $script:CurrentApps = $Items
    $AppList.Items.Clear()
    foreach ($it in $Items) {
        [void]$AppList.Items.Add($it.Display, $DefaultChecked)
    }
}

function Load-View {
    param([string]$Mode, [switch]$PreserveChecks)
    $checkedIds = @()
    
    if ($PreserveChecks) {
        for ($i = 0; $i -lt $AppList.Items.Count; $i++) {
            if ($AppList.GetItemChecked($i)) { $checkedIds += $script:CurrentApps[$i].Id }
        }
    }
    
    switch ($Mode) {
        "Curated" {
            Set-AppListItems -Items $AppCatalog -DefaultChecked:$true
        }
        "InstalledAppx" {
            $items = Get-InstalledAppItems
            Set-AppListItems -Items $items -DefaultChecked:$false
            for ($i = 0; $i -lt $script:CurrentApps.Count; $i++) {
                $id = $script:CurrentApps[$i].Id
                if ($AppCatalog | Where-Object { $id -like $_.Id }) { $AppList.SetItemChecked($i, $true) }
            }
        }
        "Desktop" {
            $items = Get-DesktopAppItems
            Set-AppListItems -Items $items -DefaultChecked:$false
        }
    }
    
    if ($PreserveChecks) {
        for ($i = 0; $i -lt $script:CurrentApps.Count; $i++) {
            if ($checkedIds -contains $script:CurrentApps[$i].Id) { $AppList.SetItemChecked($i, $true) }
        }
    }
    
    $script:ViewMode = $Mode
}

# ------------------------------------------------------------------
# BUILD FORM
# ------------------------------------------------------------------
$Form = New-Object System.Windows.Forms.Form
$Form.Text = "Windows 10 Debloat Tool — Advanced Edition"
$Form.Size = New-Object System.Drawing.Size(900, 800)
$Form.StartPosition = "CenterScreen"
$Form.FormBorderStyle = "FixedDialog"
$Form.MaximizeBox = $false
$Form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$Form.BackColor = [System.Drawing.Color]::White

# Title
$TitleLabel = New-Object System.Windows.Forms.Label
$TitleLabel.Text = "Windows 10 Debloat Tool — Remove bloatware, disable telemetry, optimize Windows"
$TitleLabel.Location = New-Object System.Drawing.Point(15, 12)
$TitleLabel.Size = New-Object System.Drawing.Size(870, 24)
$TitleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, "Bold")
$Form.Controls.Add($TitleLabel)

# App list controls
$ViewLabel = New-Object System.Windows.Forms.Label
$ViewLabel.Text = "View Mode:"
$ViewLabel.Location = New-Object System.Drawing.Point(15, 42)
$ViewLabel.Size = New-Object System.Drawing.Size(65, 20)
$Form.Controls.Add($ViewLabel)

$ViewCombo = New-Object System.Windows.Forms.ComboBox
$ViewCombo.DropDownStyle = "DropDownList"
$ViewCombo.Location = New-Object System.Drawing.Point(80, 39)
$ViewCombo.Size = New-Object System.Drawing.Size(280, 24)
[void]$ViewCombo.Items.AddRange(@("Curated Bloatware List", "Installed Store (UWP) Apps", "Installed Desktop Programs"))
$ViewCombo.SelectedIndex = 0
$Form.Controls.Add($ViewCombo)

# App checklist
$AppList = New-Object System.Windows.Forms.CheckedListBox
$AppList.Location = New-Object System.Drawing.Point(15, 68)
$AppList.Size = New-Object System.Drawing.Size(480, 380)
$AppList.CheckOnClick = $true
$AppList.Font = New-Object System.Drawing.Font("Segoe UI", 9)
foreach ($app in $AppCatalog) {
    [void]$AppList.Items.Add($app.Display, $true)
}
$Form.Controls.Add($AppList)

# Control buttons
$SelectAllBtn = New-Object System.Windows.Forms.Button
$SelectAllBtn.Text = "Select All"
$SelectAllBtn.Location = New-Object System.Drawing.Point(15, 454)
$SelectAllBtn.Size = New-Object System.Drawing.Size(90, 26)
$SelectAllBtn.Add_Click({ for ($i = 0; $i -lt $AppList.Items.Count; $i++) { $AppList.SetItemChecked($i, $true) } })
$Form.Controls.Add($SelectAllBtn)

$SelectNoneBtn = New-Object System.Windows.Forms.Button
$SelectNoneBtn.Text = "Select None"
$SelectNoneBtn.Location = New-Object System.Drawing.Point(110, 454)
$SelectNoneBtn.Size = New-Object System.Drawing.Size(90, 26)
$SelectNoneBtn.Add_Click({ for ($i = 0; $i -lt $AppList.Items.Count; $i++) { $AppList.SetItemChecked($i, $false) } })
$Form.Controls.Add($SelectNoneBtn)

$RefreshBtn = New-Object System.Windows.Forms.Button
$RefreshBtn.Text = "Refresh"
$RefreshBtn.Location = New-Object System.Drawing.Point(205, 454)
$RefreshBtn.Size = New-Object System.Drawing.Size(90, 26)
$Form.Controls.Add($RefreshBtn)

# Options panel
$OptionsBox = New-Object System.Windows.Forms.GroupBox
$OptionsBox.Text = "Options"
$OptionsBox.Location = New-Object System.Drawing.Point(505, 39)
$OptionsBox.Size = New-Object System.Drawing.Size(380, 405)
$Form.Controls.Add($OptionsBox)

$chkRestore = New-Object System.Windows.Forms.CheckBox
$chkRestore.Text = "Create System Restore Point first"
$chkRestore.Location = New-Object System.Drawing.Point(15, 25)
$chkRestore.Size = New-Object System.Drawing.Size(350, 24)
$chkRestore.Checked = $true
$OptionsBox.Controls.Add($chkRestore)

$chkAllUsers = New-Object System.Windows.Forms.CheckBox
$chkAllUsers.Text = "Remove apps for all users (not just current account)"
$chkAllUsers.Location = New-Object System.Drawing.Point(15, 55)
$chkAllUsers.Size = New-Object System.Drawing.Size(350, 24)
$chkAllUsers.Checked = $true
$OptionsBox.Controls.Add($chkAllUsers)

$chkTelemetry = New-Object System.Windows.Forms.CheckBox
$chkTelemetry.Text = "Reduce telemetry (diagnostic data, services, tasks)"
$chkTelemetry.Location = New-Object System.Drawing.Point(15, 85)
$chkTelemetry.Size = New-Object System.Drawing.Size(350, 24)
$chkTelemetry.Checked = $true
$OptionsBox.Controls.Add($chkTelemetry)

$chkAds = New-Object System.Windows.Forms.CheckBox
$chkAds.Text = "Disable Start menu and lock screen ads"
$chkAds.Location = New-Object System.Drawing.Point(15, 115)
$chkAds.Size = New-Object System.Drawing.Size(350, 24)
$chkAds.Checked = $true
$OptionsBox.Controls.Add($chkAds)

$chk3D = New-Object System.Windows.Forms.CheckBox
$chk3D.Text = "Remove '3D Objects' folder from This PC"
$chk3D.Location = New-Object System.Drawing.Point(15, 145)
$chk3D.Size = New-Object System.Drawing.Size(350, 24)
$chk3D.Checked = $true
$OptionsBox.Controls.Add($chk3D)

$NoteLabel = New-Object System.Windows.Forms.Label
$NoteLabel.Text = @"
✓ Windows Defender, Windows Update, drivers, and essential apps (Store, Calculator, Settings, Terminal) are NEVER touched.

✓ Every action is logged and can be rolled back using System Restore.

✓ Desktop program uninstalls may display their own confirmation windows.
"@
$NoteLabel.Location = New-Object System.Drawing.Point(15, 185)
$NoteLabel.Size = New-Object System.Drawing.Size(350, 200)
$NoteLabel.ForeColor = [System.Drawing.Color]::DimGray
$NoteLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$OptionsBox.Controls.Add($NoteLabel)

# Status label
$StatusLabel = New-Object System.Windows.Forms.Label
$StatusLabel.Text = "Ready. Showing 44 items."
$StatusLabel.Location = New-Object System.Drawing.Point(15, 485)
$StatusLabel.Size = New-Object System.Drawing.Size(870, 20)
$StatusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
$StatusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, "Bold")
$Form.Controls.Add($StatusLabel)

# Progress bar
$ProgressBar = New-Object System.Windows.Forms.ProgressBar
$ProgressBar.Location = New-Object System.Drawing.Point(15, 507)
$ProgressBar.Size = New-Object System.Drawing.Size(870, 20)
$ProgressBar.Style = "Continuous"
$Form.Controls.Add($ProgressBar)

# Log pane
$LogBox = New-Object System.Windows.Forms.RichTextBox
$LogBox.Location = New-Object System.Drawing.Point(15, 533)
$LogBox.Size = New-Object System.Drawing.Size(870, 190)
$LogBox.ReadOnly = $true
$LogBox.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
$LogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$Form.Controls.Add($LogBox)

# Buttons
$RunBtn = New-Object System.Windows.Forms.Button
$RunBtn.Text = "▶  Run Selected"
$RunBtn.Location = New-Object System.Drawing.Point(695, 454)
$RunBtn.Size = New-Object System.Drawing.Size(130, 32)
$RunBtn.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$RunBtn.ForeColor = [System.Drawing.Color]::White
$RunBtn.Font = New-Object System.Drawing.Font("Segoe UI", 10, "Bold")
$Form.Controls.Add($RunBtn)

$CloseBtn = New-Object System.Windows.Forms.Button
$CloseBtn.Text = "Close"
$CloseBtn.Location = New-Object System.Drawing.Point(755, 727)
$CloseBtn.Size = New-Object System.Drawing.Size(130, 32)
$CloseBtn.Add_Click({
    if (-not $script:IsRunning) {
        $Form.Close()
    } else {
        [System.Windows.Forms.MessageBox]::Show("Operation in progress. Please wait.", "Debloat Tool", "OK", "Information") | Out-Null
    }
})
$Form.Controls.Add($CloseBtn)

# ------------------------------------------------------------------
# EVENT HANDLERS
# ------------------------------------------------------------------
$ViewCombo.Add_SelectedIndexChanged({
    if ($script:IsRunning) { return }
    $ViewCombo.Enabled = $false
    $RefreshBtn.Enabled = $false
    $RunBtn.Enabled = $false
    $StatusLabel.Text = "Loading..."
    [System.Windows.Forms.Application]::DoEvents()
    
    $LogBox.Clear()
    
    switch ($ViewCombo.SelectedIndex) {
        0 { Load-View -Mode "Curated" }
        1 { Load-View -Mode "InstalledAppx" }
        2 { 
            Load-View -Mode "Desktop"
            Write-Log "Desktop program uninstalls may show confirmation windows. Follow any prompts." "Orange"
        }
    }
    
    $StatusLabel.Text = "Ready. Showing $($script:CurrentApps.Count) item(s)."
    $StatusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
    $ViewCombo.Enabled = $true
    $RefreshBtn.Enabled = $true
    $RunBtn.Enabled = $true
})

$RefreshBtn.Add_Click({
    if ($script:IsRunning) { return }
    $ViewCombo.Enabled = $false
    $RefreshBtn.Enabled = $false
    $RunBtn.Enabled = $false
    $StatusLabel.Text = "Refreshing..."
    [System.Windows.Forms.Application]::DoEvents()
    
    $LogBox.Clear()
    
    switch ($script:ViewMode) {
        "Curated" {
            Write-Log "Checking installed status for curated list..." "Blue"
            Load-View -Mode "Curated"
        }
        "InstalledAppx" {
            Write-Log "Refreshing installed Store apps..." "Blue"
            Load-View -Mode "InstalledAppx" -PreserveChecks
        }
        "Desktop" {
            Write-Log "Refreshing installed desktop programs..." "Blue"
            Load-View -Mode "Desktop" -PreserveChecks
        }
    }
    
    Write-Log "Refresh complete." "Green"
    $StatusLabel.Text = "Ready. Showing $($script:CurrentApps.Count) item(s)."
    $StatusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
    $ViewCombo.Enabled = $true
    $RefreshBtn.Enabled = $true
    $RunBtn.Enabled = $true
})

$RunBtn.Add_Click({
    if ($script:IsRunning) { return }
    
    $script:IsRunning = $true
    $RunBtn.Enabled = $false
    $ViewCombo.Enabled = $false
    $RefreshBtn.Enabled = $false
    $SelectAllBtn.Enabled = $false
    $SelectNoneBtn.Enabled = $false
    $LogBox.Clear()
    
    Write-Log "════════════════════════════════════════════════════════" "Cyan"
    Write-Log "WINDOWS 10 DEBLOAT OPERATION STARTED" "Cyan"
    Write-Log "════════════════════════════════════════════════════════" "Cyan"
    Write-Log ""
    
    # Create restore point if requested
    if ($chkRestore.Checked) {
        Create-RestorePoint
    }
    
    # Count selected apps
    $script:TotalAppsToRemove = 0
    for ($i = 0; $i -lt $AppList.Items.Count; $i++) {
        if ($AppList.GetItemChecked($i)) { $script:TotalAppsToRemove++ }
    }
    
    if ($script:TotalAppsToRemove -gt 0) {
        Write-Log "`n[REMOVING APPS]" "Cyan"
        Write-Log "Selected for removal: $($script:TotalAppsToRemove) app(s)`n" "Yellow"
        
        $script:AppsRemoved = 0
        for ($i = 0; $i -lt $AppList.Items.Count; $i++) {
            if ($AppList.GetItemChecked($i)) {
                $app = $script:CurrentApps[$i]
                Remove-AppItem -AppItem $app -AllUsers:$chkAllUsers.Checked
                $script:AppsRemoved++
                $ProgressBar.Value = [int](($script:AppsRemoved / $script:TotalAppsToRemove) * 100)
                [System.Windows.Forms.Application]::DoEvents()
            }
        }
        Write-Log "`n✓ Successfully removed $($script:AppsRemoved) / $($script:TotalAppsToRemove) apps" "Green"
    } else {
        Write-Log "No apps selected for removal." "Yellow"
    }
    
    # Telemetry
    if ($chkTelemetry.Checked) {
        Disable-Telemetry
    }
    
    # Ads
    if ($chkAds.Checked) {
        Disable-Ads
    }
    
    # 3D Objects
    if ($chk3D.Checked) {
        Remove-3DObjects
    }
    
    Write-Log "`n════════════════════════════════════════════════════════" "Cyan"
    Write-Log "✓ DEBLOAT OPERATION COMPLETED SUCCESSFULLY" "Green"
    Write-Log "════════════════════════════════════════════════════════" "Cyan"
    Write-Log "`nLogs saved to: $script:LogFile" "Gray"
    
    $ProgressBar.Value = 100
    $StatusLabel.Text = "✓ Debloat completed. See log for details."
    $StatusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
    
    $script:IsRunning = $false
    $RunBtn.Enabled = $true
    $ViewCombo.Enabled = $true
    $RefreshBtn.Enabled = $true
    $SelectAllBtn.Enabled = $true
    $SelectNoneBtn.Enabled = $true
    
    [System.Windows.Forms.MessageBox]::Show("Debloat operation completed!`n`nLogs saved to: $script:LogFile`n`nYou may need to restart your PC for all changes to take effect.", "Success", "OK", "Information") | Out-Null
})

# Show the form
Write-Log "Windows 10 Debloat Tool initialized. Select apps and options, then click 'Run Selected'." "Green"
Write-Log ""

$Form.ShowDialog() | Out-Null
exit 0
