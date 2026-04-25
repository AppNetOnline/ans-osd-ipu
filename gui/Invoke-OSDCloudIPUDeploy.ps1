#Requires -Version 5.1
<#
.SYNOPSIS
    ANS IPU deployment runspace script.
.DESCRIPTION
    Runs inside an isolated PowerShell runspace launched by Invoke-OSDCloudIPUGUI.ps1.
    Variables injected by the parent before this script runs:
        $Config       — hashtable of IPU options (OSName, Silent, NoReboot, etc.)
        $MessageQueue — ConcurrentQueue[hashtable] shared with the UI thread
        $GithubBase   — raw GitHub base URL for this repo
    Do not run this script directly.
.NOTES
    Author  : Appalachian Network Services — appnetonline.com
    Flow    :
        Phase 1 — Invoke-OSDCloudIPU in child process:
                    transcript tail + BITS polling for ESD and driver pack downloads
        Phase 2 — Windows Setup running:
                    polls HKLM:\System\Setup\mosetup\volatile\SetupProgress (0-100)
                    and maps to progress bar 87-99%
#>

# ─────────────────────────────────────────────────────────────────────────────
#  RAW LOG
# ─────────────────────────────────────────────────────────────────────────────
$RawLogPath = "C:\OSDCloud\Logs\ANS-IPU-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$null = New-Item -Path (Split-Path $RawLogPath) -ItemType Directory -Force -ErrorAction SilentlyContinue
$RawLog = [System.IO.StreamWriter]::new($RawLogPath, $False, [System.Text.Encoding]::UTF8)
$RawLog.AutoFlush = $True

# ─────────────────────────────────────────────────────────────────────────────
#  HELPERS
# ─────────────────────────────────────────────────────────────────────────────
Function Enqueue {
    Param([string]$Text, [string]$Type = 'line')
    $MessageQueue.Enqueue(@{ Type = $Type; Text = $Text })
}

Function Write-Raw {
    Param([string]$Text)
    $RawLog.WriteLine("$(Get-Date -Format 'HH:mm:ss.fff')  $Text")
}

# ─────────────────────────────────────────────────────────────────────────────
#  MONITORING HELPERS
# ─────────────────────────────────────────────────────────────────────────────
$script:DBConn    = $null
$script:DBRowId   = $null
$script:StartTime = Get-Date

Function Initialize-Monitor {
    try {
        $modulePath    = Join-Path $env:TEMP 'GitHubDB.psm1'
        $moduleContent = Invoke-RestMethod "$GithubBase/shared/GitHubDB.psm1" -UseBasicParsing -ErrorAction Stop
        Set-Content -Path $modulePath -Value $moduleContent -Encoding UTF8
        Import-Module $modulePath -Force -Global -WarningAction SilentlyContinue -ErrorAction Stop

        $secretsFile = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.Root 'OSDCloud\Config\Scripts\SetupComplete\secrets.json' } |
            Where-Object   { Test-Path $_ -ErrorAction SilentlyContinue } |
            Select-Object  -First 1

        If (-not $secretsFile) { Enqueue 'Monitoring: secrets.json not found — skipping'; Return $false }

        $sec = Get-Content $secretsFile -Raw | ConvertFrom-Json
        If (-not $sec.GitHubDBToken) { Enqueue 'Monitoring: GitHubDBToken missing — skipping'; Return $false }

        $script:DBConn = @{
            Owner  = 'AppNetOnline'
            Repo   = 'deployment-db'
            Path   = 'data/deployments.json'
            Token  = $sec.GitHubDBToken
            Branch = 'main'
        }
        Return $true
    }
    catch { Enqueue "Monitoring: init failed ($($_.Exception.Message)) — skipping"; Return $false }
}

