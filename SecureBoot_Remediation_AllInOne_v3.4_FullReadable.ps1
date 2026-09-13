<#
.SYNOPSIS
    All-in-one Secure Boot remediation for Dell, HP, and Lenovo with Dry-Run, Testing Mode, optional UEFI check, diagnostics, standardized msg.exe notifications, and restart scheduling.

.DESCRIPTION
    Intended for Microsoft Intune Remediations.

    Dell path uses Dell Command Configure / CCTK only.
    DellBIOSProvider has been removed.

    Version 3.4 is a maintenance cleanup over 3.3:
    - Keeps the readable full script structure.
    - Fixes HTML-encoded PowerShell operators.
    - Updates version metadata and changelog.
    - Keeps Dell, HP, Lenovo remediation logic from 3.3.

    Exit 0 = compliant / remediated / pending restart / dry-run completed / testing passed
    Exit 1 = failed / unsupported / testing failed
#>

# =========================
# CONFIG
# =========================

$DryRunMode = $false

$TestingMode = $false
$TestingOnly = $false
$TestingFailScriptOnTestFailure = $false

$RequireUEFICheck = $false

$ForceCoreFunctionTest = $true
$ForceCoreFunctionWrite = $false

$AllowBIOSChanges = $true
$AllowBitLockerSuspend = $true
$AllowRestartSchedule = $true

$BiosPassword = ""   # Do NOT hardcode in production.
$SuspendBitLocker = $true

$LogPath = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\SecureBoot_Remediation.log"
$StateDir = "C:\ProgramData\SecureBootRemediation"
$RestartMarkerPath = Join-Path $StateDir "RestartMarker.json"
$ScheduledTaskPrefix = "SecureBoot_Remediation_Reminder"

$RestartDelayMinutes = 5
$Reminder1AfterMinutes = 3
$Reminder2BeforeRestartMinutes = 1

$RestartReason = "Your device will restart in 5 minutes to apply a necessary security patch. Please save your work."
$Reminder1Message = "Reminder: Your device will restart in 3 minutes to apply a necessary security patch. Please save your work."
$Reminder2Message = "Final reminder: Your device will restart in 1 minute to apply a necessary security patch. Please save your work now."
$FinalRestartReason = "Restarting now to apply a necessary security patch."

$ConsoleLog = $false

# =========================
# INIT
# =========================

$exitCode = 1
$result = "Unknown"
$errorMessage = ""

$script:rebootRequired = $false
$script:remediationAttempted = $false
$script:remediationSuccess = $false
$script:restartScheduled = $false
$script:reminderTasksCreated = 0
$script:vendorMethod = ""
$script:testPassed = 0
$script:testFailures = 0
$script:bitLockerSuspended = $false
$script:cctkPath = ""

New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force | Out-Null
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

$script:Diag = [ordered]@{
    Script                 = "SecureBoot_Remediation_AllInOne"
    Version                = "3.4"
    TsUtc                  = (Get-Date).ToUniversalTime().ToString("s") + "Z"
    Result                 = "Unknown"
    ExitCode               = 1
    DryRunMode             = [bool]$DryRunMode
    TestingMode            = [bool]$TestingMode
    RequireUEFICheck       = [bool]$RequireUEFICheck
    NotificationMode       = "MsgOnly"
    TestPassed             = 0
    TestFailed             = 0
    Manufacturer           = ""
    Model                  = ""
    UEFI                   = $null
    SecureBootBefore       = $null
    SecureBootAfter        = $null
    RemediationAttempted   = $false
    RemediationSuccess     = $false
    VendorMethod           = ""
    CctkPath               = ""
    RebootRequired         = $false
    RestartScheduled       = $false
    RestartDeadlineUtc     = ""
    ReminderTasksCreated   = 0
    BitLockerSuspended     = $false
    Error                  = ""
    Events                 = New-Object System.Collections.Generic.List[string]
}

# =========================
# COMMON FUNCTIONS
# =========================

function Add-DiagEvent {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return
    }

    $clean = $Message -replace '[\r\n\t"]', ' '

    if ($clean.Length -gt 130) {
        $clean = $clean.Substring(0,130)
    }

    if ($script:Diag.Events.Count -lt 10) {
        [void]$script:Diag.Events.Add($clean)
    }
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","SUCCESS","TEST","DRYRUN")]
        [string]$Level = "INFO"
    )

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"

    if ($ConsoleLog) {
        Write-Host $line
    }

    Add-Content -Path $LogPath -Value $line

    if ($Level -in @("WARN","ERROR","SUCCESS","TEST","DRYRUN")) {
        Add-DiagEvent "$Level $Message"
    }
}

function Add-TestResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ""
    )

    if ($Passed) {
        $script:testPassed++
        Write-Log "PASS: $Name $Details" "TEST"
    }
    else {
        $script:testFailures++
        Write-Log "FAIL: $Name $Details" "ERROR"
    }
}

