#Requires -Version 5.1
<#
.SYNOPSIS
    Creates or updates an Azure app registration from a JSON configuration file.

.DESCRIPTION
    Reads a JSON config file defining an app registration's properties (display name,
    sign-in audience, redirect URIs, API permissions) and creates or updates the
    corresponding Azure app registration using Azure CLI.

    Idempotency model:
    - appId present in config: updates the existing app by exact appId match.
    - No appId: searches Azure by displayName. No match = create. Single match
      = update. Multiple matches = error.

    The output file is a superset of the input — all config fields plus generated
    identity and metadata. Feed the output back as input to update the same app.

    Permissions are specified as scope names (e.g., "User.Read") and resolved to
    GUIDs at runtime from the tenant's service principal. Configs are portable
    across tenants and sovereign clouds.

    Every az CLI call captures its return value for inspection. Critical operations
    (create, update) throw on failure. Optional operations (URIs, permissions,
    consent) warn and track the failure in _meta.steps for audit.

.PARAMETER ConfigPath
    Path to the JSON config file defining the app registration.
    Accepts both fresh configs and previous output files.

.PARAMETER OutputPath
    Directory where the timestamped result file is written.
    Defaults to the script's directory ($PSScriptRoot).

.PARAMETER AutoAdminConsent
    Attempts to grant admin consent after registration using
    'az ad app permission admin-consent'. Requires Global Administrator
    or Privileged Role Administrator. Consent is verified by querying
    the actual grant state with retry (up to 25 seconds).

.PARAMETER PassThru
    Returns a PSCustomObject with the registration result to the pipeline.
    Without this switch, only a console summary and result file are produced.

.EXAMPLE
    .\Invoke-AppRegistration.ps1 -ConfigPath .\configs\E8-Audit.json

.EXAMPLE
    .\Invoke-AppRegistration.ps1 -ConfigPath .\configs\E8-Audit.json -AutoAdminConsent -PassThru

.EXAMPLE
    .\Invoke-AppRegistration.ps1 -ConfigPath .\configs\E8-Audit.json -WhatIf

.EXAMPLE
    .\Invoke-AppRegistration.ps1 -ConfigPath .\E8-Audit.20260326_120000.json

.NOTES
    Prerequisites: Azure CLI installed, active session (az login), and sufficient
    Azure permissions to manage app registrations.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ConfigPath,

    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$OutputPath = $PSScriptRoot,

    [switch]$AutoAdminConsent,

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Constants

# Well-known resource app IDs. Use these aliases in config permissions keys.
# Raw GUIDs also accepted for unlisted resources.
$ResourceAppIds = [ordered]@{
    'graph'      = '00000003-0000-0000-c000-000000000000'
    'mde'        = 'fc780465-2017-40d4-a0c5-307022471b92'
    'sharepoint' = '00000003-0000-0ff1-ce00-000000000000'
    'exchange'   = '00000002-0000-0ff1-ce00-000000000000'
}

#endregion

#region Step tracking

$steps = [System.Collections.Generic.List[ordered]]::new()

function Add-Step {
    param(
        [string]$Name,
        [ValidateSet('success', 'warning', 'failed', 'skipped')]
        [string]$Status,
        [string]$Detail
    )
    $entry = [ordered]@{ step = $Name; status = $Status }
    if ($Detail) { $entry['detail'] = $Detail }
    $steps.Add($entry)
}

#endregion

#region Load config

$config = Get-Content -Path $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

$validationErrors = [System.Collections.Generic.List[string]]::new()

# Required strings
if ([string]::IsNullOrWhiteSpace($config.displayName)) { $validationErrors.Add("Missing: 'displayName'") }
if ([string]::IsNullOrWhiteSpace($config.signInAudience)) { $validationErrors.Add("Missing: 'signInAudience'") }

$validAudiences = @('AzureADMyOrg', 'AzureADMultipleOrgs', 'AzureADandPersonalMicrosoftAccount', 'PersonalMicrosoftAccount')
if ($config.signInAudience -and $config.signInAudience -notin $validAudiences) {
    $validationErrors.Add("Invalid signInAudience '$($config.signInAudience)'. Must be: $($validAudiences -join ', ')")
}

# Required booleans
if ($null -eq $config.isFallbackPublicClient) { $validationErrors.Add("Missing: 'isFallbackPublicClient'") }

