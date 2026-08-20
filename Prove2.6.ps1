# ============================================================
# IT235 - Prove 2.6 Progress Checker
# Designed to run with:
#
# irm https://raw.githubusercontent.com/ToddStruiksma/IT235/main/Prove2.6.ps1 | iex
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

$computerName = $env:COMPUTERNAME
$currentUser  = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$currentDateTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$isWindowsEC2 = $false

try {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop

    $netName  = $cs.Domain
    $isDomain = [bool]$cs.PartOfDomain

    if ($isDomain) {
        $netLabel = 'Domain'
    }
    else {
        $netLabel = 'Workgroup'
    }
}
catch {
    $netName  = $env:USERDOMAIN
    $netLabel = 'Domain/Workgroup'
    $isDomain = $false
}

try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $imdsToken = Invoke-RestMethod `
        -Uri 'http://169.254.169.254/latest/api/token' `
        -Method Put `
        -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '60' } `
        -TimeoutSec 2 `
        -ErrorAction Stop
    $instanceId = Invoke-RestMethod `
        -Uri 'http://169.254.169.254/latest/meta-data/instance-id' `
        -Headers @{ 'X-aws-ec2-metadata-token' = $imdsToken } `
        -TimeoutSec 2 `
        -ErrorAction Stop

    $isWindowsEC2 = ($os.Caption -match 'Windows') -and ($instanceId -match '^i-[a-z0-9]+$')
}
catch {
    $isWindowsEC2 = $false
}


# ----------------------------
# Header
# ----------------------------

Write-Host ""
Write-Color "============================================================" 'Green'
Write-Color "              IT235 - PROVE 2.6 CHECKER" 'Yellow'
Write-Color "============================================================" 'Green'
Write-Host ""


# ----------------------------
# System Information
# ----------------------------

$systemLines = @(
    "Computer Name : $computerName",
    "$netLabel       : $netName",
    "Logged On User : $currentUser",
    "Date and Time  : $currentDateTime"
)

Write-Box -Title 'System Information' -Lines $systemLines

Write-Host ""


# ============================================================
# CHECKS
#
# Add new checks to the $tests array below.
#
# Each check should contain:
#
# Name   = What the student sees
# Expect = What the student should have
# Test   = The PowerShell test that returns $true or $false
#
# The available system information is stored in $context.
# ============================================================

$context = @{
    ComputerName = $computerName
    NetName      = $netName
    IsDomain     = $isDomain
    CurrentUser  = $currentUser
    IsWindowsEC2 = $isWindowsEC2
}


$tests = @(

    # --------------------------------------------------------
    # CHECK 1 - Windows EC2 Instance
    # --------------------------------------------------------

    @{
        Name   = "Machine is a Windows EC2 instance"
        Expect = "Windows operating system running on an EC2 instance"
        Test   = {
            param($c)

            $c.IsWindowsEC2 -eq $true
        }
    },

    # --------------------------------------------------------
    # CHECK 2 - Computer Name
    # --------------------------------------------------------

    @{
        Name   = "Computer name ends with 235"
        Expect = "Computer name ending in 235"
        Test   = {
            param($c)

            $c.ComputerName -match '235$'
        }
    }


    # --------------------------------------------------------
    # ADD MORE CHECKS HERE
    #
    # Put a comma after the previous check and add another
    # hashtable.
    #
    # Example:
    #
    # ,@{
    #     Name   = "Computer is joined to the domain"
    #     Expect = "Domain joined"
    #     Test   = {
    #         param($c)
    #
    #         $c.IsDomain -eq $true
    #     }
    # }
    #
    # --------------------------------------------------------

)


# ============================================================
# RUN CHECKS
# ============================================================

Write-Color "Running $($tests.Count) check(s)..." 'Cyan'
Write-Host ""

$results = @()

for ($i = 0; $i -lt $tests.Count; $i++) {

    $test = $tests[$i]

    $number = $i + 1
    $name   = $test.Name
    $expect = $test.Expect

    try {

        $passed = [bool](& $test.Test $context)
        $errorMessage = $null

    }
    catch {

        $passed = $false
        $errorMessage = $_.Exception.Message

    }


    if ($passed) {

        Write-Color ("[{0}] {1} - PASS" -f $number, $name) 'Green'

    }
    else {

        Write-Color ("[{0}] {1} - FAIL" -f $number, $name) 'Red'

        if ($expect) {
            Write-Color "      Expected : $expect" 'Yellow'
        }

        if ($errorMessage) {
            Write-Color "      Error    : $errorMessage" 'DarkGray'
        }

    }


    $results += [PSCustomObject]@{
        Name   = $name
        Passed = $passed
    }
}


# ============================================================
# SUMMARY
# ============================================================

$total  = @($results).Count
$passed = @($results | Where-Object { $_.Passed }).Count
$failed = $total - $passed

Write-Host ""

$summaryLines = @(
    "Checks Run : $total",
    "Passed     : $passed",
    "Failed     : $failed"
)

Write-Box -Title 'Check Summary' -Lines $summaryLines

Write-Host ""

if ($failed -eq 0) {

    Write-Color "============================================================" 'Green'
    Write-Color "                 ALL CHECKS PASSED" 'Green'
    Write-Color "============================================================" 'Green'
    Write-Color "You are ready to record a video walkthough of the assignment." 'Cyan'

}
else {

    Write-Color "============================================================" 'Red'
    Write-Color "             SOME CHECKS NEED ATTENTION" 'Yellow'
    Write-Color "============================================================" 'Red'
    Write-Color "Please review the failed checks above and make corrections before recording your walkthrough video." 'Cyan'
    Write-Color "It is possible that some 'Failed' checks may be due to environmental factors and not a real issue." 'Cyan'

}
