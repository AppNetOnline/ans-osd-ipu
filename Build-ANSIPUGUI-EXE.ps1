#Requires -Version 5.1
<#
.SYNOPSIS
    Builds ANSIPUGUI.exe — a self-contained launcher with AES-256 encrypted credentials.
.DESCRIPTION
    Encrypts the Supabase key with a randomly generated AES-256 key, embeds both the
    ciphertext and the encryption key in a generated launcher script, then compiles it
    to an EXE using PS2EXE.

    At runtime the EXE:
      1. Decrypts credentials in memory
      2. Writes a short-lived temp secrets file
      3. Requests UAC elevation (embedded manifest)
      4. Downloads and runs Invoke-OSDCloudIPUGUI.ps1 from GitHub
      5. Deletes the temp secrets file when the process exits

    No secrets.json is required on the target machine.

    SECURITY NOTE:
    AES-256 ciphertext + key are both embedded in the binary.  This is obfuscation,
    not true encryption — a determined analyst with the binary can extract both.
    It defeats string scanning / casual inspection but not dedicated reverse engineering.
    For higher assurance, move credential issuance to a Supabase Edge Function.

    To avoid logging the key in PowerShell history, run with Read-Host:
        $k = Read-Host 'Supabase key'; .\Build-ANSIPUGUI-EXE.ps1 -SupabaseUrl '...' -SupabaseKey $k

.PARAMETER SupabaseUrl
    Supabase project URL  (https://<ref>.supabase.co)
.PARAMETER SupabaseKey
    Supabase anon/publishable key
.PARAMETER OutputPath
    Destination for the compiled EXE. Defaults to .\ANSIPUGUI.exe
.EXAMPLE
    $key = Read-Host 'Supabase key'
    .\Build-ANSIPUGUI-EXE.ps1 -SupabaseUrl 'https://omaigovthlknroxsisbo.supabase.co' -SupabaseKey $key
#>
param(
    [Parameter(Mandatory)][string]$SupabaseUrl,
    [Parameter(Mandatory)][string]$SupabaseKey,
    [string]$OutputPath = "$PSScriptRoot\ANSIPUGUI.exe"
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
#  Ensure PS2EXE is installed
# ─────────────────────────────────────────────────────────────────────────────
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'Installing ps2exe from PSGallery...' -ForegroundColor Cyan
    $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
    if (-not $nuget -or $nuget.Version -lt [version]'2.8.5') {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    }
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module ps2exe -Scope CurrentUser -Force -SkipPublisherCheck
}
Import-Module ps2exe -Force

# ─────────────────────────────────────────────────────────────────────────────
#  Generate AES-256 key/IV and encrypt both credential strings
# ─────────────────────────────────────────────────────────────────────────────
$aes = [System.Security.Cryptography.Aes]::Create()
$aes.KeySize = 256
$aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
$aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
$aes.GenerateKey()
$aes.GenerateIV()

function ConvertTo-EncBytes ([string]$plain) {
    $enc = $aes.CreateEncryptor()
    $b = [System.Text.Encoding]::UTF8.GetBytes($plain)
    $out = $enc.TransformFinalBlock($b, 0, $b.Length)
    $enc.Dispose()
    return $out
}

$encUrl = ConvertTo-EncBytes $SupabaseUrl
$encKey = ConvertTo-EncBytes $SupabaseKey

# Format byte arrays as inline PowerShell array literals
$litKey = $aes.Key -join ','
$litIV = $aes.IV -join ','
$litUrl = $encUrl -join ','
$litAK = $encKey -join ','
$aes.Dispose()

Write-Host "AES-256 key generated ($($aes.KeySize) bit)"     -ForegroundColor DarkGray
Write-Host "URL  encrypted : $($encUrl.Length) bytes"        -ForegroundColor DarkGray
Write-Host "Key  encrypted : $($encKey.Length) bytes"        -ForegroundColor DarkGray

# ─────────────────────────────────────────────────────────────────────────────
#  Build launcher from template
#  Single-quoted here-string = no variable expansion; {{MARKERS}} are replaced.
# ─────────────────────────────────────────────────────────────────────────────
$template = @'
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

# ── AES-256 encrypted credentials (not stored as plaintext anywhere in this binary)
$__k  = [byte[]]@({{KEY}})
$__iv = [byte[]]@({{IV}})
$__eu = [byte[]]@({{URL}})
$__ek = [byte[]]@({{APIKEY}})

function __Unwrap ([byte[]]$b) {
    $a = [System.Security.Cryptography.Aes]::Create()
    $a.KeySize = 256
    $a.Mode    = [System.Security.Cryptography.CipherMode]::CBC
    $a.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $a.Key = $__k; $a.IV = $__iv
    $d = $a.CreateDecryptor()
    $r = $d.TransformFinalBlock($b, 0, $b.Length)
    $a.Dispose(); $d.Dispose()
    return [System.Text.Encoding]::UTF8.GetString($r)
}

# ── Decrypt in memory
try {
    $__url = __Unwrap $__eu
    $__key = __Unwrap $__ek
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Credential initialization failed:`n$_",
        'ANS IPU Console', 'OK', 'Error') | Out-Null
    exit 1
}

# ── Write temp secrets — removed in the finally block when this process exits
$__tmp = Join-Path $env:TEMP "ans-ipu-$([guid]::NewGuid().Guid).json"
@{ SupabaseUrl = $__url; SupabaseKey = $__key } |
    ConvertTo-Json | Set-Content $__tmp -Encoding UTF8

# Signal to the deploy runspace where the secrets file is
$env:ANS_IPU_SECRETS = $__tmp

# ── Download and run the GUI (already elevated via EXE manifest)
$__dest = Join-Path $env:TEMP 'ans-ipu-gui.ps1'
try {
    Invoke-WebRequest `
        'https://raw.githubusercontent.com/AppNetOnline/ans-osd-ipu/main/gui/Invoke-OSDCloudIPUGUI.ps1' `
        -OutFile $__dest -UseBasicParsing -ErrorAction Stop
    & $__dest
} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Launch failed:`n$_",
        'ANS IPU Console', 'OK', 'Error') | Out-Null
} finally {
    Remove-Item $__tmp -Force -ErrorAction SilentlyContinue
}
'@

