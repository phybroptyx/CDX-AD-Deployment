<#
.SYNOPSIS
    Master Active Directory deployment script.

.DESCRIPTION
    Reads configuration from JSON files and builds, in order:
      1. AD Sites, Subnets, Site Links
      2. AD OU structure
      3. AD Groups
      4. AD Services (DNS, etc.)
      5. AD GPOs and Links
      6. AD Computer objects
      7. AD User accounts and group memberships

.NOTES
    Run as a Domain Admin with RSAT tools installed.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = ".\config",
    [string]$DomainFQDN,
    [string]$DomainDN,
    [switch]$WhatIf
)

Import-Module ActiveDirectory -ErrorAction Stop

Write-Host "=== Active Directory Deployment ===" -ForegroundColor Cyan
Write-Host "Config Path: $ConfigPath`n"

function Get-JsonConfig {
    param([Parameter(Mandatory)][string]$FileName)
    $fullPath = Join-Path -Path $ConfigPath -ChildPath $FileName
    if (-not (Test-Path $fullPath)) { throw "Config file not found: $fullPath" }
    Get-Content $fullPath -Raw | ConvertFrom-Json
}

if (-not $DomainFQDN -or -not $DomainDN) {
    try {
        $adDomain = Get-ADDomain
        $DomainFQDN = $adDomain.DNSRoot
        $DomainDN = $adDomain.DistinguishedName
        Write-Host "Auto-Detected Domain: $DomainFQDN ($DomainDN)" -ForegroundColor Yellow
    } catch {
        if (-not $DomainFQDN) { $DomainFQDN = Read-Host "Enter Domain FQDN (e.g. example.lab)" }
        if (-not $DomainDN) { $DomainDN = Read-Host "Enter Domain DN (e.g. DC=example,DC=lab)" }
    }
}

Write-Host "Using Domain: FQDN=$DomainFQDN, DN=$DomainDN" -ForegroundColor Cyan

function Invoke-DeploySitesAndOUs {
    param([Parameter(Mandatory)] $StructureConfig)

    Write-Host "`n[1] Deploying AD Sites, Subnets, and Site Links..." -ForegroundColor Cyan

    foreach ($site in $StructureConfig.sites) {
        if (-not (Get-ADReplicationSite -Filter "Name -eq '$($site.name)'" -ErrorAction SilentlyContinue)) {
            Write-Host "Creating Site: $($site.name)" -ForegroundColor Green
            New-ADReplicationSite -Name $site.name -Description $site.description -WhatIf:$WhatIf
        }
    }

    foreach ($subnet in $StructureConfig.subnets) {
        if (-not (Get-ADReplicationSubnet -Filter "Name -eq '$($subnet.cidr)'" -ErrorAction SilentlyContinue)) {
            Write-Host "Creating Subnet: $($subnet.cidr)" -ForegroundColor Green
            New-ADReplicationSubnet -Name $subnet.cidr -Site $subnet.site -Location $subnet.location -WhatIf:$WhatIf
        }
    }

    foreach ($link in $StructureConfig.sitelinks) {
        if (-not (Get-ADReplicationSiteLink -Filter "Name -eq '$($link.name)'" -ErrorAction SilentlyContinue)) {
            Write-Host "Creating Site Link: $($link.name)" -ForegroundColor Green
            New-ADReplicationSiteLink -Name $link.name -SitesIncluded $link.sites -Cost $link.cost -WhatIf:$WhatIf
        }
    }

    Write-Host "`n[2] Creating Organizational Units..." -ForegroundColor Cyan
    $sortedOUs = $StructureConfig.ous | Sort-Object { ([regex]::Matches($_.parent_dn, 'OU=').Count) }
    foreach ($ou in $sortedOUs) {
        $dn = "OU=$($ou.name),$($ou.parent_dn)"
        if (-not (Get-ADOrganizationalUnit -LDAPFilter "(distinguishedName=$dn)" -ErrorAction SilentlyContinue)) {
            Write-Host "Creating OU: $dn" -ForegroundColor Green
            New-ADOrganizationalUnit -Name $ou.name -Path $ou.parent_dn -Description $ou.description -ProtectedFromAccidentalDeletion:$true -WhatIf:$WhatIf
        }
    }
}

function Invoke-DeployGroups {
    param([Parameter(Mandatory)] $UsersConfig)

    Write-Host "`n[3] Creating Groups..." -ForegroundColor Cyan

    foreach ($group in $UsersConfig.groups) {
        if (-not (Get-ADGroup -Filter "sAMAccountName -eq '$($group.sAMAccountName)'" -ErrorAction SilentlyContinue)) {
            Write-Host "Creating Group: $($group.sAMAccountName)" -ForegroundColor Green
            New-ADGroup -Name $group.name -SamAccountName $group.sAMAccountName `
                        -GroupScope $group.scope -GroupCategory $group.category `
                        -Path "$($group.ou),$DomainDN" -WhatIf:$WhatIf
        }
    }
}