function Write-DiagnosticSummary {
    param(
        [string]$FinalResult,
        [int]$FinalExitCode,
        [string]$FinalError = ""
    )

    $script:Diag.TsUtc = (Get-Date).ToUniversalTime().ToString("s") + "Z"
    $script:Diag.Result = $FinalResult
    $script:Diag.ExitCode = $FinalExitCode
    $script:Diag.DryRunMode = [bool]$DryRunMode
    $script:Diag.TestingMode = [bool]$TestingMode
    $script:Diag.RequireUEFICheck = [bool]$RequireUEFICheck
    $script:Diag.TestPassed = [int]$script:testPassed
    $script:Diag.TestFailed = [int]$script:testFailures
    $script:Diag.RemediationAttempted = [bool]$script:remediationAttempted
    $script:Diag.RemediationSuccess = [bool]$script:remediationSuccess
    $script:Diag.VendorMethod = $script:vendorMethod
    $script:Diag.CctkPath = $script:cctkPath
    $script:Diag.RebootRequired = [bool]$script:rebootRequired
    $script:Diag.RestartScheduled = [bool]$script:restartScheduled
    $script:Diag.ReminderTasksCreated = [int]$script:reminderTasksCreated
    $script:Diag.BitLockerSuspended = [bool]$script:bitLockerSuspended

    if (-not [string]::IsNullOrWhiteSpace($FinalError)) {
        $cleanError = $FinalError -replace '[\r\n\t"]', ' '

        if ($cleanError.Length -gt 300) {
            $cleanError = $cleanError.Substring(0,300)
        }

        $script:Diag.Error = $cleanError
    }

    $prefix = "DIAG_JSON="
    $maxLength = 2000
    $allowed = $maxLength - $prefix.Length

    try {
        $json = $script:Diag | ConvertTo-Json -Compress -Depth 5
    }
    catch {
        $json = '{"Script":"SecureBoot_Remediation_AllInOne","Version":"3.4","Result":"DiagnosticJsonFailed","ExitCode":1}'
    }

    if ($json.Length -gt $allowed) {
        $script:Diag.Events.Clear()
        [void]$script:Diag.Events.Add("Diagnostic output trimmed to fit 2000 chars")

        if ($script:Diag.Error.Length -gt 120) {
            $script:Diag.Error = $script:Diag.Error.Substring(0,120)
        }

        $json = $script:Diag | ConvertTo-Json -Compress -Depth 5
    }

    if ($json.Length -gt $allowed) {
        $minimal = [ordered]@{
            Script           = "SecureBoot_Remediation_AllInOne"
            Version          = "3.4"
            Result           = $FinalResult
            ExitCode         = $FinalExitCode
            DryRunMode       = [bool]$DryRunMode
            TestingMode      = [bool]$TestingMode
            NotificationMode = "MsgOnly"
            TestPassed       = [int]$script:testPassed
            TestFailed       = [int]$script:testFailures
            Manufacturer     = $script:Diag.Manufacturer
            Model            = $script:Diag.Model
            VendorMethod     = $script:vendorMethod
            CctkPath         = $script:cctkPath
            Error            = $script:Diag.Error
        }

        $json = $minimal | ConvertTo-Json -Compress -Depth 3
    }

    if (($prefix.Length + $json.Length) -gt $maxLength) {
        $json = '{"Script":"SecureBoot_Remediation_AllInOne","Version":"3.4","Result":"' + $FinalResult + '","ExitCode":' + $FinalExitCode + ',"DryRunMode":' + ([string][bool]$DryRunMode).ToLower() + ',"NotificationMode":"MsgOnly"}'
    }

    Write-Output "$prefix$json"
}

function Test-SecureBootEnabled {
    try {
        return (Confirm-SecureBootUEFI -ErrorAction Stop)
    }
    catch {
        try {
            $regValue = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State" -Name "UEFISecureBootEnabled" -ErrorAction Stop
            return ([bool]$regValue.UEFISecureBootEnabled)
        }
        catch {
            return $null
        }
    }
}

function Test-IsUEFI {
    try {
        $fwType = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "PEFirmwareType" -ErrorAction Stop).PEFirmwareType
        return ($fwType -eq 2)
    }
    catch {
        Write-Log "Could not confirm firmware type: $($_.Exception.Message)" "WARN"
        return $false
    }
}

function Get-DeviceInfo {
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $script:Diag.Manufacturer = (($cs.Manufacturer).Trim())
        $script:Diag.Model = (($cs.Model).Trim())
        return $true
    }
    catch {
        Write-Log "Failed to read device info: $($_.Exception.Message)" "WARN"
        return $false
    }
}

function Get-Manufacturer {
    if (-not [string]::IsNullOrWhiteSpace($script:Diag.Manufacturer)) {
        return $script:Diag.Manufacturer
    }

    try {
        return ((Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Manufacturer).Trim()
    }
    catch {
        Write-Log "Failed to read manufacturer: $($_.Exception.Message)" "ERROR"
        return ""
    }
}

function Get-LastBootUtc {
    try {
        return ((Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime).ToUniversalTime()
    }
    catch {
        return $null
    }
}

function Can-WriteBIOS {
    if ($DryRunMode) {
        return $false
    }

    if (-not $AllowBIOSChanges) {
        return $false
    }

    if ($TestingMode -and -not $ForceCoreFunctionWrite) {
        return $false
    }

    return $true
}

function Can-SuspendBitLocker {
    if ($DryRunMode) {
        return $false
    }

    if (-not $AllowBitLockerSuspend) {
        return $false
    }

    return $true
}

function Can-ScheduleRestart {
    if ($DryRunMode) {
        return $false
    }

    if (-not $AllowRestartSchedule) {
        return $false
    }

    return $true
}

function Suspend-BitLockerIfNeeded {
    if (-not $SuspendBitLocker) {
        Write-Log "BitLocker suspend disabled by config."
        return
    }

    try {
        $volumes = Get-BitLockerVolume -ErrorAction Stop | Where-Object { $_.ProtectionStatus -eq "On" }

        foreach ($volume in $volumes) {
            if (-not (Can-SuspendBitLocker)) {
                Write-Log "Would suspend BitLocker on $($volume.MountPoint) for 1 reboot. DryRunMode=$DryRunMode AllowBitLockerSuspend=$AllowBitLockerSuspend" "DRYRUN"
                continue
            }

            Write-Log "Suspending BitLocker on $($volume.MountPoint) for 1 reboot."
            Suspend-BitLocker -MountPoint $volume.MountPoint -RebootCount 1 -ErrorAction Stop | Out-Null
            $script:bitLockerSuspended = $true
        }
    }
    catch {
        Write-Log "BitLocker suspend/read failed or BitLocker module unavailable: $($_.Exception.Message)" "WARN"
    }
}

# =========================
# RESTART / STANDARDIZED MSG.EXE NOTIFICATION FUNCTIONS
# =========================

function Remove-OldReminderTasks {
    try {
        Get-ScheduledTask -TaskName "$ScheduledTaskPrefix*" -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Log "Removing old Secure Boot reminder/restart task: $($_.TaskName)"
            Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Log "Failed to remove old reminder/restart tasks: $($_.Exception.Message)" "WARN"
    }
}

function Get-RestartMarker {
    try {
        if (Test-Path $RestartMarkerPath) {
            return (Get-Content -Path $RestartMarkerPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
        }
    }
    catch {
        Write-Log "Failed to read restart marker: $($_.Exception.Message)" "WARN"
    }

    return $null
}

function Clear-RestartState {
    param([bool]$AbortPendingShutdown = $false)

    $hadOwnMarker = Test-Path $RestartMarkerPath
    Remove-OldReminderTasks

    try {
        Remove-Item -Path $RestartMarkerPath -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Log "Failed to remove restart marker: $($_.Exception.Message)" "WARN"
    }

    if ($AbortPendingShutdown -and $hadOwnMarker) {
        if ($DryRunMode) {
            Write-Log "Would abort pending shutdown created by this remediation, but DryRunMode=true." "DRYRUN"
            return
        }

        try {
            & shutdown.exe /a 2>$null | Out-Null
            Write-Log "Aborted pending shutdown countdown created by Secure Boot remediation." "WARN"
        }
        catch {
            # No pending shutdown to abort or shutdown.exe rejected abort.
        }
    }
}

function Initialize-RestartState {
    $marker = Get-RestartMarker

    if (-not $marker) {
        return
    }

    $lastBootUtc = Get-LastBootUtc

    try {
        $createdUtc = ([datetime]$marker.CreatedUtc).ToUniversalTime()
        $deadlineUtc = ([datetime]$marker.RestartDeadlineUtc).ToUniversalTime()

        if ($lastBootUtc -and $lastBootUtc -gt $createdUtc) {
            Write-Log "Detected reboot after previous restart marker. Cleaning old reminder state."
            Clear-RestartState -AbortPendingShutdown:$false
            return
        }

        if ((Get-Date).ToUniversalTime() -gt $deadlineUtc) {
            Write-Log "Previous restart marker expired. Cleaning old reminder state."
            Clear-RestartState -AbortPendingShutdown:$false
            return
        }
    }
    catch {
        Write-Log "Restart marker invalid. Cleaning old reminder state." "WARN"
        Clear-RestartState -AbortPendingShutdown:$false
    }
}

function New-EncodedPowerShellTask {
    param(
        [string]$TaskName,
        [datetime]$RunAt,
        [string]$PowerShellCode
    )

    try {
        $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($PowerShellCode))
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
        $trigger = New-ScheduledTaskTrigger -Once -At $RunAt
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -Compatibility Win8 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable:$false

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-Log "Created scheduled task '$TaskName' for $($RunAt.ToString('yyyy-MM-dd HH:mm:ss'))."
        return $true
    }
    catch {
        Write-Log "Failed to create scheduled task '$TaskName': $($_.Exception.Message)" "WARN"
        return $false
    }
}

function New-ReminderTask {
    param(
        [string]$TaskName,
        [datetime]$RunAt,
        [string]$Message
    )

    $encodedMessage = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Message))

    $command = @"
`$msg = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$encodedMessage'))
try { & "`$env:SystemRoot\System32\msg.exe" * /TIME:300 `$msg 2>`$null } catch {}
try { Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false -ErrorAction SilentlyContinue } catch {}
"@

    $created = New-EncodedPowerShellTask -TaskName $TaskName -RunAt $RunAt -PowerShellCode $command

    if ($created) {
        $script:reminderTasksCreated++
    }

    return $created
}

