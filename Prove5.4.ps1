# ============================================================
# IT235 - Prove 5.4 Progress Checker
# Designed to run with:
#
# irm https://raw.githubusercontent.com/ToddStruiksma/IT235/main/Prove5.4.ps1 | iex
#
# ============================================================

$checkerName = 'Prove5.4'
$checkerDisplayName = 'Prove 5.4'


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

function Test-PortInSpec {
	# Only an explicit single port value is accepted for this assignment.
	param(
		$PortSpec,
		[int]$TargetPort
	)

	foreach ($entry in @($PortSpec)) {
		if ($null -eq $entry) { continue }
		$entryText = [string]$entry
		if ([string]::IsNullOrWhiteSpace($entryText)) { continue }
		foreach ($token in ($entryText -split ',')) {
			$token = $token.Trim()
			if ($token -match '^\d+$' -and [int]$token -eq $TargetPort) {
				return $true
			}
		}
	}

	return $false
}

function Find-FirewallRuleForPort {
	param(
		[ValidateSet('Inbound', 'Outbound')]
		[string]$Direction,

		[int]$Port,

		[string]$Protocol = 'TCP',

		[string]$Action = 'Allow'
	)

	$requiredRuleName = if ($Direction -eq 'Inbound') { 'TCP-50000-In' } else { 'TCP-50000-Out' }
	$ruleResults = New-Object 'System.Collections.Generic.List[object]'

	$rules = @(Get-NetFirewallRule `
		-PolicyStore ActiveStore `
		-ErrorAction SilentlyContinue |
		Where-Object {
			$_.DisplayName -eq $requiredRuleName -and
			$_.Direction -eq $Direction
		})

	if ($rules.Count -eq 0) {
		$ruleResults.Add([PSCustomObject]@{
			Name = $requiredRuleName
			Enabled = $false
			Action = $null
			Direction = $Direction
			Protocol = $null
			LocalPort = $null
			RemotePort = $null
			MatchedPort = $null
			PortValue = $null
			IsCorrect = $false
			Found = $false
		})
		return $ruleResults.ToArray()
	}

	foreach ($rule in $rules) {
		try {
			$portFilters = @($rule | Get-NetFirewallPortFilter -ErrorAction Stop)
		}
		catch {
			$portFilters = @()
		}

		foreach ($portFilter in $portFilters) {
			$protocolText = [string]$portFilter.Protocol
			$protocolOk = $protocolText -in @('TCP', '6')
			$directionOk = [string]$rule.Direction -ieq $Direction
			$actionOk = [string]$rule.Action -ieq $Action

			$matchedPort = $null
			if (Test-PortInSpec -PortSpec $portFilter.LocalPort -TargetPort $Port) {
				$matchedPort = 'LocalPort'
			}
			elseif (($Direction -eq 'Outbound') -and (Test-PortInSpec `
				-PortSpec $portFilter.RemotePort -TargetPort $Port)) {
				$matchedPort = 'RemotePort'
			}

			$ruleResults.Add([PSCustomObject]@{
				Name = [string]$rule.DisplayName
				Enabled = [bool]$rule.Enabled
				Action = [string]$rule.Action
				Direction = [string]$rule.Direction
				Protocol = $protocolText
				LocalPort = (@($portFilter.LocalPort) -join ', ')
				RemotePort = (@($portFilter.RemotePort) -join ', ')
				MatchedPort = $matchedPort
				PortValue = if ($matchedPort -eq 'LocalPort') { [string]$portFilter.LocalPort } else { [string]$portFilter.RemotePort }
				IsCorrect = $protocolOk -and $directionOk -and $actionOk -and $null -ne $matchedPort
				Found = $true
			})
		}
	}

	if ($ruleResults.Count -eq 0) {
		$ruleResults.Add([PSCustomObject]@{
			Name = $requiredRuleName
			Enabled = $false
			Action = $null
			Direction = $Direction
			Protocol = $null
			LocalPort = $null
			RemotePort = $null
			MatchedPort = $null
			PortValue = $null
			IsCorrect = $false
			Found = $true
		})
	}

	return $ruleResults.ToArray()
}

function Find-CandidateScheduledTasks {
	# Exclude the built-in Microsoft task library so students are only shown
	# tasks they are likely to have created themselves.
	Get-ScheduledTask -ErrorAction SilentlyContinue |
		Where-Object {
			$taskName = [string]$_.TaskName
			$taskName -notmatch '^\d+$' -and
			$taskName -ne 'CreateExplorerShellUnelevatedTask' -and
			$taskName -notlike 'MicrosoftEdgeUpdateTaskMachine*' -and
			$_.TaskPath -notlike '\Microsoft\*'
		}
}

function Select-ScheduledTaskForReview {
	Write-Color 'Searching for scheduled tasks you may have created...' 'DarkGray'
	$candidates = @(Find-CandidateScheduledTasks)

	if ($candidates.Count -eq 1) {
		Write-Color "Found scheduled task: $($candidates[0].TaskName)" 'Green'
		return $candidates[0]
	}

	if ($candidates.Count -gt 1) {
		Write-Color 'Multiple candidate scheduled tasks were found:' 'Yellow'
		for ($i = 0; $i -lt $candidates.Count; $i++) {
			Write-Color ("  [{0}] {1}  (Path: {2})" -f ($i + 1), $candidates[$i].TaskName, $candidates[$i].TaskPath) 'White'
		}

		$choice = Read-Host 'Enter the number of the correct task, type its exact name, or press Enter to skip'
		if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $candidates.Count) {
			return $candidates[[int]$choice - 1]
		}
		if (-not [string]::IsNullOrWhiteSpace($choice)) {
			try { return Get-ScheduledTask -TaskName $choice -ErrorAction Stop } catch { return $null }
		}
		return $null
	}

	Write-Color 'No obviously custom scheduled task was found automatically.' 'Yellow'
	$name = Read-Host 'Enter the exact name of the scheduled task you created, or press Enter to skip'
	if ([string]::IsNullOrWhiteSpace($name)) { return $null }

	try {
		return Get-ScheduledTask -TaskName $name -ErrorAction Stop
	}
	catch {
		Write-Color "Could not find a scheduled task named '$name': $($_.Exception.Message)" 'DarkGray'
		return $null
	}
}

function Test-ScheduledTaskActionValid {
	# Accepts either "launch a program" (any .exe/.bat/.cmd/.ps1 target, on
	# disk or resolvable on PATH) or "launch a website" (explorer.exe with an
	# http(s) argument), matching the two options the assignment allows.
	param($TaskAction)

	if ([string]::IsNullOrWhiteSpace($TaskAction.Execute)) { return $false }

	$execute = $TaskAction.Execute.Trim('"')
	$isExplorer = (Split-Path -Path $execute -Leaf -ErrorAction SilentlyContinue) -eq 'explorer.exe' -or $execute -match '(?i)^explorer(\.exe)?$'

	if ($isExplorer) {
		return $TaskAction.Arguments -match '^(https?://)'
	}

	if (Test-Path -LiteralPath $execute -ErrorAction SilentlyContinue) { return $true }
	if (Get-Command -Name $execute -ErrorAction SilentlyContinue) { return $true }

	# Fall back to a lenient extension check for a program on a path that
	# isn't resolvable in this particular session (e.g. installed but not on
	# this user's PATH).
	return $execute -match '\.(exe|bat|cmd|ps1)$'
}

# ----------------------------
# Collect System Information
# ----------------------------

$computerName = [System.Environment]::MachineName
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$currentDateTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

$inboundRuleMatches = Find-FirewallRuleForPort -Direction Inbound -Port 50000 -Protocol TCP -Action Allow
$outboundRuleMatches = Find-FirewallRuleForPort -Direction Outbound -Port 50000 -Protocol TCP -Action Allow

$selectedTask = Select-ScheduledTaskForReview

$displayTask = if ($selectedTask) { $selectedTask.TaskName } else { 'Not selected' }

Write-Host ''
Write-Color '============================================================' 'Green'
Write-Color ("              IT235 - $($checkerDisplayName.ToUpper()) CHECKER") 'Yellow'
Write-Color '============================================================' 'Green'
Write-Host ''

Write-Box -Title 'System Information' -Lines @(
	"Computer Name  : $computerName",
	"Logged On User : $currentUser",
	"Date and Time  : $currentDateTime",
	"Scheduled Task : $displayTask"
)
Write-Host ''

$context = @{
	ComputerName = $computerName
	CurrentUser = $currentUser
	SelectedTask = $selectedTask
	InboundRuleMatches = $inboundRuleMatches
	OutboundRuleMatches = $outboundRuleMatches
}

$tests = @(
	@{
		Name = 'An inbound firewall rule allows TCP port 50000'
		Expect = "A Windows Firewall rule named 'TCP-50000-In': Inbound, Allow, TCP, LocalPort 50000"
		Test = { param($c) @($c.InboundRuleMatches | Where-Object { $_.IsCorrect }).Count -gt 0 }
		Detail = {
			param($c)
			foreach ($rule in $c.InboundRuleMatches) {
				if (-not $rule.Found) {
					Write-Color "      [NOT FOUND]      Create a rule named 'TCP-50000-In'." 'DarkRed'
				}
				else {
					Write-Color ("      [MISCONFIGURED] '{0}' Enabled: {1}  Direction: {2}  Action: {3}  Protocol: {4}  LocalPort: {5}" -f $rule.Name, $rule.Enabled, $rule.Direction, $rule.Action, $rule.Protocol, $rule.LocalPort) 'Red'
				}
			}
		}
	},
	@{
		Name = 'An outbound firewall rule allows TCP port 50000'
		Expect = "A Windows Firewall rule named 'TCP-50000-Out': Outbound, Allow, TCP, LocalPort 50000 or RemotePort 50000"
		Test = { param($c) @($c.OutboundRuleMatches | Where-Object { $_.IsCorrect }).Count -gt 0 }
		Detail = {
			param($c)
			foreach ($rule in $c.OutboundRuleMatches) {
				if (-not $rule.Found) {
					Write-Color "      [NOT FOUND]      Create a rule named 'TCP-50000-Out'." 'DarkRed'
				}
				else {
					Write-Color ("      [MISCONFIGURED] '{0}' Enabled: {1}  Direction: {2}  Action: {3}  Protocol: {4}  LocalPort: {5}  RemotePort: {6}" -f $rule.Name, $rule.Enabled, $rule.Direction, $rule.Action, $rule.Protocol, $rule.LocalPort, $rule.RemotePort) 'Red'
				}
			}
		}
	},
	@{
		Name = 'A scheduled task was selected for review'
		Expect = 'A scheduled task you created is available to check'
		Test = { param($c) $null -ne $c.SelectedTask }
		Detail = {
			param($c)
			Write-Color '      No scheduled task was found or selected. Create the task, then re-run this checker.' 'DarkRed'
		}
	},
	@{
		Name = 'The scheduled task runs on a daily schedule'
		Expect = 'At least one trigger is a Daily trigger'
		Test = {
			param($c)
			if (-not $c.SelectedTask) { return $false }
			@($c.SelectedTask.Triggers | Where-Object {
				$_.CimClass.CimClassName -eq 'MSFT_TaskDailyTrigger' -and $_.Enabled -ne $false
			}).Count -gt 0
		}
		Detail = {
			param($c)
			if (-not $c.SelectedTask) {
				Write-Color '      No task selected - cannot check triggers.' 'DarkRed'
				return
			}
			$triggers = @($c.SelectedTask.Triggers)
			if ($triggers.Count -eq 0) {
				Write-Color '      This task has no triggers at all.' 'DarkRed'
				return
			}
			foreach ($trigger in $triggers) {
				$type = $trigger.CimClass.CimClassName -replace '^MSFT_Task', '' -replace 'Trigger$', ''
				Write-Color ("      Trigger: {0,-10} Enabled: {1}" -f $type, $trigger.Enabled) 'White'
			}
		}
	},
	@{
		Name = 'The scheduled task launches a program or a website'
		Expect = 'An action that runs a program, or runs explorer.exe with a http(s) argument'
		Test = {
			param($c)
			if (-not $c.SelectedTask) { return $false }
			@($c.SelectedTask.Actions | Where-Object { Test-ScheduledTaskActionValid $_ }).Count -gt 0
		}
		Detail = {
			param($c)
			if (-not $c.SelectedTask) {
				Write-Color '      No task selected - cannot check actions.' 'DarkRed'
				return
			}
			$actions = @($c.SelectedTask.Actions)
			if ($actions.Count -eq 0) {
				Write-Color '      This task has no actions at all.' 'DarkRed'
				return
			}
			foreach ($action in $actions) {
				$valid = Test-ScheduledTaskActionValid $action
				$tag = if ($valid) { '[OK]     ' } else { '[INVALID]' }
				$color = if ($valid) { 'DarkGreen' } else { 'Red' }
				Write-Color ("      {0} Execute: {1}  Arguments: {2}" -f $tag, $action.Execute, $action.Arguments) $color
			}
		}
	}
)

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

	# The matching firewall rules are useful even on a PASS, since Enabled
	# state doesn't affect pass/fail (toggling it is part of the demo).
	if ($passed -and $test.Name -like 'An * firewall rule*') {
		$ruleSet = if ($test.Name -like '*inbound*') { $context.InboundRuleMatches } else { $context.OutboundRuleMatches }
		foreach ($rule in $ruleSet) {
			Write-Color ("      Matched rule: '{0}'  Enabled: {1}  {2}: {3}" -f $rule.Name, $rule.Enabled, $rule.MatchedPort, $rule.PortValue) 'DarkGray'
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
Write-Color '2. Show active connections/listening ports (netstat -ano or Get-NetTCPConnection). Pick two ports and explain what they are used for.' 'Cyan'
Write-Color '3. Show running services (Get-Service or Server Manager). Pick two network-related services and explain what they do.' 'Cyan'
Write-Color '4. Show the port 50000 TCP firewall rule (Inbound and Outbound), including turning it on and off.' 'Cyan'
Write-Color '5. Show the scheduled task in Task Scheduler, then run it on demand and show the result.' 'Cyan'
Write-Color '6. Upload the video to a location accessible to the grading team.' 'Cyan'

try {
	$encodedComputer = [System.Uri]::EscapeDataString($computerName)
	$trackingUrl = "https://it235-checker.todd-struiksma.workers.dev/run?checker=$checkerName&computer=$encodedComputer"
	Invoke-RestMethod -Uri $trackingUrl -Method Get -TimeoutSec 3 -ErrorAction SilentlyContinue | Out-Null
}
catch {
	# Tracking is optional and never affects validation.
}