# ============================================================
# IT235 - Prove 3.7 Progress Checker
# Designed to run with:
#
# irm https://raw.githubusercontent.com/ToddStruiksma/IT235/main/Prove3.7.ps1 | iex
#
# ============================================================

# ----------------------------
# Display Helpers
# ----------------------------

function Write-Color {
    param(
        [string]$Text,
        [string]$Color = 'White'
    )

    Write-Host $Text -ForegroundColor $Color
}

function Write-Box {
    param(
        [string]$Title,
        [string[]]$Lines
    )

    $maxLength = ($Lines | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    $width = [Math]::Max($maxLength, $Title.Length) + 4
    $border = '=' * ($width + 2)

    Write-Color $border 'Green'
    Write-Color ("= " + $Title.PadRight($width - 2) + " =") 'Yellow'
    Write-Color $border 'Green'

    foreach ($line in $Lines) {
        Write-Color ("| " + $line.PadRight($width) + " |") 'White'
    }

    Write-Color $border 'Green'
}


# ----------------------------
# Collect System Information
# ----------------------------

$computerName = [System.Environment]::MachineName
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$currentDateTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$adDsInstalled = $false
$isDomainJoined = $false
$isDomainController = $false
$domainName = $null
$region = 'Unavailable'
$domainAdminExists = $false
$domainAdminEnabled = $false
$domainAdminIsDomainAdmin = $false
$whoAmI = (whoami.exe 2>$null).Trim()

try {
    $adFeature = Get-WindowsFeature -Name AD-Domain-Services -ErrorAction Stop
    $adDsInstalled = [bool]($adFeature.Installed -or $adFeature.InstallState -eq 'Installed')
}
catch {
    $adDsInstalled = $false
}

try {
    $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $isDomainJoined = [bool]$computerSystem.PartOfDomain
    $domainName = $computerSystem.Domain
    $isDomainController = $isDomainJoined -and -not [string]::IsNullOrWhiteSpace($domainName)
}
catch {
    $isDomainJoined = $false
}

try {
    Import-Module ActiveDirectory -ErrorAction Stop

    $domainAdmin = Get-ADUser -Identity 'domainadmin' -Properties Enabled, MemberOf -ErrorAction Stop
    $domainAdminExists = $true
    $domainAdminEnabled = [bool]$domainAdmin.Enabled

    $domainAdminGroup = Get-ADGroup -Identity 'Domain Admins' -ErrorAction Stop
    $domainAdminIsDomainAdmin = $domainAdmin.MemberOf -contains $domainAdminGroup.DistinguishedName
}
catch {
    # Win32_ComputerSystem.Domain remains the fallback domain source.
}

try {
    $imdsToken = Invoke-RestMethod `
        -Uri 'http://169.254.169.254/latest/api/token' `
        -Method Put `
        -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '60' } `
        -TimeoutSec 2 `
        -ErrorAction Stop
    $region = Invoke-RestMethod `
        -Uri 'http://169.254.169.254/latest/meta-data/placement/region' `
        -Headers @{ 'X-aws-ec2-metadata-token' = $imdsToken } `
        -TimeoutSec 2 `
        -ErrorAction Stop
}
catch {
    $region = 'Unavailable'
}

$displayDomain = if ($domainName) { $domainName } else { 'Not detected' }

# ----------------------------
# Header and System Information
# ----------------------------

Write-Host ''
Write-Color '============================================================' 'Green'
Write-Color '              IT235 - PROVE 3.7 CHECKER' 'Yellow'
Write-Color '============================================================' 'Green'
Write-Host ''

$systemLines = @(
    "Computer Name : $computerName",
    "Logged On User: $currentUser",
    "Date and Time : $currentDateTime",
    "Domain        : $displayDomain",
    "AWS Region    : $region"
)

Write-Box -Title 'System Information' -Lines $systemLines
Write-Host ''


# ============================================================
# CHECKS
# ============================================================

$context = @{
    ComputerName             = $computerName
    CurrentUser              = $currentUser
    CurrentDateTime          = $currentDateTime
    Region                   = $region
    AdDsInstalled            = $adDsInstalled
    IsDomainJoined           = $isDomainJoined
    IsDomainController       = $isDomainController
    DomainName               = $domainName
    DomainAdminExists        = $domainAdminExists
    DomainAdminEnabled       = $domainAdminEnabled
    DomainAdminIsDomainAdmin = $domainAdminIsDomainAdmin
    WhoAmI                   = $whoAmI
}

$tests = @(
	@{
		Name   = 'Active Directory Domain Services is installed'
		Expect = 'AD-Domain-Services installed on the server'
		Test   = { param($c) $c.AdDsInstalled }
	},
    @{
        Name   = 'Server is joined to a domain'
        Expect = 'Windows reports that the server is part of a domain'
        Test   = { param($c) $c.IsDomainJoined -and -not [string]::IsNullOrWhiteSpace($c.DomainName) }
    },
    @{
        Name   = 'Server is a domain controller'
        Expect = 'The NTDS service is running and an Active Directory domain is detected'
        Test   = { param($c) $c.IsDomainController -and -not [string]::IsNullOrWhiteSpace($c.DomainName) }
    },
    @{
        Name   = 'The domainadmin account exists and is enabled'
        Expect = 'An enabled Active Directory user named domainadmin'
        Test   = { param($c) $c.DomainAdminExists -and $c.DomainAdminEnabled }
    },
    @{
        Name   = 'domainadmin has Domain Administrator privileges'
        Expect = 'domainadmin is a member of Domain Admins'
        Test   = { param($c) $c.DomainAdminIsDomainAdmin }
    },
    @{
        Name   = 'The current login is the domainadmin domain account'
        Expect = 'whoami output in the form yourdomain\domainadmin'
        Test   = { param($c) $c.WhoAmI -match '\\domainadmin$' }
    }
)


# ============================================================
# RUN CHECKS
# ============================================================

Write-Color "Running $($tests.Count) check(s)..." 'Cyan'
Write-Host ''

$results = @()

for ($i = 0; $i -lt $tests.Count; $i++) {
    $test = $tests[$i]
    $number = $i + 1

    try {
        $passed = [bool](& $test.Test $context)
        $errorMessage = $null
    }
    catch {
        $passed = $false
        $errorMessage = $_.Exception.Message
    }

    if ($passed) {
        Write-Color ("[{0}] {1} - PASS" -f $number, $test.Name) 'Green'
    }
    else {
        Write-Color ("[{0}] {1} - FAIL" -f $number, $test.Name) 'Red'
        Write-Color "      Expected : $($test.Expect)" 'Yellow'

        if ($errorMessage) {
            Write-Color "      Error    : $errorMessage" 'DarkGray'
        }
    }

    $results += [PSCustomObject]@{
        Name   = $test.Name
        Passed = $passed
    }
}


# ============================================================
# SUMMARY AND RECORDING NOTES
# ============================================================

$total = @($results).Count
$passed = @($results | Where-Object { $_.Passed }).Count
$failed = $total - $passed

Write-Host ''
Write-Box -Title 'Check Summary' -Lines @(
    "Checks Run : $total",
    "Passed     : $passed",
    "Failed     : $failed"
)

Write-Host ''
if ($failed -eq 0) {
    Write-Color "============================================================" 'Green'
    Write-Color "                 ALL CHECKS PASSED" 'Green'
    Write-Color "============================================================" 'Green'
    Write-Color "You are ready to record a video walkthrough of the assignment." 'Green'
}
else {
    Write-Color "============================================================" 'Red'
    Write-Color "             SOME CHECKS MAY NEED ATTENTION" 'Yellow'
    Write-Color "============================================================" 'Red'
    Write-Color "Please review the failed checks above and make corrections before recording your walkthrough video." 'Yellow'
    Write-Color "It is possible that some 'Failed' checks may be due to environmental factors and not a real issue." 'Yellow'
    Write-Color "IF ANY DISCREPANCIES ARE FOUND, PLEASE REFERENCE THE CANVAS ASSIGNMENT PAGE " 'Yellow'
}

Write-Host ''
Write-Color '============================================================' 'Cyan'
Write-Color '                 RECORDING NOTES' 'Cyan'
Write-Color '============================================================' 'Cyan'
Write-Color '1. Make sure your video contains audio narration describing what you are doing.' 'Cyan'
Write-Color '2. Review the Prove 3.7 assignment page to ensure that all required evidence is included in your video.' 'Cyan'
Write-Color '3. Show Active Directory Domain Services is installed.' 'Cyan'
Write-Color '4. Show the domain name and explain that the server was promoted to a domain controller.' 'Cyan'
Write-Color '5. Show the domainadmin account and its membership in Domain Admins.' 'Cyan'
Write-Color '6. Show the RDP login using yourdomain\domainadmin.' 'Cyan'
Write-Color '7. Open PowerShell or Command Prompt, run whoami, and show yourdomain\domainadmin.' 'Cyan'
Write-Color "8. Make sure your video is uploaded to a location that is accessible to the grading team." 'Cyan'
Write-Host ''



# ------------------------------------------------------------
#  Usage Tracking
# ------------------------------------------------------------

try {

    $encodedComputer = [System.Uri]::EscapeDataString($computerName)

    $trackingUrl = "https://it235-checker.todd-struiksma.workers.dev/run?checker=Prove3.7&computer=$encodedComputer"

    Invoke-RestMethod `
        -Uri $trackingUrl `
        -Method Get `
        -TimeoutSec 3 `
        -ErrorAction SilentlyContinue |
        Out-Null

}
catch {

    # Tracking is optional.
    # Never allow tracking problems to affect the checker.

}