# Implicit grant settings
if (-not $config.implicitGrantSettings) {
    $validationErrors.Add("Missing section: 'implicitGrantSettings'")
}
else {
    if ($null -eq $config.implicitGrantSettings.enableIdTokenIssuance) { $validationErrors.Add("Missing: 'implicitGrantSettings.enableIdTokenIssuance'") }
    if ($null -eq $config.implicitGrantSettings.enableAccessTokenIssuance) { $validationErrors.Add("Missing: 'implicitGrantSettings.enableAccessTokenIssuance'") }
}

# Redirect URIs
if (-not $config.redirectUris -or @($config.redirectUris).Count -eq 0) {
    $validationErrors.Add("Missing or empty: 'redirectUris'")
}

# Permissions
if (-not $config.permissions) {
    $validationErrors.Add("Missing section: 'permissions'")
}
elseif (@($config.permissions.PSObject.Properties).Count -eq 0) {
    $validationErrors.Add("'permissions' has no resource entries")
}
else {
    foreach ($prop in $config.permissions.PSObject.Properties) {
        $resource = $prop.Value
        $hasDel   = $resource.PSObject.Properties['delegated']   -and @($resource.delegated).Count -gt 0
        $hasApp   = $resource.PSObject.Properties['application'] -and @($resource.application).Count -gt 0
        if (-not $hasDel -and -not $hasApp) {
            $validationErrors.Add("Resource '$($prop.Name)' has no scopes (delegated or application)")
        }
    }
}

