<#
.SYNOPSIS
    Master Active Directory deployment script for lab "exercises".

.DESCRIPTION
    Reads configuration from JSON files under:
        EXERCISES\<ExerciseName>\

    And builds, in order:
      1. AD Sites, Subnets, Site Links
      2. AD OU structure
      3. AD Groups
      4. AD Services (DNS, etc.)
      5. AD GPOs and Links
      6. AD Computer objects
      7. AD User accounts and group memberships

.NOTES
    - Run as a Domain Admin with RSAT tools installed.
    - Designed to be reusable across multiple exercises.
#>

[CmdletBinding()]
param(
    # Root folder where exercise configs live
    [string]$ExercisesRoot = ".\EXERCISES",

    # Name of the specific exercise (e.g., CHILLED_ROCKET)
    [string]$ExerciseName,

    # Optional: override full config path directly
    [string]$ConfigPath,

    # Optional: override domain info; otherwise auto-detected/prompted
    [string]$DomainFQDN,
    [string]$DomainDN,

    # Pass through to AD/DNS/GPO cmdlets
    [switch]$WhatIf
)

# -----------------------------------------------------------------------------
# Resolve config path based on exercise layout
# -----------------------------------------------------------------------------

if (-not $ConfigPath) {
    if (-not $ExerciseName) {
        $ExerciseName = Read-Host "Enter exercise name (e.g., CHILLED_ROCKET)"
    }
    $ConfigPath = Join-Path -Path $ExercisesRoot -ChildPath $ExerciseName
}

if (-not (Test-Path $ConfigPath)) {
    throw "Config path not found: $ConfigPath"
}

Write-Host "=== Active Directory Deployment ===" -ForegroundColor Cyan
Write-Host "Exercises Root : $ExercisesRoot"
Write-Host "Exercise Name  : $ExerciseName"
Write-Host "Config Path    : $ConfigPath`n"

# -----------------------------------------------------------------------------
# Module imports
# -----------------------------------------------------------------------------

Import-Module ActiveDirectory -ErrorAction Stop

# -----------------------------------------------------------------------------
# Helper: Load JSON config from the exercise folder
# -----------------------------------------------------------------------------
function Get-JsonConfig {
    param(
        [Parameter(Mandatory)]
        [string]$FileName
    )

    $fullPath = Join-Path -Path $ConfigPath -ChildPath $FileName
    if (-not (Test-Path $fullPath)) {
        throw "Config file not found: $fullPath"
    }

    Get-Content $fullPath -Raw | ConvertFrom-Json
}

# -----------------------------------------------------------------------------
# Domain discovery / prompting
# -----------------------------------------------------------------------------
if (-not $DomainFQDN -or -not $DomainDN) {
    try {
        $adDomain  = Get-ADDomain -ErrorAction Stop
        if (-not $DomainFQDN) { $DomainFQDN = $adDomain.DNSRoot }
        if (-not $DomainDN)   { $DomainDN   = $adDomain.DistinguishedName }

        Write-Host "Auto-detected domain: FQDN=$DomainFQDN, DN=$DomainDN" -ForegroundColor Yellow
    }
    catch {
        Write-Warning "Unable to auto-detect AD domain; prompting for values."
        if (-not $DomainFQDN) {
            $DomainFQDN = Read-Host "Enter target domain FQDN (e.g., example.lab)"
        }
        if (-not $DomainDN) {
            $DomainDN = Read-Host "Enter target domain DN (e.g., DC=example,DC=lab)"
        }
    }
}

Write-Host "Using domain: FQDN=$DomainFQDN; DN=$DomainDN`n" -ForegroundColor Cyan