function Show-UserMessageNow {
    param([string]$Message)

    try {
        & "$env:SystemRoot\System32\msg.exe" * /TIME:300 $Message 2>$null
        Write-Log "Displayed immediate user message via msg.exe."
        return $true
    }
    catch {
        Write-Log "Failed to display immediate msg.exe message: $($_.Exception.Message)" "WARN"
        return $false
    }
}

function New-RestartTask {
    param(
        [string]$TaskName,
        [datetime]$RunAt,
        [string]$Reason
    )

    $encodedReason = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Reason))

    $command = @"
`$reason = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$encodedReason'))
try { & "`$env:SystemRoot\System32\shutdown.exe" /r /f /t 0 /c `$reason /d p:2:17 } catch {}
try { Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false -ErrorAction SilentlyContinue } catch {}
"@

    return New-EncodedPowerShellTask -TaskName $TaskName -RunAt $RunAt -PowerShellCode $command
}

function Test-ReminderTaskCreation {
    $testTaskName = "$ScheduledTaskPrefix-Test"

    try {
        Unregister-ScheduledTask -TaskName $testTaskName -Confirm:$false -ErrorAction SilentlyContinue

        $created = New-ReminderTask -TaskName $testTaskName -RunAt (Get-Date).AddMinutes(30) -Message "Secure Boot remediation test reminder. This task should be removed immediately."

        if (-not $created) {
            return $false
        }

        $exists = Get-ScheduledTask -TaskName $testTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $testTaskName -Confirm:$false -ErrorAction SilentlyContinue

        return [bool]$exists
    }
    catch {
        Write-Log "Reminder task test failed: $($_.Exception.Message)" "WARN"
        return $false
    }
}