if ($validationErrors.Count -gt 0) {
    throw "Config validation failed:`n  - $($validationErrors -join "`n  - ")"
}

# Safe extraction of optional properties (StrictMode -Version Latest throws on missing properties)
$configAppId       = if ($config.PSObject.Properties['appId'])       { $config.appId }       else { $null }
$configDescription = if ($config.PSObject.Properties['description']) { $config.description } else { $null }

#endregion

#region Check AzCLI

$azRaw = az account show --output json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $azRaw) {
    throw "No active Azure CLI session. Run 'az login' first."
}
$azAccount = $azRaw | ConvertFrom-Json
$tenantId  = $azAccount.tenantId

Write-Host ''
Write-Host '  Azure App Registration Assistant' -ForegroundColor Cyan
Write-Host "  Config: $ConfigPath"
Write-Host "  Tenant: $tenantId ($($azAccount.name))"
Write-Host ''

#endregion

#region Find existing app

$isUpdate        = $false
$appObjectId     = $null
$appClientId     = $null
$liveDisplayName = $null
$liveApp         = $null

Write-Host "  $([string]::new([char]0x2500, 2)) Identity $([string]::new([char]0x2500, 42))" -ForegroundColor Cyan
if ($configAppId) {
    Write-Host "  Searching by appId ($configAppId)..." -ForegroundColor DarkGray
    # Exact match by appId from config
    $raw = az ad app list --filter "appId eq '$configAppId'" `
        --query '[].{id:id, appId:appId, displayName:displayName, signInAudience:signInAudience, isFallbackPublicClient:isFallbackPublicClient, implicitGrant:web.implicitGrantSettings}' --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and $raw) {
        $apps = @($raw | ConvertFrom-Json)
        if ($apps.Count -eq 1) {
            $isUpdate        = $true
            $appObjectId     = $apps[0].id
            $appClientId     = $apps[0].appId
            $liveDisplayName = $apps[0].displayName
            $liveApp         = $apps[0]
            Write-Host "  Match (AppId): $liveDisplayName [$appClientId]" -ForegroundColor Green
        }
        else {
            throw "AppId '$configAppId' not found in tenant."
        }
    }
    else {
        throw "Failed to query Azure for appId '$configAppId'."
    }
}
else {
    Write-Host "  Searching by displayName ($($config.displayName))..." -ForegroundColor DarkGray
    # Search by DisplayName (az CLI does substring match, so filter client-side for exact)
    $raw = az ad app list --display-name $config.displayName `
        --query '[].{id:id, appId:appId, displayName:displayName, signInAudience:signInAudience, isFallbackPublicClient:isFallbackPublicClient, implicitGrant:web.implicitGrantSettings}' --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and $raw) {
        $apps = @(($raw | ConvertFrom-Json) | Where-Object { $_.displayName -eq $config.displayName })

        switch ($apps.Count) {
            0 {
                Write-Host '  No existing app found' -ForegroundColor DarkGray
            }
            1 {
                $isUpdate        = $true
                $appObjectId     = $apps[0].id
                $appClientId     = $apps[0].appId
                $liveDisplayName = $apps[0].displayName
                $liveApp         = $apps[0]
                Write-Host "  Match (Name): $liveDisplayName [$appClientId]" -ForegroundColor Green
            }
            { $_ -gt 1 } {
                foreach ($a in $apps) { Write-Warning "  - $($a.appId) ($($a.displayName))" }
                throw "Multiple apps named '$($config.displayName)'. Add appId to the config to target a specific app."
            }
        }
    }
    elseif ($LASTEXITCODE -ne 0) {
        throw "Failed to query Azure for display name '$($config.displayName)'."
    }
}

#endregion

#region Rename detection

if ($isUpdate -and $liveDisplayName -and $config.displayName -ne $liveDisplayName) {
    if ($PSCmdlet.ShouldContinue(
            "Rename '$liveDisplayName' to '$($config.displayName)'?",
            'Display Name Change Detected')) {
        Write-Host "  Renaming: $liveDisplayName -> $($config.displayName)" -ForegroundColor Yellow
    }
    else {
        Write-Host "  Rename declined. Keeping '$liveDisplayName'." -ForegroundColor DarkGray
        $config.displayName = $liveDisplayName
    }
}

#endregion

#region Set Core Props

Write-Host ''
Write-Host "  $([string]::new([char]0x2500, 2)) Configuration $([string]::new([char]0x2500, 36))" -ForegroundColor Cyan
$boolIdToken  = $config.implicitGrantSettings.enableIdTokenIssuance.ToString().ToLower()
$boolAccToken = $config.implicitGrantSettings.enableAccessTokenIssuance.ToString().ToLower()
$boolPublic   = $config.isFallbackPublicClient.ToString().ToLower()

if ($isUpdate) {
    # Compare config against live state to detect actual changes
    Write-Host '  Comparing core properties...' -ForegroundColor DarkGray
    $liveAudience = if ($liveApp.signInAudience) { [string]$liveApp.signInAudience } else { '' }
    $livePublic   = if ($null -ne $liveApp.isFallbackPublicClient) { $liveApp.isFallbackPublicClient.ToString().ToLower() } else { 'false' }
    $liveIdToken  = 'false'
    $liveAccToken = 'false'
    if ($liveApp.implicitGrant) {
        if ($null -ne $liveApp.implicitGrant.enableIdTokenIssuance)     { $liveIdToken  = $liveApp.implicitGrant.enableIdTokenIssuance.ToString().ToLower() }
        if ($null -ne $liveApp.implicitGrant.enableAccessTokenIssuance) { $liveAccToken = $liveApp.implicitGrant.enableAccessTokenIssuance.ToString().ToLower() }
    }

    $changes = [System.Collections.Generic.List[string]]::new()
    if ($config.signInAudience -ne $liveAudience) { $changes.Add("audience: $liveAudience -> $($config.signInAudience)") }
    if ($boolPublic   -ne $livePublic)            { $changes.Add("publicClient: $livePublic -> $boolPublic") }
    if ($boolIdToken  -ne $liveIdToken)           { $changes.Add("idToken: $liveIdToken -> $boolIdToken") }
    if ($boolAccToken -ne $liveAccToken)          { $changes.Add("accessToken: $liveAccToken -> $boolAccToken") }

    if ($changes.Count -eq 0) {
        Write-Host "    audience=$liveAudience, publicClient=$livePublic, idToken=$liveIdToken, accessToken=$liveAccToken" -ForegroundColor DarkGray
        Add-Step -Name 'Core properties' -Status 'success' -Detail 'Already correct'
        Write-Host '  Core properties already correct' -ForegroundColor DarkGray
    }
    elseif ($PSCmdlet.ShouldProcess("'$($config.displayName)' ($appClientId)", 'Update')) {
        Write-Host '  Updating core properties...' -ForegroundColor Yellow
        $result = az ad app update --id $appObjectId `
            --display-name $config.displayName `
            --sign-in-audience $config.signInAudience `
            --enable-id-token-issuance $boolIdToken `
            --enable-access-token-issuance $boolAccToken `
            --is-fallback-public-client $boolPublic 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Core property update failed: $result"
        }
        Add-Step -Name 'Core properties' -Status 'success' -Detail "$($changes.Count) property change(s)"
        foreach ($c in $changes) {
            Write-Host "    $c" -ForegroundColor Green
        }
    }
}
else {
    if ($PSCmdlet.ShouldProcess("'$($config.displayName)' (new)", 'Create')) {
        Write-Host '  Creating app registration...' -ForegroundColor Yellow
        $raw = az ad app create `
            --display-name $config.displayName `
            --sign-in-audience $config.signInAudience `
            --enable-id-token-issuance $boolIdToken `
            --enable-access-token-issuance $boolAccToken `
            --is-fallback-public-client $boolPublic `
            --query '{id:id, appId:appId}' --output json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) {
            throw "App creation failed: $raw"
        }

        $created     = $raw | ConvertFrom-Json
        $appObjectId = $created.id
        $appClientId = $created.appId
        Add-Step -Name 'App creation' -Status 'success' -Detail $appClientId
        Write-Host "  Created: $appClientId" -ForegroundColor Green
    }
}

