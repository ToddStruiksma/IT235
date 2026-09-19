# ============================================================
# IT235 - Prove 5.6 Progress Checker
# Designed to run with:
#
# irm https://raw.githubusercontent.com/ToddStruiksma/IT235/main/Prove5.6.ps1 | iex
#
# ============================================================

$checkerName = 'Prove5.6'
$checkerDisplayName = 'Prove 5.6'
$requiredGpoName = 'Ensign Domain Policy'
$checkerUrl = 'https://raw.githubusercontent.com/ToddStruiksma/IT235/main/Prove5.6.ps1'

function Test-IsAdministrator {
	$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
	$principal = New-Object Security.Principal.WindowsPrincipal($identity)
	return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-AdministratorRelaunch {
	param([string]$ScriptUrl)

	Write-Host 'This checker should be run as Administrator so computer-scope RSoP can be collected.' -ForegroundColor Yellow
	$answer = Read-Host 'Relaunch this checker as Administrator now? [Y/n]'
	if ($answer -match '^(n|no)$') { return $false }

	$temporaryScript = $null
	try {
		$scriptPath = $PSCommandPath
		if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
			$temporaryScript = Join-Path $env:TEMP ("Prove5.6-{0}.ps1" -f ([guid]::NewGuid().ToString('N')))
			Invoke-WebRequest -Uri $ScriptUrl -UseBasicParsing -OutFile $temporaryScript -ErrorAction Stop
			$scriptPath = $temporaryScript
		}

		$argumentList = '-NoExit -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath
		$process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argumentList -Wait -PassThru -ErrorAction Stop
        
		return $true
	}
	catch {
		Write-Host "Could not relaunch as Administrator: $($_.Exception.Message)" -ForegroundColor DarkRed
		return $false
	}
	finally {
		if ($temporaryScript) {
			Remove-Item -LiteralPath $temporaryScript -Force -ErrorAction SilentlyContinue
		}
	}
}

if (-not (Test-IsAdministrator)) {
	if (Request-AdministratorRelaunch -ScriptUrl $checkerUrl) {
		return
	}
	Write-Host 'Continuing without elevation. The computer-scope RSoP check may fail.' -ForegroundColor Yellow
}

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

function New-TempXmlPath {
	param([string]$Suffix)

	Join-Path $env:TEMP ("Prove5.6-{0}-{1}{2}" -f $PID, ([guid]::NewGuid().ToString('N')), $Suffix)
}

function Test-GpoReportContainsSetting {
	param(
		[xml]$Report,
		[string[]]$Names
	)

	if ($null -eq $Report) { return $false }
	$nodes = @($Report.SelectNodes('//*[local-name()="Name" or local-name()="DisplayName" or local-name()="SettingName"]'))
	foreach ($node in $nodes) {
		if ([string]$node.InnerText -in $Names) { return $true }
	}
	return $false
}

function Get-GpoBooleanSetting {
	param(
		[xml]$Report,
		[string]$Name
	)

	if ($null -eq $Report) { return $null }
	$account = @($Report.SelectNodes('//*[local-name()="Account"]')) |
		Where-Object {
			$nameNode = $_.SelectSingleNode('./*[local-name()="Name"]')
			$nameNode -and $nameNode.InnerText -eq $Name
		} |
		Select-Object -First 1

	if ($null -eq $account) { return $null }
	$valueNode = $account.SelectSingleNode('./*[local-name()="SettingBoolean"]')
	if ($null -eq $valueNode) { return $null }
	return [bool]::Parse($valueNode.InnerText)
}

function Get-RsopGpoNames {
	param([xml]$Report)

	if ($null -eq $Report) { return @() }
	$nodes = @($Report.SelectNodes('//*[local-name()="GPO" or local-name()="GroupPolicyObject"]'))
	$names = New-Object System.Collections.Generic.List[string]
	foreach ($node in $nodes) {
		foreach ($attributeName in @('Name', 'DisplayName', 'GPOName')) {
			$attribute = $node.Attributes[$attributeName]
			if ($attribute -and -not [string]::IsNullOrWhiteSpace($attribute.Value)) {
				$names.Add($attribute.Value)
			}
		}
		$nameNode = $node.SelectSingleNode('./*[local-name()="Name" or local-name()="DisplayName" or local-name()="GPOName"]')
		if ($nameNode -and -not [string]::IsNullOrWhiteSpace($nameNode.InnerText)) {
			$names.Add($nameNode.InnerText)
		}
	}
	return @($names | Select-Object -Unique)
}

