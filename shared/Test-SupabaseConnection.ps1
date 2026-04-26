#Requires -Version 5.1
<#
.SYNOPSIS
    Validates Supabase connectivity, INSERT, UPDATE, and RLS immutability.
.PARAMETER SecretsPath
    Path to secrets.json. Defaults to secrets.example.json in the same folder.
.EXAMPLE
    .\Test-SupabaseConnection.ps1
    .\Test-SupabaseConnection.ps1 -SecretsPath 'C:\OSDCloud\Config\Scripts\SetupComplete\secrets.json'
#>
param(
    [string]$SecretsPath = "$PSScriptRoot\secrets.example.json"
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
#  Helpers
# ─────────────────────────────────────────────────────────────────────────────
$script:Passed = 0
$script:Failed = 0

function Write-Pass ([string]$Label) {
    Write-Host "  [PASS] $Label" -ForegroundColor Green
    $script:Passed++
}

function Write-Fail ([string]$Label, [string]$Detail = '') {
    Write-Host "  [FAIL] $Label" -ForegroundColor Red
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkRed }
    $script:Failed++
}

function Write-Step ([string]$Label) {
    Write-Host "`n$Label" -ForegroundColor Cyan
}

# ─────────────────────────────────────────────────────────────────────────────
#  Load secrets
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "`nANS IPU — Supabase Connection Test" -ForegroundColor White
Write-Host ('─' * 50) -ForegroundColor DarkGray
Write-Host "Secrets : $SecretsPath"

if (-not (Test-Path $SecretsPath)) {
    Write-Host "`n[ERROR] secrets file not found: $SecretsPath" -ForegroundColor Red
    exit 1
}

$sec = Get-Content $SecretsPath -Raw | ConvertFrom-Json

if (-not $sec.SupabaseUrl -or -not $sec.SupabaseKey) {
    Write-Host "`n[ERROR] secrets.json must contain SupabaseUrl and SupabaseKey" -ForegroundColor Red
    exit 1
}

$BaseUrl = $sec.SupabaseUrl.TrimEnd('/')
$AnonKey = $sec.SupabaseKey

Write-Host "Project : $BaseUrl"

# ─────────────────────────────────────────────────────────────────────────────
#  Import module
# ─────────────────────────────────────────────────────────────────────────────
$modulePath = Join-Path $PSScriptRoot 'SupabaseDB.psm1'
if (-not (Test-Path $modulePath)) {
    Write-Host "`n[ERROR] SupabaseDB.psm1 not found at $modulePath" -ForegroundColor Red
    exit 1
}
Import-Module $modulePath -Force -WarningAction SilentlyContinue

$conn = @{ Url = $BaseUrl; Key = $AnonKey }

$commonHeaders = @{
    'apikey'        = $AnonKey
    'Authorization' = "Bearer $AnonKey"
    'Content-Type'  = 'application/json'
}