#endregion

#region WhatIf exit

if ($WhatIfPreference) {
    Write-Host "`n  WhatIf: redirect URIs, permissions, consent, and result file skipped.`n" -ForegroundColor DarkYellow
    return
}
if (-not $appObjectId -or -not $appClientId) {
    throw 'App IDs unavailable after create/update.'
}

#endregion

#region Redirect URIs

$redirectUris = @($config.redirectUris | ForEach-Object {
        $_ -replace '\{clientId\}', $appClientId
    })

$uriType = if ($config.isFallbackPublicClient) { 'public-client' } else { 'web' }

if ($PSCmdlet.ShouldProcess("$($redirectUris.Count) redirect URI(s)", 'Set')) {
    Write-Host "  Setting redirect URIs ($uriType)..." -ForegroundColor Yellow
    if ($config.isFallbackPublicClient) {
        $uriArgs = @('ad', 'app', 'update', '--id', $appObjectId, '--public-client-redirect-uris') + $redirectUris
    }
    else {
        $uriArgs = @('ad', 'app', 'update', '--id', $appObjectId, '--web-redirect-uris') + $redirectUris
    }
    $result = & az @uriArgs 2>$null
    if ($LASTEXITCODE -ne 0) {
        Add-Step -Name 'Redirect URIs' -Status 'failed' -Detail "az returned exit code $LASTEXITCODE"
        Write-Warning "Failed to set redirect URIs: $result"
    }
    else {
        Add-Step -Name 'Redirect URIs' -Status 'success' -Detail "$($redirectUris.Count) URI(s)"
        Write-Host "    $($redirectUris.Count) URI(s) set" -ForegroundColor Green
    }
}

#endregion

#region Apply Permissions

Write-Host ''
Write-Host "  $([string]::new([char]0x2500, 2)) API Access $([string]::new([char]0x2500, 39))" -ForegroundColor Cyan
Write-Host '  Resolving permissions...' -ForegroundColor DarkGray
$requiredResourceAccess = [System.Collections.Generic.List[hashtable]]::new()
$consentMap             = [System.Collections.Generic.List[hashtable]]::new()
$totalResolved  = 0
$totalRequested = 0