function Invoke-DeployServices {
    param([Parameter(Mandatory)] $ServicesConfig)

    Write-Host "`n[4] Configuring DNS..." -ForegroundColor Cyan

    if (-not (Import-Module DnsServer -ErrorAction SilentlyContinue)) {
        Write-Warning "DnsServer module unavailable. Skipping DNS."
        return
    }

    foreach ($zone in $ServicesConfig.dns.zones) {
        if (-not (Get-DnsServerZone -Name $zone.name -ErrorAction SilentlyContinue)) {
            Write-Host "Creating DNS Zone: $($zone.name)" -ForegroundColor Green
            Add-DnsServerPrimaryZone -Name $zone.name -ReplicationScope $zone.replicationScope -WhatIf:$WhatIf
        }
    }

    foreach ($fwd in $ServicesConfig.dns.forwarders) {
        if (-not ((Get-DnsServerForwarder).IPAddress -contains $fwd)) {
            Write-Host "Adding DNS Forwarder: $fwd" -ForegroundColor Green
            Add-DnsServerForwarder -IPAddress $fwd -WhatIf:$WhatIf
        }
    }
}

function Invoke-DeployGPOs {
    param([Parameter(Mandatory)] $GpoConfig)

    Write-Host "`n[5] Creating GPOs and Linking..." -ForegroundColor Cyan
    Import-Module GroupPolicy -ErrorAction SilentlyContinue

    foreach ($gpo in $GpoConfig.gpos) {
        if (-not (Get-GPO -Name $gpo.name -ErrorAction SilentlyContinue)) {
            Write-Host "Creating GPO: $($gpo.name)" -ForegroundColor Green
            New-GPO -Name $gpo.name -Comment $gpo.description -WhatIf:$WhatIf
        }
    }

    foreach ($link in $GpoConfig.links) {
        $target = "$($link.targetOu),$DomainDN"
        Write-Host "Linking GPO: $($link.gpoName) to $target" -ForegroundColor Green
        New-GPLink -Name $link.gpoName -Target $target -Enforced:$link.enforced -LinkEnabled:$link.enabled -WhatIf:$WhatIf
    }
}

function Invoke-DeployComputers {
    param([Parameter(Mandatory)] $ComputersConfig)

    Write-Host "`n[6] Creating Computer Accounts..." -ForegroundColor Cyan

    foreach ($comp in $ComputersConfig.computers) {
        $path = "$($comp.ou),$DomainDN"
        if (-not (Get-ADComputer -Filter "Name -eq '$($comp.name)'" -ErrorAction SilentlyContinue)) {
            Write-Host "Creating Computer: $($comp.name)" -ForegroundColor Green
            New-ADComputer -Name $comp.name -Path $path -Description $comp.description -WhatIf:$WhatIf
        }
    }
}

function Invoke-DeployUsers {
    param([Parameter(Mandatory)] $UsersConfig, [string]$DomainFQDN, [string]$DomainDN)

    Write-Host "`n[7] Creating User Accounts..." -ForegroundColor Cyan

    foreach ($user in $UsersConfig.users) {
        $upn = "$($user.numericId)@$DomainFQDN"
        $path = "$($user.ou),$DomainDN"

        if (-not (Get-ADUser -Filter "sAMAccountName -eq '$($user.sAMAccountName)'" -ErrorAction SilentlyContinue)) {
            Write-Host "Creating User: $($user.sAMAccountName)" -ForegroundColor Green
            New-ADUser -Name $user.displayName `
                       -SamAccountName $user.sAMAccountName `
                       -UserPrincipalName $upn `
                       -GivenName $user.givenName -Surname $user.sn `
                       -Initials $user.initials -Title $user.title `
                       -StreetAddress $user.streetAddress -City $user.city `
                       -State $user.state -PostalCode $user.postalCode `
                       -Country $user.country -OfficePhone $user.telephoneNumber `
                       -AccountPassword (ConvertTo-SecureString $user.password -AsPlainText -Force) `
                       -Path $path -Enabled $user.enabled -WhatIf:$WhatIf
        }

        foreach ($grp in $user.groups) {
            Write-Host "Ensuring membership: $($user.sAMAccountName) -> $grp" -ForegroundColor Green
            Add-ADGroupMember -Identity $grp -Members $user.sAMAccountName -ErrorAction SilentlyContinue -WhatIf:$WhatIf
        }
    }
}

# Main deployment process
try {
    $structureConfig = Get-JsonConfig -FileName "structure.json"
    $servicesConfig  = Get-JsonConfig -FileName "services.json"
    $usersConfig     = Get-JsonConfig -FileName "users.json"
    $computersConfig = Get-JsonConfig -FileName "computers.json"
    $gpoConfig       = Get-JsonConfig -FileName "gpo.json"

    Invoke-DeploySitesAndOUs -StructureConfig $structureConfig
    Invoke-DeployGroups -UsersConfig $usersConfig
    Invoke-DeployServices -ServicesConfig $servicesConfig
    Invoke-DeployGPOs -GpoConfig $gpoConfig
    Invoke-DeployComputers -ComputersConfig $computersConfig
    Invoke-DeployUsers -UsersConfig $usersConfig -DomainFQDN $DomainFQDN -DomainDN $DomainDN

    Write-Host "`nDeployment Complete." -ForegroundColor Green
} catch {
    Write-Error $_
    exit 1
}
