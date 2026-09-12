# ============================================================
# IT235 - Prove 4.6 Progress Checker
# Designed to run with:
#
# irm https://raw.githubusercontent.com/ToddStruiksma/IT235/main/Prove4.6.ps1 | iex
#
# ============================================================

$checkerName = 'Prove4.6'
$checkerDisplayName = 'Prove 4.6'


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

function Find-MiddleEarthFolder {
	# Look in the places students almost always create the folder first.
	# This lets most students skip the GUI/manual prompt entirely.
	$candidates = New-Object System.Collections.Generic.List[string]

	$commonRoots = @(
		[Environment]::GetFolderPath('Desktop')
		[Environment]::GetFolderPath('MyDocuments')
		'C:\'
		'C:\Users\Public\Desktop'
	) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

	foreach ($root in $commonRoots) {
		try {
			Get-ChildItem -LiteralPath $root -Directory -Filter 'Middle-earth' -ErrorAction SilentlyContinue |
				ForEach-Object { $candidates.Add($_.FullName) }
		}
		catch {
			# Ignore roots that can't be enumerated (permissions, etc.)
		}
	}

	if ($candidates.Count -eq 0) {
		# Fall back to a shallow recursive scan of each fixed drive so we still
		# find the folder if it was created somewhere unexpected, without
		# scanning the entire disk (which could take a very long time).
		$fixedDrives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
			Where-Object { $_.Root -match '^[A-Za-z]:\\$' }

		foreach ($drive in $fixedDrives) {
			try {
				Get-ChildItem -LiteralPath $drive.Root -Directory -Filter 'Middle-earth' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
					ForEach-Object { $candidates.Add($_.FullName) }
			}
			catch {
				# Ignore drives that can't be enumerated.
			}
		}
	}

	return @($candidates | Select-Object -Unique)
}

function Select-MiddleEarthFolder {
	Write-Color 'Searching common locations for the Middle-earth folder...' 'DarkGray'
	# Keep a single result as an array so $found[0] is the full path,
	# not the first character of the path.
	$found = @(Find-MiddleEarthFolder)

	if ($found.Count -eq 1) {
		Write-Color "Found Middle-earth folder: $($found[0])" 'Green'
		return $found[0]
	}

	if ($found.Count -gt 1) {
		Write-Color 'Multiple folders named Middle-earth were found:' 'Yellow'
		for ($i = 0; $i -lt $found.Count; $i++) {
			Write-Color ("  [{0}] {1}" -f ($i + 1), $found[$i]) 'White'
		}

		$choice = Read-Host 'Enter the number of the correct folder, paste a full path, or press Enter to skip'
		if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $found.Count) {
			return $found[[int]$choice - 1]
		}
		if (-not [string]::IsNullOrWhiteSpace($choice)) {
			return $choice.Trim().Trim('"')
		}
		return $null
	}

	Write-Color 'No Middle-earth folder was found automatically.' 'Yellow'

	# Only attempt the graphical picker when this thread is STA. In an MTA
	# session (PowerShell 7 without -sta, some remote/automation hosts),
	# ShowDialog() can throw or the window can render off-screen/behind other
	# windows with no visible error, which looks exactly like the script
	# "stalling." Skipping straight to a clear prompt avoids that trap.
	if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA) {
		try {
			Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
			Add-Type -AssemblyName System.Drawing -ErrorAction Stop

			Write-Color 'Opening a folder selection window - check your desktop (minimize everything) if it does not appear on top.' 'Cyan'

			# An invisible, always-on-top owner window forces the dialog to the
			# foreground instead of possibly opening hidden behind the console.
			$owner = New-Object System.Windows.Forms.Form
			$owner.TopMost = $true
			$owner.ShowInTaskbar = $false
			$owner.StartPosition = 'CenterScreen'
			$owner.Size = New-Object System.Drawing.Size(0, 0)
			$owner.Show()
			$owner.Focus() | Out-Null

			$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
			$dialog.Description = "Select the Middle-earth folder for $checkerDisplayName validation."
			$dialog.ShowNewFolderButton = $false

			$result = $dialog.ShowDialog($owner)
			$owner.Dispose()

			if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
				return $dialog.SelectedPath
			}

			Write-Color 'No folder was selected.' 'DarkGray'
		}
		catch {
			Write-Color "Folder picker unavailable: $($_.Exception.Message)" 'DarkGray'
		}
	}
	else {
		Write-Color 'Graphical folder picker is unavailable in this PowerShell session (not STA). Skipping to manual entry.' 'DarkGray'
	}

	$path = Read-Host 'Enter the full path to the Middle-earth folder, or press Enter to skip folder checks'
	if ([string]::IsNullOrWhiteSpace($path)) {
		return $null
	}

	return $path.Trim().Trim('"')
}