foreach ($prop in $config.permissions.PSObject.Properties) {
    $resource         = $prop.Value
    $delegatedNames   = @()
    $applicationNames = @()
    if ($resource.PSObject.Properties['delegated'])   { $delegatedNames   = @($resource.delegated) }
    if ($resource.PSObject.Properties['application']) { $applicationNames = @($resource.application) }
    $scopeCount       = $delegatedNames.Count + $applicationNames.Count
    $totalRequested  += $scopeCount
    if ($scopeCount -eq 0) { continue }

    # Resolve resource alias to appId
    $alias = $prop.Name.ToLower()
    $resourceAppId = if ($ResourceAppIds.Contains($alias)) {
        $ResourceAppIds[$alias]
    }
    elseif ($prop.Name -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
        $prop.Name
    }
    else {
        throw "Unknown resource '$($prop.Name)'. Aliases: $($ResourceAppIds.Keys -join ', '). Or use a GUID."
    }

    # Query the service principal's object ID, delegated scopes, and application roles
    $spRaw = az ad sp show --id $resourceAppId --query '{id:id, scopes:oauth2PermissionScopes, roles:appRoles}' --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $spRaw) {
        Write-Warning "Service principal '$resourceAppId' not found in tenant. Skipping '$($prop.Name)'."
        continue
    }

    $sp             = $spRaw | ConvertFrom-Json
    $resourceSpId   = $sp.id
    $spScopes       = @()
    $spRoles        = @()
    if ($sp.scopes) { $spScopes = @($sp.scopes) }
    if ($sp.roles)  { $spRoles  = @($sp.roles) }
    $resolved       = [System.Collections.Generic.List[hashtable]]::new()
    $missing        = [System.Collections.Generic.List[string]]::new()
    $delegatedScope = [System.Collections.Generic.List[string]]::new()
    $roleGuids      = [System.Collections.Generic.List[string]]::new()

    # Resolve delegated scopes against oauth2PermissionScopes
    foreach ($name in $delegatedNames) {
        $match = $spScopes | Where-Object { $_.value -eq $name } | Select-Object -First 1
        if ($match) {
            $resolved.Add(@{ id = $match.id; type = 'Scope' })
            $delegatedScope.Add($name)
        }
        else { $missing.Add("$name (delegated)") }
    }

    # Resolve application roles against appRoles
    foreach ($name in $applicationNames) {
        $match = $spRoles | Where-Object { $_.value -eq $name } | Select-Object -First 1
        if ($match) {
            $resolved.Add(@{ id = $match.id; type = 'Role' })
            $roleGuids.Add($match.id)
        }
        else { $missing.Add("$name (application)") }
    }

    if ($missing.Count -gt 0) {
        Write-Warning "Unresolved on '$($prop.Name)': $($missing -join ', ')"
    }

    if ($resolved.Count -gt 0) {
        $requiredResourceAccess.Add(@{
                resourceAppId  = $resourceAppId
                resourceAccess = @($resolved)
            })
        $consentMap.Add(@{
                alias          = $prop.Name
                resourceAppId  = $resourceAppId
                resourceSpId   = $resourceSpId
                delegatedScope = ($delegatedScope -join ' ')
                roleGuids      = @($roleGuids)
            })
        $totalResolved += $resolved.Count
        $typeParts = @()
        if ($delegatedScope.Count -gt 0) { $typeParts += "$($delegatedScope.Count) delegated" }
        if ($roleGuids.Count -gt 0)      { $typeParts += "$($roleGuids.Count) application" }
        Write-Host "    $($prop.Name): $($typeParts -join ', ') ($($resolved.Count)/$scopeCount)" -ForegroundColor DarkGray
    }
}

if ($requiredResourceAccess.Count -gt 0 -and
    $PSCmdlet.ShouldProcess("$totalResolved permission(s)", 'Apply')) {

    Write-Host '  Applying permissions...' -ForegroundColor Yellow
    $json = ConvertTo-Json -InputObject @($requiredResourceAccess) -Depth 10 -Compress
    $permissionsFile = Join-Path -Path $env:TEMP -ChildPath 'azara-permissions.json'
    [System.IO.File]::WriteAllText($permissionsFile, $json, [System.Text.Encoding]::UTF8)

    try {
        $result = az ad app update --id $appObjectId --required-resource-accesses "@$permissionsFile" 2>$null
        if ($LASTEXITCODE -ne 0) {
            $permDetail = "az returned exit code $LASTEXITCODE"
            if ($totalRequested -gt $totalResolved) {
                $permDetail += "; $($totalRequested - $totalResolved) unresolved"
            }
            Add-Step -Name 'Permissions' -Status 'failed' -Detail $permDetail
            Write-Warning "Permission application failed: $result"
        }
        else {
            $permDetail = "$totalResolved/$totalRequested applied"
            if ($totalRequested -gt $totalResolved) {
                Add-Step -Name 'Permissions' -Status 'warning' -Detail "$totalResolved/$totalRequested ($($totalRequested - $totalResolved) unresolved)"
                Write-Host "    $totalResolved/$totalRequested scope(s) applied (some unresolved)" -ForegroundColor Yellow
            }
            else {
                Add-Step -Name 'Permissions' -Status 'success' -Detail $permDetail
                Write-Host "    $totalResolved/$totalRequested scope(s) applied" -ForegroundColor Green
            }
        }
    }
    finally {
        if (Test-Path -Path $permissionsFile) {
            Remove-Item -Path $permissionsFile -Force -ErrorAction SilentlyContinue
        }
    }
}
elseif ($requiredResourceAccess.Count -eq 0) {
    Add-Step -Name 'Permissions' -Status 'warning' -Detail 'No permissions resolved'
    Write-Warning 'No permissions could be resolved from config.'
}

#endregion

#region Admin consent

$consentUrl = "https://login.microsoftonline.com/$tenantId/adminconsent?client_id=$appClientId"

