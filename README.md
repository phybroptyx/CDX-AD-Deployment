# AD Deployment Engine (`ad_deploy.ps1`)

## 1. Overview

`ad_deploy.ps1` is a **generic Active Directory deployment engine** designed to build and rebuild lab environments from structured JSON configuration files. It works with a matching structure generator (`generate_structure.ps1`) to produce all required Active Directory design files for scalable, reusable cyber defense exercises.

This framework is **scenario-agnostic**, meaning the same `ad_deploy.ps1` file can deploy multiple Active Directory environments based on the selected scenario folder.

---

## 2. Folder Layout

Recommended structure:

```
ad_deploy.ps1              # Main AD deployment script
generate_structure.ps1     # Optional topology generator

EXERCISES/
├── CHILLED_ROCKET/        # Example scenario folder
│   ├── structure.json     # AD Sites, Subnets, Site Links, OU structure
│   ├── services.json      # DNS Zones and other service configuration
│   ├── users.json         # User accounts, group memberships
│   ├── computers.json     # Computer objects (pre-staged)
│   ├── gpo.json           # Group Policy Objects and linked targets
│   └── README.md          # (Optional) Scenario notes
└── <OTHER_SCENARIO>/
    └── ...
```

---

## 3. Prerequisites

Before using this script, ensure:

1. You are logged in as (or running PowerShell as) a **Domain Admin**
2. The target system is joined to the **target domain** or will host a new one
3. Required PowerShell modules are installed:
   - `ActiveDirectory` (mandatory)
   - `DnsServer` (for DNS deployment)
   - `GroupPolicy` (for GPO deployment)

If deploying a **new forest**, the script will prompt for:

- Domain FQDN (e.g., `stark.lab`)
- Safe Mode / DSRM password

---

## 4. Script Responsibilities

`ad_deploy.ps1` deploys Active Active Directory configurations based on the contents of the selected `EXERCISES/<ExerciseName>` folder.

### Deployment Order

1. Deploy or detect AD Forest
2. Sites, Subnets, Site Links (including cleanup of `DEFAULTIPSITELINK`)
3. Organizational Units (OUs)
4. Groups and Group Memberships
5. DNS and service configuration
6. Group Policies (linking included)
7. Computer Objects
8. User Accounts

> 🟢 All operations are idempotent: existing objects are skipped or updated, not recreated.

---

## 5. Script Parameters

```
[CmdletBinding()]
param(
    [string]$ExercisesRoot = ".\EXERCISES",
    [string]$ExerciseName,
    [string]$ConfigPath,
    [string]$DomainFQDN,
    [string]$DomainDN,
    [switch]$GenerateStructure,
    [switch]$WhatIf
)
```

### -GenerateStructure  
Generates (or overwrites) `structure.json` under `EXERCISES/<ExerciseName>` by calling `generate_structure.ps1`.

Useful for regenerating site and OU topology when building or modifying an exercise.

### -WhatIf  
Runs in simulation mode. No changes are made.

---

## 6. JSON Configuration Files

The following files must be present under the selected exercise folder:

| File                | Purpose                                   |
|---------------------|-------------------------------------------|
| `structure.json`    | Sites/Subnets, SiteLinks, OU hierarchy    |
| `services.json`     | DNS zones, forwarders, NTP servers        |
| `users.json`        | Users, attributes, and group membership   |
| `computers.json`    | Pre-staged computer objects               |
| `gpo.json`          | GPOs and OU link targets                  |

> ⚠️ JSON must be free of comments (`//`) and trailing commas.  
> OUs must be specified in **relative DN format** (e.g., `"OU=Users,OU=HQ,OU=Sites"`), not full DN.

---

## 7. Running the Scripts

### First-time initialization

```
.\ad_deploy.ps1 -ExerciseName "CHILLED_ROCKET" -GenerateStructure
```

This will:

- Create the exercise folder (if it doesn’t exist)
- Generate a fresh `structure.json` using `generate_structure.ps1`
- Deploy the AD environment from JSON configuration

### Idempotent redeployment

```
.\ad_deploy.ps1 -ExerciseName "CHILLED_ROCKET"
```

The script will:

- Detect existing AD forest
- Only add or update missing objects
- Skip anything already correct

### What-If Mode

```
.\ad_deploy.ps1 -ExerciseName "CHILLED_ROCKET" -WhatIf
```

Use this to validate intended actions without making changes.

---

## 8. Notes on Dynamic Structure Generation

The optional script `generate_structure.ps1` dynamically generates `structure.json` based on an AD exercise blueprint, including:

- Sites and Subnets (e.g., StarkTower-NYC, Malibu-Mansion)
- AD Site Links with realistic latency and cost modeling
- Full Organizational Unit tree with departments and sub-OUs per site

When run with `-GenerateStructure`, `ad_deploy.ps1` will run the generator and deploy from the resulting structure.

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
