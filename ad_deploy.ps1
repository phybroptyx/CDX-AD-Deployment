<#
.SYNOPSIS
    Master Active Directory deployment script for lab "exercises".

.DESCRIPTION
    - If an AD domain already exists:
        * Autodetects domain info (or uses overrides).
        * Deploys Sites, OUs, Groups, DNS, GPOs, Computers, Users from JSON.
    - If no AD domain exists:
        * Prompts for domain details.
        * Installs AD DS role if needed.
        * Creates a new AD forest on this server.
        * Instructs you to reboot and rerun to apply the exercise config.

.NOTES
    - Run as a local admin (pre-forest) or Domain Admin (post-forest).
    - Designed for Windows Server 2012 R2 and later.
#>

[CmdletBinding()]
param(
    # Root folder where exercise configs live
    [string]$ExercisesRoot = ".\EXERCISES",

    # Name of the specific exercise (e.g., CHILLED_ROCKET)
    [string]$ExerciseName,

    # Optional: override full config path directly
    [string]$ConfigPath,

    # Optional: override domain info; otherwise auto-detected or prompted
    [string]$DomainFQDN,
    [string]$DomainDN,

    # Optional: regenerate structure.json for the exercise before deployment
    [switch]$GenerateStructure,

    # Pass through to AD/DNS/GPO cmdlets
    [switch]$WhatIf
)

Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "           Active Directory Deployment Engine        " -ForegroundColor Cyan
Write-Host "=====================================================`n" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Resolve config path based on exercise layout
# ---------------------------------------------------------------------------
if (-not $ConfigPath) {
    if (-not $ExerciseName) {
        $ExerciseName = Read-Host "Enter exercise name (e.g., CHILLED_ROCKET)"
    }
    $ConfigPath = Join-Path -Path $ExercisesRoot -ChildPath $ExerciseName
}

# Ensure exercise folder exists if we are generating structure
if ($GenerateStructure) {
    if (-not (Test-Path $ConfigPath)) {
        Write-Host "[Config] Creating exercise folder: $ConfigPath" -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $ConfigPath -Force | Out-Null
    }

    # Locate generate_structure.ps1 in the same folder as this script
    $scriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
    $generatorPath = Join-Path $scriptDir "generate_structure.ps1"

    if (-not (Test-Path $generatorPath)) {
        throw "Structure generator not found: $generatorPath"
    }

    Write-Host "[Config] Regenerating structure.json via generate_structure.ps1..." -ForegroundColor Yellow
    & $generatorPath -ExercisesRoot $ExercisesRoot -ExerciseName $ExerciseName -ErrorAction Stop
}

if (-not (Test-Path $ConfigPath)) {
    throw "Config path not found: $ConfigPath"
}

Write-Host "Exercises Root : $ExercisesRoot"
Write-Host "Exercise Name  : $ExerciseName"
Write-Host "Config Path    : $ConfigPath`n"

# Make sure structure.json exists before we try to load it
$structurePath = Join-Path $ConfigPath "structure.json"
if (-not (Test-Path $structurePath)) {
    throw "structure.json not found at expected path: $structurePath. Run with -GenerateStructure or create it manually."
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
function Test-Prerequisites {
    Write-Host "[Prereq] Checking environment..." -ForegroundColor Cyan

    # Basic OS hint
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os -and $os.ProductType -eq 1) {
            Write-Warning "This appears to be a client OS (e.g., Windows 10/11). AD DS deployment typically runs on Windows Server."
        }
    } catch {}

    # Required modules (some may be added later once roles are installed)
    $requiredModules = @("ActiveDirectory", "ADDSDeployment", "DnsServer", "GroupPolicy")

    foreach ($mod in $requiredModules) {
        $found = Get-Module -ListAvailable -Name $mod
        if (-not $found) {
            Write-Warning "Module not currently available: $mod (may be installed later if needed)."
        }
        else {
            Write-Host "[OK] Module available: $mod" -ForegroundColor DarkGreen
        }
    }

    Write-Host "[Prereq] Check complete.`n" -ForegroundColor Cyan
}

Test-Prerequisites

# Try to import AD module (may fail pre-forest; that's ok)
Import-Module ActiveDirectory -ErrorAction SilentlyContinue | Out-Null