function Get-RequiredAccessEntry {
	param(
		[System.Security.AccessControl.DirectorySecurity]$Acl,
		[System.Security.Principal.SecurityIdentifier]$UserSid,
		[System.Security.AccessControl.FileSystemRights]$RequiredRights
	)

	foreach ($rule in $Acl.Access) {
		if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
			continue
		}

		try {
			$ruleSid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier])
		}
		catch {
			continue
		}

		if ($ruleSid -ne $UserSid) {
			continue
		}

		$hasRights = (($rule.FileSystemRights -band $RequiredRights) -eq $RequiredRights)
		if ($hasRights) {
			return $true
		}
	}

	return $false
}

# ----------------------------
# Collect System Information
# ----------------------------

$computerName = [System.Environment]::MachineName
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$currentDateTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$domainName = $null
$domainDistinguishedName = $null
$adAvailable = $false
$adError = $null
$folderPath = Select-MiddleEarthFolder
$adUsers = @{}
$adOus = @{}

$requiredOus = @(
	'Employees', 'HR', 'IT', 'Management',
	'Research', 'Stakeholders', 'Accounting', 'Auditors'
)

$requiredUsers = @(
	'Frodo', 'Sam', 'Merry', 'Pippin', 'Gandalf', 'Aragorn', 'Legolas',
	'Gimli', 'Boromir', 'Faramir', 'Eowyn', 'Arwen', 'Bilbo', 'Gollum'
)

try {
	Import-Module ActiveDirectory -ErrorAction Stop
	$domain = Get-ADDomain -ErrorAction Stop
	$domainName = $domain.DNSRoot
	$domainDistinguishedName = $domain.DistinguishedName
	$adAvailable = $true

	foreach ($ouName in $requiredOus) {
		try {
			$adOus[$ouName] = @(Get-ADOrganizationalUnit `
				-SearchBase $domainDistinguishedName `
				-SearchScope OneLevel `
				-Filter "Name -eq '$ouName'" `
				-ErrorAction Stop)[0]
		}
		catch {
			# Guarantee every OU name gets an entry (even $null) so a single
			# missing/erroring lookup can never short-circuit the rest of the
			# loop and leave $adOus incomplete.
			$adOus[$ouName] = $null
		}
	}

	foreach ($userName in $requiredUsers) {
		try {
			# Get-ADUser's -Identity parameter can throw during parameter
			# BINDING when the identity does not resolve, which happens
			# before the cmdlet's own error pipeline runs - ErrorAction does
			# NOT catch that. Without this try/catch, the first missing user
			# aborts the entire loop, leaving $adUsers empty, which then made
			# the "no null values found" check trivially (and wrongly) pass.
			$adUsers[$userName] = Get-ADUser -Identity $userName -Properties DistinguishedName, SID -ErrorAction Stop
		}
		catch {
			$adUsers[$userName] = $null
		}
	}
}
catch {
	$adError = $_.Exception.Message
}

$userOuAssignments = @{
	Frodo = 'HR'
	Sam = 'Research'
	Merry = 'Research'
	Gimli = 'IT'
	Gandalf = 'Stakeholders'
	Aragorn = 'Stakeholders'
	Legolas = 'Stakeholders'
	Boromir = 'Management'
	Faramir = 'Management'
	Eowyn = 'Management'
	Arwen = 'Auditors'
	Bilbo = 'Auditors'
	Gollum = 'Accounting'
	Pippin = 'Accounting'
}

$folderNames = @(
	'Employees', 'HR', 'IT', 'Management',
	'Research', 'Accounting', 'Stakeholders', 'Auditors'
)

$permissionAssignments = @{
	HR = @{
		Rights = [System.Security.AccessControl.FileSystemRights]::FullControl
		Users = @('Frodo')
		DisplayRights = 'Full Control'
	}
	Research = @{
		Rights = [System.Security.AccessControl.FileSystemRights]::Modify
		Users = @('Sam', 'Merry')
		DisplayRights = 'Modify'
	}
	IT = @{
		Rights = [System.Security.AccessControl.FileSystemRights]::FullControl
		Users = @('Gimli')
		DisplayRights = 'Full Control'
	}
	Stakeholders = @{
		Rights = [System.Security.AccessControl.FileSystemRights]::Modify
		Users = @('Gandalf', 'Aragorn', 'Legolas')
		DisplayRights = 'Modify'
	}
	Management = @{
		Rights = [System.Security.AccessControl.FileSystemRights]::Read -bor [System.Security.AccessControl.FileSystemRights]::Write
		Users = @('Boromir', 'Faramir', 'Eowyn')
		DisplayRights = 'Read and Write'
	}
	Auditors = @{
		Rights = [System.Security.AccessControl.FileSystemRights]::FullControl
		Users = @('Arwen', 'Bilbo')
		DisplayRights = 'Full Control'
	}
	Accounting = @{
		Rights = [System.Security.AccessControl.FileSystemRights]::Modify
		Users = @('Gollum', 'Pippin')
		DisplayRights = 'Modify'
	}
}

