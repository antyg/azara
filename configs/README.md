# Configs

Pre-built JSON configurations for common Azure app registration scenarios. Each config is a complete, self-contained input for `Invoke-AppRegistration.ps1`.

## Variants

Every profile is provided in three variants:

| Suffix | Client Type | Permissions | Use Case |
| --- | --- | --- | --- |
| `-Delegated` | Public client | Delegated scopes only | Interactive sessions — scripts, CLI tools, and user-context automation where a human signs in |
| `-App` | Confidential client | Application roles only | Daemon and service workloads — no user present, runs under the app's own identity |
| `-Combined` | Public client | Both delegated and application | Maximum flexibility — covers both interactive and background scenarios in a single registration |

All configs use `AzureADMyOrg` (single tenant). Delegated and Combined variants include four redirect URIs (localhost, native client, WAM broker plugin, MSAL). App variants use localhost only.

## Profiles

### E8-Audit — Essential Eight Compliance Audit

**Resources:** Microsoft Graph + Microsoft Defender for Endpoint

The broadest read-only config and the only profile that includes MDE permissions. Designed for organisations assessing compliance against the Australian Essential Eight maturity model.

**What it covers:**

- **Endpoint management** — Intune apps, device configuration, managed devices, compliance policies, RBAC roles, and scripting (`DeviceManagementApps`, `DeviceManagementConfiguration`, `DeviceManagementManagedDevices`, `DeviceManagementRBAC`, `DeviceManagementServiceConfig`)
- **Identity and directory** — Users, groups, organisation settings, directory roles, and audit logs (`User.Read.All`, `Group.Read.All`, `Organization.Read.All`, `AuditLog.Read.All`, `Application.Read.All`)
- **Security operations** — Alerts, incidents, advanced hunting, and threat intelligence (`SecurityAlert`, `SecurityIncident`, `ThreatHunting`, `ThreatIntelligence`)
- **Identity governance** — PIM for groups, access reviews, entitlement management, and admin consent requests (`PrivilegedAccess.Read.AzureADGroup`, `AccessReview`, `EntitlementManagement`, `ConsentRequest`)
- **Identity protection** — Risk events and risky user state (`IdentityRiskEvent`, `IdentityRiskyUser`)
- **Information protection** — Sensitivity labels and label policies (`InformationProtectionPolicy`)
- **Windows Update** — Update ring deployment and feature update compliance (`WindowsUpdates.ReadWrite.All` — ReadWrite is the only variant Microsoft publishes; see Permission Notes in root README)
- **Policy** — Conditional access and authentication policies (`Policy.Read.All`)
- **MDE endpoint data** — Machine inventory, security recommendations, software inventory, and known vulnerabilities (`Machine`, `SecurityRecommendation`, `Software`, `Vulnerability`)

### Intune-Admin — Endpoint Management Administration

**Resources:** Microsoft Graph

Full read-write access to Intune management domains, plus read-only context from security, identity, and governance APIs. Built for endpoint administrators who need to create and modify Intune policies, not just audit them.

**What it covers (read-write):**

- **Intune management** — Full CRUD across all seven Intune domains: apps, device configuration, managed devices, RBAC, scripting, service config, and Cloud CA (`DeviceManagement*.ReadWrite.All`)
- **Cloud PC** — Windows 365 provisioning and management (`CloudPC.ReadWrite.All`)
- **Groups** — Create and manage security groups for policy targeting (`Group.ReadWrite.All`)

**What it covers (read-only context):**

- **Device credentials** — BitLocker recovery keys and local admin passwords (`BitlockerKey.ReadBasic.All`, `DeviceLocalCredential.ReadBasic.All`)
- **Device and directory** — Hardware inventory, directory objects, organisation info (`Device.Read.All`, `Directory.Read.All`, `Organization.Read.All`)
- **Security and identity** — Alerts, incidents, hunting, audit logs, users, policies, risk data, governance — same read-only scopes as E8-Audit minus MDE, ThreatIntelligence, InformationProtectionPolicy, and the PIM role schedule/policy scopes

### Intune-Audit — Endpoint Management Audit

**Resources:** Microsoft Graph