function Format-PolicyValue {
	param($Value)

	if ($Value -is [TimeSpan]) { return ("{0} days, {1} minutes" -f $Value.Days, $Value.Minutes) }
	if ($null -eq $Value) { return '(not available)' }
	return [string]$Value
}

# ----------------------------
# Discover AD and Group Policy
# ----------------------------

$moduleError = $null
$domain = $null
$forest = $null
$gpo = $null
$rootLink = $null
$inheritance = $null
$passwordPolicy = $null
$gpoReport = $null
$rsopReport = $null
$gpoReportError = $null
$rsopError = $null
$domainError = $null

try {
	Import-Module ActiveDirectory -ErrorAction Stop
	Import-Module GroupPolicy -ErrorAction Stop

	$domain = Get-ADDomain -Current LocalComputer -ErrorAction Stop
	$forest = Get-ADForest -Current LocalComputer -ErrorAction Stop
	$pdc = $domain.PDCEmulator
	$domainName = [string]$domain.DNSRoot
	$domainDn = [string]$domain.DistinguishedName
	$forestName = [string]$forest.Name

	$gpo = Get-GPO -Name $requiredGpoName -Domain $domainName -Server $pdc -ErrorAction Stop
	$inheritance = Get-GPInheritance -Target $domainDn -Domain $domainName -Server $pdc -ErrorAction Stop
	$rootLink = @($inheritance.GpoLinks | Where-Object { $_.GpoId -eq $gpo.Id })
	$passwordPolicy = Get-ADDefaultDomainPasswordPolicy -Identity $domainName -Server $pdc -ErrorAction Stop
}
catch {
	$domainError = $_.Exception.Message
}

if ($gpo -and $domainName) {
	$gpoReportPath = New-TempXmlPath -Suffix '.gpo.xml'
	try {
		Get-GPOReport -Guid $gpo.Id -ReportType Xml -Path $gpoReportPath -Domain $domainName -Server $pdc -ErrorAction Stop
		$gpoReport = [xml](Get-Content -LiteralPath $gpoReportPath -Raw -ErrorAction Stop)
	}
	catch {
		$gpoReportError = $_.Exception.Message
	}
	finally {
		Remove-Item -LiteralPath $gpoReportPath -Force -ErrorAction SilentlyContinue
	}
}

if ($gpo -and $domainName) {
	$rsopReportPath = New-TempXmlPath -Suffix '.rsop.xml'
	try {
		Get-GPResultantSetOfPolicy -Computer $env:COMPUTERNAME -ReportType Xml -Path $rsopReportPath -ErrorAction Stop
		$rsopReport = [xml](Get-Content -LiteralPath $rsopReportPath -Raw -ErrorAction Stop)
	}
	catch {
		$rsopError = $_.Exception.Message
	}
	finally {
		Remove-Item -LiteralPath $rsopReportPath -Force -ErrorAction SilentlyContinue
	}
}

$computerName = [Environment]::MachineName
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$currentDateTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$link = @($rootLink)[0]
$rsopNames = @(Get-RsopGpoNames -Report $rsopReport)
$rsopText = if ($rsopReport) { $rsopReport.OuterXml } else { '' }
$gpoText = if ($gpoReport) { $gpoReport.OuterXml } else { '' }
$gpoReportHasPassword = Test-GpoReportContainsSetting -Report $gpoReport -Names @('PasswordHistorySize', 'MaximumPasswordAge', 'MinimumPasswordAge', 'MinimumPasswordLength', 'PasswordComplexity', 'ClearTextPassword')
$gpoReportHasLockout = Test-GpoReportContainsSetting -Report $gpoReport -Names @('LockoutDuration', 'LockoutBadCount', 'ResetLockoutCount', 'AllowAdministratorLockout')
$allowAdministratorLockout = Get-GpoBooleanSetting -Report $gpoReport -Name 'AllowAdministratorLockout'
$rsopApplied = $false
if ($rsopText -and $gpo) {
	$guidText = ([guid]$gpo.Id).ToString('B')
	$rsopApplied = $rsopText -match [regex]::Escape($guidText) -or $rsopText -match [regex]::Escape(([guid]$gpo.Id).ToString()) -or $rsopNames -contains $requiredGpoName
}

Write-Host ''
Write-Color '============================================================' 'Green'
Write-Color ("              IT235 - $($checkerDisplayName.ToUpper()) CHECKER") 'Yellow'
Write-Color '============================================================' 'Green'
Write-Host ''

Write-Box -Title 'System Information' -Lines @(
	"Computer Name : $computerName",
	"Logged On User: $currentUser",
	"Date and Time : $currentDateTime",
	"Forest        : $(if ($forestName) { $forestName } else { 'Not detected' })",
	"Domain        : $(if ($domainName) { $domainName } else { 'Not detected' })",
	"Required GPO  : $requiredGpoName"
)
Write-Host ''

