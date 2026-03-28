# azara

Azure App Registration Assistant — a PowerShell script that creates or updates Azure Azure app registrations from JSON configuration files.

## Prerequisites

- **Azure CLI** (`az`) installed and on PATH
- Active Azure CLI session — run `az login` before use
- Sufficient Azure permissions to manage app registrations (Application Developer, Application Administrator, or Global Administrator)

## Quick Start

```powershell
# Login to Azure
az login

# Create an app registration from a config
.\Invoke-AppRegistration.ps1 -ConfigPath .\configs\E8-Audit-Combined.json

# Preview without making changes
.\Invoke-AppRegistration.ps1 -ConfigPath .\configs\E8-Audit-Combined.json -WhatIf

# Create with admin consent and pipeline output
.\Invoke-AppRegistration.ps1 -ConfigPath .\configs\E8-Audit-Combined.json -AutoAdminConsent -PassThru
```

## Parameters

| Parameter           | Type   | Required | Default         | Description                                  |
| ------------------- | ------ | -------- | --------------- | -------------------------------------------- |
| `-ConfigPath`       | string | Yes      | —               | Path to JSON config file                     |
| `-OutputPath`       | string | No       | `$PSScriptRoot` | Directory for timestamped result file        |
| `-AutoAdminConsent` | switch | No       | —               | Attempt automated admin consent grant        |
| `-PassThru`         | switch | No       | —               | Return PSCustomObject result to pipeline     |
| `-WhatIf`           | switch | No       | —               | Preview changes without executing            |
| `-Confirm`          | switch | No       | —               | Prompt before each operation                 |

## Config Schema

All fields are required unless noted otherwise. No defaults are applied — each config is a complete, self-contained definition.

```json
{
  "displayName": "string — App registration display name",
  "description": "string (optional) — App description",
  "signInAudience": "string — See audiences table below",
  "isFallbackPublicClient": "boolean — Enable public client flows (device code, ROPC)",
  "implicitGrantSettings": {
    "enableIdTokenIssuance": "boolean",
    "enableAccessTokenIssuance": "boolean"
  },
  "redirectUris": ["string[] — Redirect URIs. Use {clientId} as placeholder."],
  "permissions": {
    "resourceAlias": {
      "delegated": ["string[] — Delegated scope names (type: Scope)"],
      "application": ["string[] — Application role names (type: Role)"]
    }
  }
}
```

### Sign-In Audiences

| Value                                | Meaning                                        |
| ------------------------------------ | ---------------------------------------------- |
| `AzureADMyOrg`                       | Single tenant (recommended for most scenarios) |
| `AzureADMultipleOrgs`                | Any Azure AD tenant                            |
| `AzureADandPersonalMicrosoftAccount` | Azure AD + personal Microsoft accounts         |
| `PersonalMicrosoftAccount`           | Personal Microsoft accounts only               |

### Well-Known Resource Aliases

Use these aliases as keys in the `permissions` object. For unlisted resources, use the raw App ID GUID.

| Alias        | App ID                                 | Service                         |
| ------------ | -------------------------------------- | ------------------------------- |
| `graph`      | `00000003-0000-0000-c000-000000000000` | Microsoft Graph                 |
| `mde`        | `fc780465-2017-40d4-a0c5-307022471b92` | Microsoft Defender for Endpoint |
| `sharepoint` | `00000003-0000-0ff1-ce00-000000000000` | SharePoint Online               |
| `exchange`   | `00000002-0000-0ff1-ce00-000000000000` | Exchange Online                 |

### Redirect URIs

URIs may contain `{clientId}` placeholders — the script replaces these with the assigned Application (client) ID. On re-runs with a previous output, URIs are already resolved so replacement is a no-op. Standard set for public client apps:

```json
[
  "http://localhost",
  "https://login.microsoftonline.com/common/oauth2/nativeclient",
  "ms-appx-web://Microsoft.AAD.BrokerPlugin/{clientId}",
  "msal{clientId}://auth"
]
```