# =============================================================================
# 1 & 2. AD Sites, Subnets, Site Links, and OUs
# =============================================================================
function Invoke-DeploySitesAndOUs {
    param(
        [Parameter(Mandatory)]
        $StructureConfig
    )

    Write-Host "`n[1] Deploying AD Sites, Subnets, and Site Links..." -ForegroundColor Cyan

    # --- Sites ---
    foreach ($site in $StructureConfig.sites) {
        $name = $site.name
        $desc = $site.description

        $existing = Get-ADReplicationSite -Filter "Name -eq '$name'" -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "Site exists: $name" -ForegroundColor DarkGray
        }
        else {
            Write-Host "Creating site: $name" -ForegroundColor Green
            New-ADReplicationSite -Name $name -Description $desc -WhatIf:$WhatIf
        }
    }

    # --- Subnets ---
    foreach ($subnet in $StructureConfig.subnets) {
        $cidr     = $subnet.cidr
        $siteName = $subnet.site
        $location = $subnet.location

        $existing = Get-ADReplicationSubnet -Filter "Name -eq '$cidr'" -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "Subnet exists: $cidr" -ForegroundColor DarkGray
        }
        else {
            Write-Host "Creating subnet: $cidr -> site $siteName" -ForegroundColor Green
            New-ADReplicationSubnet -Name $cidr -Site $siteName -Location $location -WhatIf:$WhatIf
        }
    }

    # --- Site Links ---
    foreach ($link in $StructureConfig.sitelinks) {
        $name = $link.name
        $sitesIncluded = $link.sites
        $cost = $link.cost

        $existing = Get-ADReplicationSiteLink -Filter "Name -eq '$name'" -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "Site link exists: $name" -ForegroundColor DarkGray
        }
        else {
            Write-Host "Creating site link: $name [sites: $($sitesIncluded -join ', ')]" -ForegroundColor Green
            New-ADReplicationSiteLink -Name $name -SitesIncluded $sitesIncluded -Cost $cost -WhatIf:$WhatIf
        }
    }

    # --- OUs ---
    Write-Host "`n[2] Creating Organizational Units..." -ForegroundColor Cyan

    # Ensure parents are created before children (sort by depth of parent_dn)
    $sortedOUs = $StructureConfig.ous | Sort-Object {
        ([regex]::Matches($_.parent_dn, 'OU=').Count)
    }

    foreach ($ou in $sortedOUs) {
        $name     = $ou.name
        $parentDn = $ou.parent_dn
        $desc     = $ou.description
        $dn       = "OU=$name,$parentDn"

        $existing = Get-ADOrganizationalUnit -LDAPFilter "(distinguishedName=$dn)" -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "OU exists: $dn" -ForegroundColor DarkGray
        }
        else {
            Write-Host "Creating OU: $dn" -ForegroundColor Green
            New-ADOrganizationalUnit -Name $name `
                                     -Path $parentDn `
                                     -Description $desc `
                                     -ProtectedFromAccidentalDeletion $true `
                                     -WhatIf:$WhatIf | Out-Null
        }
    }
}

# =============================================================================
# 3. AD Group creation
# =============================================================================
function Invoke-DeployGroups {
    param(
        [Parameter(Mandatory)]
        $UsersConfig,
        [Parameter(Mandatory)]
        [string]$DomainDN
    )

    Write-Host "`n[3] Creating Groups..." -ForegroundColor Cyan

    foreach ($group in $UsersConfig.groups) {
        $sam   = $group.sAMAccountName
        $name  = $group.name
        $scope = $group.scope
        $cat   = $group.category
        $desc  = $group.description
        $ou    = $group.ou   # partial OU (no DC=...)

        $path  = "$ou,$DomainDN"

        $existing = Get-ADGroup -Filter "sAMAccountName -eq '$sam'" -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "Group exists: $sam" -ForegroundColor DarkGray
        }
        else {
            Write-Host "Creating group: $sam in $path" -ForegroundColor Green
            New-ADGroup -Name $name `
                        -SamAccountName $sam `
                        -GroupCategory $cat `
                        -GroupScope $scope `
                        -Path $path `
                        -Description $desc `
                        -WhatIf:$WhatIf | Out-Null
        }
    }
}