$displayDomain = if ($domainName) { $domainName } else { 'Not detected' }
$displayFolder = if ($folderPath) { $folderPath } else { 'Not selected' }

Write-Host ''
Write-Color '============================================================' 'Green'
Write-Color ("              IT235 - $($checkerDisplayName.ToUpper()) CHECKER") 'Yellow'
Write-Color '============================================================' 'Green'
Write-Host ''

Write-Box -Title 'System Information' -Lines @(
	"Computer Name : $computerName",
	"Logged On User: $currentUser",
	"Date and Time : $currentDateTime",
	"Domain        : $displayDomain",
	"Middle-earth  : $displayFolder"
)
Write-Host ''

$context = @{
	ComputerName = $computerName
	CurrentUser = $currentUser
	CurrentDateTime = $currentDateTime
	DomainName = $domainName
	DomainDistinguishedName = $domainDistinguishedName
	AdAvailable = $adAvailable
	AdError = $adError
	AdUsers = $adUsers
	AdOus = $adOus
	RequiredOus = $requiredOus
	RequiredUsers = $requiredUsers
	UserOuAssignments = $userOuAssignments
	FolderPath = $folderPath
	FolderNames = $folderNames
	PermissionAssignments = $permissionAssignments
}

$tests = @(
	@{
		Name = 'Active Directory is available'
		Expect = 'The ActiveDirectory module loads and a domain can be queried'
		Test = { param($c) $c.AdAvailable }
		Detail = {
			param($c)
			if (-not $c.AdAvailable -and $c.AdError) {
				Write-Color "      Detail   : $($c.AdError)" 'DarkGray'
			}
		}
	},
	@{
		Name = 'All required organizational units exist at the domain root'
		Expect = 'Employees, HR, IT, Management, Research, Stakeholders, Accounting, and Auditors as direct domain children'
		Test = {
			param($c)
			# Checking "zero nulls" is not sufficient on its own - a hashtable
			# that ended up empty for any reason would also report zero
			# nulls. Also require the expected number of entries.
			$c.AdAvailable -and
				$c.AdOus.Count -eq 8 -and
				@($c.AdOus.Values | Where-Object { $null -eq $_ }).Count -eq 0
		}
		Detail = {
			param($c)
			foreach ($ouName in $c.RequiredOus) {
				$ou = $c.AdOus[$ouName]
				if ($ou) {
					Write-Color ("      [FOUND]   {0,-14} {1}" -f $ouName, $ou.DistinguishedName) 'DarkGreen'
				}
				else {
					Write-Color ("      [MISSING] {0,-14}" -f $ouName) 'DarkRed'
				}
			}
		}
	},
	@{
		Name = 'All required user accounts exist'
		Expect = 'Frodo, Sam, Merry, Pippin, Gandalf, Aragorn, Legolas, Gimli, Boromir, Faramir, Eowyn, Arwen, Bilbo, and Gollum'
		Test = {
			param($c)
			$c.AdAvailable -and
				$c.AdUsers.Count -eq 14 -and
				@($c.AdUsers.Values | Where-Object { $null -eq $_ }).Count -eq 0
		}
		Detail = {
			param($c)
			foreach ($userName in $c.RequiredUsers) {
				$user = $c.AdUsers[$userName]
				if ($user) {
					Write-Color ("      [FOUND]   {0,-10} {1}" -f $userName, $user.DistinguishedName) 'DarkGreen'
				}
				else {
					Write-Color ("      [MISSING] {0,-10}" -f $userName) 'DarkRed'
				}
			}
		}
	},
	@{
		Name = 'Users are placed in the assigned organizational units'
		Expect = 'Every required user is located in the OU listed by the assignment'
		Test = {
			param($c)
			if (-not $c.AdAvailable) { return $false }

			foreach ($userName in $c.UserOuAssignments.Keys) {
				$user = $c.AdUsers[$userName]
				$expectedOu = $c.AdOus[$c.UserOuAssignments[$userName]]
				if ($null -eq $user -or $null -eq $expectedOu) { return $false }
				if ($user.DistinguishedName -notlike "*,$($expectedOu.DistinguishedName)") { return $false }
			}

			return $true
		}
		Detail = {
			param($c)
			foreach ($userName in $c.UserOuAssignments.Keys | Sort-Object) {
				$user = $c.AdUsers[$userName]
				$expectedOuName = $c.UserOuAssignments[$userName]
				$expectedOu = $c.AdOus[$expectedOuName]

				if (-not $user) {
					Write-Color ("      [MISSING] {0,-10} expected in {1}" -f $userName, $expectedOuName) 'DarkRed'
					continue
				}
				if (-not $expectedOu) {
					Write-Color ("      [SKIPPED] {0,-10} target OU '{1}' does not exist to check placement" -f $userName, $expectedOuName) 'Yellow'
					continue
				}

				$isInExpectedOu = $user.DistinguishedName -like "*,$($expectedOu.DistinguishedName)"
				if ($isInExpectedOu) {
					Write-Color ("      [OK]      {0,-10} in {1}" -f $userName, $expectedOuName) 'DarkGreen'
				}
				else {
					Write-Color ("      [WRONG OU]{0,-10} expected {1}, actual DN: {2}" -f $userName, $expectedOuName, $user.DistinguishedName) 'Red'
				}
			}
		}
	},
	@{
		Name = 'The Middle-earth folder exists'
		Expect = 'A selected folder named Middle-earth'
		Test = {
			param($c)
			if ([string]::IsNullOrWhiteSpace($c.FolderPath) -or -not (Test-Path -LiteralPath $c.FolderPath -PathType Container)) {
				return $false
			}

			# Test-Path only confirms *something* was selected - it never confirmed
			# the selected folder is actually named "Middle-earth". Without this,
			# selecting any existing folder (e.g. the Desktop) would pass.
			(Split-Path -Path $c.FolderPath -Leaf) -eq 'Middle-earth'
		}
		Detail = {
			param($c)
			if ([string]::IsNullOrWhiteSpace($c.FolderPath)) {
				Write-Color "      [MISSING] No folder was selected." 'DarkRed'
				return
			}
			if (-not (Test-Path -LiteralPath $c.FolderPath -PathType Container)) {
				Write-Color "      [MISSING] Selected path does not exist: $($c.FolderPath)" 'DarkRed'
				return
			}

			$leafName = Split-Path -Path $c.FolderPath -Leaf
			if ($leafName -eq 'Middle-earth') {
				Write-Color "      [OK]      $($c.FolderPath)" 'DarkGreen'
			}
			else {
				Write-Color "      [WRONG NAME] Folder exists but is named '$leafName', not 'Middle-earth': $($c.FolderPath)" 'Red'
			}
		}
	},
	@{
		Name = 'All required department folders exist directly inside Middle-earth'
		Expect = 'Employees, HR, IT, Management, Research, Accounting, Stakeholders, and Auditors at the same folder level'
		Test = {
			param($c)
			if ([string]::IsNullOrWhiteSpace($c.FolderPath) -or -not (Test-Path -LiteralPath $c.FolderPath -PathType Container)) { return $false }

			foreach ($folderName in $c.FolderNames) {
				$childPath = Join-Path -Path $c.FolderPath -ChildPath $folderName
				if (-not (Test-Path -LiteralPath $childPath -PathType Container)) { return $false }
			}

			return $true
		}
		Detail = {
			param($c)
			if ([string]::IsNullOrWhiteSpace($c.FolderPath) -or -not (Test-Path -LiteralPath $c.FolderPath -PathType Container)) {
				Write-Color "      (no valid Middle-earth folder to check subfolders in)" 'DarkGray'
				return
			}

			foreach ($folderName in $c.FolderNames) {
				$childPath = Join-Path -Path $c.FolderPath -ChildPath $folderName
				if (Test-Path -LiteralPath $childPath -PathType Container) {
					Write-Color ("      [FOUND]   {0,-14} {1}" -f $folderName, $childPath) 'DarkGreen'
				}
				else {
					Write-Color ("      [MISSING] {0,-14} {1}" -f $folderName, $childPath) 'DarkRed'
				}
			}
		}
	}
)