$context = @{
	DomainAvailable = $null -ne $domain -and $null -ne $gpo
	Domain = $domain
	Forest = $forest
	DomainName = $domainName
	DomainDn = $domainDn
	ForestName = $forestName
	Gpo = $gpo
	GpoLink = $link
	Inheritance = $inheritance
	PasswordPolicy = $passwordPolicy
	GpoReport = $gpoReport
	GpoReportError = $gpoReportError
	RsopReport = $rsopReport
	RsopError = $rsopError
	RsopApplied = $rsopApplied
	GpoReportHasPassword = $gpoReportHasPassword
	GpoReportHasLockout = $gpoReportHasLockout
	AllowAdministratorLockout = $allowAdministratorLockout
}

$tests = @(
	@{
		Name = 'Active Directory and Group Policy are available'
		Expect = 'The ActiveDirectory and GroupPolicy modules load and the current domain can be discovered'
		Test = { param($c) $c.DomainAvailable }
		Detail = { param($c) if ($domainError) { Write-Color "      Error: $domainError" 'DarkRed' } }
	},
	@{
		Name = 'The Ensign Domain Policy GPO exists'
		Expect = "A GPO named '$requiredGpoName' in the discovered domain"
		Test = { param($c) $null -ne $c.Gpo }
		Detail = { param($c) if ($c.Gpo) { Write-Color "      GUID: $($c.Gpo.Id)" 'DarkGreen' } else { Write-Color "      GPO not found. $domainError" 'DarkRed' } }
	},
	@{
		Name = 'The GPO has computer settings enabled'
		Expect = 'Computer settings are enabled in the GPO'
		Test = { param($c) $null -ne $c.Gpo -and $c.Gpo.GpoStatus -notin @('ComputerSettingsDisabled', 'AllSettingsDisabled') }
		Detail = { param($c) if ($c.Gpo) { Write-Color "      GPO status: $($c.Gpo.GpoStatus)" 'DarkGray' } }
	},
	@{
		Name = 'The GPO is linked directly to the domain root'
		Expect = 'A direct GpoLinks entry at the discovered domain DN'
		Test = { param($c) $null -ne $c.GpoLink -and $c.Inheritance.ContainerType -eq 'Domain' -and $c.Inheritance.Path -eq $c.DomainDn }
		Detail = { param($c) Write-Color "      Domain DN: $($c.DomainDn)" 'DarkGray' }
	},
	@{
		Name = 'The domain-root GPO link is enabled'
		Expect = 'The Ensign Domain Policy link has Enabled=True'
		Test = { param($c) $null -ne $c.GpoLink -and [bool]$c.GpoLink.Enabled }
		Detail = { param($c) if ($c.GpoLink) { Write-Color "      Enabled: $($c.GpoLink.Enabled)" 'DarkGray' } }
	},
	@{
		Name = 'The domain-root GPO link is enforced'
		Expect = 'The Ensign Domain Policy link has Enforced=True'
		Test = { param($c) $null -ne $c.GpoLink -and [bool]$c.GpoLink.Enforced }
		Detail = { param($c) if ($c.GpoLink) { Write-Color "      Enforced: $($c.GpoLink.Enforced)" 'DarkGray' } }
	},
	@{
		Name = 'The GPO is applied to this computer'
		Expect = 'Computer-scope RSoP contains the Ensign Domain Policy GPO'
		Test = { param($c) $c.RsopApplied }
		Detail = { param($c) if ($c.RsopError) { Write-Color "      RSoP error: $($c.RsopError)" 'DarkRed' } else { Write-Color '      The GPO was not found in the computer RSoP report.' 'DarkRed' } }
	},
	@{
		Name = 'The GPO report contains password and lockout policy settings'
		Expect = 'Password Policy and Account Lockout Policy settings in the GPO report'
		Test = { param($c) $c.GpoReportHasPassword -and $c.GpoReportHasLockout }
		Detail = { param($c) Write-Color "      Password section: $($c.GpoReportHasPassword); Lockout section: $($c.GpoReportHasLockout)" 'DarkGray' }
	},
	@{
		Name = 'Password policy values match the assignment'
		Expect = 'History 24, maximum age 60 days, minimum age 1 day, minimum length 14, complexity enabled, reversible encryption disabled'
		Test = {
			param($c)
			$p = $c.PasswordPolicy
			$p -and $p.PasswordHistoryCount -eq 24 -and $p.MaxPasswordAge.Days -eq 60 -and $p.MinPasswordAge.Days -eq 1 -and $p.MinPasswordLength -eq 14 -and [bool]$p.ComplexityEnabled -and -not [bool]$p.ReversibleEncryptionEnabled
		}
		Detail = {
			param($c)
			$p = $c.PasswordPolicy
			if ($p) { Write-Color ("      History: {0}; Max age: {1}; Min age: {2}; Min length: {3}; Complexity: {4}; Reversible: {5}" -f $p.PasswordHistoryCount, (Format-PolicyValue $p.MaxPasswordAge), (Format-PolicyValue $p.MinPasswordAge), $p.MinPasswordLength, $p.ComplexityEnabled, $p.ReversibleEncryptionEnabled) 'DarkGray' }
		}
	},
	@{
		Name = 'Account lockout values match the assignment'
		Expect = 'Duration 30 minutes, threshold 5, reset counter 30 minutes, Administrator lockout enabled'
		Test = {
			param($c)
			$p = $c.PasswordPolicy
			$p -and $p.LockoutDuration.TotalMinutes -eq 30 -and $p.LockoutThreshold -eq 5 -and $p.LockoutObservationWindow.TotalMinutes -eq 30 -and $c.AllowAdministratorLockout -eq $true
		}
		Detail = {
			param($c)
			$p = $c.PasswordPolicy
			if ($p) {
				$adminLockout = if ($null -eq $c.AllowAdministratorLockout) { '(not found in GPO report)' } else { $c.AllowAdministratorLockout }
				Write-Color ("      Duration: {0}; Threshold: {1}; Reset window: {2}; Administrator lockout: {3}" -f (Format-PolicyValue $p.LockoutDuration), $p.LockoutThreshold, (Format-PolicyValue $p.LockoutObservationWindow), $adminLockout) 'DarkGray'
			}
		}
	}
)