# =============================================================================
# 4. AD Services (DNS, etc.)
# =============================================================================
function Invoke-DeployServices {
    param(
        [Parameter(Mandatory)]
        $ServicesConfig
    )

    Write-Host "`n[4] Configuring Services (DNS)..." -ForegroundColor Cyan

    if (-not (Import-Module DnsServer -ErrorAction SilentlyContinue)) {
        Write-Warning "DnsServer module not available; skipping DNS configuration."
        return
    }

    # DNS Zones
    if ($ServicesConfig.dns -and $ServicesConfig.dns.zones) {
        foreach ($zone in $ServicesConfig.dns.zones) {
            $name  = $zone.name
            $scope = $zone.replicationScope

            $existingZone = Get-DnsServerZone -Name $name -ErrorAction SilentlyContinue
            if ($existingZone) {
                Write-Host "DNS zone exists: $name" -ForegroundColor DarkGray
            }
            else {
                Write-Host "Creating DNS zone: $name" -ForegroundColor Green
                Add-DnsServerPrimaryZone -Name $name -ReplicationScope $scope -WhatIf:$WhatIf | Out-Null
            }
        }
    }

    # DNS Forwarders
    if ($ServicesConfig.dns -and $ServicesConfig.dns.forwarders) {
        $currentForwarders = @()
        try {
            $currentForwarders = (Get-DnsServerForwarder -ErrorAction SilentlyContinue).IPAddress
        } catch {}

        foreach ($fwd in $ServicesConfig.dns.forwarders) {
            if ($currentForwarders -and $currentForwarders -contains $fwd) {
                Write-Host "DNS forwarder exists: $fwd" -ForegroundColor DarkGray
            }
            else {
                Write-Host "Adding DNS forwarder: $fwd" -ForegroundColor Green
                Add-DnsServerForwarder -IPAddress $fwd -ErrorAction SilentlyContinue -WhatIf:$WhatIf | Out-Null
            }
        }
    }

    # Placeholder for NTP/DHCP/etc. if you choose to model them here later.
}

# =============================================================================
# 5. AD GPO creation and linking
# =============================================================================
function Invoke-DeployGPOs {
    param(
        [Parameter(Mandatory)]
        $GpoConfig,
        [Parameter(Mandatory)]
        [string]$DomainDN
    )

    Write-Host "`n[5] Creating GPOs and Linking..." -ForegroundColor Cyan

    if (-not (Import-Module GroupPolicy -ErrorAction SilentlyContinue)) {
        Write-Warning "GroupPolicy module not available; skipping GPO configuration."
        return
    }

    # Create GPOs if not present
    foreach ($gpo in $GpoConfig.gpos) {
        $name        = $gpo.name
        $description = $gpo.description

        $existing = Get-GPO -Name $name -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "GPO exists: $name" -ForegroundColor DarkGray
        }
        else {
            Write-Host "Creating GPO: $name" -ForegroundColor Green
            New-GPO -Name $name -Comment $description -WhatIf:$WhatIf | Out-Null
        }
    }

    # Link GPOs to OUs
    foreach ($link in $GpoConfig.links) {
        $gpoName  = $link.gpoName
        $targetOu = $link.targetOu   # partial DN (OU=...,OU=...)
        $enforced = [bool]$link.enforced
        $enabled  = [bool]$link.enabled

        $targetDn = "$targetOu,$DomainDN"

        Write-Host "Ensuring GPO link: $gpoName -> $targetDn" -ForegroundColor DarkCyan
        # For simplicity, always attempt to create/refresh the link
        New-GPLink -Name $gpoName -Target $targetDn -Enforced:$enforced -LinkEnabled:$enabled -WhatIf:$WhatIf | Out-Null
    }
}

