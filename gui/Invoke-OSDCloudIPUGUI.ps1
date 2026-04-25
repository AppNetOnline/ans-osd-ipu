#Requires -Version 5.1
<#
.SYNOPSIS
    ANS IPU Console — launcher
.DESCRIPTION
    Fetches the UI layout (XAML) and upgrade logic from GitHub, then opens the
    WPF monitor and runs Invoke-OSDCloudIPU in a background runspace.
    Only this file needs to be present on the machine or USB.
    Edit $IPUConfig and $GithubBase; do not edit the companion files directly.
.NOTES
    Author  : Appalachian Network Services — appnetonline.com
    Requires: OSD module, .NET Framework 4.8+, Admin elevation
    Companion files (GitHub):
        OSDCloudIPUGUI.xaml          — window layout
        Invoke-OSDCloudIPUDeploy.ps1 — runspace upgrade logic
#>

Set-StrictMode -Off
$ErrorActionPreference = 'SilentlyContinue'

# ─────────────────────────────────────────────────────────────────────────────
#  UPGRADE CONFIGURATION — edit these values before running
# ─────────────────────────────────────────────────────────────────────────────
$IPUConfig = @{
    # Target OS — passed directly to Invoke-OSDCloudIPU -OSName
    # Valid: 'Windows 11 24H2 x64' | 'Windows 11 24H2 ARM64' | 'Windows 11 23H2 x64'
    #        'Windows 11 23H2 ARM64' | 'Windows 11 22H2 x64' | 'Windows 11 21H2 x64'
    #        'Windows 10 22H2 x64'   | 'Windows 10 22H2 ARM64'
    OSName          = 'Windows 11 24H2 x64'

    # Suppress all Windows Setup UI (recommended for unattended runs)
    Silent          = $True

    # Pass /noreboot — Setup completes down-level phase but does not restart
    NoReboot        = $False

    # Skip driver pack download and integration
    SkipDriverPack  = $False

    # Download ESD and driver pack only; do not launch Setup.exe
    DownloadOnly    = $False

    # Allow Windows Setup to pull Dynamic Updates from Windows Update
    DynamicUpdate   = $False
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
#  BOOTSTRAP — fetch XAML and runspace script before showing the window
# ─────────────────────────────────────────────────────────────────────────────
try {
    [xml]$XAML = Invoke-RestMethod "$GithubRaw/OSDCloudIPUGUI.xaml"           -UseBasicParsing
    $script:DeployScriptContent = Invoke-RestMethod "$GithubRaw/Invoke-OSDCloudIPUDeploy.ps1" -UseBasicParsing
}
catch {
    Write-Host "Bootstrap failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Verify network connectivity and that $GithubRaw is reachable." -ForegroundColor Yellow
    exit 1
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

$RtbLog         = Get-Control 'RtbLog'
$LogScroller    = Get-Control 'LogScroller'
$StatusDot      = Get-Control 'StatusDot'
$TxtStatusLabel = Get-Control 'TxtStatusLabel'
$TxtProgress    = Get-Control 'TxtProgress'
$TxtPercent     = Get-Control 'TxtPercent'
$ProgressFill   = Get-Control 'ProgressFill'
$TxtClock       = Get-Control 'TxtClock'
$BtnMinimize    = Get-Control 'BtnMinimize'

# Size the window: 70% of work area width, 75% of height, centered
$workArea = [System.Windows.SystemParameters]::WorkArea
$Window.Width  = [Math]::Round($workArea.Width  * 0.70)
$Window.Height = [Math]::Round($workArea.Height * 0.75)
$Window.Left   = $workArea.Left + [Math]::Round(($workArea.Width  - $Window.Width)  / 2)
$Window.Top    = $workArea.Top  + [Math]::Round(($workArea.Height - $Window.Height) / 2)

$BtnMinimize.Add_Click({ $Window.WindowState = 'Minimized' })

# Fix RichTextBox PageWidth — prevents single-character-per-line rendering in .NET Framework
$RtbLog.Document.PageWidth = 2000
$RtbLog.Document.LineHeight = [Double]::NaN
$RtbLog.HorizontalContentAlignment = 'Stretch'
$Window.Add_SizeChanged({
    $RtbLog.Document.PageWidth = [Math]::Max($LogScroller.ActualWidth - 48, 400)
})

# ─────────────────────────────────────────────────────────────────────────────
#  SHARED STATE
# ─────────────────────────────────────────────────────────────────────────────
$script:MessageQueue    = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
$script:IsRunning       = $False
$script:SectionParseState = 0   # 0=normal  1=saw-separator  2=saw-timestamp

$script:ProgressMap = [ordered]@{
    # IPU phases — ordered most-specific first.
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

    If ($t -match '^\*{10,}')                                           { Return @{ Skip = $True } }
    If ($t -match '^(Windows PowerShell transcript|Transcript started|Start time:|End time:|Username:|RunAs User:|Configuration Name:|Machine:|Host Application:|Process ID:|PSVersion:|PSEdition:|PSCompatibleVersions:|BuildVersion:|CLRVersion:|WSManStackVersion:|PSRemotingProtocolVersion:|SerializationVersion:)') {
        Return @{ Skip = $True }
    }
    If ($t -match '^VERBOSE:')                                          { Return @{ Skip = $True } }

    If ($t  -match '^\[i\] ')                                          { Return @{ Color = '#5B9BD5'; Bold = $False } }
    If ($tl -match '\b(error|fail|exception|critical)\b')              { Return @{ Color = '#E50019'; Bold = $False } }
    If ($t  -match '^WARNING:' -or $tl -match '\bwarn')               { Return @{ Color = '#C8820A'; Bold = $False } }
    If ($tl -match '\b(success|complete|done|finished|completed in)\b'){ Return @{ Color = '#3A9B50'; Bold = $True  } }
    If ($t  -match '^https?://')                                        { Return @{ Color = '#4A8FA8'; Bold = $False } }
    If ($t  -match '^[\w][\w\s]{1,30}\s{1,}: ')                        { Return @{ Color = '#8B8B8B'; Bold = $False } }
    If ($t  -match '^[-\s]+$' -and $t.Length -gt 4 -and $t -match '-{3,}') {
        Return @{ Color = '#3A3A3A'; Bold = $False }
    }
    If ($t  -match '^\[\d{1,2}/\d{1,2}/\d{4} \d{1,2}:\d{2}:\d{2} [AP]M\]') {
        Return @{ Color = '#6B6B6B'; Bold = $False }
    }
    If ($tl -match '^\s*\[')                                           { Return @{ Color = '#AEB0B3'; Bold = $False } }

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
$DispatchTimer = [System.Windows.Threading.DispatcherTimer]::new()
$DispatchTimer.Interval = [TimeSpan]::FromMilliseconds(80)
$DispatchTimer.Add_Tick({
    $TxtClock.Text = (Get-Date).ToString('HH:mm:ss')
    $msg = [hashtable]$Null
    $n = 0
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
                    If ($text.Trim() -eq '') {
                        # stay in state 1
                    }
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
                    If ($text.Trim() -eq '') {
                        # stay in state 2
                    }
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
            'warning' {
                Write-LogLine "[$ts]  $($msg.Text)" '#C8820A' $False
            }
            'progress' {
                Update-Progress $msg.Percent $msg.Label
            }
            'error' {
                Write-LogLine "[$ts]  ERROR: $($msg.Text)" '#E50019' $True
                Set-Status 'Error' '#E50019' '#E50019'
                $script:IsRunning = $False
            }
            'complete' {
                Write-LogDivider 'Upgrade Phase Complete — machine will restart' '#3A9B50'
                Update-Progress 100 'Upgrade complete!'
                Set-Status 'Complete' '#3A9B50' '#3A9B50'
                $script:IsRunning = $False
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
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
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
#  WINDOW EVENTS
# ─────────────────────────────────────────────────────────────────────────────
$Window.Add_MouseLeftButtonDown({ $Window.DragMove() })

$Window.Add_Loaded({
    Set-Status 'Upgrading' '#E50019' '#E50019'
    Write-LogDivider "ANS IPU Console  //  $(Get-Date -Format 'yyyy-MM-dd  HH:mm:ss')" '#E50019'
    Write-LogLine "  Target OS : $($IPUConfig.OSName)" '#5B9BD5'
    Write-LogLine "  Silent    : $($IPUConfig.Silent)    NoReboot: $($IPUConfig.NoReboot)    SkipDriverPack: $($IPUConfig.SkipDriverPack)" '#5B9BD5'
    Write-LogLine ''

    If (Get-Module -ListAvailable -Name OSD -ErrorAction SilentlyContinue) {
        $v = (Get-Module -ListAvailable -Name OSD | Select-Object -First 1).Version
        Write-LogLine "  OSD Module v$v detected." '#3A9B50'
    }
    Else {
        Write-LogLine '  WARNING: OSD Module not found. Install with: Install-Module OSD' '#C8820A'
    }
    Write-LogLine ''

    Start-IPURunspace -Config $IPUConfig
})

# ─────────────────────────────────────────────────────────────────────────────
#  SHOW
# ─────────────────────────────────────────────────────────────────────────────
[void]$Window.ShowDialog()

$DispatchTimer.Stop()
If ($script:IPUPipeline) {
    try { $script:IPUPipeline.Stop() } catch {}
    try { $script:IPURunspace.Close() } catch {}
}