Write-Color "Running $($tests.Count) check(s)..." 'Cyan'
Write-Host ''

$results = @()
for ($i = 0; $i -lt $tests.Count; $i++) {
	$test = $tests[$i]
	$passed = $false
	$errorMessage = $null
	try { $passed = [bool](& $test.Test $context) } catch { $errorMessage = $_.Exception.Message }

	if ($passed) {
		Write-Color ("[{0}] {1} - PASS" -f ($i + 1), $test.Name) 'Green'
	}
	else {
		Write-Color ("[{0}] {1} - FAIL" -f ($i + 1), $test.Name) 'Red'
		Write-Color "      Expected : $($test.Expect)" 'Yellow'
		if ($errorMessage) { Write-Color "      Error    : $errorMessage" 'DarkGray' }
		if ($test.Detail) { try { & $test.Detail $context } catch { Write-Color "      Detail unavailable: $($_.Exception.Message)" 'DarkGray' } }
	}
	$results += [PSCustomObject]@{ Name = $test.Name; Passed = $passed }
}

$total = @($results).Count
$passed = @($results | Where-Object { $_.Passed }).Count
$failed = $total - $passed

Write-Host ''
Write-Box -Title 'Check Summary' -Lines @("Checks Run : $total", "Passed     : $passed", "Failed     : $failed")
Write-Host ''
if ($failed -eq 0) {
	Write-Color '============================================================' 'Green'
	Write-Color '                 ALL CHECKS PASSED' 'Green'
	Write-Color '============================================================' 'Green'
}
else {
	Write-Color '============================================================' 'Red'
	Write-Color '             SOME CHECKS MAY NEED ATTENTION' 'Yellow'
	Write-Color '============================================================' 'Red'
}

Write-Host ''
Write-Color '============================================================' 'Cyan'
Write-Color '                 RECORDING NOTES' 'Cyan'
Write-Color '============================================================' 'Cyan'
Write-Color "0. Review the $checkerDisplayName assignment instructions before recording." 'Cyan'
Write-Color '1. Show the Ensign Domain Policy GPO and its enforced link.' 'Cyan'
Write-Color '2. Show gpresult /r or rsop.msc proving the policy is applied.' 'Cyan'
Write-Color '3. Show all six Password Policy and four Account Lockout Policy requirements.' 'Cyan'
Write-Color '4. Upload the video link to Canvas.' 'Cyan'

try {
	$encodedComputer = [Uri]::EscapeDataString($computerName)
	$trackingUrl = "https://it235-checker.todd-struiksma.workers.dev/run?checker=$checkerName&computer=$encodedComputer"
	Invoke-RestMethod -Uri $trackingUrl -Method Get -TimeoutSec 3 -ErrorAction SilentlyContinue | Out-Null
}
catch {
	# Tracking is optional and never affects validation.
}
