#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Remediates Windows in-place upgrade failures.

.DESCRIPTION
    Addresses the most common failure chains seen in setupact.log / SetupDiag output:
      0. Pre-flight checks          - disk space, pending reboot, Win11 readiness
      1. Clear stale staging dirs   - $WINDOWS.~BT, $GetCurrent, $Windows.~WS
      2. MoSetup registry cleanup   - clears result codes that block retry
      3. Pending CBS cleanup        - clears pending.xml / SessionsPending that block DISM
      4. Reset Windows Update       - services, SoftwareDistribution, DLL re-registration
      5. OneSettings network fix    - HOSTS blocks, WU policies, DNS check
      6. Network stack reset        - winsock/IP reset, DNS flush
      7. Hibernate space reclaim    - disables hibernation to free disk space if needed
      8. DISM / SFC repair          - component store integrity
      9. Compatibility pre-scan     - runs Setup /Compat ScanOnly against staged media

.PARAMETER SkipPreflight
    Skip disk-space and pending-reboot checks.
.PARAMETER SkipDismRepair
    Skip DISM /RestoreHealth and SFC /scannow.
.PARAMETER SkipCompatScan
    Skip the Setup.exe /Compat ScanOnly run.
.PARAMETER SkipNetworkFix
    Skip HOSTS / WU policy / DNS checks.
.PARAMETER SkipNetworkReset
    Skip netsh winsock/ip reset and DNS flush.
.PARAMETER SkipHibernate
    Skip the hibernation disable step.
.PARAMETER LogPath
    Override the default log file path.

.NOTES
    Run this script BEFORE re-running the upgrade or Windows Update Assistant.
    A reboot after this script is strongly recommended before retrying.
#>