if ($AutoAdminConsent -and
    $PSCmdlet.ShouldProcess("'$($config.displayName)'", 'Grant admin consent')) {

    Write-Host ''
    Write-Host "  $([string]::new([char]0x2500, 2)) Admin Consent $([string]::new([char]0x2500, 36))" -ForegroundColor Cyan
    # Check for existing service principal (required for consent and verification)
    Write-Host '  Checking service principal...' -ForegroundColor DarkGray
    $spCreated = $false
    $spIdRaw = az ad sp show --id $appClientId --query 'id' --output tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $spIdRaw) {
        Write-Host '    Creating service principal...' -ForegroundColor Yellow
        $spIdRaw = az ad sp create --id $appClientId --query 'id' --output tsv 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $spIdRaw) {
            Add-Step -Name 'Admin consent' -Status 'failed' -Detail 'Could not create service principal'
            Write-Warning "Failed to create service principal for '$appClientId'. Admin consent requires an SP."
        }
        else { $spCreated = $true }
    }

    if ($spIdRaw) {
        $spObjectId = $spIdRaw.Trim()
        if ($spCreated) {
            Write-Host "    SP created: $spObjectId" -ForegroundColor Green
            Write-Host '  Waiting 5s for SP propagation...' -ForegroundColor DarkGray
            Start-Sleep -Seconds 5
        }
        else {
            Write-Host "    SP exists: $spObjectId" -ForegroundColor DarkGray
        }

        # Grant consent via direct Graph API calls (per-resource, per-type)
        Write-Host '  Granting consent via Graph API...' -ForegroundColor Yellow
        $grantErrors = [System.Collections.Generic.List[string]]::new()
        $grantedDelegated = 0
        $grantedRoles     = 0

        foreach ($cm in $consentMap) {
            # Delegated grants: POST oauth2PermissionGrants (one per resource SP)
            if ($cm.delegatedScope) {
                $grantFile = Join-Path -Path $env:TEMP -ChildPath 'azara-grant.json'

                # Check for existing oauth2PermissionGrant (GET before POST/PATCH)
                $getUrl = "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$spObjectId' and resourceId eq '$($cm.resourceSpId)'"
                $existingOut = az rest --method GET --url $getUrl 2>&1
                $existingGrant = $null
                if ($LASTEXITCODE -eq 0) {
                    $parsed = $existingOut | ConvertFrom-Json
                    if ($parsed.value -and $parsed.value.Count -gt 0) {
                        $existingGrant = $parsed.value[0]
                    }
                }

                if ($existingGrant) {
                    # Existing grant found — merge scopes and PATCH
                    $existingScopes = @($existingGrant.scope -split '\s+' | Where-Object { $_ })
                    $newScopes      = @($cm.delegatedScope -split '\s+' | Where-Object { $_ })
                    $mergedScopes   = ($existingScopes + $newScopes | Sort-Object -Unique) -join ' '
                    $patchBody = @{ scope = $mergedScopes } | ConvertTo-Json -Compress
                    [System.IO.File]::WriteAllText($grantFile, $patchBody, [System.Text.Encoding]::UTF8)
                    $grantOut = az rest --method PATCH `
                        --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$($existingGrant.id)" `
                        --body "@$grantFile" `
                        --headers 'Content-Type=application/json' 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        $grantedDelegated++
                        $addedCount = $mergedScopes.Split(' ').Count - $existingScopes.Count
                        if ($addedCount -gt 0) {
                            Write-Host "    $($cm.alias): delegated grant updated ($($existingScopes.Count) existing + $addedCount new = $($mergedScopes.Split(' ').Count) scope(s))" -ForegroundColor DarkGray
                        }
                        else {
                            Write-Host "    $($cm.alias): delegated grant unchanged ($($mergedScopes.Split(' ').Count) scope(s))" -ForegroundColor DarkGray
                        }
                    }
                    else {
                        $errMsg = ($grantOut | Out-String).Trim()
                        $grantErrors.Add("$($cm.alias) delegated: $errMsg")
                        Write-Warning "    $($cm.alias): delegated grant update failed: $errMsg"
                    }
                }
                else {
                    # No existing grant — POST new
                    $grantBody = @{
                        clientId    = $spObjectId
                        consentType = 'AllPrincipals'
                        resourceId  = $cm.resourceSpId
                        scope       = $cm.delegatedScope
                    } | ConvertTo-Json -Compress
                    [System.IO.File]::WriteAllText($grantFile, $grantBody, [System.Text.Encoding]::UTF8)
                    $grantOut = az rest --method POST `
                        --url 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants' `
                        --body "@$grantFile" `
                        --headers 'Content-Type=application/json' 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        $grantedDelegated++
                        Write-Host "    $($cm.alias): delegated grant created" -ForegroundColor DarkGray
                    }
                    else {
                        $errMsg = ($grantOut | Out-String).Trim()
                        $grantErrors.Add("$($cm.alias) delegated: $errMsg")
                        Write-Warning "    $($cm.alias): delegated grant failed: $errMsg"
                    }
                }
                if (Test-Path -Path $grantFile) {
                    Remove-Item -Path $grantFile -Force -ErrorAction SilentlyContinue
                }
            }

            # Application role assignments: POST appRoleAssignments (one per role)
            foreach ($roleId in $cm.roleGuids) {
                $roleBody = @{
                    principalId = $spObjectId
                    resourceId  = $cm.resourceSpId
                    appRoleId   = $roleId
                } | ConvertTo-Json -Compress
                $roleFile = Join-Path -Path $env:TEMP -ChildPath 'azara-role.json'
                [System.IO.File]::WriteAllText($roleFile, $roleBody, [System.Text.Encoding]::UTF8)
                $roleOut = az rest --method POST `
                    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spObjectId/appRoleAssignments" `
                    --body "@$roleFile" `
                    --headers 'Content-Type=application/json' 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $grantedRoles++
                }
                else {
                    $errMsg = ($roleOut | Out-String).Trim()
                    $grantErrors.Add("$($cm.alias) role $roleId`: $errMsg")
                }
                if (Test-Path -Path $roleFile) {
                    Remove-Item -Path $roleFile -Force -ErrorAction SilentlyContinue
                }
            }
            if ($cm.roleGuids.Count -gt 0) {
                $roleResult = if ($grantErrors.Count -eq 0) { 'assigned' } else { 'partial' }
                Write-Host "    $($cm.alias): $($cm.roleGuids.Count) app role(s) $roleResult" -ForegroundColor DarkGray
            }
        }

        if ($grantErrors.Count -gt 0) {
            Add-Step -Name 'Admin consent' -Status 'warning' -Detail "$grantedDelegated delegated grant(s), $grantedRoles role(s); $($grantErrors.Count) error(s)"
            Write-Warning "Consent partially failed ($($grantErrors.Count) error(s)):`n  $($grantErrors -join "`n  ")`n  Grant manually: $consentUrl"
        }

        if ($grantErrors.Count -eq 0 -or $grantedDelegated -gt 0 -or $grantedRoles -gt 0) {
            # Verify consent by querying actual grant state with retry
            Write-Host '  Verifying consent...' -ForegroundColor DarkGray
            $verified   = $false
            $delays     = @(5, 10, 10)  # 25 seconds total max

            foreach ($wait in $delays) {
                Write-Host "    Waiting ${wait}s for propagation..." -ForegroundColor DarkGray
                Start-Sleep -Seconds $wait

                # Check delegated grants (oauth2PermissionGrants)
                $grantsRaw = az rest --method GET `
                    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spObjectId/oauth2PermissionGrants" `
                    --query 'value' --output json 2>$null
                $hasGrants = $false
                if ($LASTEXITCODE -eq 0 -and $grantsRaw) {
                    $grants = $grantsRaw | ConvertFrom-Json
                    if (@($grants).Count -gt 0) { $hasGrants = $true }
                }

                # Check application role assignments (appRoleAssignments)
                $rolesRaw = az rest --method GET `
                    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spObjectId/appRoleAssignments" `
                    --query 'value' --output json 2>$null
                $hasRoles = $false
                if ($LASTEXITCODE -eq 0 -and $rolesRaw) {
                    $roles = $rolesRaw | ConvertFrom-Json
                    if (@($roles).Count -gt 0) { $hasRoles = $true }
                }

                if ($hasGrants -or $hasRoles) {
                    $verified = $true
                    $grantCount = if ($hasGrants) { @($grants).Count } else { 0 }
                    $roleCount  = if ($hasRoles)  { @($roles).Count }  else { 0 }
                    break
                }
            }

            if ($verified) {
                $consentDetail = "Verified: $grantCount grant(s), $roleCount role assignment(s)"
                if ($grantErrors.Count -eq 0) {
                    Add-Step -Name 'Admin consent' -Status 'success' -Detail $consentDetail
                }
                Write-Host "  Consent verified ($consentDetail)" -ForegroundColor Green
            }
            elseif ($grantErrors.Count -eq 0) {
                Add-Step -Name 'Admin consent' -Status 'failed' -Detail 'No grants found after 25s'
                Write-Warning "Consent grants were accepted but no grants detected after 25 seconds.`n  Grant manually: $consentUrl"
            }
        }
    }
}
elseif ($AutoAdminConsent) {
    Add-Step -Name 'Admin consent' -Status 'skipped' -Detail 'ShouldProcess declined'
}

