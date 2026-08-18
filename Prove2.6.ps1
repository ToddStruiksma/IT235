<# 
.SYNOPSIS
    Check an AWS Windows VM and display the results in a screenshot-friendly report.

.DESCRIPTION
    This script reports the VM computer name, its workgroup or domain membership, and
    the currently logged-on Windows account. It then runs the Prove 2.6 assignment
    checks and returns exit code 0 when every check passes, or exit code 1 when a check
    fails. The colored report is intended to be captured as assignment evidence.

.PARAMETER ComputerNamePattern
    Regular expression that the computer name must match. The default, 235$, checks
    that the computer name ends in 235, as required by the current assignment.

.EXAMPLE
    .\Prove2.6.ps1
    Runs the standard Prove 2.6 checks.

.EXAMPLE
    .\Prove2.6.ps1 -ComputerNamePattern '235$'
    Runs the checks with an explicit computer-name requirement.
#>

param(
        [string]$ComputerNamePattern = '235$'
)

function Write-Color {
    param(
        [string]$Text,
        [string]$Color = 'White'
    )
    Write-Host $Text -ForegroundColor $Color
}

function Write-Box {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string[]]$Lines
    )

    $maxLength = ($Lines | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    $innerWidth = [Math]::Max($maxLength, $Title.Length) + 4
    $border = '=' * ($innerWidth + 2)

    Write-Color $border 'Green'
    Write-Color ('= ' + $Title.PadRight($innerWidth - 2) + ' =') 'Yellow'
    Write-Color $border 'Green'
    foreach ($line in $Lines) {
        Write-Color ('| ' + $line.PadRight($innerWidth) + ' |') 'White'
    }
    Write-Color $border 'Green'
}

try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
} catch {
    $cs = @{ Name = $env:COMPUTERNAME; Domain = $env:USERDOMAIN; PartOfDomain = $false }
}

$computerName = $cs.Name
$netName = $cs.Domain
$isDomain = [bool]$cs.PartOfDomain
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

if ($isDomain) { $netLabel = 'Domain' } else { $netLabel = 'Workgroup' }

$systemLines = @(
    "Computer Name : $computerName",
    "$netLabel       : $netName",
    "Logged On User : $currentUser"
)

Write-Box -Title 'System Information' -Lines $systemLines

# ----------------------
# Tests (template-friendly runner)
# Add new tests to the `$tests` array below as needed.
# Each test is a hashtable with `Name` and `Test` (a scriptblock taking one parameter: the context).
# Example: @{ Name='Example'; Test = { param($ctx) $ctx.ComputerName -match 'regex$' } }
# ----------------------

function Run-Tests {
    param(
        [Parameter(Mandatory=$true)]$Context,
        [Parameter(Mandatory=$true)][array]$Tests
    )

    $results = @()
    for ($i = 0; $i -lt $Tests.Count; $i++) {
        $t = $Tests[$i]
        $num = $i + 1
        $name = $t.Name
        $sb = $t.Test
        $expectText = if ($t.ContainsKey('Expect')) { $t.Expect } else { '' }
        try {
            $raw = & $sb $Context
            $passed = [bool]$raw
            $errorMessage = $null
        } catch {
            $raw = $null
            $passed = $false
            $errorMessage = $_.Exception.Message
        }

        $status = if ($passed) { 'PASS' } else { 'FAIL' }
        $color = if ($passed) { 'Green' } else { 'Red' }

        Write-Color ("{0}) {1} - {2}" -f $num, $name, $status) $color

        if (-not $passed) {
            if ($expectText) { Write-Color ("   Expected : $expectText") 'Yellow' }
            $actualDisplay = $null
            if ($Context -is [hashtable]) {
                if ($Context.ContainsKey('ComputerName')) { $actualDisplay = $Context['ComputerName'] }
            } elseif ($Context -and $Context.PSObject.Properties.Name -contains 'ComputerName') {
                $actualDisplay = $Context.ComputerName
            }
            if (-not $actualDisplay) { $actualDisplay = $raw }
            Write-Color ("   Actual   : $actualDisplay") 'Cyan'
            if ($errorMessage) { Write-Color ("   Error    : $errorMessage") 'DarkGray' }
        }

        $results += [pscustomobject]@{ Name = $name; Passed = [bool]$passed; Actual = $actualDisplay; Expect = $expectText }
    }

    return $results
}

# Prepare context for tests.
$context = @{
    ComputerName = $computerName
    NetName = $netName
    IsDomain = $isDomain
    CurrentUser = $currentUser
}

$tests = @(
    @{
        Name = "Computer name matches '$ComputerNamePattern'"
        Expect = "Computer name matching the regular expression $ComputerNamePattern"
        Test = { param($c) $c.ComputerName -match $ComputerNamePattern }
    }
)

Write-Color "`nRunning $($tests.Count) test(s)..." 'Cyan'
$results = Run-Tests -Context $context -Tests $tests

$passedCount = (@($results | Where-Object { $_.Passed })).Count
$totalCount  = (@($results)).Count
$failedCount = $totalCount - $passedCount

$summaryLines = @(
    "Tests run : $totalCount",
    "Passed    : $passedCount",
    "Failed    : $failedCount"
)

$maxLen = ($summaryLines | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
$pad = 4
$innerW = $maxLen + $pad
$border = ('=' * ($innerW + 2))

Write-Color "`n" 'White'
Write-Color $border 'Green'
Write-Color ("= " + ' Test Summary '.PadRight($innerW - 2) + " =") 'Yellow'
Write-Color $border 'Green'
foreach ($s in $summaryLines) {
    Write-Color ("| " + $s.PadRight($innerW) + " |") 'White'
}
Write-Color $border 'Green'

if ($failedCount -gt 0) { exit 1 } else { exit 0 }