Read-only mirror of Intune-Admin. Every ReadWrite scope is downgraded to its Read equivalent. Use this when you need visibility into Intune configuration without the ability to modify it.

**What it covers:**

- Same capability domains as Intune-Admin, but all seven Intune management scopes are `.Read.All` instead of `.ReadWrite.All`
- CloudPC is `.Read.All`, Group is `.Read.All`
- Adds `InformationProtectionPolicy.Read` (not present in Intune-Admin)
- All other context scopes remain identical (already read-only in Intune-Admin)

### SecOps-Audit — Security Operations

**Resources:** Microsoft Graph

The most focused config — three scopes only. Purpose-built for security operations teams that need alert triage, incident investigation, and advanced hunting without broader directory or device access.

**What it covers:**

- **Security alerts** — Read M365 Defender alerts (`SecurityAlert.Read.All`)
- **Security incidents** — Read correlated incident data (`SecurityIncident.Read.All`)
- **Advanced hunting** — Run KQL queries across the unified security schema (`ThreatHunting.Read.All`)

### IAM-Audit — Identity and Access Management

**Resources:** Microsoft Graph

Combined identity governance and identity protection. This is the exact union of Governance-Audit and Protection-Audit — use it when both capability areas are needed under a single app registration.

**What it covers:**

- **Access reviews** — Read access review definitions, instances, and decisions (`AccessReview.Read.All`)
- **Admin consent** — Read pending consent requests and approval workflows (`ConsentRequest.Read.All`)
- **Entitlement management** — Read access packages, assignments, and catalogs (`EntitlementManagement.Read.All`)
- **PIM for groups** — Read privileged group eligibility and assignments (`PrivilegedAccess.Read.AzureADGroup`)
- **Risk events** — Read sign-in and user risk detections from Identity Protection (`IdentityRiskEvent.Read.All`)
- **Risky users** — Read users flagged as risky and their risk history (`IdentityRiskyUser.Read.All`)

### Governance-Audit — Identity Governance

**Resources:** Microsoft Graph

Subset of IAM-Audit covering governance controls only. Use when identity protection scopes are not needed.

**What it covers:**

- Access reviews (`AccessReview.Read.All`)
- Admin consent requests (`ConsentRequest.Read.All`)
- Entitlement management (`EntitlementManagement.Read.All`)
- PIM for groups (`PrivilegedAccess.Read.AzureADGroup`)

### Protection-Audit — Identity Protection

**Resources:** Microsoft Graph

Subset of IAM-Audit covering identity protection only. Use when governance scopes are not needed.

**What it covers:**

- Risk event detections (`IdentityRiskEvent.Read.All`)
- Risky user state and history (`IdentityRiskyUser.Read.All`)

### Compliance-Audit — Information Protection

**Resources:** Microsoft Graph

The smallest config — a single scope. Provides read access to Microsoft Purview sensitivity labels and label policies.

**What it covers:**

- Sensitivity labels and label policies (`InformationProtectionPolicy.Read` for delegated, `InformationProtectionPolicy.Read.All` for application)

## Profile Relationships

```
E8-Audit (broadest — all read-only domains + MDE)
 ├── Intune scopes ──► Intune-Audit (read-only) / Intune-Admin (read-write)
 ├── SecOps scopes ──► SecOps-Audit
 ├── IAM scopes ────► IAM-Audit
 │    ├── Governance ► Governance-Audit
 │    └── Protection ► Protection-Audit
 └── Compliance ────► Compliance-Audit
```

E8-Audit is a superset of every other audit profile's scopes (plus MDE). The smaller profiles exist for least-privilege — register only the access your workload actually needs.

## Choosing a Config

| You need to... | Use |
| --- | --- |
| Assess Essential Eight compliance across the full stack | E8-Audit |
| Manage Intune policies, apps, and device configuration | Intune-Admin |
| Audit Intune configuration without write access | Intune-Audit |
| Triage security alerts and run hunting queries | SecOps-Audit |
| Audit PIM, access reviews, entitlements, and risk data | IAM-Audit |
| Audit governance controls only (PIM, reviews, consent) | Governance-Audit |
| Audit identity protection only (risk events, risky users) | Protection-Audit |
| Read sensitivity labels and label policies | Compliance-Audit |