#endregion

#region Write result

$action     = if ($isUpdate) { 'Update' } else { 'Create' }
$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$configBase = [System.IO.Path]::GetFileNameWithoutExtension($ConfigPath)
$configBase = $configBase -replace '\.\d{8}_\d{6}$', ''
$resultPath = Join-Path $OutputPath "$configBase.$timestamp.json"

$result = [ordered]@{
    appId                  = $appClientId
    objectId               = $appObjectId
    displayName            = $config.displayName
    description            = $configDescription
    signInAudience         = $config.signInAudience
    isFallbackPublicClient = [bool]$config.isFallbackPublicClient
    implicitGrantSettings  = [ordered]@{
        enableIdTokenIssuance     = [bool]$config.implicitGrantSettings.enableIdTokenIssuance
        enableAccessTokenIssuance = [bool]$config.implicitGrantSettings.enableAccessTokenIssuance
    }
    redirectUris           = $redirectUris
    permissions            = [ordered]@{}
    _meta                  = [ordered]@{
        tenantId        = $tenantId
        tenantName      = $azAccount.name
        action          = $action
        registeredAt    = (Get-Date -Format 'o')
        permissionCount = $totalResolved
        consentUrl      = $consentUrl
        steps           = @($steps)
    }
}

# Omit description if not present in input
if (-not $configDescription) { $result.Remove('description') }

