# AD Deployment Engine (`ad_deploy.ps1`)

## 1. Overview

`ad_deploy.ps1` is a **generic Active Directory deployment engine** designed to build and rebuild lab/exercise environments from structured JSON configuration files.

It is **scenario-agnostic**: all exercise-specific data (sites, OUs, users, groups, etc.) is stored under `EXERCISES/<ExerciseName>/`. The same script can be reused to deploy multiple AD scenarios by simply pointing it at a different exercise folder.

**Use cases include:**

- Building a full AD environment for a cyber defense exercise.
- Rebuilding a known-good base for repeatable training deployments.
- Iterating quickly on AD design, vulnerabilities, and multi-site scenarios.

---

## 2. Folder Layout

Recommended structure:

```plaintext
ad_deploy.ps1            # Generic deployment engine

EXERCISES/
├── CHILLED_ROCKET/      # Scenario folder
│   ├── structure.json   # AD Sites, Subnets, Site Links, OU layout
│   ├── services.json    # DNS and other services configuration
│   ├── users.json       # Users + groups + memberships
│   ├── computers.json   # Pre-staged computer objects
│   ├── gpo.json         # GPOs and link targets
│   └── README.md        # (Optional) Scenario notes for this lab
└── <OTHER_SCENARIO>/
    └── ...
```

The `ad_deploy.ps1` script lives **one level above** `EXERCISES/`.  
A different domain scenario is selected simply by changing the `-ExerciseName` argument.

---

## 3. Prerequisites

Before using this script, ensure:

1. You're running on a **domain-joined Windows system**
2. You are logged in as, or running PowerShell as, a **Domain Admin**
3. The following RSAT modules exist on this system:
   - `ActiveDirectory` (required)
   - `DnsServer` (for use with `services.json`)
   - `GroupPolicy` (if using `gpo.json`)

---

## 4. Script Responsibilities

`ad_deploy.ps1` reads JSON configuration files from the selected `EXERCISES/<ExerciseName>/` folder and deploys Active Directory elements **in this order**:

1. AD Sites, Subnets, Site Links
2. OU Structure
3. Groups
4. Services (DNS Zones, Forwarders)
5. GPOs and GPO Linking
6. Computer Objects
7. User Accounts & Group Memberships

> ⚠️ The deployment actions are **idempotent**, where possible.

---

## 5. Script Parameters

```powershell
[CmdletBinding()]
param(
    [string]$ExercisesRoot = ".\EXERCISES",
    [string]$ExerciseName,
    [string]$ConfigPath,
    [string]$DomainFQDN,
    [string]$DomainDN,
    [switch]$WhatIf
)
```

### `-ExercisesRoot`  
The root folder that holds all exercises. Defaults to `.\EXERCISES`.

### `-ExerciseName`  
The name of the scenario folder (e.g., `CHILLED_ROCKET`). Used to build `$ConfigPath` automatically if not provided.

### `-ConfigPath`  
Directly specify the path where config files live. If provided, `-ExerciseName` is ignored.

### `-DomainFQDN` / `-DomainDN`  
Override domain values. Both are auto-detected by default based on current domain membership.

### `-WhatIf`  
Runs deployment in **simulation mode**. No changes are made.

---

## 6. JSON Configuration Files

Each scenario folder must include:

- `structure.json`: Sites/Subnets, Site Links, OU layout
- `services.json`: DNS configuration
- `users.json`: Group and User definitions
- `computers.json`: Pre-defined computer objects
- `gpo.json`: GPO definitions and links

### Example: `structure.json`

```json
{
  "sites": [
    { "name": "StarkTower-NYC", "description": "Global HQ, NYC" }
  ],
  "subnets": [
    { "cidr": "66.218.180.0/22", "site": "StarkTower-NYC", "location": "New York, USA" }
  ],
  "sitelinks": [
    { "name": "Default-InterSite-Transport", "sites": ["StarkTower-NYC"], "cost": 100 }
  ],
  "ous": [
    {
      "name": "Sites",
      "parent_dn": "DC=stark,DC=local",
      "description": "Root OU for sites"
    }
  ]
}
```

> Note: OUs use partial DN syntax — the script appends the `DomainDN` automatically.

---

## 7. Running the Script

### Dry Run (Recommended)

```powershell
./ad_deploy.ps1 -ExerciseName "CHILLED_ROCKET" -WhatIf
```

### Apply Configuration

```powershell
./ad_deploy.ps1 -ExerciseName "CHILLED_ROCKET"
```

You may override the domain if working in a shared lab:

```powershell
./ad_deploy.ps1 -ExerciseName "CHILLED_ROCKET" -DomainFQDN "stark.local" -DomainDN "DC=stark,DC=local"
```

Or point directly to a config path:

```powershell
./ad_deploy.ps1 -ConfigPath "D:\LabConfigs\CHILLED_ROCKET"
```

---

## 8. Idempotency and Re-Runs

The script:

- Checks if objects exist before creating them
- Ensures user group memberships match the JSON
- Does **not** remove objects that aren't in JSON (non-destructive)

This allows:

- Re-running after edits to JSON
- Validating changes via `-WhatIf`
- Iterative or partial deployment

---

## 9. Troubleshooting

- If the AD module is missing → install via RSAT
- If domain auto-detection fails → supply `-DomainFQDN` and `-DomainDN` explicitly
- If DNS or GPO modules are missing → those sections are skipped with a warning
- Use verbose mode for more insight:

  ```powershell
  ./ad_deploy.ps1 -ExerciseName "CHILLED_ROCKET" -Verbose
  ```

Check the PowerShell error output for stack traces or which object caused a failure.

---

## 10. Extending This Framework

You can extend this deployment engine by:

- Adding additional JSON files / sections for:
  - Cross-forest trusts
  - Service accounts and constrained delegation
  - Custom ACLs or delegation models
- Writing a generator script to synthesize large user populations into `users.json`
- Adding validation or “post-checks” after deployment that:
  - Confirm all expected OUs, groups, users, and GPO links exist
  - Produce a summary report for the exercise controller

---

This modular approach enables **rapid iteration** and **repeatable AD builds** for multiple cyber range scenarios.  
Use it as the backbone to spin up Stark Industries today… and tear it down tomorrow. 🛡️🧨