# =============================================================================
# 6. AD Computer object creation
# =============================================================================
function Invoke-DeployComputers {
    param(
        [Parameter(Mandatory)]
        $ComputersConfig,
        [Parameter(Mandatory)]
        [string]$DomainDN
    )

    Write-Host "`n[6] Creating Computer Accounts..." -ForegroundColor Cyan

    foreach ($comp in $ComputersConfig.computers) {
        $name = $comp.name
        $ou   = $comp.ou       # partial OU
        $desc = $comp.description

        $path = "$ou,$DomainDN"

        $existing = Get-ADComputer -Filter "Name -eq '$name'" -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "Computer exists: $name" -ForegroundColor DarkGray
        }
        else {
            Write-Host "Creating computer: $name in $path" -ForegroundColor Green
            New-ADComputer -Name $name `
                           -Path $path `
                           -Description $desc `
                           -WhatIf:$WhatIf | Out-Null
        }
    }
}

# =============================================================================
# 7. AD User creation and group membership
# =============================================================================
function Invoke-DeployUsers {
    param(
        [Parameter(Mandatory)]
        $UsersConfig,
        [Parameter(Mandatory)]
        [string]$DomainFQDN,
        [Parameter(Mandatory)]
        [string]$DomainDN
    )

    Write-Host "`n[7] Creating User Accounts..." -ForegroundColor Cyan

    foreach ($user in $UsersConfig.users) {
        $sam       = $user.sAMAccountName
        $numericId = $user.numericId
        $given     = $user.givenName
        $sn        = $user.sn
        $middle    = $user.initials
        $display   = $user.displayName
        $title     = $user.title

        $street    = $user.streetAddress
        $city      = $user.city
        $state     = $user.state
        $postal    = $user.postalCode
        $country   = $user.country
        $phone     = $user.telephoneNumber

        $ouPartial = $user.ou      # partial OU path
        $path      = "$ouPartial,$DomainDN"

        $password  = $user.password
        $enabled   = [bool]$user.enabled

        # Build UPN from numericId + domain
        $upn       = "$numericId@$DomainFQDN"

        $existing = Get-ADUser -Filter "sAMAccountName -eq '$sam'" -ErrorAction SilentlyContinue

        if ($existing) {
            Write-Host "User exists: $sam" -ForegroundColor DarkGray
            # Optional: add drift-correction here if you want strict state enforcement
        }
        else {
            Write-Host "Creating user: $sam in $path" -ForegroundColor Green

            $securePassword = (ConvertTo-SecureString $password -AsPlainText -Force)

            New-ADUser -Name $display `
                       -SamAccountName $sam `
                       -UserPrincipalName $upn `
                       -GivenName $given `
                       -Surname $sn `
                       -Initials $middle `
                       -DisplayName $display `
                       -Title $title `
                       -StreetAddress $street `
                       -City $city `
                       -State $state `
                       -PostalCode $postal `
                       -Country $country `
                       -OfficePhone $phone `
                       -Path $path `
                       -AccountPassword $securePassword `
                       -Enabled $enabled `
                       -WhatIf:$WhatIf | Out-Null
        }
    }

    Write-Host "`n[7b] Ensuring group memberships..." -ForegroundColor Cyan

    foreach ($user in $UsersConfig.users) {
        $sam       = $user.sAMAccountName
        $groupList = @($user.groups)

        if (-not $groupList -or $groupList.Count -eq 0) { continue }

        $userObj = Get-ADUser -Filter "sAMAccountName -eq '$sam'" -ErrorAction SilentlyContinue
        if (-not $userObj) {
            Write-Warning "User not found for membership processing: $sam"
            continue
        }

        foreach ($groupSam in $groupList) {
            $groupObj = Get-ADGroup -Filter "sAMAccountName -eq '$groupSam'" -ErrorAction SilentlyContinue
            if (-not $groupObj) {
                Write-Warning "Group not found for membership: $sam -> $groupSam"
                continue
            }

            $isMember = Get-ADGroupMember -Identity $groupObj.DistinguishedName -Recursive |
                        Where-Object { $_.DistinguishedName -eq $userObj.DistinguishedName }

            if ($isMember) {
                Write-Host "Membership already present: $sam -> $groupSam" -ForegroundColor DarkGray
            }
            else {
                Write-Host "Adding membership: $sam -> $groupSam" -ForegroundColor Green
                Add-ADGroupMember -Identity $groupObj.DistinguishedName `
                                  -Members $userObj.DistinguishedName `
                                  -ErrorAction SilentlyContinue `
                                  -WhatIf:$WhatIf
            }
        }
    }
}

# =============================================================================
# Main execution
# =============================================================================
try {
    $structureConfig = Get-JsonConfig -FileName "structure.json"
    $servicesConfig  = Get-JsonConfig -FileName "services.json"
    $usersConfig     = Get-JsonConfig -FileName "users.json"
    $computersConfig = Get-JsonConfig -FileName "computers.json"
    $gpoConfig       = Get-JsonConfig -FileName "gpo.json"

    Invoke-DeploySitesAndOUs  -StructureConfig $structureConfig
    Invoke-DeployGroups       -UsersConfig $usersConfig   -DomainDN $DomainDN
    Invoke-DeployServices     -ServicesConfig $servicesConfig
    Invoke-DeployGPOs         -GpoConfig $gpoConfig       -DomainDN $DomainDN
    Invoke-DeployComputers    -ComputersConfig $computersConfig -DomainDN $DomainDN
    Invoke-DeployUsers        -UsersConfig $usersConfig   -DomainFQDN $DomainFQDN -DomainDN $DomainDN

    Write-Host "`nDeployment complete for exercise '$ExerciseName'." -ForegroundColor Green
}
catch {
    Write-Error $_
    exit 1
}