# ---------------------------------------------------------------------------
# Helper: Load JSON config from the exercise folder
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Ensure domain exists: either detect or create a new forest
# ---------------------------------------------------------------------------
function Ensure-ActiveDirectoryDomain {
    param(
        [string]$DomainFQDNParam,
        [string]$DomainDNParam
    )

    Write-Host "[Domain] Checking for existing Active Directory domain..." -ForegroundColor Cyan

    # Try to detect an existing domain
    try {
        $adDomain = Get-ADDomain -ErrorAction Stop
        Write-Host "[Domain] Existing AD domain detected: $($adDomain.DNSRoot)" -ForegroundColor Green

        if (-not $DomainFQDNParam) { $DomainFQDNParam = $adDomain.DNSRoot }
        if (-not $DomainDNParam)   { $DomainDNParam   = $adDomain.DistinguishedName }

        Write-Host "=== MODE: POST-FOREST CONFIGURATION / EXERCISE DEPLOYMENT ===`n" -ForegroundColor Magenta

        return @{
            DomainFQDN = $DomainFQDNParam
            DomainDN   = $DomainDNParam
            CreatedNew = $false
        }
    }
    catch {
        Write-Warning "[Domain] No existing domain detected or unable to contact one."
    }

    # At this point, no domain is detected.
    Write-Host "`nNo Active Directory domain detected." -ForegroundColor Yellow
    $choice = Read-Host "Do you want to create a NEW AD forest on this server? (Y/N)"

    if ($choice -notin @("Y","y","Yes","YES")) {
        throw "Aborting: No domain found and user chose not to create a new forest."
    }

    Write-Host "`n=== MODE: FOREST CREATION ===`n" -ForegroundColor Magenta

    # Ensure ADDSDeployment module exists; install AD DS role if missing
    if (-not (Get-Module -ListAvailable -Name ADDSDeployment)) {
        Write-Warning "[Domain] ADDSDeployment module is not available. Installing Active Directory Domain Services role..."

        try {
            Install-WindowsFeature AD-Domain-Services -IncludeManagementTools -ErrorAction Stop | Out-Null
            Write-Host "[Domain] AD DS role installed successfully. A reboot may be required." -ForegroundColor Green
        }
        catch {
            throw "Failed to install Active Directory Domain Services role: $_"
        }
    }

    try {
        Import-Module ADDSDeployment -ErrorAction Stop
        Write-Host "[Domain] ADDSDeployment module successfully loaded." -ForegroundColor Green
    }
    catch {
        throw "ADDSDeployment module still not available after install. A reboot may be required."
    }

    # Prompt for domain details if not provided
    if (-not $DomainFQDNParam) {
        $DomainFQDNParam = Read-Host "Enter new domain FQDN (e.g., stark.local)"
    }

    # Derive DomainDN from FQDN if missing
    if (-not $DomainDNParam) {
        $parts = $DomainFQDNParam.Split(".")
        $DomainDNParam = ($parts | ForEach-Object { "DC=$_" }) -join ","
    }

    # NetBIOS name (optional, auto-derived)
    $defaultNetBIOS = ($DomainFQDNParam.Split(".")[0]).ToUpper()
    if ($defaultNetBIOS.Length -gt 15) {
        $defaultNetBIOS = $defaultNetBIOS.Substring(0,15)
    }
    $netbios = Read-Host "Enter NetBIOS name for the domain [`$default: $defaultNetBIOS`]"

    if ([string]::IsNullOrWhiteSpace($netbios)) {
        $netbios = $defaultNetBIOS
    }

    Write-Host "`nIMPORTANT: This forest installation will run under the CURRENT USER context." -ForegroundColor Yellow
    Write-Host "Ensure you are running this script as a local administrator on this server.`n" -ForegroundColor Yellow

    # DSRM password
    Write-Host "Enter a Directory Services Restore Mode (DSRM) password." -ForegroundColor Cyan
    $dsrmPassword = Read-Host -AsSecureString -Prompt "DSRM password"

    if ($WhatIf) {
        Write-Host "[WhatIf] Would create new AD forest with:" -ForegroundColor Yellow
        Write-Host "  DomainFQDN : $DomainFQDNParam"
        Write-Host "  DomainDN   : $DomainDNParam"
        Write-Host "  NetBIOS    : $netbios"
        Write-Host "  (Forest creation requires reboot; no further config would run until rerun.)"
        return @{
            DomainFQDN = $DomainFQDNParam
            DomainDN   = $DomainDNParam
            CreatedNew = $true
        }
    }

    Write-Host "`n[Domain] Creating new AD forest '$DomainFQDNParam' on this server..." -ForegroundColor Green

    $splat = @{
        DomainName                    = $DomainFQDNParam
        DomainNetbiosName             = $netbios
        SafeModeAdministratorPassword = $dsrmPassword
        InstallDNS                    = $true
        Force                         = $true
        NoRebootOnCompletion          = $true
    }

    Install-ADDSForest @splat

    Write-Host "`n[Domain] New forest created. You MUST reboot this server before continuing." -ForegroundColor Yellow
    Write-Host "After reboot, rerun this script to apply the exercise configuration." -ForegroundColor Yellow

    return @{
        DomainFQDN = $DomainFQDNParam
        DomainDN   = $DomainDNParam
        CreatedNew = $true
    }
}

