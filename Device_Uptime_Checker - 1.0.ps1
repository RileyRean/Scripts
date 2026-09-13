<#
.SYNOPSIS
    Detects if a Windows device has been running longer than configured uptime threshold.

.DESCRIPTION
    Intended for Microsoft Intune Remediations / Proactive Remediations.
    Outputs compact JSON so the result can be visible in PreRemediationDetectionScriptOutput.

.EXIT CODES
    0 = Compliant
    1 = Non-compliant / remediation needed
#>

# =========================
# Configuration
# =========================

$MaxUptimeDays = 2
$DryRun = $false

# =========================
# Detection Logic
# =========================

try {
    $OS = Get-CimInstance -ClassName Win32_OperatingSystem
    $LastBootTime = $OS.LastBootUpTime
    $CurrentTime = Get-Date
    $Uptime = $CurrentTime - $LastBootTime
    $UptimeDays = [math]::Round($Uptime.TotalDays, 2)

    if ($Uptime.TotalDays -gt $MaxUptimeDays) {
        $Status = "NonCompliant"
        $ExitCode = 1
    }
    else {
        $Status = "Compliant"
        $ExitCode = 0
    }

    $Result = [PSCustomObject]@{
        Status        = $Status
        UptimeDays    = $UptimeDays
        LastBootTime  = $LastBootTime.ToString("yyyy-MM-dd HH:mm:ss")
        ThresholdDays = $MaxUptimeDays
        CurrentTime   = $CurrentTime.ToString("yyyy-MM-dd HH:mm:ss")
        DryRun        = $DryRun
    }

    Write-Output ($Result | ConvertTo-Json -Compress)

    if ($DryRun) {
        exit 0
    }

    exit $ExitCode
}
catch {
    $Result = [PSCustomObject]@{
        Status  = "DetectionError"
        Error   = $_.Exception.Message
        DryRun  = $DryRun
    }

    Write-Output ($Result | ConvertTo-Json -Compress)

    if ($DryRun) {
        exit 0
    }

    exit 1
}