Function Get-HardwareInfo {
    $hw = @{}
    try {
        $cs   = Get-CimInstance Win32_ComputerSystem        -ErrorAction SilentlyContinue
        $bios = Get-CimInstance Win32_BIOS                  -ErrorAction SilentlyContinue
        $cpu  = Get-CimInstance Win32_Processor             -ErrorAction SilentlyContinue | Select-Object -First 1
        $disk = Get-CimInstance Win32_DiskDrive             -ErrorAction SilentlyContinue | Sort-Object Size -Descending | Select-Object -First 1
        $prod = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
        $macs = Get-CimInstance Win32_NetworkAdapter        -ErrorAction SilentlyContinue |
                    Where-Object { $_.MACAddress -and $_.PhysicalAdapter } |
                    ForEach-Object { $_.MACAddress } |
                    Select-Object -First 3

        $hw.Hostname        = $env:COMPUTERNAME
        $hw.Manufacturer    = $cs.Manufacturer
        $hw.Model           = $cs.Model
        $hw.SerialNumber    = $bios.SerialNumber
        $hw.UUID            = $prod.UUID
        $hw.CPU             = $cpu.Name.Trim()
        $hw.CPUCores        = [int]$cpu.NumberOfCores
        $hw.CPULogicalProcs = [int]$cpu.NumberOfLogicalProcessors
        $hw.CPUSpeedMHz     = [int]$cpu.MaxClockSpeed
        $hw.RAMGb           = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        $hw.DiskGB          = if ($disk.Size) { [math]::Round($disk.Size / 1GB) } else { $null }
        $hw.BIOSVersion     = $bios.SMBIOSBIOSVersion
        $hw.BIOSDate        = if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('yyyy-MM-dd') } else { $null }
        $hw.MACAddresses    = ($macs -join ', ')
    }
    catch {}
    Return $hw
}

Function Get-GeoInfo {
    try {
        $geo = Invoke-RestMethod 'http://ip-api.com/json' -UseBasicParsing -ErrorAction Stop
        Return @{
            PublicIP = $geo.query
            ISP      = $geo.isp
            City     = $geo.city
            Region   = $geo.regionName
            Country  = $geo.country
            Timezone = $geo.timezone
        }
    }
    catch { Return @{} }
}

Function New-IPURecord {
    Param([hashtable]$HW, [hashtable]$Geo, [string]$OSTarget, [string]$OSDVersion)
    If (-not $script:DBConn) { Return }
    try {
        $row = @{
            Status          = 'Running'
            Type            = 'IPU'
            StartTime       = $script:StartTime.ToString('o')
            EndTime         = $null
            DurationMinutes = $null
            ErrorMessage    = $null
            OSTarget        = $OSTarget
            OSDCloudVersion = $OSDVersion
        }
        ForEach ($k in $HW.Keys) { $row[$k] = $HW[$k] }
        ForEach ($k in $Geo.Keys) { $row[$k] = $Geo[$k] }
        $added          = Add-GHDBRow -Connection $script:DBConn -Row $row
        $script:DBRowId = $added.id
        Enqueue "Monitoring: record created (id=$($script:DBRowId))"
    }
    catch { Enqueue "Monitoring: failed to create record ($($_.Exception.Message))" }
}

Function Complete-IPURecord {
    If (-not $script:DBConn -or -not $script:DBRowId) { Return }
    try {
        $end = Get-Date
        Update-GHDBRow -Connection $script:DBConn -Id $script:DBRowId -Updates @{
            Status          = 'Complete'
            EndTime         = $end.ToString('o')
            DurationMinutes = [math]::Round(($end - $script:StartTime).TotalMinutes, 1)
        }
    }
    catch {}
}

Function Fail-IPURecord {
    Param([string]$ErrorMessage)
    If (-not $script:DBConn -or -not $script:DBRowId) { Return }
    try {
        $end = Get-Date
        Update-GHDBRow -Connection $script:DBConn -Id $script:DBRowId -Updates @{
            Status          = 'Error'
            EndTime         = $end.ToString('o')
            DurationMinutes = [math]::Round(($end - $script:StartTime).TotalMinutes, 1)
            ErrorMessage    = $ErrorMessage
        }
    }
    catch {}
}

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────────────────────────────────────
$monitorActive = Initialize-Monitor