$tests += @{
	Name = 'NTFS permissions match the assignment'
	Expect = 'Each listed user has the required permission on the matching department folder'
	Test = {
		param($c)
		if ([string]::IsNullOrWhiteSpace($c.FolderPath)) { return $false }

		foreach ($folderName in $c.PermissionAssignments.Keys) {
			$assignment = $c.PermissionAssignments[$folderName]
			$folderPath = Join-Path -Path $c.FolderPath -ChildPath $folderName
			if (-not (Test-Path -LiteralPath $folderPath -PathType Container)) { return $false }

			$acl = Get-Acl -LiteralPath $folderPath -ErrorAction Stop
			foreach ($userName in $assignment.Users) {
				$user = $c.AdUsers[$userName]
				if ($null -eq $user -or -not (Get-RequiredAccessEntry -Acl $acl -UserSid $user.SID -RequiredRights $assignment.Rights)) {
					return $false
				}
			}
		}

		return $true
	}
	Detail = {
		param($c)
		if ([string]::IsNullOrWhiteSpace($c.FolderPath)) {
			Write-Color '      [ERROR]   No Middle-earth folder is available to check.' 'DarkRed'
			return
		}

		foreach ($folderName in $c.PermissionAssignments.Keys | Sort-Object) {
			$assignment = $c.PermissionAssignments[$folderName]
			$folderPath = Join-Path -Path $c.FolderPath -ChildPath $folderName
			if (-not (Test-Path -LiteralPath $folderPath -PathType Container)) {
				Write-Color ("      [MISSING FOLDER] {0}" -f $folderName) 'DarkRed'
				continue
			}

			$acl = Get-Acl -LiteralPath $folderPath -ErrorAction SilentlyContinue
			if (-not $acl) {
				Write-Color ("      [ACL ERROR]     {0} - could not read permissions" -f $folderName) 'DarkRed'
				continue
			}

			foreach ($userName in $assignment.Users) {
				$user = $c.AdUsers[$userName]
				if (-not $user) {
					Write-Color ("      [MISSING USER]   {0} on {1}" -f $userName, $folderName) 'DarkRed'
					continue
				}

				$granted = Get-RequiredAccessEntry -Acl $acl -UserSid $user.SID -RequiredRights $assignment.Rights
				if (-not $granted) {
					$actualRule = $acl.Access | Where-Object {
						try { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) -eq $user.SID } catch { $false }
					}
					$actualRights = if ($actualRule) { ($actualRule | ForEach-Object { $_.FileSystemRights }) -join ', ' } else { '(no ACE for this user)' }
					Write-Color ("      [MISSING RIGHTS] {0} on {1}: needs {2}; actual: {3}" -f $userName, $folderName, $assignment.DisplayRights, $actualRights) 'Red'
				}
				else {
					Write-Color ("      [OK]              {0} on {1}: has {2}" -f $userName, $folderName, $assignment.DisplayRights) 'DarkGreen'
				}
			}
		}
	}
}

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

	if (-not $passed -and $test.Detail) {
		try {
			& $test.Detail $context
		}
		catch {
			Write-Color "      (detail unavailable: $($_.Exception.Message))" 'DarkGray'
		}
	}

	$results += [PSCustomObject]@{
		Name = $test.Name
		Passed = $passed
	}
}

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
	Write-Color '============================================================' 'Green'
	Write-Color '                 ALL CHECKS PASSED' 'Green'
	Write-Color '============================================================' 'Green'
	Write-Color 'You are ready to record a video walkthrough of the assignment.' 'Green'
}
else {
	Write-Color '============================================================' 'Red'
	Write-Color '             SOME CHECKS MAY NEED ATTENTION' 'Yellow'
	Write-Color '============================================================' 'Red'
	Write-Color 'Please review the failed checks above and make corrections before recording your walkthrough video.' 'Yellow'
	Write-Color 'Some failures may be caused by environmental factors. Reference the Canvas assignment page for final requirements.' 'Yellow'
}

Write-Host ''
Write-Color '============================================================' 'Cyan'
Write-Color '                 RECORDING NOTES' 'Cyan'
Write-Color '============================================================' 'Cyan'
Write-Color "0. Review the $checkerDisplayName assignment instructions and requirements before recording." 'Cyan'
Write-Color '1. Include audio narration describing what you are doing.' 'Cyan'
Write-Color '2. Show the required OUs and user placement in Active Directory Users and Computers.' 'Cyan'
Write-Color '3. Show the department folders and their NTFS permissions.' 'Cyan'
Write-Color '4. Upload the video to a location accessible to the grading team.' 'Cyan'

try {
	$encodedComputer = [System.Uri]::EscapeDataString($computerName)
	$trackingUrl = "https://it235-checker.todd-struiksma.workers.dev/run?checker=$checkerName&computer=$encodedComputer"
	Invoke-RestMethod -Uri $trackingUrl -Method Get -TimeoutSec 3 -ErrorAction SilentlyContinue | Out-Null
}
catch {
	# Tracking is optional and never affects validation.
}