Function Start-Repair {

    [CmdletBinding(SupportsShouldProcess)]
    Param(
        [switch]$SkipPreflight,
        [switch]$SkipDismRepair,
        [switch]$SkipCompatScan,
        [switch]$SkipNetworkFix,
        [switch]$SkipNetworkReset,
        [switch]$SkipHibernate,
        [string]$LogPath = "$env:SystemDrive\UpgradeRepair_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    )

    $ErrorActionPreference = 'Stop'

    Function Write-Log {
        Param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')]$Level = 'INFO')
        $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
        $line | Tee-Object -FilePath $LogPath -Append | Write-Host -ForegroundColor $(
            switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Cyan' } }
        )
    }

    Function Invoke-Step {
        Param([string]$Name, [scriptblock]$Action)
        Write-Log "--- $Name ---"
        try   { & $Action; Write-Log "$Name completed." }
        catch { Write-Log "$Name failed: $_" -Level ERROR }
    }

    Write-Log "Upgrade repair started. Log: $LogPath"
    Write-Log "OS: $([System.Environment]::OSVersion.VersionString)"

    # ── 0. Pre-flight checks ───────────────────────────────────────────────────
    if (-not $SkipPreflight) {
        Invoke-Step "Pre-flight checks" {

            # Disk space - upgrade needs roughly 20 GB free on system drive
            $disk      = Get-PSDrive ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
            $freeGB    = if ($disk) { [Math]::Round($disk.Free / 1GB, 1) } else { $null }
            if ($null -ne $freeGB) {
                Write-Log "Free disk space on $env:SystemDrive`: $freeGB GB"
                if ($freeGB -lt 20) {
                    Write-Log "WARNING: Less than 20 GB free. Upgrade requires ~20 GB minimum. Consider freeing space." -Level WARN
                }
            }

            # Pending reboot detection - multiple indicators
            $rebootNeeded = $false
            $pendingRename  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
            $pendingFiles   = (Get-ItemProperty -LiteralPath $pendingRename -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
            if ($pendingFiles) { Write-Log "Pending file rename operations detected - reboot required before upgrade." -Level WARN; $rebootNeeded = $true }

            $wuReboot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
            if (Test-Path $wuReboot) { Write-Log "Windows Update reboot pending." -Level WARN; $rebootNeeded = $true }

            $cbsReboot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
            if (Test-Path $cbsReboot) { Write-Log "CBS component reboot pending." -Level WARN; $rebootNeeded = $true }

            if (-not $rebootNeeded) { Write-Log "No pending reboot detected." }

            # TPM check (Windows 11 requires TPM 2.0)
            try {
                $tpm = Get-CimInstance -Namespace 'root\cimv2\security\microsofttpm' -ClassName Win32_Tpm -ErrorAction Stop
                if ($tpm) {
                    $tpmVer = $tpm.SpecVersion -split ',' | Select-Object -First 1
                    Write-Log "TPM detected. Spec version: $tpmVer"
                    if ([version]($tpmVer.Trim()) -lt [version]'2.0') {
                        Write-Log "TPM version is below 2.0 - Windows 11 requires TPM 2.0." -Level WARN
                    }
                } else {
                    Write-Log "No TPM found - Windows 11 requires TPM 2.0." -Level WARN
                }
            }
            catch { Write-Log "Could not query TPM: $_" -Level WARN }

            # Secure Boot status
            try {
                $sb = Confirm-SecureBootUEFI -ErrorAction Stop
                Write-Log "Secure Boot: $(if ($sb) { 'Enabled' } else { 'DISABLED - Windows 11 requires Secure Boot.' })"
                if (-not $sb) { Write-Log "Enable Secure Boot in UEFI firmware settings before upgrading to Windows 11." -Level WARN }
            }
            catch { Write-Log "Secure Boot check skipped (may not be UEFI system or cmdlet unavailable)." }

            # RAM check (Windows 11 requires 4 GB)
            $ramGB = [Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
            Write-Log "Installed RAM: $ramGB GB"
            if ($ramGB -lt 4) { Write-Log "RAM is below 4 GB - Windows 11 requires a minimum of 4 GB." -Level WARN }
        }
    }

    # ── 1. Clear stale staging directories ────────────────────────────────────
    Invoke-Step "Clear staging directories" {
        $stagingDirs = @(
            "$env:SystemDrive\`$WINDOWS.~BT",
            "$env:SystemDrive\`$GetCurrent",
            "$env:SystemDrive\`$Windows.~WS",
            "$env:SystemDrive\Windows10Upgrade"
        )
        foreach ($dir in $stagingDirs) {
            if (Test-Path $dir) {
                Write-Log "Removing $dir"
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path $dir)) {
                    Write-Log "Removed $dir"
                } else {
                    Write-Log "Could not fully remove $dir (files may be in use)." -Level WARN
                }
            } else {
                Write-Log "$dir not present, skipping."
            }
        }

        # Remove Panther logs that carry stale compat state
        $pantherLog = "$env:SystemRoot\Panther"
        if (Test-Path $pantherLog) {
            Get-ChildItem $pantherLog -Filter '*.log'  -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            Get-ChildItem $pantherLog -Filter '*.xml'  -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            Write-Log "Cleared stale Panther logs."
        }
    }

    # ── 2. Clean MoSetup / SetupWatson registry residue ───────────────────────
    Invoke-Step "Clear MoSetup registry residue" {
        $regPaths = @(
            'HKLM:\System\Setup\MoSetup\RegBackup',
            'HKLM:\System\Setup\SetupWatson',
            'HKLM:\System\Setup\MoSetup\Tracking'
        )
        foreach ($rp in $regPaths) {
            if (Test-Path $rp) {
                Remove-Item -LiteralPath $rp -Recurse -Force
                Write-Log "Removed registry key: $rp"
            } else {
                Write-Log "Registry key not found (ok): $rp"
            }
        }

        # Clear result codes that block retry
        $mosetupKey    = 'HKLM:\System\Setup\MoSetup'
        $valuesToClear = @('PostRebootResult', 'SetupStatusCode', 'UpgradeAttempted', 'SafeOsErrorCode')
        if (Test-Path $mosetupKey) {
            foreach ($val in $valuesToClear) {
                Remove-ItemProperty -LiteralPath $mosetupKey -Name $val -ErrorAction SilentlyContinue
                Write-Log "Cleared MoSetup value: $val"
            }
        }

        # Clear MoSetup volatile data
        $volatileKey = 'HKLM:\System\Setup\MoSetup\Volatile'
        if (Test-Path $volatileKey) {
            Remove-Item -LiteralPath $volatileKey -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Cleared MoSetup volatile key."
        }
    }

    # ── 3. Pending CBS / component-store cleanup ───────────────────────────────
    Invoke-Step "Clear pending CBS operations" {
        # pending.xml blocks DISM RestoreHealth; rename it so CBS regenerates it
        $pendingXml = "$env:SystemRoot\WinSxS\pending.xml"
        if (Test-Path $pendingXml) {
            $bak = "$pendingXml.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            Rename-Item $pendingXml $bak -Force
            Write-Log "Renamed pending.xml to $bak"
        } else {
            Write-Log "pending.xml not present (ok)."
        }

        # SessionsPending key can also serialize CBS operations
        $sessionsPending = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\SessionsPending'
        if (Test-Path $sessionsPending) {
            $count = (Get-ItemProperty -LiteralPath $sessionsPending).Exclusive
            if ($count -and $count -gt 0) {
                Set-ItemProperty -LiteralPath $sessionsPending -Name Exclusive -Value 0 -ErrorAction SilentlyContinue
                Write-Log "Reset CBS SessionsPending\Exclusive from $count to 0."
            } else {
                Write-Log "CBS SessionsPending looks clean."
            }
        }

        # Clear Windows Error Reporting queue - wermgr can hold locks that interfere
        Get-Service WerSvc -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
        $werQueue = "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"
        if (Test-Path $werQueue) {
            Remove-Item "$werQueue\*" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Cleared WER report queue."
        }
        Start-Service WerSvc -ErrorAction SilentlyContinue
    }

    # ── 4. Reset Windows Update components ────────────────────────────────────
    Invoke-Step "Reset Windows Update components" {
        $services = @('wuauserv', 'cryptsvc', 'bits', 'msiserver', 'dosvc', 'usosvc')
        Write-Log "Stopping services: $($services -join ', ')"
        foreach ($svc in $services) { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue }

        # Rename SoftwareDistribution and Catroot2 to force fresh cache
        $swDist  = "$env:SystemRoot\SoftwareDistribution"
        $catroot2 = "$env:SystemRoot\System32\catroot2"
        foreach ($p in @($swDist, $catroot2)) {
            $bak = "${p}.bak"
            if (Test-Path $p) {
                if (Test-Path $bak) { Remove-Item $bak -Recurse -Force -ErrorAction SilentlyContinue }
                Rename-Item $p $bak -Force -ErrorAction SilentlyContinue
                Write-Log "Renamed $p -> $bak"
            }
        }

        # Re-register WU DLLs
        $wuDlls = @(
            'atl.dll','urlmon.dll','mshtml.dll','shdocvw.dll','browseui.dll',
            'jscript.dll','vbscript.dll','scrrun.dll','msxml.dll','msxml3.dll',
            'msxml6.dll','actxprxy.dll','softpub.dll','wintrust.dll','dssenh.dll',
            'rsaenh.dll','gpkcsp.dll','sccbase.dll','slbcsp.dll','cryptdlg.dll',
            'oleaut32.dll','ole32.dll','shell32.dll','initpki.dll','wuapi.dll',
            'wuaueng.dll','wuaueng1.dll','wucltui.dll','wups.dll','wups2.dll',
            'wuweb.dll','qmgr.dll','qmgrprxy.dll','wucltux.dll','muweb.dll','wuwebv.dll'
        )
        foreach ($dll in $wuDlls) {
            $path = Join-Path "$env:SystemRoot\System32" $dll
            if (Test-Path $path) { regsvr32.exe /s $path }
        }
        Write-Log "Re-registered $($wuDlls.Count) WU DLLs."

        sc.exe sdset bits 'D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)'
        Set-Service -Name wuauserv -StartupType Automatic -ErrorAction SilentlyContinue
        Set-Service -Name bits     -StartupType Automatic -ErrorAction SilentlyContinue

        Write-Log "Restarting services."
        foreach ($svc in $services) { Start-Service -Name $svc -ErrorAction SilentlyContinue }
    }

    # ── 5. Fix network access for OneSettings ─────────────────────────────────
    if (-not $SkipNetworkFix) {
        Invoke-Step "Verify and restore OneSettings connectivity" {
            $hostsPath    = "$env:SystemRoot\System32\drivers\etc\hosts"
            $hostsContent = Get-Content $hostsPath -Raw
            $blockedDomains = @(
                'settings-win.data.microsoft.com',
                'watson.microsoft.com',
                'vortex.data.microsoft.com',
                'sls.update.microsoft.com',
                'fe3.delivery.mp.microsoft.com',
                'tsfe.trafficshaping.microsoft.com'
            )
            $hostsModified = $false
            foreach ($domain in $blockedDomains) {
                if ($hostsContent -match "^\s*[^#].*$([regex]::Escape($domain))") {
                    Write-Log "Found blocked domain in HOSTS: $domain - removing." -Level WARN
                    $hostsContent = ($hostsContent -split "`n" |
                        Where-Object { $_ -notmatch "^\s*[^#].*$([regex]::Escape($domain))" }) -join "`n"
                    $hostsModified = $true
                }
            }
            if ($hostsModified) {
                Set-Content $hostsPath -Value $hostsContent -Encoding UTF8
                Write-Log "HOSTS file updated."
            } else {
                Write-Log "No blocked Microsoft domains found in HOSTS."
            }

            $wuPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
            if (Test-Path $wuPolicyPath) {
                $blockedPolicies = @(
                    'DoNotConnectToWindowsUpdateInternetLocations',
                    'DisableWindowsUpdateAccess',
                    'DisableDualScan'
                )
                foreach ($policyName in $blockedPolicies) {
                    $pv = Get-ItemProperty -LiteralPath $wuPolicyPath -Name $policyName -ErrorAction SilentlyContinue
                    if ($pv -and $pv.$policyName -eq 1) {
                        Write-Log "Policy '$policyName' is blocking - removing for upgrade." -Level WARN
                        Remove-ItemProperty -LiteralPath $wuPolicyPath -Name $policyName -ErrorAction SilentlyContinue
                        Write-Log "  Removed. Restore after upgrade if required by your environment."
                    }
                }

                # WUServer pointing to internal WSUS can block dynamic updates
                $wuServer = (Get-ItemProperty -LiteralPath $wuPolicyPath -Name WUServer -ErrorAction SilentlyContinue).WUServer
                if ($wuServer) {
                    Write-Log "WSUS server configured: $wuServer - dynamic update may be redirected through WSUS." -Level WARN
                }
            } else {
                Write-Log "No Windows Update policy key found; network policy not the issue."
            }

            Write-Log "Testing DNS for settings-win.data.microsoft.com..."
            try {
                $resolve = Resolve-DnsName 'settings-win.data.microsoft.com' -ErrorAction Stop
                Write-Log "DNS resolved: $($resolve[0].IPAddress)"
            }
            catch { Write-Log "DNS resolution failed. Check firewall/proxy for settings-win.data.microsoft.com." -Level WARN }
        }
    }

    # ── 6. Network stack reset ─────────────────────────────────────────────────
    if (-not $SkipNetworkReset) {
        Invoke-Step "Reset network stack" {
            Write-Log "Running: netsh winsock reset"
            $r = & netsh.exe winsock reset 2>&1; Write-Log ($r -join ' ')

            Write-Log "Running: netsh int ip reset"
            $r = & netsh.exe int ip reset 2>&1; Write-Log ($r -join ' ')

            Write-Log "Flushing DNS cache..."
            $r = & ipconfig.exe /flushdns 2>&1; Write-Log ($r -join ' ')

            Write-Log "NOTE: A reboot is required for the winsock/IP reset to take effect."
        }
    }

    # ── 7. Disable hibernation to reclaim hiberfil.sys space ──────────────────
    if (-not $SkipHibernate) {
        Invoke-Step "Reclaim hibernation disk space" {
            $hiberFile = "$env:SystemDrive\hiberfil.sys"
            if (Test-Path $hiberFile) {
                $hiberSizeGB = [Math]::Round((Get-Item $hiberFile -Force).Length / 1GB, 1)
                Write-Log "hiberfil.sys found: $hiberSizeGB GB"
                if ($hiberSizeGB -gt 2) {
                    Write-Log "Disabling hibernation to free $hiberSizeGB GB (re-enable with: powercfg /hibernate on)." -Level WARN
                    & powercfg.exe /hibernate off 2>&1 | ForEach-Object { Write-Log $_ }
                    Write-Log "Hibernation disabled. Run 'powercfg /hibernate on' after the upgrade if needed."
                } else {
                    Write-Log "hiberfil.sys is small ($hiberSizeGB GB); skipping disable."
                }
            } else {
                Write-Log "Hibernation already disabled (hiberfil.sys not present)."
            }
        }
    }

    # ── 8. DISM component store repair ────────────────────────────────────────
    if (-not $SkipDismRepair) {
        Invoke-Step "DISM component store repair" {
            Write-Log "Running DISM /ScanHealth..."
            $r = & dism.exe /Online /Cleanup-Image /ScanHealth 2>&1
            Write-Log ($r -join "`n")

            Write-Log "Running DISM /RestoreHealth..."
            $r = & dism.exe /Online /Cleanup-Image /RestoreHealth 2>&1
            Write-Log ($r -join "`n")

            Write-Log "Running SFC /scannow..."
            $r = & sfc.exe /scannow 2>&1
            Write-Log ($r -join "`n")
        }
    }

    # ── 9. Compatibility pre-scan (ScanOnly - no install) ─────────────────────
    if (-not $SkipCompatScan) {
        Invoke-Step "Compatibility pre-scan" {
            $setupExe = "$env:SystemDrive\`$GetCurrent\media\Setup.exe"
            if (-not (Test-Path $setupExe)) {
                Write-Log "Setup.exe not found at $setupExe - re-run the Windows Update Assistant first to re-stage, then run compat scan." -Level WARN
                return
            }

            Write-Log "Running compat scan against staged media (no install)..."
            $proc = Start-Process -FilePath $setupExe `
                -ArgumentList @('/Auto', 'Upgrade', '/Quiet', '/NoReboot', '/Compat', 'ScanOnly') `
                -Wait -PassThru -NoNewWindow
            Write-Log "Compat scan exit code: $($proc.ExitCode)"

            $reports = Get-ChildItem "$env:SystemDrive\`$WINDOWS.~BT\Sources\Panther\CompatData*.xml" -ErrorAction SilentlyContinue
            if ($reports) {
                Write-Log "Compat report(s) found:"
                $reports | ForEach-Object { Write-Log "  $($_.FullName)" }
                Write-Log 'Review XML files for <BlockingType>HardBlock</BlockingType> before proceeding.'
            } else {
                Write-Log "No compat report found. Check $env:SystemDrive\`$WINDOWS.~BT\Sources\Panther\setupact.log"
            }
        }
    }

    # ── 10. Summary ────────────────────────────────────────────────────────────
    Write-Log ""
    Write-Log "=== Repair complete ==="
    Write-Log "Next steps:"
    Write-Log "  1. Review this log: $LogPath"
    Write-Log "  2. REBOOT the machine (required for winsock/IP reset and CBS changes)."
    Write-Log "  3. Re-run the upgrade - Invoke-OSDCloudIPUGUI.ps1 or Windows Update Assistant."
    Write-Log "  4. If the compat scan ran, review CompatData*.xml in `$WINDOWS.~BT\Sources\Panther\"
    Write-Log '     Look for <BlockingType>HardBlock</BlockingType> -- these require driver/app removal.'
    Write-Log "  5. If 0xC1900108 persists after reboot+retry, a driver or app is hard-blocking upgrade."
    Write-Log "  6. Restore any removed policies (DoNotConnectToWindowsUpdateInternetLocations) after upgrade."
    Write-Log "  7. If hibernation was disabled, re-enable with: powercfg /hibernate on"
}

Start-Repair