try {
    Enqueue 'ANS IPU Console'
    Enqueue (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Enqueue "Raw log : $RawLogPath"
    Enqueue ''

    # ── OSD module ────────────────────────────────────────────────────────────
    If (-not (Get-Module -Name OSD -ErrorAction SilentlyContinue)) {
        Enqueue 'Loading OSD module...'
        Import-Module OSD -WarningAction SilentlyContinue -ErrorAction Stop
    }
    $osdVersion = (Get-Module OSD).Version.ToString()
    Enqueue "OSD module v$osdVersion loaded."
    Enqueue ''

    # ── Hardware detection ────────────────────────────────────────────────────
    $HW  = Get-HardwareInfo
    $Geo = Get-GeoInfo

    Enqueue "Hardware : $($HW.Manufacturer) $($HW.Model) — S/N $($HW.SerialNumber)"
    Enqueue "CPU      : $($HW.CPU) ($($HW.CPUCores)C/$($HW.CPULogicalProcs)T)"
    Enqueue "RAM      : $($HW.RAMGb) GB    Disk: $($HW.DiskGB) GB"
    Enqueue "Location : $($Geo.City), $($Geo.Region) ($($Geo.PublicIP))"
    Enqueue ''
    Enqueue "Target   : $($Config.OSName)"
    Enqueue ''

    If ($monitorActive) {
        New-IPURecord -HW $HW -Geo $Geo -OSTarget $Config.OSName -OSDVersion $osdVersion
    }

    # ── Build params for Invoke-OSDCloudIPU ──────────────────────────────────
    $IPUParams = @{ OSName = $Config.OSName }
    If ($Config.Silent)         { $IPUParams.Silent         = $True }
    If ($Config.NoReboot)       { $IPUParams.NoReboot       = $True }
    If ($Config.SkipDriverPack) { $IPUParams.SkipDriverPack = $True }
    If ($Config.DownloadOnly)   { $IPUParams.DownloadOnly   = $True }
    If ($Config.DynamicUpdate)  { $IPUParams.DynamicUpdate  = $True }

    # ── Write child process files ─────────────────────────────────────────────
    $TranscriptPath = "C:\OSDCloud\Logs\IPU-Transcript-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    $RunnerPath     = Join-Path $env:TEMP "Run-IPU-$([guid]::NewGuid()).ps1"
    $ParamsPath     = Join-Path $env:TEMP "IPU-Params-$([guid]::NewGuid()).clixml"

    $IPUParams | Export-Clixml -Path $ParamsPath

    $OSDModulePath = (Get-Module OSD).Path

    Set-Content -Path $RunnerPath -Encoding UTF8 -Value @"
`$ErrorActionPreference  = 'Continue'
`$WarningPreference      = 'Continue'
`$ProgressPreference     = 'SilentlyContinue'

Start-Transcript -Path '$TranscriptPath' -Force | Out-Null

Try {
    Import-Module '$OSDModulePath' -Force -WarningAction SilentlyContinue -ErrorAction Stop
    `$Params = Import-Clixml -Path '$ParamsPath' -ErrorAction Stop
    Invoke-OSDCloudIPU @Params
}
Catch {
    Write-Host ('ERROR: ' + `$_.Exception.Message)
    If (`$_.ScriptStackTrace) { Write-Host `$_.ScriptStackTrace }
}
Finally {
    Stop-Transcript | Out-Null
}
"@

    Enqueue "Transcript : $TranscriptPath"
    Enqueue 'Starting Invoke-OSDCloudIPU...'
    Enqueue ''

    # ── Noise patterns ────────────────────────────────────────────────────────
    $NoisePatterns = @(
        '^\*{10,}'
        '^Windows PowerShell transcript start'
        '^Windows PowerShell transcript end'
        '^Start time:'
        '^End time:'
        '^Username:'
        '^RunAs User:'
        '^Configuration Name:'
        '^Machine:'
        '^Host Application:'
        '^Process ID:'
        '^PSVersion:'
        '^PSEdition:'
        '^PSCompatibleVersions:'
        '^BuildVersion:'
        '^CLRVersion:'
        '^WSManStackVersion:'
        '^PSRemotingProtocolVersion:'
        '^SerializationVersion:'
    )

    # ── Start child process (Phase 1) ─────────────────────────────────────────
    $Process = Start-Process `
        -FilePath    'powershell.exe' `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$RunnerPath`"" `
        -WindowStyle  Hidden `
        -PassThru

    $script:LastIndex    = 0
    $LastDownloadPct     = -1
    $LastBitsDisplayName = ''

    Function Read-NewTranscriptLines {
        If (-not (Test-Path $TranscriptPath)) { Return }
        $Lines = Get-Content -Path $TranscriptPath -ErrorAction SilentlyContinue
        If ($Lines.Count -le $script:LastIndex) { Return }
        $NewLines = $Lines[$script:LastIndex..($Lines.Count - 1)]
        $script:LastIndex = $Lines.Count
        ForEach ($Line in $NewLines) {
            If ([string]::IsNullOrWhiteSpace($Line)) { Continue }
            $Trimmed  = $Line.Trim()
            $SkipLine = $False
            ForEach ($Pattern in $NoisePatterns) {
                If ($Trimmed -match $Pattern) { $SkipLine = $True; Break }
            }
            If ($SkipLine)              { Continue }
            Write-Raw $Line
            If ($Trimmed -match '^VERBOSE:') { Continue }
            If ($Trimmed -match '^ERROR:')   { Enqueue $Line 'error'   }
            ElseIf ($Trimmed -match '^WARNING:') { Enqueue $Line 'warning' }
            Else                             { Enqueue $Line           }
        }
    }

    # ── Phase 1 poll loop: transcript tail + BITS progress ───────────────────
    While (-not $Process.HasExited) {
        $BitsJob = Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue |
            Where-Object { $_.JobState -in 'Transferring', 'Queued', 'Connecting' } |
            Sort-Object BytesTotal -Descending |
            Select-Object -First 1

        If ($BitsJob -and $BitsJob.BytesTotal -gt 0) {
            $dlPct   = [math]::Floor($BitsJob.BytesTransferred / $BitsJob.BytesTotal * 100)
            $doneMB  = [math]::Round($BitsJob.BytesTransferred / 1MB)
            $totalMB = [math]::Round($BitsJob.BytesTotal / 1MB)

            If ($dlPct -ne $LastDownloadPct -or $BitsJob.DisplayName -ne $LastBitsDisplayName) {
                $LastDownloadPct     = $dlPct
                $LastBitsDisplayName = $BitsJob.DisplayName

                $isDriverPack = $BitsJob.DisplayName -match 'driver'
                If ($isDriverPack) {
                    $mapped = 72 + [math]::Round($dlPct * 0.08)   # 72–80%
                    $label  = "Downloading driver pack... ($dlPct%)"
                }
                Else {
                    $mapped = 12 + [math]::Round($dlPct * 0.40)   # 12–52%
                    $label  = "Downloading ESD... ($dlPct%  –  $doneMB MB / $totalMB MB)"
                }

                Enqueue $label
                $MessageQueue.Enqueue(@{
                    Type    = 'progress'
                    Percent = [int][math]::Min(80, $mapped)
                    Label   = $label
                })
            }
        }

        Read-NewTranscriptLines
        Start-Sleep -Milliseconds 500
    }

    $Process.WaitForExit()
    Read-NewTranscriptLines
    Remove-Item -Path $RunnerPath, $ParamsPath -Force -ErrorAction SilentlyContinue

    # ── Phase 2: monitor Windows Setup via registry ───────────────────────────
    If (-not $Config.DownloadOnly) {
        Enqueue ''
        Enqueue 'Windows Setup launched — monitoring progress via registry...'
        Enqueue 'The machine will restart automatically when the down-level phase completes.'
        Enqueue ''

        $SetupProgressPath = 'HKLM:\System\Setup\mosetup\volatile'
        $MaxWaitMinutes    = 120
        $WaitStart         = Get-Date
        $LastSetupPct      = -1

        While (((Get-Date) - $WaitStart).TotalMinutes -lt $MaxWaitMinutes) {
            $SetupPct = Get-ItemPropertyValue -Path $SetupProgressPath -Name 'SetupProgress' -ErrorAction SilentlyContinue

            If ($null -ne $SetupPct -and $SetupPct -ne $LastSetupPct) {
                $LastSetupPct = $SetupPct
                $mapped = 87 + [math]::Round($SetupPct * 0.12)   # 87–99%
                $label  = "Windows Setup: $SetupPct% complete"
                Enqueue $label
                $MessageQueue.Enqueue(@{
                    Type    = 'progress'
                    Percent = [int][math]::Min(99, $mapped)
                    Label   = $label
                })
                If ($SetupPct -ge 100) { Break }
            }

            Start-Sleep -Seconds 10
        }
    }

    $MessageQueue.Enqueue(@{ Type = 'complete'; Text = '' })
    If ($monitorActive) { Complete-IPURecord }
}
catch {
    Write-Raw "EXCEPTION: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    $MessageQueue.Enqueue(@{ Type = 'error'; Text = $_.Exception.Message })
    $MessageQueue.Enqueue(@{ Type = 'line';  Text = $_.ScriptStackTrace })
    If ($monitorActive) { Fail-IPURecord -ErrorMessage $_.Exception.Message }
}
finally {
    $RawLog.Close()
}