$launcher = $template `
    -replace '{{KEY}}', $litKey `
    -replace '{{IV}}', $litIV  `
    -replace '{{URL}}', $litUrl `
    -replace '{{APIKEY}}', $litAK

# ─────────────────────────────────────────────────────────────────────────────
#  Write temp launcher script and compile to EXE
# ─────────────────────────────────────────────────────────────────────────────
$tmpScript = Join-Path $env:TEMP 'ans-ipu-launcher.ps1'
Set-Content $tmpScript $launcher -Encoding UTF8

Write-Host 'Compiling EXE...' -ForegroundColor Cyan

try {
    Invoke-PS2EXE `
        -InputFile    $tmpScript `
        -OutputFile   $OutputPath `
        -NoConsole `
        -RequireAdmin `
        -Title        'ANS IPU Console' `
        -Description  'Appalachian Network Services - In-Place Upgrade Console' `
        -Company      'Appalachian Network Services' `
        -Version      '1.0.0.0' `
        -Copyright    '(c) Appalachian Network Services'
}
finally {
    Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────────────────
#  Report
# ─────────────────────────────────────────────────────────────────────────────
if (Test-Path $OutputPath) {
    $sizeKB = [math]::Round((Get-Item $OutputPath).Length / 1KB)
    Write-Host ''
    Write-Host "Built : $OutputPath ($sizeKB KB)" -ForegroundColor Green
    Write-Host ''
    Write-Host 'Protection layers:' -ForegroundColor White
    Write-Host '  - Credentials AES-256 encrypted (random key per build)' -ForegroundColor DarkGray
    Write-Host '  - No plaintext secrets in binary (verify with: strings ANSIPUGUI.exe)' -ForegroundColor DarkGray
    Write-Host '  - Temp secrets file deleted when process exits' -ForegroundColor DarkGray
    Write-Host '  - EXE requests UAC elevation (embedded manifest)' -ForegroundColor DarkGray
    Write-Host '  - Script body compressed by PS2EXE' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host 'Distribute ANSIPUGUI.exe only. No secrets.json needed on target machines.' -ForegroundColor Cyan
}
else {
    Write-Host 'Build failed — EXE not produced.' -ForegroundColor Red
    exit 1
}