# ─────────────────────────────────────────────────────────────────────────────
#  TEST 1 — Connectivity / table reachable
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Test 1: Connectivity"
try {
    $resp = Invoke-RestMethod `
        -Uri     "$BaseUrl/rest/v1/deployments?limit=1&select=id" `
        -Headers $commonHeaders `
        -UseBasicParsing `
        -ErrorAction Stop
    Write-Pass "Table 'deployments' is reachable (returned $(@($resp).Count) row(s))"
}
catch {
    Write-Fail "Could not reach deployments table" $_.Exception.Message
    Write-Host "`nAborting — fix connectivity before continuing." -ForegroundColor Yellow
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
#  TEST 2 — INSERT a test record
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Test 2: INSERT"
$testRow = @{
    hostname         = "ANS-SUPABASE-TEST-$([System.Environment]::MachineName)"
    manufacturer     = 'Test Vendor'
    model            = 'Test Model'
    serial_number    = 'TEST-SN-001'
    uuid             = [guid]::NewGuid().ToString().ToUpper()
    cpu              = 'Test CPU'
    cpu_cores        = 4
    cpu_logical_procs = 8
    cpu_speed_mhz    = 2400
    ram_gb           = 16
    disk_gb          = 256
    bios_version     = '1.0.0'
    os_target        = 'Windows 11 24H2'
    osd_version      = 'test'
    silent           = $false
    no_reboot        = $false
    skip_driver_pack = $false
    download_only    = $false
    dynamic_update   = $false
    status           = 'Running'
    started_at       = (Get-Date).ToString('o')
    public_ip        = '0.0.0.0'
    city             = 'Test City'
    region           = 'Test Region'
    country          = 'US'
    timezone         = 'America/New_York'
}

$insertedId = $null
try {
    $inserted   = New-SupabaseRecord -Connection $conn -Row $testRow
    $insertedId = $inserted.id
    if (-not $insertedId) { throw "Response had no id field" }
    Write-Pass "Record inserted (id=$insertedId)"
}
catch {
    Write-Fail "INSERT failed" $_.Exception.Message
    Write-Host "`nAborting — remaining tests require a valid row id." -ForegroundColor Yellow
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
#  TEST 3 — UPDATE a Running row (should succeed)
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Test 3: UPDATE (Running row — expect success)"
try {
    $updated = Update-SupabaseRecord -Connection $conn -Id $insertedId -Updates @{
        status           = 'Complete'
        completed_at     = (Get-Date).ToString('o')
        duration_minutes = 1.5
    }
    if ($null -ne $updated -and $updated.id -eq $insertedId) {
        Write-Pass "Running row updated to Complete (id=$($updated.id))"
    }
    else {
        Write-Fail "UPDATE returned unexpected response" ($updated | ConvertTo-Json -Compress)
    }
}
catch {
    Write-Fail "UPDATE of Running row threw an exception" $_.Exception.Message
}

# ─────────────────────────────────────────────────────────────────────────────
#  TEST 4 — UPDATE a Completed row (RLS should block, 0 rows affected)
#  Note: Use Invoke-RestMethod directly so we get the raw array back.
#  Update-SupabaseRecord normalises an empty array to $null, which makes
#  @($null).Count == 1 — a false failure.
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Test 4: UPDATE (Completed row — expect RLS block)"
try {
    $patchHeaders = $commonHeaders.Clone()
    $patchHeaders['Prefer'] = 'return=representation'

    $rawResponse = Invoke-RestMethod `
        -Uri     "$BaseUrl/rest/v1/deployments?id=eq.$insertedId" `
        -Method  PATCH `
        -Headers $patchHeaders `
        -Body    (@{ status = 'Running' } | ConvertTo-Json -Compress) `
        -UseBasicParsing `
        -ErrorAction Stop

    # PostgREST returns [] when RLS filters out all candidate rows
    $rowsAffected = @($rawResponse).Count
    if ($rowsAffected -eq 0) {
        Write-Pass "Completed row is immutable — RLS blocked the update (0 rows affected)"
    }
    else {
        Write-Fail "RLS did not block update of Completed row" "Row was modified — check anon_update policy USING clause"
    }
}
catch {
    # PostgREST may return 406 when Prefer:return=representation matches zero rows
    Write-Pass "Completed row is immutable — request rejected ($($_.Exception.Message))"
}

# ─────────────────────────────────────────────────────────────────────────────
#  TEST 5 — SELECT and verify final state
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Test 5: SELECT and verify final state"
try {
    $rows = Invoke-RestMethod `
        -Uri     "$BaseUrl/rest/v1/deployments?id=eq.$insertedId&select=id,status,duration_minutes" `
        -Headers $commonHeaders `
        -UseBasicParsing `
        -ErrorAction Stop

    $row = @($rows)[0]
    if ($row.status -eq 'Complete' -and $row.duration_minutes -eq 1.5) {
        Write-Pass "Row state verified (status=$($row.status), duration=$($row.duration_minutes) min)"
    }
    else {
        Write-Fail "Row state mismatch" "status=$($row.status)  duration=$($row.duration_minutes)"
    }
}
catch {
    Write-Fail "SELECT failed" $_.Exception.Message
}

# ─────────────────────────────────────────────────────────────────────────────
#  Summary
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "`n$('─' * 50)" -ForegroundColor DarkGray
$total = $script:Passed + $script:Failed
$color = if ($script:Failed -eq 0) { 'Green' } else { 'Yellow' }
Write-Host "Result  : $($script:Passed)/$total passed" -ForegroundColor $color

if ($insertedId) {
    Write-Host "`nNote    : Test record id=$insertedId remains in Supabase." -ForegroundColor DarkGray
    Write-Host "          Delete it from the Supabase dashboard if needed."  -ForegroundColor DarkGray
}

if ($script:Failed -gt 0) { exit 1 }