# --- Domain handling ---
$domainInfo = Ensure-ActiveDirectoryDomain -DomainFQDNParam $DomainFQDN -DomainDNParam $DomainDN
$DomainFQDN = $domainInfo.DomainFQDN
$DomainDN   = $domainInfo.DomainDN

Write-Host "`nUsing domain: FQDN = $DomainFQDN; DN = $DomainDN`n" -ForegroundColor Cyan

# If we just created a new forest in this run (and not in -WhatIf), stop here.
if ($domainInfo.CreatedNew -and -not $WhatIf) {
    Write-Host "`n[Domain] Forest creation completed. Please reboot this server, then rerun ad_deploy.ps1 for '$ExerciseName' to continue with Sites/OUs/etc." -ForegroundColor Yellow
    return
}

# =============================================================================
# Deployment functions
# =============================================================================

function Invoke-DeploySitesAndOUs {
    param(
        [Parameter(Mandatory)]
        $StructureConfig,

        [Parameter(Mandatory)]
        [string]$DomainDN
    )

    Write-Host "`n[1] Deploying AD Sites, Subnets, and Site Links..." -ForegroundColor Cyan

    # --- Sites ---
    foreach ($site in $StructureConfig.sites) {
        $name = $site.name
        $desc = $site.description

        # Does the target site already exist?
        $existing = Get-ADReplicationSite -Filter "Name -eq '$name'" -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "Site exists: $name" -ForegroundColor DarkGray
        }
        else {
            # If the target site doesn't exist, check for the default site to rename
            $defaultSite = Get-ADReplicationSite -Filter "Name -eq 'Default-First-Site-Name'" -ErrorAction SilentlyContinue

            if ($defaultSite -and $name -eq "StarkTower-NYC") {
                Write-Host "Renaming existing 'Default-First-Site-Name' to '$name'..." -ForegroundColor Yellow

                if ($WhatIf) {
                    Write-Host "[WhatIf] Would rename 'Default-First-Site-Name' to '$name' and set description." -ForegroundColor Yellow
                }
                else {
                    Rename-ADObject -Identity $defaultSite.DistinguishedName -NewName $name

                    $renamed = Get-ADReplicationSite -Filter "Name -eq '$name'" -ErrorAction SilentlyContinue
                    if ($renamed -and $desc) {
                        Set-ADObject -Identity $renamed.DistinguishedName -Replace @{description = $desc}
                    }
                }
            }
            else {
                Write-Host "Creating site: $name" -ForegroundColor Green
                New-ADReplicationSite -Name $name -Description $desc -WhatIf:$WhatIf
            }
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
        $name          = $link.name
        $sitesIncluded = @($link.sites)
        $cost          = $link.cost
        $intervalMins  = $link.replicationIntervalMins

        $existing = Get-ADReplicationSiteLink -Filter "Name -eq '$name'" -ErrorAction SilentlyContinue

        if ($existing) {
            Write-Host "Site link exists: $name - updating cost/sites as needed..." -ForegroundColor DarkGray

            if ($WhatIf) {
                Write-Host "[WhatIf] Would set cost to $cost and ensure sites [$($sitesIncluded -join ', ')] are included on link '$name'." -ForegroundColor Yellow
            }
            else {
                # Merge existing sites with desired sites (idempotent, non-destructive)
                $currentSiteDNs   = $existing.SitesIncluded
                $currentSiteNames = $currentSiteDNs | ForEach-Object {
                    ($_ -split ",")[0] -replace "^CN=", ""
                }

                $allSiteNames = ($currentSiteNames + $sitesIncluded) | Select-Object -Unique

                $params = @{
                    Identity      = $existing.DistinguishedName
                    Cost          = $cost
                    SitesIncluded = $allSiteNames
                }

                # Only set ReplicationInterval if the cmdlet supports it
                $paramSet = (Get-Command Set-ADReplicationSiteLink).Parameters
                if ($intervalMins -and $paramSet.ContainsKey("ReplicationInterval")) {
                    $params["ReplicationInterval"] = [int]$intervalMins
                }
                elseif ($intervalMins) {
                    Write-Warning "ReplicationInterval not supported on this OS version; skipping that setting for site link '$name'."
                }

                Set-ADReplicationSiteLink @params -WhatIf:$WhatIf
            }
        }
        else {
            Write-Host "Creating site link: $name [sites: $($sitesIncluded -join ', ')]" -ForegroundColor Green

            if ($WhatIf) {
                Write-Host "[WhatIf] Would create site link '$name' with cost $cost and sites [$($sitesIncluded -join ', ')]" -ForegroundColor Yellow
            }
            else {
                $params = @{
                    Name          = $name
                    SitesIncluded = $sitesIncluded
                    Cost          = $cost
                }

                # Only set ReplicationInterval if the cmdlet supports it
                $paramSet = (Get-Command New-ADReplicationSiteLink).Parameters
                if ($intervalMins -and $paramSet.ContainsKey("ReplicationInterval")) {
                    $params["ReplicationInterval"] = [int]$intervalMins
                }
                elseif ($intervalMins) {
                    Write-Warning "ReplicationInterval not supported on this OS version; skipping that setting for new site link '$name'."
                }

                New-ADReplicationSiteLink @params -WhatIf:$WhatIf
            }
        }
    }

    # --- Remove DEFAULTIPSITELINK if we manage our own links ---
    try {
        $defaultIpSiteLink = Get-ADReplicationSiteLink -Filter "Name -eq 'DEFAULTIPSITELINK'" -ErrorAction SilentlyContinue
        if ($defaultIpSiteLink) {
            # Only remove if it's NOT explicitly defined in structure.json
            $weManageDefault = $false
            if ($StructureConfig.sitelinks) {
                $weManageDefault = $StructureConfig.sitelinks.name -contains 'DEFAULTIPSITELINK'
            }

            if (-not $weManageDefault) {
                Write-Host "Removing auto-created site link 'DEFAULTIPSITELINK'..." -ForegroundColor Yellow

                if ($WhatIf) {
                    Write-Host "[WhatIf] Would remove DEFAULTIPSITELINK." -ForegroundColor Yellow
                }
                else {
                    Remove-ADReplicationSiteLink -Identity $defaultIpSiteLink.DistinguishedName -Confirm:$false
                }
            }
            else {
                Write-Host "DEFAULTIPSITELINK is defined in structure.json; leaving it in place." -ForegroundColor DarkGray
            }
        }
    }
    catch {
        Write-Warning "Failed to evaluate or remove DEFAULTIPSITELINK: $_"
    }

    # --- OUs ---
    Write-Host "`n[2] Creating Organizational Units..." -ForegroundColor Cyan

    # Your structure.json OUs look like:
    # { "name": "Sites", "parent_dn": "", "description": "..." }
    # { "name": "HQ", "parent_dn": "OU=Sites", "description": "..." }
    # etc.

    # Sort so that parents are created before children, based on parent_dn depth
    $sortedOUs = $StructureConfig.ous | Sort-Object {
        if ([string]::IsNullOrWhiteSpace($_.parent_dn)) {
            0
        }
        else {
            ([regex]::Matches($_.parent_dn, 'OU=').Count)
        }
    }

    foreach ($ou in $sortedOUs) {
        $name     = $ou.name
        $parentDn = $ou.parent_dn
        $desc     = $ou.description

        # Build full parent path:
        #  - If parent_dn is empty/null => directly under the domain
        #  - Otherwise treat parent_dn as a relative OU chain and append DomainDN
        if ([string]::IsNullOrWhiteSpace($parentDn)) {
            $parentPath = $DomainDN
        }
        else {
            $parentPath = "$parentDn,$DomainDN"
        }

        $dn = "OU=$name,$parentPath"

        $existing = Get-ADOrganizationalUnit -LDAPFilter "(distinguishedName=$dn)" -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "OU exists: $dn" -ForegroundColor DarkGray
        }
        else {
            Write-Host "Creating OU: $dn" -ForegroundColor Green
            New-ADOrganizationalUnit -Name $name `
                                     -Path $parentPath `
                                     -Description $desc `
                                     -ProtectedFromAccidentalDeletion $false `
                                     -WhatIf:$WhatIf | Out-Null
        }
    }
}

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
        $ou    = $group.ou

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