function Start-SecureBootRestartCountdown {
    try {
        $now = Get-Date
        $restartAt = $now.AddMinutes($RestartDelayMinutes)
        $restartDeadlineUtc = $restartAt.ToUniversalTime()
        $script:Diag.RestartDeadlineUtc = $restartDeadlineUtc.ToString("s") + "Z"

        if (-not (Can-ScheduleRestart)) {
            Write-Log "Would schedule MSG-only restart flow in $RestartDelayMinutes minutes. DryRunMode=$DryRunMode AllowRestartSchedule=$AllowRestartSchedule" "DRYRUN"
            Write-Log "Would show immediate msg.exe warning, reminder 1, reminder 2, and create final restart task." "DRYRUN"
            return $true
        }

        $existingMarker = Get-RestartMarker

        if ($existingMarker) {
            try {
                $deadlineUtc = ([datetime]$existingMarker.RestartDeadlineUtc).ToUniversalTime()
                $createdUtc = ([datetime]$existingMarker.CreatedUtc).ToUniversalTime()
                $lastBootUtc = Get-LastBootUtc

                if (((Get-Date).ToUniversalTime() -lt $deadlineUtc) -and (-not $lastBootUtc -or $lastBootUtc -le $createdUtc)) {
                    Write-Log "Restart already scheduled by previous remediation run. Deadline UTC: $($deadlineUtc.ToString('s'))Z" "SUCCESS"
                    $script:restartScheduled = $true
                    $script:Diag.RestartDeadlineUtc = $deadlineUtc.ToString("s") + "Z"
                    return $true
                }
            }
            catch {
                Write-Log "Existing marker could not be evaluated. Recreating restart schedule." "WARN"
                Clear-RestartState -AbortPendingShutdown:$false
            }
        }

        Remove-OldReminderTasks

        $reminder1At = $now.AddMinutes($Reminder1AfterMinutes)
        $reminder2At = $restartAt.AddMinutes(-$Reminder2BeforeRestartMinutes)

        Write-Log "Scheduling MSG-only restart flow. Restart planned in $RestartDelayMinutes minutes."

        $marker = [ordered]@{
            CreatedUtc         = $now.ToUniversalTime().ToString("o")
            RestartDeadlineUtc = $restartDeadlineUtc.ToString("o")
            Reason             = "SecureBootRemediation"
            NotificationMode   = "MsgOnly"
        }

        $marker | ConvertTo-Json -Compress | Set-Content -Path $RestartMarkerPath -Encoding UTF8 -Force

        Show-UserMessageNow -Message $RestartReason | Out-Null

        New-ReminderTask -TaskName "$ScheduledTaskPrefix-Reminder1" -RunAt $reminder1At -Message $Reminder1Message | Out-Null
        New-ReminderTask -TaskName "$ScheduledTaskPrefix-Reminder2" -RunAt $reminder2At -Message $Reminder2Message | Out-Null

        $restartTaskCreated = New-RestartTask -TaskName "$ScheduledTaskPrefix-RestartNow" -RunAt $restartAt -Reason $FinalRestartReason

        if (-not $restartTaskCreated) {
            Write-Log "Failed to create final restart task." "ERROR"
            return $false
        }

        $script:restartScheduled = $true
        $script:Diag.RestartDeadlineUtc = $restartDeadlineUtc.ToString("s") + "Z"

        Write-Log "MSG-only restart flow active. Restart planned at $($restartAt.ToString('yyyy-MM-dd HH:mm:ss'))." "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Failed to schedule MSG-only restart flow: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# =========================
# VENDOR FUNCTIONS
# =========================

function Find-DellCctk {
    $possibleCctkPaths = @(
        "$PSScriptRoot\cctk.exe",
        "$PSScriptRoot\X86_64\cctk.exe",
        "C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe",
        "C:\Program Files\Dell\Command Configure\X86_64\cctk.exe",
        "C:\Program Files\Dell\EndpointConfigure\X86_64\cctk.exe",
        "C:\Program Files (x86)\Dell\EndpointConfigure\X86_64\cctk.exe"
    )

    $cctk = $possibleCctkPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($cctk) {
        return $cctk
    }

    $searchRoots = @(
        "$env:ProgramFiles\Dell",
        "${env:ProgramFiles(x86)}\Dell",
        "$PSScriptRoot"
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path $_) }

    if ($searchRoots.Count -gt 0) {
        $found = Get-ChildItem -Path $searchRoots -Filter "cctk.exe" -Recurse -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName -First 1

        if ($found) {
            return $found
        }
    }

    return $null
}

function Enable-SecureBootDell {
    Write-Log "Dell remediation selected."
    $script:vendorMethod = "DellCCTK"

    try {
        $cctk = Find-DellCctk

        if (-not $cctk) {
            Write-Log "Dell cctk.exe not found. Package Dell Command Configure with remediation or install Dell Command Configure/Endpoint Configure." "ERROR"
            return $false
        }

        $script:cctkPath = $cctk
        Write-Log "Using Dell cctk.exe: $cctk"

        if (-not (Can-WriteBIOS)) {
            Write-Log "Would run Dell CCTK secureboot enable. No BIOS write performed." "DRYRUN"
            $script:rebootRequired = $true
            return $true
        }

        Suspend-BitLockerIfNeeded

        $passwordArg = @()

        if (-not [string]::IsNullOrWhiteSpace($BiosPassword)) {
            $passwordArg = @("--valsetuppwd=$BiosPassword")
        }

        $queryResult = & $cctk "--secureboot" 2>&1
        $queryExit = $LASTEXITCODE
        $queryResult | ForEach-Object { Write-Log "Dell CCTK current secureboot: $_" }
        Write-Log "Dell CCTK secureboot query exit code: $queryExit"

        Write-Log "Running Dell CCTK best-effort command: --legacyorom=disable"
        $legacyResult = & $cctk "--legacyorom=disable" @passwordArg 2>&1
        $legacyExit = $LASTEXITCODE
        $legacyResult | ForEach-Object { Write-Log "Dell CCTK legacyorom: $_" }

        if ($legacyExit -ne 0) {
            Write-Log "Dell CCTK legacyorom returned exit code $legacyExit. Continuing because this setting may not exist on modern Dell models." "WARN"
        }

        Write-Log "Running Dell CCTK best-effort command: bootorder --activebootlist=uefi"
        $bootResult = & $cctk "bootorder" "--activebootlist=uefi" @passwordArg 2>&1
        $bootExit = $LASTEXITCODE
        $bootResult | ForEach-Object { Write-Log "Dell CCTK bootorder: $_" }

        if ($bootExit -ne 0) {
            Write-Log "Dell CCTK bootorder returned exit code $bootExit. Continuing to Secure Boot command." "WARN"
        }

        Write-Log "Running Dell CCTK required command: --secureboot=enable"
        $secureBootResult = & $cctk "--secureboot=enable" @passwordArg 2>&1
        $secureBootExit = $LASTEXITCODE
        $secureBootText = ($secureBootResult | Out-String)

        $secureBootResult | ForEach-Object { Write-Log "Dell CCTK secureboot: $_" }
        Write-Log "Dell CCTK secureboot exit code: $secureBootExit"

        if ($secureBootExit -ne 0) {
            Write-Log "Dell CCTK secureboot command failed. ExitCode=$secureBootExit Output=$secureBootText" "ERROR"
            return $false
        }

        if ($secureBootText -match "error|failed|fail|unsupported|not available|password|denied|invalid") {
            Write-Log "Dell CCTK secureboot output indicates failure. Output=$secureBootText" "ERROR"
            return $false
        }

        $script:rebootRequired = $true
        Write-Log "Dell Secure Boot command submitted successfully through CCTK. Reboot required." "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Dell CCTK method failed: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Enable-SecureBootHP {
    Write-Log "HP remediation selected."
    $script:vendorMethod = "HPBIOSWMI"

    try {
        $namespace = "root\HP\InstrumentedBIOS"
        $interface = Get-CimInstance -Namespace $namespace -ClassName HP_BIOSSettingInterface -ErrorAction Stop
        $settings = Get-CimInstance -Namespace $namespace -ClassName HP_BIOSSetting -ErrorAction Stop

        if (Can-WriteBIOS) {
            Suspend-BitLockerIfNeeded
        }

        $passwordParam = ""

        if (-not [string]::IsNullOrWhiteSpace($BiosPassword)) {
            $passwordParam = "<utf-16/>$BiosPassword"
        }

        $candidateSettings = @(
            @{ Name = "Configure Legacy Support and Secure Boot"; Values = @( "Legacy Support Disable and Secure Boot Enable", "Legacy Support Disabled and Secure Boot Enabled" ) },
            @{ Name = "Secure Boot"; Values = @("Enable", "Enabled") },
            @{ Name = "SecureBoot"; Values = @("Enable", "Enabled") },
            @{ Name = "UEFI Boot Options"; Values = @("Enable", "Enabled") },
            @{ Name = "Boot Mode"; Values = @("UEFI Native (Without CSM)", "UEFI Native") }
        )

        $appliedAny = $false

        foreach ($candidate in $candidateSettings) {
            $existing = $settings | Where-Object { $_.Name -eq $candidate.Name } | Select-Object -First 1

            if (-not $existing) {
                Write-Log "HP setting not present on this model: $($candidate.Name)"
                continue
            }

            Write-Log "HP setting found: $($candidate.Name), current value: $($existing.Value)"

            foreach ($value in $candidate.Values) {
                if (-not (Can-WriteBIOS)) {
                    Write-Log "Would set HP BIOS '$($candidate.Name)'='$value'. No BIOS write performed." "DRYRUN"
                    $appliedAny = $true
                    break
                }

                try {
                    $hpResult = Invoke-CimMethod -InputObject $interface -MethodName SetBIOSSetting -Arguments @{
                        Name     = $candidate.Name
                        Value    = $value
                        Password = $passwordParam
                    } -ErrorAction Stop

                    Write-Log "HP result for '$($candidate.Name)'='$value': $($hpResult.Return)"

                    if ($hpResult.Return -eq 0 -or $hpResult.Return -eq "Success") {
                        $appliedAny = $true
                        break
                    }
                }
                catch {
                    Write-Log "HP attempt failed for '$($candidate.Name)'='$value': $($_.Exception.Message)" "WARN"
                }
            }
        }

        if ($appliedAny) {
            $script:rebootRequired = $true
            Write-Log "HP Secure Boot related BIOS settings submitted or dry-run validated. Reboot required." "SUCCESS"
            return $true
        }

        Write-Log "No HP Secure Boot setting could be applied or dry-run validated." "ERROR"
        return $false
    }
    catch {
        Write-Log "HP remediation failed: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Enable-SecureBootLenovo {
    Write-Log "Lenovo remediation selected."
    $script:vendorMethod = "LenovoWMI"

    try {
        $biosSettings = Get-WmiObject -Namespace root\wmi -Class Lenovo_BiosSetting -ErrorAction Stop
        $secureBoot = $biosSettings | Where-Object { $_.CurrentSetting -match "^SecureBoot," } | Select-Object -First 1

        if (-not $secureBoot) {
            Write-Log "Lenovo SecureBoot setting not found." "ERROR"
            return $false
        }

        Write-Log "Current Lenovo SecureBoot value: $($secureBoot.CurrentSetting)"

        if ($secureBoot.CurrentSetting -match "SecureBoot,Enable") {
            if ($TestingMode -and $ForceCoreFunctionTest) {
                Write-Log "Lenovo Secure Boot already enabled, continuing core-path test." "TEST"
            }
            else {
                Write-Log "Lenovo Secure Boot already enabled." "SUCCESS"
                return $true
            }
        }

        if (-not (Can-WriteBIOS)) {
            Write-Log "Would set Lenovo SecureBoot,Enable and save BIOS settings. No BIOS write performed." "DRYRUN"
            $script:rebootRequired = $true
            return $true
        }

        Suspend-BitLockerIfNeeded

        $setBios = Get-WmiObject -Namespace root\wmi -Class Lenovo_SetBiosSetting -ErrorAction Stop
        $saveBios = Get-WmiObject -Namespace root\wmi -Class Lenovo_SaveBiosSettings -ErrorAction Stop

        $setResult = $setBios.SetBiosSetting("SecureBoot,Enable")
        Write-Log "Lenovo SetBiosSetting result: $($setResult.Return)"

        if (-not [string]::IsNullOrWhiteSpace($BiosPassword)) {
            try {
                $opcode = Get-WmiObject -Namespace root\wmi -Class Lenovo_WmiOpcodeInterface -ErrorAction Stop
                $opcodeResult = $opcode.WmiOpcodeInterface("WmiOpcodePasswordAdmin:$BiosPassword;")
                Write-Log "Lenovo WmiOpcodeInterface password result: $($opcodeResult.Return)"
            }
            catch {
                Write-Log "Lenovo WmiOpcodeInterface not available or failed: $($_.Exception.Message)" "WARN"
            }
        }

        $saveResult = $saveBios.SaveBiosSettings()
        Write-Log "Lenovo SaveBiosSettings result: $($saveResult.Return)"

        if ($setResult.Return -match "Success|0" -or $saveResult.Return -match "Success|0") {
            $script:rebootRequired = $true
            Write-Log "Lenovo Secure Boot setting submitted. Reboot required." "SUCCESS"
            return $true
        }

        Write-Log "Lenovo BIOS setting did not return success." "ERROR"
        return $false
    }
    catch {
        Write-Log "Lenovo remediation failed: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Invoke-VendorSecureBootFunction {
    $manufacturer = Get-Manufacturer
    $script:Diag.Manufacturer = $manufacturer

    Write-Log "Manufacturer detected: $manufacturer"

    switch -Regex ($manufacturer) {
        "Dell" {
            return (Enable-SecureBootDell)
        }
        "HP|Hewlett-Packard|Hewlett Packard" {
            return (Enable-SecureBootHP)
        }
        "Lenovo" {
            return (Enable-SecureBootLenovo)
        }
        default {
            Write-Log "Unsupported manufacturer: $manufacturer" "ERROR"
            return $false
        }
    }
}

# =========================
# TESTING PHASE
# =========================

function Invoke-TestingPhase {
    param([bool]$ExitAfterTest = $true)

    Write-Log "===== Secure Boot remediation TESTING phase started =====" "TEST"

    try {
        Add-Content -Path $LogPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [TEST] Log write validation" -ErrorAction Stop
        Add-TestResult -Name "LogPathWritable" -Passed $true -Details $LogPath
    }
    catch {
        Add-TestResult -Name "LogPathWritable" -Passed $false -Details $_.Exception.Message
    }

    $deviceInfoOk = Get-DeviceInfo
    Add-TestResult -Name "GetDeviceInfo" -Passed $deviceInfoOk -Details "$($script:Diag.Manufacturer) $($script:Diag.Model)"

    $secureBoot = Test-SecureBootEnabled
    $script:Diag.SecureBootBefore = $secureBoot
    Add-TestResult -Name "TestSecureBootEnabled" -Passed ($null -ne $secureBoot) -Details "Value=$secureBoot"

    $isUefi = Test-IsUEFI
    $script:Diag.UEFI = $isUefi

    if ($RequireUEFICheck) {
        Add-TestResult -Name "TestIsUEFI" -Passed ($isUefi -eq $true) -Details "UEFI=$isUefi RequireUEFICheck=true"
    }
    else {
        Write-Log "UEFI check result: $isUefi. Not enforced because RequireUEFICheck=false." "WARN"
        Add-TestResult -Name "TestIsUEFIOptional" -Passed $true -Details "UEFI=$isUefi RequireUEFICheck=false"
    }

    try {
        $volumes = Get-BitLockerVolume -ErrorAction Stop
        Add-TestResult -Name "BitLockerReadAccess" -Passed $true -Details "Volumes=$($volumes.Count)"
    }
    catch {
        Add-TestResult -Name "BitLockerReadAccess" -Passed $false -Details $_.Exception.Message
    }

    Suspend-BitLockerIfNeeded
    Add-TestResult -Name "SuspendBitLockerGuard" -Passed $true -Details "DryRunMode=$DryRunMode AllowBitLockerSuspend=$AllowBitLockerSuspend"

    $taskTest = Test-ReminderTaskCreation
    Add-TestResult -Name "ReminderTaskCreateRemove" -Passed $taskTest

    $restartTest = Start-SecureBootRestartCountdown
    Add-TestResult -Name "RestartScheduleGuard" -Passed $restartTest -Details "DryRunMode=$DryRunMode AllowRestartSchedule=$AllowRestartSchedule NotificationMode=MsgOnly"

    $script:remediationAttempted = $true
    $vendorTest = Invoke-VendorSecureBootFunction
    $script:remediationSuccess = [bool]$vendorTest

    Add-TestResult -Name "VendorCoreFunctionPath" -Passed $vendorTest -Details "Method=$script:vendorMethod ForceCoreFunctionTest=$ForceCoreFunctionTest DryRunMode=$DryRunMode"

    Write-Log "===== Secure Boot remediation TESTING phase finished. Passed=$script:testPassed Failed=$script:testFailures =====" "TEST"

    if ($script:testFailures -gt 0 -and $TestingFailScriptOnTestFailure) {
        if ($ExitAfterTest) {
            Write-DiagnosticSummary -FinalResult "TestingFailed" -FinalExitCode 1 -FinalError "One or more testing checks failed"
            exit 1
        }

        return $false
    }

    if ($ExitAfterTest) {
        Write-DiagnosticSummary -FinalResult "TestingCompleted" -FinalExitCode 0
        exit 0
    }

    return ($script:testFailures -eq 0)
}

# =========================
# MAIN
# =========================

Write-Log "===== Secure Boot remediation started ====="

if ($DryRunMode) {
    Write-Log "DRY-RUN MODE ENABLED. No BIOS changes, BitLocker suspend, restart scheduling, or shutdown abort will be performed." "DRYRUN"
}

try {
    Initialize-RestartState

    if ($TestingMode) {
        $testOk = Invoke-TestingPhase -ExitAfterTest:$TestingOnly

        if (-not $testOk -and $TestingFailScriptOnTestFailure) {
            $result = "TestingFailed"
            $errorMessage = "One or more testing checks failed"
            $exitCode = 1
            throw $errorMessage
        }
    }

    Get-DeviceInfo | Out-Null

    $secureBootBefore = Test-SecureBootEnabled
    $script:Diag.SecureBootBefore = $secureBootBefore

    if ($secureBootBefore -eq $true -and -not ($TestingMode -and $ForceCoreFunctionTest)) {
        Write-Log "Secure Boot already enabled. No remediation needed." "SUCCESS"
        Clear-RestartState -AbortPendingShutdown:$true

        $result = "AlreadyCompliant"
        $exitCode = 0
    }
    else {
        if ($secureBootBefore -eq $true -and $TestingMode -and $ForceCoreFunctionTest) {
            Write-Log "Secure Boot already enabled, but TestingMode + ForceCoreFunctionTest allows vendor core-path execution." "TEST"
        }

        $isUefi = Test-IsUEFI
        $script:Diag.UEFI = $isUefi

        if (-not $isUefi -and $RequireUEFICheck) {
            Write-Log "Device is not confirmed as UEFI. Secure Boot cannot be enabled safely by this remediation." "ERROR"

            $result = "FailedNotUEFI"
            $errorMessage = "Device not confirmed as UEFI"
            $exitCode = 1
        }
        else {
            if (-not $isUefi -and -not $RequireUEFICheck) {
                Write-Log "UEFI check failed or could not confirm UEFI, but continuing because RequireUEFICheck=false." "WARN"
            }

            $script:remediationAttempted = $true
            $success = Invoke-VendorSecureBootFunction
            $script:remediationSuccess = [bool]$success

            $secureBootAfter = Test-SecureBootEnabled
            $script:Diag.SecureBootAfter = $secureBootAfter

            if ($success) {
                if ($DryRunMode) {
                    Write-Log "Dry-run completed successfully. Changes were not applied." "SUCCESS"

                    $result = "DryRunCompleted"
                    $exitCode = 0
                }
                elseif ($secureBootAfter -eq $true) {
                    Write-Log "Secure Boot is now enabled." "SUCCESS"
                    Clear-RestartState -AbortPendingShutdown:$false

                    $result = "CompliantAfterRemediation"
                    $exitCode = 0
                }
                elseif ($script:rebootRequired) {
                    Write-Log "Secure Boot change submitted. Restart required before detection turns green." "SUCCESS"

                    $restartOk = Start-SecureBootRestartCountdown

                    if ($restartOk) {
                        $result = "RemediatedPendingRestart"
                        $exitCode = 0
                    }
                    else {
                        $result = "RemediatedButRestartScheduleFailed"
                        $errorMessage = "Secure Boot remediation succeeded, but restart scheduling failed"
                        $exitCode = 1
                    }
                }
                else {
                    Write-Log "Command completed, but Secure Boot is not confirmed enabled yet." "WARN"

                    $result = "CompletedButNotConfirmed"
                    $exitCode = 0
                }
            }
            else {
                Write-Log "Secure Boot remediation failed." "ERROR"

                $result = "FailedVendorRemediation"
                $errorMessage = "Vendor remediation returned false"
                $exitCode = 1
            }
        }
    }
}
catch {
    if ([string]::IsNullOrWhiteSpace($result) -or $result -eq "Unknown") {
        $result = "FailedUnhandled"
    }

    if ([string]::IsNullOrWhiteSpace($errorMessage)) {
        $errorMessage = $_.Exception.Message
    }

    Write-Log "Unhandled remediation error: $($_.Exception.Message)" "ERROR"
    $exitCode = 1
}
finally {
    Write-Log "===== Secure Boot remediation finished ====="
}

Write-DiagnosticSummary -FinalResult $result -FinalExitCode $exitCode -FinalError $errorMessage
exit $exitCode




# =========================
# CHANGELOG
# SecureBoot_Remediation_AllInOne
# Latest version: 3.4
# =========================
#
# Version 3.4
# -------------------------
# Maintenance and syntax cleanup:
# - Kept the expanded/readable v3.3 structure.
# - Replaced HTML-encoded PowerShell operators with native PowerShell syntax.
# - Replaced encoded call operator text with native ampersand call operator in executable code.
# - Replaced encoded greater-than redirection text with native PowerShell redirection in executable code.
# - Replaced encoded HP BIOS password prefix with native HP utf-16 password prefix in executable code.
# - Updated script Version field from 3.3 to 3.4.
# - Updated diagnostic fallback JSON version strings from 3.3 to 3.4.
# - Updated minimal diagnostic JSON version string from 3.3 to 3.4.
# - Updated changelog latest version from 3.3 to 3.4.
#
# Restart/notification:
# - Kept standardized msg.exe-only notification flow from v3.3.
# - Kept scheduled final restart task using shutdown.exe with immediate zero-second timeout.
# - Renamed reminder scheduled task suffixes from time-specific names to generic Reminder1 and Reminder2.
# - No restart scheduling logic change beyond task name cleanup.
#
# Dell remediation:
# - No Dell remediation logic change from v3.3.
# - Dell CCTK remains the only Dell remediation method.
# - DellBIOSProvider remains removed from executable remediation logic.
# - Dell legacyorom remains best-effort only.
# - Dell bootorder activebootlist UEFI remains best-effort only.
# - Dell secureboot enable remains the required command.
#
# HP remediation:
# - No HP remediation logic change from v3.3.
# - HP still uses HP BIOS WMI under root\HP\InstrumentedBIOS.
# - HP BIOS password prefix is now native PowerShell text, not HTML-encoded text.
#
# Lenovo remediation:
# - No Lenovo remediation logic change from v3.3.
# - Lenovo still uses Lenovo WMI under root\wmi.
#
# Quality:
# - Preserved the readable full script format instead of compressing functions into one-line blocks.
# - Preserved detailed historical changelog sections.
# - Reduced risk of copy/paste failures from HTML-rendered sources.
# - Confirmed no long shutdown countdown is used.
# - Confirmed final restart still uses a scheduled task and shutdown.exe immediate restart.
#
# Version 3.3
# -------------------------
# Dell remediation:
# - Improved Dell CCTK execution quality.
# - Dell CCTK remains the only Dell remediation method.
# - DellBIOSProvider remains removed.
# - Dell CCTK path support retained for:
#     C:\Program Files\Dell\EndpointConfigure\X86_64\cctk.exe
#     C:\Program Files (x86)\Dell\EndpointConfigure\X86_64\cctk.exe
#     C:\Program Files\Dell\Command Configure\X86_64\cctk.exe
#     C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe
# - Changed Dell legacyorom handling to best-effort only.
# - Changed Dell bootorder --activebootlist=uefi handling to best-effort only.
# - Dell remediation now hard-fails only when the required secureboot enable command fails.
# - Added Dell Secure Boot query before applying changes.
# - Added clearer CCTK output and exit-code logging.
# - Added output-content validation for Dell secureboot command failures.
#
# BitLocker:
# - Moved BitLocker suspension closer to actual vendor BIOS write operation.
# - Removed early BitLocker suspension from main flow.
# - Dell now suspends BitLocker only after CCTK path is confirmed and BIOS write is allowed.
# - HP now suspends BitLocker only after HP BIOS WMI interface is confirmed and BIOS write is allowed.
# - Lenovo now suspends BitLocker only after Lenovo SecureBoot setting is confirmed and BIOS write is allowed.
#
# Restart/notification:
# - Kept standardized msg.exe-only notification flow from v3.2.
# - Kept scheduled final restart task using:
#     shutdown.exe /r /f /t 0
# - Replaced non-production final restart reason text with professional security restart text.
#
# Quality:
# - Reduced false Dell remediation failures caused by missing or unsupported legacyorom setting.
# - Reduced unnecessary BitLocker suspension when vendor tooling is missing or unsupported.
# - Improved troubleshooting quality for Dell CCTK failures.
#
# Notes:
# - Dell Secure Boot enable may require BIOS/admin password.
# - Password must be passed to CCTK with:
#     --valsetuppwd=<password>
# - BIOS/admin password must not be hardcoded in production.
#
# Version 3.2
# -------------------------
# Dell remediation:
# - Removed DellBIOSProvider from the Dell remediation path.
# - Dell remediation now uses Dell Command Configure / CCTK only.
# - Dell vendor method now reports as "DellCCTK".
# - Added Dell EndpointConfigure CCTK paths:
#     C:\Program Files\Dell\EndpointConfigure\X86_64\cctk.exe
#     C:\Program Files (x86)\Dell\EndpointConfigure\X86_64\cctk.exe
# - Kept support for older Dell Command Configure CCTK paths:
#     C:\Program Files\Dell\Command Configure\X86_64\cctk.exe
#     C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe
# - Added Dell CCTK command output logging.
# - Added Dell CCTK exit-code validation.
# - Dell remediation now fails if required CCTK commands return non-zero exit code.
# - Confirmed Dell Secure Boot enable requires BIOS/admin password on tested Dell Latitude device.
# - BIOS/admin password is passed to CCTK with:
#     --valsetuppwd=<password>
#
# Notification/restart:
# - Standardized restart notifications to msg.exe only.
# - Removed mixed notification behavior caused by combining shutdown.exe countdown UI and msg.exe.
# - Removed long shutdown.exe countdown:
#     shutdown.exe /r /f /t <delay>
# - Final restart is now performed by a scheduled task at the deadline.
# - Final restart task uses:
#     shutdown.exe /r /f /t 0
# - Immediate warning, reminder 1, and reminder 2 now use the same msg.exe notification style.
# - Added NotificationMode="MsgOnly" to diagnostics and restart marker.
# - Fixed duplicate reminder behavior seen when native Windows shutdown countdown and msg.exe warning fired at the same time.
#
# Diagnostics:
# - Kept DIAG_JSON output capped to 2000 characters.
# - Added/kept key diagnostic fields:
#     Result
#     ExitCode
#     DryRunMode
#     TestingMode
#     RequireUEFICheck
#     NotificationMode
#     Manufacturer
#     Model
#     UEFI
#     SecureBootBefore
#     SecureBootAfter
#     RemediationAttempted
#     RemediationSuccess
#     VendorMethod
#     RebootRequired
#     RestartScheduled
#     RestartDeadlineUtc
#     ReminderTasksCreated
#     BitLockerSuspended
#     Error
#     Events
#
# Notes:
# - DellBIOSProvider module is no longer required.
# - Dell Command Configure / CCTK must be installed locally or packaged with the remediation.
# - BIOS/admin password must be supplied securely when BIOS is password-protected.
#
# Version 3.1
# -------------------------
# Restart/reminder improvements:
# - Added forced restart scheduling after successful Secure Boot remediation.
# - Added user-facing restart warning flow.
# - Added configurable restart timing:
#     $RestartDelayMinutes
#     $Reminder1AfterMinutes
#     $Reminder2BeforeRestartMinutes
# - Added restart marker file:
#     C:\ProgramData\SecureBootRemediation\RestartMarker.json
# - Added stale restart marker cleanup.
# - Added old reminder scheduled task cleanup.
# - Added logic to avoid extending restart countdown across repeated Intune runs.
# - Added handling for users restarting earlier than the scheduled restart.
# - Added logic to clean old reminder/restart state after reboot.
#
# Initial notification design:
# - Added immediate restart warning.
# - Added reminder after configured delay.
# - Added final reminder before restart.
# - Initial implementation mixed native shutdown.exe countdown notifications with msg.exe reminders.
# - Later standardized in v3.2 to msg.exe only.
#
# Testing and dry-run:
# - Added DryRunMode.
# - DryRunMode prevents real BIOS writes.
# - DryRunMode prevents BitLocker suspension.
# - DryRunMode prevents restart scheduling.
# - DryRunMode logs intended actions instead of applying changes.
# - Added TestingMode.
# - Added TestingOnly.
# - Added TestingFailScriptOnTestFailure.
# - Added ForceCoreFunctionTest.
# - Added ForceCoreFunctionWrite guard.
# - Added testing phase for core operational checks:
#     LogPathWritable
#     GetDeviceInfo
#     TestSecureBootEnabled
#     TestIsUEFI
#     BitLockerReadAccess
#     SuspendBitLockerGuard
#     ReminderTaskCreateRemove
#     RestartScheduleGuard
#     VendorCoreFunctionPath
#
# UEFI behavior:
# - Added optional UEFI enforcement through:
#     $RequireUEFICheck
# - UEFI detection failure can be treated as warning-only when RequireUEFICheck=false.
# - This prevents false failure when registry value PEFirmwareType is missing.
#
# Diagnostics:
# - Added compact DIAG_JSON output for later Graph/API export.
# - Added max 2000-character diagnostic limit.
# - Added event trimming when diagnostic output is too long.
# - Added fallback minimal diagnostic JSON if full diagnostic output exceeds limit.
#
# BitLocker:
# - Added BitLocker suspension for one reboot.
# - Added config switch:
#     $SuspendBitLocker
# - Added guard logic so BitLocker suspension is blocked in DryRunMode.
# - Added BitLockerSuspended state to diagnostics.
#
# Vendor remediation:
# - Dell initially supported DellBIOSProvider first, then CCTK fallback.
# - HP remediation used HP BIOS WMI:
#     root\HP\InstrumentedBIOS
# - Lenovo remediation used Lenovo WMI:
#     root\wmi
#
# Notes:
# - v3.1 introduced the broad operational framework:
#     dry-run
#     testing
#     restart scheduling
#     reminders
#     diagnostic JSON
#     stale state cleanup
#
# Version 3.0
# -------------------------
# Core remediation baseline:
# - Created all-in-one Secure Boot remediation script for Intune Remediations.
# - Supported Dell, HP, and Lenovo devices.
# - Added vendor detection using:
#     Win32_ComputerSystem.Manufacturer
# - Added Secure Boot detection using:
#     Confirm-SecureBootUEFI
# - Added fallback Secure Boot detection using registry:
#     HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State
#     UEFISecureBootEnabled
# - Added UEFI firmware detection using:
#     HKLM:\SYSTEM\CurrentControlSet\Control
#     PEFirmwareType
# - Added basic logging to:
#     C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\SecureBoot_Remediation.log
#
# Dell support:
# - Added Dell Secure Boot remediation logic.
# - Initial Dell method used DellBIOSProvider when installed.
# - Added Dell Command Configure / CCTK fallback.
# - Initial Dell CCTK paths included older Command Configure locations.
# - Added Dell CCTK commands for:
#     --legacyorom=disable
#     bootorder --activebootlist=uefi
#     --secureboot=enable
#
# HP support:
# - Added HP BIOS WMI remediation.
# - Used namespace:
#     root\HP\InstrumentedBIOS
# - Used class:
#     HP_BIOSSettingInterface
# - Added candidate HP BIOS setting names:
#     Configure Legacy Support and Secure Boot
#     Secure Boot
#     SecureBoot
#     UEFI Boot Options
#     Boot Mode
# - Added support for HP password format:
#     <utf-16/>password
#
# Lenovo support:
# - Added Lenovo BIOS WMI remediation.
# - Used namespace:
#     root\wmi
# - Used classes:
#     Lenovo_BiosSetting
#     Lenovo_SetBiosSetting
#     Lenovo_SaveBiosSettings
#     Lenovo_WmiOpcodeInterface
# - Added SecureBoot,Enable setting.
# - Added SaveBiosSettings call.
# - Added optional password handling through Lenovo WmiOpcodeInterface.
#
# Exit behavior:
# - Exit 0 used for:
#     already compliant
#     remediation completed
#     remediation submitted and pending reboot
# - Exit 1 used for:
#     unsupported manufacturer
#     unsupported firmware state
#     vendor remediation failure
#     unhandled error
#
# Original limitations:
# - No restart scheduling.
# - No user reminders.
# - No dry-run mode.
# - No dedicated testing mode.
# - No Graph-friendly compact diagnostics.
# - DellBIOSProvider was preferred before CCTK.
#
# Operational notes for latest version:
# -------------------------
# - Run as SYSTEM/admin.
# - Run in 64-bit PowerShell in Intune.
# - Do not hardcode BIOS/admin password in production.
# - Provide BIOS/admin password securely if BIOS is password-protected.
# - Dell devices require Dell Command Configure / CCTK to be installed or packaged.
# - Secure Boot usually applies only after restart.
# - If user restarts earlier, marker and reminder cleanup should handle stale state on next run.
# - Avoid copying from HTML-rendered sources that preserve encoded entities.
# - Current executable code has been cleaned to use native PowerShell operators.
#
# Recommended validation config:
# - $DryRunMode = $true
# - $TestingMode = $true
# - $TestingOnly = $true
# - $ForceCoreFunctionTest = $true
# - $ForceCoreFunctionWrite = $false
#
# Recommended production config:
# - $DryRunMode = $false
# - $TestingMode = $false
# - $TestingOnly = $false
# - $AllowBIOSChanges = $true
# - $AllowBitLockerSuspend = $true
# - $AllowRestartSchedule = $true
#
# =========================
# END CHANGELOG
# =========================