## Idempotency

The script reads a single config file and uses the properties present to decide create vs update:

1. **`appId` present** — Updates the existing app registration by exact appId match.
2. **No `appId`** — Searches Azure by `displayName`:
   - No match: creates new app registration
   - Single match: updates existing app
   - Multiple matches: errors (ambiguous — add `appId` to the config to target a specific app)

No sidecar files or naming conventions are required. The output file is a valid input — feed it back to update the same app with modified properties.

## Output

### Result File

Written to `<OutputPath>/<configBaseName>.<yyyyMMdd_HHmmss>.json` — each run produces a uniquely timestamped output. The output is a superset of the input: all original config fields are preserved, with generated identity and runtime metadata appended. The output file can be edited and fed back as input for subsequent runs.

### Console Summary

Always printed: Client ID, Object ID, tenant, action, permission counts, and admin consent URL. When `-AutoAdminConsent` is used, consent is verified by querying the actual grant state with retry (5s, 10s, 10s — 25 seconds max).

A per-step status table is displayed showing the outcome of each operation:

```
  Step                Status
  ──────────────────────────────────────────────────
  App creation        ✓ success (76d7b3d9-...)
  Redirect URIs       ✓ success (4 URI(s))
  Permissions         ✓ success (56/56 applied)
  Admin consent       ✓ success (Verified: 2 grant(s), 4 role assignment(s))
```

### PassThru Object

With `-PassThru`, the same result structure is returned as `[PSCustomObject]` for pipeline use.

## Configs

Eight permission profiles with three variants each (Delegated, App, Combined) — 24 configs total. See [`configs/README.md`](configs/README.md) for detailed descriptions of what each profile grants access to and guidance on choosing between them.

## Permission Notes

### Scope naming — delegated vs application

Most Microsoft Graph scopes use the same `value` string for both delegated and application types (e.g., `DeviceManagementApps.Read.All` exists as both). Exceptions where the names differ:

| Delegated scope | Application role |
| --- | --- |
| `InformationProtectionPolicy.Read` | `InformationProtectionPolicy.Read.All` |
| MDE `Machine.Read` | MDE `Machine.Read.All` |
| MDE `SecurityRecommendation.Read` | MDE `SecurityRecommendation.Read.All` |
| MDE `Software.Read` | MDE `Software.Read.All` |
| MDE `Vulnerability.Read` | MDE `Vulnerability.Read.All` |

The resolver in `Invoke-AppRegistration.ps1` handles this automatically — delegated names resolve against `oauth2PermissionScopes`, application names resolve against `appRoles`.

### Over-privileged exceptions

| Scope | Issue | Justification |
| --- | --- | --- |
| `WindowsUpdates.ReadWrite.All` | No `WindowsUpdates.Read.All` exists in Microsoft Graph. The ReadWrite variant is the only way to access Windows Update deployment data (update rings, feature update status, compliance). | Used in audit configs despite being write-capable. Effective access in delegated flows is limited to the user's own permissions; app-only requires explicit admin consent. |

### Known Microsoft issues

| Scope | Issue |
| --- | --- |
| `RoleEligibilitySchedule.Read.Directory` | Documented as supporting read operations, but the API may return 403 and demand `RoleEligibilitySchedule.ReadWrite.Directory` even for GET requests. This is a known Microsoft discrepancy ([Q&A thread](https://learn.microsoft.com/en-us/answers/questions/1656176)). |
| `RoleManagementPolicy.Read.Directory` | Same issue as above — read-only scope may be insufficient for read operations in practice. |

### User.Read exclusion

`User.Read` is excluded from all configs. `User.Read.All` (present in all configs) is a superset — it grants `GET /me` access for every user via admin consent, making `User.Read` redundant. The `.All` scope covers both the signed-in user's own profile and directory-wide user enumeration.

## Future

Native web-request authentication (device code, client credentials, interactive browser) may be added via integration with the az-ctx codebase. Current scope uses Azure CLI exclusively.
