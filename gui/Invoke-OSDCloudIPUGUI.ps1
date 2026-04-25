#Requires -Version 5.1
<#
.SYNOPSIS
    ANS IPU Console — launcher
.DESCRIPTION
    Opens the WPF config panel so the operator can choose the target OS and
    options before starting.  Runs Invoke-OSDCloudIPU in a background runspace.
    Only this file needs to be present on the machine or USB.
    Edit $IPUConfig defaults and $GithubBase; do not edit companion files directly.
.PARAMETER TestMode
    Load the XAML from the local file instead of GitHub and skip the runspace.
    Use this to test the UI without an OSD module or admin elevation.
.NOTES
    Author  : Appalachian Network Services — appnetonline.com
    Requires: OSD module, .NET Framework 4.8+, Admin elevation (not needed with -TestMode)
    Companion files (GitHub):
        OSDCloudIPUGUI.xaml          — window layout
        Invoke-OSDCloudIPUDeploy.ps1 — runspace upgrade logic
#>
param(
    [switch]$TestMode
)

Set-StrictMode -Off
$ErrorActionPreference = 'SilentlyContinue'

# ─────────────────────────────────────────────────────────────────────────────
#  UPGRADE CONFIGURATION — these are the defaults shown in the config panel.
#  The operator can change them in the UI before clicking Start Upgrade.
# ─────────────────────────────────────────────────────────────────────────────
$IPUConfig = @{
    # Target OS — passed directly to Invoke-OSDCloudIPU -OSName
    # Valid: 'Windows 11 25H2 x64' | 'Windows 11 25H2 ARM64' | 'Windows 11 24H2 x64'
    #        'Windows 11 24H2 ARM64' | 'Windows 11 23H2 x64' | 'Windows 11 23H2 ARM64'
    #        'Windows 11 22H2 x64'   | 'Windows 11 21H2 x64'
    #        'Windows 10 22H2 x64'   | 'Windows 10 22H2 ARM64'
    OSName         = 'Windows 11 25H2 x64'

    # Suppress all Windows Setup UI (recommended for unattended runs)
    Silent         = $True

    # Pass /noreboot — Setup completes down-level phase but does not restart
    NoReboot       = $False

    # Skip driver pack download and integration
    SkipDriverPack = $False

    # Download ESD and driver pack only; do not launch Setup.exe
    DownloadOnly   = $False

    # Allow Windows Setup to pull Dynamic Updates from Windows Update
    DynamicUpdate  = $False
}

# ─────────────────────────────────────────────────────────────────────────────
#  GITHUB — base URLs for companion files
# ─────────────────────────────────────────────────────────────────────────────
$GithubBase = 'https://raw.githubusercontent.com/AppNetOnline/ans-osd-ipu/main'
$GithubRaw  = "$GithubBase/gui"