foreach ($prop in $config.permissions.PSObject.Properties) {
    $resource  = $prop.Value
    $permEntry = [ordered]@{}
    if ($resource.PSObject.Properties['delegated'])   { $permEntry['delegated']   = @($resource.delegated) }
    if ($resource.PSObject.Properties['application']) { $permEntry['application'] = @($resource.application) }
    $result.permissions[$prop.Name] = $permEntry
}

$resultJson = ConvertTo-Json -InputObject $result -Depth 10
[System.IO.File]::WriteAllText($resultPath, $resultJson)

#endregion

#region Summary

Write-Host ''
Write-Host '  --- Summary -----------------------------------------' -ForegroundColor Cyan
Write-Host "  App:          $($config.displayName)"
Write-Host "  Client ID:    $appClientId"
Write-Host "  Object ID:    $appObjectId"
Write-Host "  Tenant:       $tenantId"
Write-Host "  Action:       $action"
Write-Host "  Permissions:  $totalResolved/$totalRequested scope(s)"
Write-Host "  URIs:         $($redirectUris.Count)"
Write-Host "  Result:       $resultPath"
Write-Host ''

# Per-step status table
if ($steps.Count -gt 0) {
    $maxNameLen = ($steps | ForEach-Object { $_.step.Length } | Measure-Object -Maximum).Maximum
    $padLen     = [Math]::Max($maxNameLen + 2, 20)

    Write-Host "  $('Step'.PadRight($padLen))Status" -ForegroundColor Cyan
    Write-Host "  $([string]::new([char]0x2500, $padLen))$([string]::new([char]0x2500, 30))" -ForegroundColor DarkGray

    foreach ($s in $steps) {
        $icon = switch ($s.status) {
            'success' { [char]0x2713 }
            'warning' { [char]0x26A0 }
            'failed'  { [char]0x2717 }
            'skipped' { [char]0x2014 }
        }
        $color = switch ($s.status) {
            'success' { 'Green' }
            'warning' { 'Yellow' }
            'failed'  { 'Red' }
            'skipped' { 'DarkGray' }
        }
        $detail = if ($s['detail']) { " ($($s['detail']))" } else { '' }
        Write-Host "  $($s.step.PadRight($padLen))$icon $($s.status)$detail" -ForegroundColor $color
    }
    Write-Host ''
}

if (-not $AutoAdminConsent) {
    Write-Host '  Consent URL:' -ForegroundColor Yellow
    Write-Host "  $consentUrl"
    Write-Host ''
}
Write-Host '  -----------------------------------------------------' -ForegroundColor Cyan
Write-Host ''

if ($PassThru) { [PSCustomObject]$result }

#endregion