function Invoke-DeployServices {
    param(
        [Parameter(Mandatory)]
        $ServicesConfig,
        [Parameter(Mandatory)]
        [string]$DomainFQDN
    )

    Write-Host "`n[4] Configuring Services (DNS)..." -ForegroundColor Cyan

    if (-not (Get-Module -ListAvailable -Name DnsServer)) {
        Write-Warning "DnsServer module not available; skipping DNS configuration."
        return
    }

    Import-Module DnsServer -ErrorAction SilentlyContinue | Out-Null

    # DNS Zones
    if ($ServicesConfig.dns -and $ServicesConfig.dns.zones) {
        foreach ($zone in $ServicesConfig.dns.zones) {

            # Allow domain-agnostic placeholder in JSON
            $rawName = $zone.name
            if ($rawName -eq "__AD_DOMAIN__") {
                $name = $DomainFQDN
            }
            else {
                $name = $rawName
            }

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
}

function Invoke-DeployGPOs {
    param(
        [Parameter(Mandatory)]
        $GpoConfig,
        [Parameter(Mandatory)]
        [string]$DomainDN
    )

    Write-Host "`n[5] Creating GPOs and Linking..." -ForegroundColor Cyan

    if (-not (Get-Module -ListAvailable -Name GroupPolicy)) {
        Write-Warning "GroupPolicy module not available; skipping GPO configuration."
        return
    }

    Import-Module GroupPolicy -ErrorAction SilentlyContinue | Out-Null

    # --- Create / ensure GPOs exist ---
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

    # --- Create / ensure GPO links ---
    foreach ($link in $GpoConfig.links) {
        $gpoName  = $link.gpoName
        $targetOu = $link.targetOu

        # JSON uses booleans; translate to the strings the cmdlet expects
        $enforcedBool = [bool]$link.enforced
        $enabledBool  = [bool]$link.enabled

        # New-GPLink expects "Yes"/"No" for these parameters
        $enforcedValue = if ($enforcedBool) { "Yes" } else { "No" }
        $enabledValue  = if ($enabledBool)  { "Yes" } else { "No" }

        $targetDn = "$targetOu,$DomainDN"

        Write-Host "Ensuring GPO link: $gpoName -> $targetDn (Enforced=$enforcedValue, Enabled=$enabledValue)" -ForegroundColor DarkCyan

        if ($WhatIf) {
            Write-Host "[WhatIf] Would link GPO '$gpoName' to '$targetDn' (Enforced=$enforcedValue, Enabled=$enabledValue)." -ForegroundColor Yellow
        }
        else {
            New-GPLink -Name $gpoName `
                       -Target $targetDn `
                       -Enforced $enforcedValue `
                       -LinkEnabled $enabledValue | Out-Null
        }
    }
}

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
        $ou   = $comp.ou
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

        $ouPartial = $user.ou
        $path      = "$ouPartial,$DomainDN"

        $password  = $user.password
        $enabled   = [bool]$user.enabled

        $upn       = "$numericId@$DomainFQDN"

        $existing = Get-ADUser -Filter "sAMAccountName -eq '$sam'" -ErrorAction SilentlyContinue

        if ($existing) {
            Write-Host "User exists: $sam" -ForegroundColor DarkGray
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

    Invoke-DeploySitesAndOUs  -StructureConfig $structureConfig -DomainDN $DomainDN
    Invoke-DeployGroups       -UsersConfig $usersConfig   -DomainDN $DomainDN
    Invoke-DeployServices     -ServicesConfig $servicesConfig -DomainFQDN $DomainFQDN
    Invoke-DeployGPOs         -GpoConfig $gpoConfig       -DomainDN $DomainDN
    Invoke-DeployComputers    -ComputersConfig $computersConfig -DomainDN $DomainDN
    Invoke-DeployUsers        -UsersConfig $usersConfig   -DomainFQDN $DomainFQDN -DomainDN $DomainDN

    Write-Host "`nDeployment complete for exercise '$ExerciseName'." -ForegroundColor Green
}
catch {
    Write-Error $_
    exit 1
}
