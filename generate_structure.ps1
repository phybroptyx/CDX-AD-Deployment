param(
    [string]$ExercisesRoot = ".\EXERCISES",
    [Parameter(Mandatory)]
    [string]$ExerciseName
)

# Resolve output path
$exercisePath = Join-Path -Path $ExercisesRoot -ChildPath $ExerciseName
if (-not (Test-Path $exercisePath)) {
    New-Item -ItemType Directory -Path $exercisePath -Force | Out-Null
}

$structureJsonPath = Join-Path -Path $exercisePath -ChildPath "structure.json"

Write-Host "[Generator] Writing structure.json to: $structureJsonPath" -ForegroundColor Cyan

# ---------------------------
# 1. AD Sites & Subnets
# ---------------------------

$sites = @(
    @{
        name        = "StarkTower-NYC"
        description = "Stark Industries Global Headquarters, New York City, USA"
    },
    @{
        name        = "Malibu-Mansion"
        description = "Tony Stark's primary residence and private lab, Malibu, CA, USA"
    },
    @{
        name        = "Dallas-Branch"
        description = "Stark Industries U.S. Manufacturing and Operations Center, Dallas, TX, USA"
    },
    @{
        name        = "Nagasaki-Facility"
        description = "Stark Industries Overseas R&D and Weapons Facility, Nagasaki, Japan"
    },
    @{
        name        = "Amsterdam-Hub"
        description = "Stark Industries European Administration and Logistics Hub, Amsterdam, Netherlands"
    }
)

$subnets = @(
    @{
        cidr     = "66.218.180.0/22"
        site     = "StarkTower-NYC"
        location = "New York, USA"
    },
    @{
        cidr     = "4.150.216.0/22"
        site     = "Malibu-Mansion"
        location = "Malibu, CA, USA"
    },
    @{
        cidr     = "50.222.72.0/22"
        site     = "Dallas-Branch"
        location = "Dallas, TX, USA"
    },
    @{
        cidr     = "14.206.0.0/22"
        site     = "Nagasaki-Facility"
        location = "Nagasaki, Japan"
    },
    @{
        cidr     = "37.74.124.0/22"
        site     = "Amsterdam-Hub"
        location = "Amsterdam, Netherlands"
    }
)

$sitelinks = @(
    @{
        name                    = "US-Backbone-Link"
        sites                   = @("StarkTower-NYC", "Dallas-Branch", "Malibu-Mansion")
        cost                    = 50
        replicationIntervalMins = 15
    },
    @{
        name                    = "Transatlantic-Link"
        sites                   = @("StarkTower-NYC", "Amsterdam-Hub")
        cost                    = 90
        replicationIntervalMins = 60
    },
    @{
        name                    = "PAC-Link"
        sites                   = @("StarkTower-NYC", "Nagasaki-Facility")
        cost                    = 110
        replicationIntervalMins = 120
    },
    @{
        name                    = "EU-APAC-Link"
        sites                   = @("Amsterdam-Hub", "Nagasaki-Facility")
        cost                    = 120
        replicationIntervalMins = 120
    }
)

# ---------------------------
# 2. OU Tree (Sites / Depts / Sub-OUs)
# ---------------------------

$ous = @()

# Root "Sites" OU
$ous += [pscustomobject]@{
    name        = "Sites"
    parent_dn   = ""
    description = "Top-level container for all site-specific OUs"
}

# Site → Departments mapping
# IT-Core only at HQ, Nagasaki, Amsterdam
# HQ has extra departments: HR, Legal, Gov-Liaison
$siteDefinitions = @{
    "HQ"        = @("Operations", "IT-Core", "Ops-Support", "HR", "Legal", "Gov-Liaison", "Engineering", "Engineering Development", "QA", "CAD")
    "Dallas"    = @("Operations", "IT-Core", "Ops-Support", "Engineering", "Engineering Development", "QA", "CAD")
    "Malibu"    = @("Operations", "Development")
    "Nagasaki"  = @("Operations", "IT-Core", "Ops-Support", "Engineering", "Engineering Development", "QA")
    "Amsterdam" = @("Operations", "IT-Core", "Ops-Support", "Engineering", "Engineering Development", "QA")
}

# Sub-OUs under each department (unique per department)
$departmentSubOUs = @(
    "Workstations",
    "Servers",
    "Users",
    "Groups",
    "ServiceAccounts",
    "Resources"
)

foreach ($siteName in $siteDefinitions.Keys) {

    # Site OU under OU=Sites
    $ous += [pscustomobject]@{
        name        = $siteName
        parent_dn   = "OU=Sites"
        description = "$siteName logical OU"
    }

    foreach ($dept in $siteDefinitions[$siteName]) {

        $deptParentDn = "OU=$siteName,OU=Sites"

        # Department OU
        $ous += [pscustomobject]@{
            name        = $dept
            parent_dn   = $deptParentDn
            description = "$dept department at $siteName"
        }

        # Sub-OUs per department
        foreach ($subOu in $departmentSubOUs) {
            $ous += [pscustomobject]@{
                name        = $subOu
                parent_dn   = "OU=$dept,$deptParentDn"
                description = "$subOu for $dept at $siteName"
            }
        }
    }
}

# ---------------------------
# 3. Combine into structure object and write JSON
# ---------------------------

$structure = [ordered]@{
    sites     = $sites
    subnets   = $subnets
    sitelinks = $sitelinks
    ous       = $ous
}

$structure |
    ConvertTo-Json -Depth 6 |
    Set-Content -Encoding UTF8 $structureJsonPath

Write-Host "[Generator] structure.json generated." -ForegroundColor Green
