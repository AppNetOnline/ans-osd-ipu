<#
.SYNOPSIS
    Supabase REST API helpers for ANS IPU deployment tracking.
.DESCRIPTION
    Drop-in replacement for GitHubDB.psm1.
    Requires a Supabase project with the deployments table (see shared/schema.sql).

    secrets.json format:
    {
      "SupabaseUrl" : "https://<project-ref>.supabase.co",
      "SupabaseKey" : "<anon-key>"
    }

    Use the anon (publishable) key — NOT the service-role key.
    RLS policies in schema.sql restrict anon to INSERT + UPDATE(Running) + SELECT.
    Store secrets.json at:
      C:\OSDCloud\Config\Scripts\SetupComplete\secrets.json
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
#  PRIVATE — shared REST caller
# ─────────────────────────────────────────────────────────────────────────────
Function Invoke-SupabaseRest {
    Param(
        [string]$BaseUrl,
        [string]$ApiKey,
        [string]$Table,
        [string]$Method = 'GET',
        [hashtable]$Body = $null,
        [string]$Filter = ''
    )

    $headers = @{
        'apikey'        = $ApiKey
        'Authorization' = "Bearer $ApiKey"
        'Content-Type'  = 'application/json'
    }

    # Ask Supabase to return the affected row(s) on write operations
    if ($Method -in 'POST', 'PATCH') {
        $headers['Prefer'] = 'return=representation'
    }

    $uri = "$BaseUrl/rest/v1/$Table"
    if ($Filter) { $uri += "?$Filter" }

    $invokeParams = @{
        Uri             = $uri
        Method          = $Method
        Headers         = $headers
        UseBasicParsing = $True
        ErrorAction     = 'Stop'
    }

    if ($null -ne $Body) {
        $invokeParams['Body'] = ($Body | ConvertTo-Json -Depth 10 -Compress)
    }

    return Invoke-RestMethod @invokeParams
};

# ─────────────────────────────────────────────────────────────────────────────
#  PUBLIC — Insert a new deployment row
# ─────────────────────────────────────────────────────────────────────────────
Function New-SupabaseRecord {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][hashtable]$Row
    )

    $result = Invoke-SupabaseRest `
        -BaseUrl $Connection.Url `
        -ApiKey  $Connection.Key `
        -Table   'deployments' `
        -Method  'POST' `
        -Body    $Row

    # PostgREST returns an array; return the first element
    if ($result -is [array]) { return $result[0] }
    return $result
};

# ─────────────────────────────────────────────────────────────────────────────
#  PUBLIC — Patch an existing row by id
# ─────────────────────────────────────────────────────────────────────────────
Function Update-SupabaseRecord {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][hashtable]$Updates
    )

    $result = Invoke-SupabaseRest `
        -BaseUrl $Connection.Url `
        -ApiKey  $Connection.Key `
        -Table   'deployments' `
        -Method  'PATCH' `
        -Filter  "id=eq.$Id" `
        -Body    $Updates

    if ($result -is [array]) { return $result[0] }
    return $result
};

Export-ModuleMember -Function New-SupabaseRecord, Update-SupabaseRecord