# ─────────────────────────────────────────────────────────────────────────────
#  ASSEMBLIES
# ─────────────────────────────────────────────────────────────────────────────
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# ─────────────────────────────────────────────────────────────────────────────
#  BOOTSTRAP — fetch (or load locally in TestMode) XAML and runspace script
# ─────────────────────────────────────────────────────────────────────────────
if ($TestMode) {
    $localXaml   = Join-Path $PSScriptRoot 'OSDCloudIPUGUI.xaml'
    $localDeploy = Join-Path $PSScriptRoot 'Invoke-OSDCloudIPUDeploy.ps1'
    try {
        [xml]$XAML = Get-Content $localXaml -Raw -ErrorAction Stop
        $script:DeployScriptContent = if (Test-Path $localDeploy) {
            Get-Content $localDeploy -Raw
        } else { '# TestMode placeholder' }
    }
    catch {
        Write-Host "TestMode bootstrap failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Expected XAML at: $localXaml" -ForegroundColor Yellow
        exit 1
    }
}
else {
    try {
        [xml]$XAML                   = Invoke-RestMethod "$GithubRaw/OSDCloudIPUGUI.xaml"            -UseBasicParsing
        $script:DeployScriptContent  = Invoke-RestMethod "$GithubRaw/Invoke-OSDCloudIPUDeploy.ps1"   -UseBasicParsing
    }
    catch {
        Write-Host "Bootstrap failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Verify network connectivity and that $GithubRaw is reachable." -ForegroundColor Yellow
        exit 1
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  LOAD WINDOW
# ─────────────────────────────────────────────────────────────────────────────
try {
    $reader = [System.Xml.XmlNodeReader]::new($XAML)
    $Window = [System.Windows.Markup.XamlReader]::Load($reader)
}
catch {
    Write-Host "XAML Error : $($_.Exception.Message)"                -ForegroundColor Red
    Write-Host "Line       : $($_.Exception.LineNumber)"             -ForegroundColor Yellow
    Write-Host "Inner      : $($_.Exception.InnerException.Message)" -ForegroundColor Magenta
    exit 1
}

Function Get-Control { Param($Name) $Window.FindName($Name) }

# ── Core display controls
$RtbLog         = Get-Control 'RtbLog'
$LogScroller    = Get-Control 'LogScroller'
$StatusDot      = Get-Control 'StatusDot'
$TxtStatusLabel = Get-Control 'TxtStatusLabel'
$TxtProgress    = Get-Control 'TxtProgress'
$TxtPercent     = Get-Control 'TxtPercent'
$ProgressFill   = Get-Control 'ProgressFill'
$TxtClock       = Get-Control 'TxtClock'

# ── Header buttons
$BtnMinimize    = Get-Control 'BtnMinimize'
$BtnClose       = Get-Control 'BtnClose'

# ── Progress-footer buttons
$BtnRepair      = Get-Control 'BtnRepair'
$BtnCancel      = Get-Control 'BtnCancel'

# ── Config overlay controls
$ConfigOverlay      = Get-Control 'ConfigOverlay'
$CboOSName          = Get-Control 'CboOSName'
$ChkSilent          = Get-Control 'ChkSilent'
$ChkNoReboot        = Get-Control 'ChkNoReboot'
$ChkSkipDriverPack  = Get-Control 'ChkSkipDriverPack'
$ChkDownloadOnly    = Get-Control 'ChkDownloadOnly'
$ChkDynamicUpdate   = Get-Control 'ChkDynamicUpdate'
$BtnStartUpgrade    = Get-Control 'BtnStartUpgrade'
$BtnRepairOverlay   = Get-Control 'BtnRepairOverlay'
$BtnCancelOverlay   = Get-Control 'BtnCancelOverlay'

# Size the window: 70% of work area width, 75% of height, centered
$workArea      = [System.Windows.SystemParameters]::WorkArea
$Window.Width  = [Math]::Round($workArea.Width  * 0.70)
$Window.Height = [Math]::Round($workArea.Height * 0.75)
$Window.Left   = $workArea.Left + [Math]::Round(($workArea.Width  - $Window.Width)  / 2)
$Window.Top    = $workArea.Top  + [Math]::Round(($workArea.Height - $Window.Height) / 2)

# Fix RichTextBox PageWidth — prevents single-character-per-line rendering in .NET Framework
$RtbLog.Document.PageWidth        = 2000
$RtbLog.Document.LineHeight       = [Double]::NaN
$RtbLog.HorizontalContentAlignment = 'Stretch'
$Window.Add_SizeChanged({
    $RtbLog.Document.PageWidth = [Math]::Max($LogScroller.ActualWidth - 48, 400)
})

# ─────────────────────────────────────────────────────────────────────────────
#  SHARED STATE
# ─────────────────────────────────────────────────────────────────────────────
$script:MessageQueue      = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
$script:IsRunning         = $False
$script:SectionParseState = 0   # 0=normal  1=saw-separator  2=saw-timestamp
$script:PendingConfig     = $null

$script:ProgressMap = [ordered]@{
    'starting invoke-osdcloudipu'       = @(2,  'Starting IPU engine...')
    'looking of details'                = @(3,  'Gathering device info...')
    'device is windows 11 capable'      = @(5,  'Win11 readiness: CAPABLE')
    'device is !not! windows 11'        = @(5,  'Win11 readiness: NOT CAPABLE')
    'starting feature update lookup'    = @(8,  'Looking up feature update...')
    'getting content for upgrade media' = @(10, 'Preparing upgrade media...')
    'sha1 match on'                     = @(50, 'ESD verified, skipping download...')
    'starting download to'              = @(12, 'Downloading ESD...')
    'starting extract of esd'           = @(55, 'Extracting ESD...')
    'expanding'                         = @(58, 'Expanding Windows image...')
    'getting driver pack for ipu'       = @(72, 'Downloading driver pack...')
    'confirmed driver pack expanded'    = @(80, 'Driver pack ready.')
    'download complete, exiting'        = @(85, 'Download complete.')
    'triggering windows upgrade setup'  = @(85, 'Launching Windows Setup...')
    'setup path:'                       = @(87, 'Windows Setup starting...')
}

# ─────────────────────────────────────────────────────────────────────────────
#  UI HELPERS
# ─────────────────────────────────────────────────────────────────────────────
Function Write-LogLine {
    Param([string]$Text, [string]$Color = '#C8C8C8', [bool]$Bold = $False)
    $para = [System.Windows.Documents.Paragraph]::new()
    $para.Margin = [System.Windows.Thickness]::new(0, 0, 0, 1)
    $run = [System.Windows.Documents.Run]::new($Text)
    $run.Foreground = [System.Windows.Media.SolidColorBrush][System.Windows.Media.ColorConverter]::ConvertFromString($Color)
    If ($Bold) { $run.FontWeight = [System.Windows.FontWeights]::SemiBold }
    $para.Inlines.Add($run)
    $RtbLog.Document.Blocks.Add($para)
    $LogScroller.ScrollToBottom()
}

Function Write-LogDivider {
    Param([string]$Label = '', [string]$Color = '#E50019')
    Write-LogLine ''
    If ($Label) { Write-LogLine "  $Label" $Color $True }
    Write-LogLine ('  ' + ([string][char]0x2500 * 56)) '#2A2A2A'
    Write-LogLine ''
}

Function Set-Status {
    Param([string]$Label, [string]$DotColor, [string]$TextColor)
    $StatusDot.Fill      = [System.Windows.Media.SolidColorBrush][System.Windows.Media.ColorConverter]::ConvertFromString($DotColor)
    $TxtStatusLabel.Text = $Label
    $TxtStatusLabel.Foreground = [System.Windows.Media.SolidColorBrush][System.Windows.Media.ColorConverter]::ConvertFromString($TextColor)
}

Function Update-Progress {
    Param([int]$Pct, [string]$Label)
    $TxtProgress.Text = $Label
    $TxtPercent.Text  = "$Pct%"
    $parent = $ProgressFill.Parent
    If ($parent -and $parent.ActualWidth -gt 0) {
        $ProgressFill.Width = [Math]::Round($parent.ActualWidth * ($Pct / 100), 1)
    }
    $color = If ($Pct -lt 50) { '#E50019' } ElseIf ($Pct -lt 90) { '#C8820A' } Else { '#3A9B50' }
    $ProgressFill.Background = [System.Windows.Media.SolidColorBrush][System.Windows.Media.ColorConverter]::ConvertFromString($color)
}

Function Get-LineStyle {
    Param([string]$Line)
    $t  = $Line.TrimStart()
    $tl = $t.ToLower()

    If ($t -match '^\*{10,}') { Return @{ Skip = $True } }
    If ($t -match '^(Windows PowerShell transcript|Transcript started|Start time:|End time:|Username:|RunAs User:|Configuration Name:|Machine:|Host Application:|Process ID:|PSVersion:|PSEdition:|PSCompatibleVersions:|BuildVersion:|CLRVersion:|WSManStackVersion:|PSRemotingProtocolVersion:|SerializationVersion:)') {
        Return @{ Skip = $True }
    }
    If ($t -match '^VERBOSE:') { Return @{ Skip = $True } }

    If ($t -match '^\[i\] ')          { Return @{ Color = '#5B9BD5'; Bold = $False } }
    If ($tl -match '\b(error|fail|exception|critical)\b') { Return @{ Color = '#E50019'; Bold = $False } }
    If ($t -match '^WARNING:' -or $tl -match '\bwarn') { Return @{ Color = '#C8820A'; Bold = $False } }
    If ($tl -match '\b(success|complete|done|finished|completed in)\b') { Return @{ Color = '#3A9B50'; Bold = $True } }
    If ($t -match '^https?://')        { Return @{ Color = '#4A8FA8'; Bold = $False } }
    If ($t -match '^[\w][\w\s]{1,30}\s{1,}: ') { Return @{ Color = '#8B8B8B'; Bold = $False } }
    If ($t -match '^[-\s]+$' -and $t.Length -gt 4 -and $t -match '-{3,}') {
        Return @{ Color = '#3A3A3A'; Bold = $False }
    }
    If ($t -match '^\[\d{1,2}/\d{1,2}/\d{4} \d{1,2}:\d{2}:\d{2} [AP]M\]') {
        Return @{ Color = '#6B6B6B'; Bold = $False }
    }
    If ($tl -match '^\s*\[') { Return @{ Color = '#AEB0B3'; Bold = $False } }

    Return @{ Color = '#C8C8C8'; Bold = $False }
}

Function Get-ProgressHint {
    Param([string]$Line)
    $l = $Line.ToLower()
    ForEach ($key in $script:ProgressMap.Keys) {
        If ($l -match [regex]::Escape($key)) { Return $script:ProgressMap[$key] }
    }
    Return $Null
}

# ─────────────────────────────────────────────────────────────────────────────
#  DISPATCHER TIMER — drains message queue onto UI thread every 80 ms
# ─────────────────────────────────────────────────────────────────────────────
$DispatchTimer          = [System.Windows.Threading.DispatcherTimer]::new()
$DispatchTimer.Interval = [TimeSpan]::FromMilliseconds(80)
$DispatchTimer.Add_Tick({
    $TxtClock.Text = (Get-Date).ToString('HH:mm:ss')
    $msg = [hashtable]$Null
    $n   = 0
    while ($script:MessageQueue.TryDequeue([ref]$msg) -and $n -lt 30) {
        $n++
        $ts = (Get-Date).ToString('HH:mm:ss')
        switch ($msg.Type) {
            'line' {
                $text = $msg.Text
                If ($text -match '^={10,}') {
                    $script:SectionParseState = 1
                }
                ElseIf ($script:SectionParseState -eq 1) {
                    If ($text.Trim() -eq '') { }
                    ElseIf ($text -match '^\[\d{1,2}/\d{1,2}/\d{4}') {
                        $script:SectionParseState = 2
                    }
                    Else {
                        $script:SectionParseState = 0
                        $style = Get-LineStyle $text
                        If (-not $style.Skip) { Write-LogLine "[$ts]  $text" $style.Color ($style.Bold -eq $True) }
                        $hint = Get-ProgressHint $text; If ($hint) { Update-Progress $hint[0] $hint[1] }
                    }
                }
                ElseIf ($script:SectionParseState -eq 2) {
                    If ($text.Trim() -eq '') { }
                    Else {
                        $script:SectionParseState = 0
                        Write-LogDivider $text.Trim() '#5B9BD5'
                        $hint = Get-ProgressHint $text; If ($hint) { Update-Progress $hint[0] $hint[1] }
                    }
                }
                Else {
                    $style = Get-LineStyle $text
                    If (-not $style.Skip) { Write-LogLine "[$ts]  $text" $style.Color ($style.Bold -eq $True) }
                    $hint = Get-ProgressHint $text; If ($hint) { Update-Progress $hint[0] $hint[1] }
                }
            }
            'warning'  { Write-LogLine "[$ts]  $($msg.Text)" '#C8820A' $False }
            'progress' { Update-Progress $msg.Percent $msg.Label }
            'error' {
                Write-LogLine "[$ts]  ERROR: $($msg.Text)" '#E50019' $True
                Set-Status 'Error' '#E50019' '#E50019'
                $script:IsRunning = $False
                $BtnRepair.IsEnabled = $True
                $BtnCancel.Content   = 'Close'
            }
            'complete' {
                Write-LogDivider 'Upgrade Phase Complete — machine will restart' '#3A9B50'
                Update-Progress 100 'Upgrade complete!'
                Set-Status 'Complete' '#3A9B50' '#3A9B50'
                $script:IsRunning  = $False
                $BtnCancel.Content = 'Close'
            }
        }
    }
})
$DispatchTimer.Start()

# ─────────────────────────────────────────────────────────────────────────────
#  RUNSPACE — upgrade logic runs here; never blocks the UI thread
# ─────────────────────────────────────────────────────────────────────────────
Function Start-IPURunspace {
    Param([hashtable]$Config)

    $script:IsRunning = $True

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState  = 'STA'
    $rs.ThreadOptions   = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Config',       $Config)
    $rs.SessionStateProxy.SetVariable('MessageQueue', $script:MessageQueue)
    $rs.SessionStateProxy.SetVariable('GithubBase',   $GithubBase)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript($script:DeployScriptContent)

    $script:IPURunspace = $rs
    $script:IPUPipeline = $ps
    $null = $ps.BeginInvoke()
}

# ─────────────────────────────────────────────────────────────────────────────
#  REPAIR HELPER — finds and launches Start-Repair.ps1 elevated
# ─────────────────────────────────────────────────────────────────────────────
Function Invoke-Repair {
    $repairScript = Join-Path $PSScriptRoot '..\shared\Start-Repair.ps1'
    $repairScript = [System.IO.Path]::GetFullPath($repairScript)

    if (-not (Test-Path $repairScript)) {
        [System.Windows.MessageBox]::Show(
            "Start-Repair.ps1 not found at:`n$repairScript`n`nVerify the shared\ folder is present.",
            'Repair Script Not Found',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
        return
    }

    Write-LogLine '' '#C8C8C8'
    Write-LogLine "  Launching Start-Repair.ps1 in an elevated window..." '#C8820A' $True
    Write-LogLine "  Script: $repairScript" '#8B8B8B'
    Write-LogLine '' '#C8C8C8'

    try {
        Start-Process powershell.exe `
            -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"$repairScript`"" `
            -Verb RunAs
    }
    catch {
        [System.Windows.MessageBox]::Show(
            "Could not launch repair script:`n$($_.Exception.Message)",
            'Launch Failed',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  CLOSE HELPER — optionally confirms when upgrade is running
# ─────────────────────────────────────────────────────────────────────────────
Function Request-Close {
    if ($script:IsRunning) {
        $ans = [System.Windows.MessageBox]::Show(
            "An upgrade is in progress.`nClosing now may leave the system in an inconsistent state.`n`nClose anyway?",
            'Upgrade In Progress',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }
    $Window.Close()
}

# ─────────────────────────────────────────────────────────────────────────────
#  WINDOW EVENTS
# ─────────────────────────────────────────────────────────────────────────────
$Window.Add_MouseLeftButtonDown({ $Window.DragMove() })

$BtnMinimize.Add_Click({ $Window.WindowState = 'Minimized' })
$BtnClose.Add_Click({ Request-Close })
$BtnCancel.Add_Click({ Request-Close })
$BtnRepair.Add_Click({ Invoke-Repair })
$BtnRepairOverlay.Add_Click({ Invoke-Repair })
$BtnCancelOverlay.Add_Click({ $Window.Close() })

# ── Start Upgrade — reads controls, collapses overlay, launches runspace
$BtnStartUpgrade.Add_Click({
    # Read selections from UI
    $selectedOS = if ($CboOSName.SelectedItem) {
        $CboOSName.SelectedItem.Content
    } else { $IPUConfig.OSName }

    $IPUConfig.OSName         = $selectedOS
    $IPUConfig.Silent         = [bool]$ChkSilent.IsChecked
    $IPUConfig.NoReboot       = [bool]$ChkNoReboot.IsChecked
    $IPUConfig.SkipDriverPack = [bool]$ChkSkipDriverPack.IsChecked
    $IPUConfig.DownloadOnly   = [bool]$ChkDownloadOnly.IsChecked
    $IPUConfig.DynamicUpdate  = [bool]$ChkDynamicUpdate.IsChecked

    # Disable button to prevent double-click
    $BtnStartUpgrade.IsEnabled = $False
    $BtnStartUpgrade.Content   = 'Starting...'

    # Hide overlay and show log
    $ConfigOverlay.Visibility = 'Collapsed'

    # Log chosen config
    Set-Status 'Upgrading' '#E50019' '#E50019'
    Write-LogDivider "ANS IPU Console  //  $(Get-Date -Format 'yyyy-MM-dd  HH:mm:ss')" '#E50019'
    Write-LogLine "  Target OS      : $($IPUConfig.OSName)"       '#5B9BD5'
    Write-LogLine "  Silent         : $($IPUConfig.Silent)    NoReboot: $($IPUConfig.NoReboot)    SkipDriverPack: $($IPUConfig.SkipDriverPack)" '#5B9BD5'
    Write-LogLine "  DownloadOnly   : $($IPUConfig.DownloadOnly)    DynamicUpdate: $($IPUConfig.DynamicUpdate)" '#5B9BD5'
    Write-LogLine ''

    If (Get-Module -ListAvailable -Name OSD -ErrorAction SilentlyContinue) {
        $v = (Get-Module -ListAvailable -Name OSD | Select-Object -First 1).Version
        Write-LogLine "  OSD Module v$v detected." '#3A9B50'
    } Else {
        Write-LogLine '  WARNING: OSD Module not found. Install with: Install-Module OSD' '#C8820A'
    }
    Write-LogLine ''

    if ($TestMode) {
        Write-LogDivider 'TEST MODE — runspace not started' '#C8820A'
        Write-LogLine '  Use -TestMode to explore the UI without running an actual upgrade.' '#C8820A'
        Write-LogLine '  All buttons and controls are live.' '#8B8B8B'
        Write-LogLine ''
        Set-Status 'Test Mode' '#C8820A' '#C8820A'
        $BtnCancel.Content = 'Close'
    } else {
        Start-IPURunspace -Config $IPUConfig
    }
})

# ── Loaded — pre-populate config controls from $IPUConfig defaults
$Window.Add_Loaded({
    Set-Status 'Ready' '#555555' '#555555'

    # Select the matching OS in the ComboBox
    foreach ($item in $CboOSName.Items) {
        if ($item.Content -eq $IPUConfig.OSName) {
            $CboOSName.SelectedItem = $item
            break
        }
    }

    $ChkSilent.IsChecked         = $IPUConfig.Silent
    $ChkNoReboot.IsChecked       = $IPUConfig.NoReboot
    $ChkSkipDriverPack.IsChecked = $IPUConfig.SkipDriverPack
    $ChkDownloadOnly.IsChecked   = $IPUConfig.DownloadOnly
    $ChkDynamicUpdate.IsChecked  = $IPUConfig.DynamicUpdate

    if ($TestMode) {
        $Window.Title = 'ANS IPU Console [TEST MODE]'
        Set-Status 'Test Mode' '#C8820A' '#C8820A'
    }
})

# ─────────────────────────────────────────────────────────────────────────────
#  SHOW
# ─────────────────────────────────────────────────────────────────────────────
[void]$Window.ShowDialog()

$DispatchTimer.Stop()
If ($script:IPUPipeline) {
    try { $script:IPUPipeline.Stop()    } catch {}
    try { $script:IPURunspace.Close()   } catch {}
}
