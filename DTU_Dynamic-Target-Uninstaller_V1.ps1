<#
.SYNOPSIS
  Dynamically uninstall MSI- or (optionally) EXE-based instances of an application by DisplayName.

.DESCRIPTION
  - Searches x64 and x86 HKLM uninstall registry keys.
  - Exact DisplayName match by default (set in CONFIG).
  - Optional partial literal matching with -AllowPartialMatch.
  - MSI-first. Non-MSI uninstallers are skipped unless explicitly allowed per CONFIG.
  - Prefers QuietUninstallString when available.
  - Extracts MSI ProductCode from uninstall string or registry key name.
  - Runs:
      - msiexec.exe /x {GUID} /qn /norestart for MSI
      - or the EXE uninstall string when AllowNonMsiUninstall = $true
  - Logs transcript and MSI/EXE logs to C:\ProgramData\AppUninstallLogs.
  - Intune/SCCM friendly exit codes:
      0    = Success / already not installed
      3010 = Success, reboot required
      1    = Failure

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\Uninstall-AppByName.ps1

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\Uninstall-AppByName.ps1 -WhatIf
#>

param(
    # Optional switches for testing / flexibility
    [switch]$AllowPartialMatch,
    [switch]$WhatIf
)

# =====================================================================
# CONFIG
# =====================================================================

# EDIT THIS PER APP: must match DisplayName from Programs and Features
$AppName = 'Dell'

# Allow EXE/non-MSI uninstall for THIS packaged Intune app only.
# Keep $false by default. Set to $true only after confirming the uninstall string is silent and tested as SYSTEM.
$AllowNonMsiUninstall = $true

$AllowPartialMatch  = $true

# Optional extra args to append to non-MSI uninstall commands (usually empty,
# or something like "/S" if vendor didn't bake silent switches into the registry value)
$NonMsiExtraArgs = '/S'

$EnableDetailedLogging = $false
$LogRoot = 'C:\ProgramData\AppUninstallLogs'

$global:TranscriptStarted = $false
$global:TranscriptPath    = $null
$global:OverallExitCode   = 0

$ErrorActionPreference = 'Stop'

# =====================================================================
# HELPERS
# =====================================================================

function Ensure-LogDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path -PathType Container)) {
        try {
            New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        catch {
            throw "Failed to create log directory '$Path': $($_.Exception.Message)"
        }
    }

    if (-not (Test-Path -Path $Path -PathType Container)) {
        throw "Log directory '$Path' does not exist after creation attempt."
    }
}

function Start-DetailedLogging {
    param(
        [string]$TargetAppName
    )

    if (-not $EnableDetailedLogging) {
        return
    }

    try {
        Ensure-LogDirectory -Path $LogRoot

        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $safeName  = $TargetAppName -replace '[^\w\.-]', '_'

        $global:TranscriptPath = Join-Path -Path $LogRoot -ChildPath "$safeName-uninstall-$timestamp.transcript.log"

        Start-Transcript -Path $global:TranscriptPath -IncludeInvocationHeader -Force | Out-Null
        $global:TranscriptStarted = $true

        Write-Host "Logging enabled. Transcript: $global:TranscriptPath"
    }
    catch {
        Write-Host "WARNING: Failed to start transcript logging: $($_.Exception.Message)"
        $global:TranscriptStarted = $false
        $global:TranscriptPath = $null
    }
}

function Stop-DetailedLogging {
    if ($EnableDetailedLogging -and $global:TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            Write-Host "WARNING: Failed to stop transcript: $($_.Exception.Message)"
        }
        finally {
            $global:TranscriptStarted = $false
        }
    }
}

function Get-MatchedApps {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NamePattern,

        [Parameter(Mandatory = $true)]
        [bool]$UsePartialMatch
    )

    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $results = foreach ($path in $regPaths) {
        if (-not (Test-Path -Path $path)) {
            continue
        }

        Get-ChildItem -Path $path -ErrorAction SilentlyContinue | ForEach-Object {
            # Store the current registry item before try/catch.
            $regEntry = $_

            try {
                $item = Get-ItemProperty -Path $regEntry.PSPath -ErrorAction Stop

                if (-not $item.DisplayName) {
                    return
                }

                if ($UsePartialMatch) {
                    $match = $item.DisplayName.IndexOf($NamePattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                }
                else {
                    $match = $item.DisplayName.Equals($NamePattern, [System.StringComparison]::OrdinalIgnoreCase)
                }

                if ($match) {
                    [PSCustomObject]@{
                        DisplayName          = $item.DisplayName
                        DisplayVersion       = $item.DisplayVersion
                        UninstallString      = $item.UninstallString
                        QuietUninstallString = $item.QuietUninstallString
                        PSChildName          = $regEntry.PSChildName
                        RegistryPath         = $regEntry.PSPath
                    }
                }
            }
            catch {
                Write-Host "WARNING: Failed to read registry item '$($regEntry.PSPath)': $($_.Exception.Message)"
            }
        }
    }

    return $results | Sort-Object -Property RegistryPath -Unique
}

function Get-MSIProductCode {
    param(
        [string]$UninstallString,
        [string]$RegistryKeyName
    )

    # Standard MSI ProductCode GUID regex
    $guidRegex = '\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}'

    if ($UninstallString -and $UninstallString -match $guidRegex) {
        return $matches[0]
    }

    if ($RegistryKeyName -and $RegistryKeyName -match "^$guidRegex$") {
        return $matches[0]
    }

    return $null
}

function Invoke-MSIUninstall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProductCode,

        [Parameter(Mandatory = $true)]
        [string]$DisplayName,

        [string]$DisplayVersion
    )

    $arguments = "/x $ProductCode /qn /norestart"

    if ($EnableDetailedLogging) {
        try {
            Ensure-LogDirectory -Path $LogRoot

            $safeName    = $DisplayName -replace '[^\w\.-]', '_'
            $safeVersion = if ($DisplayVersion) { $DisplayVersion -replace '[^\w\.-]', '_' } else { 'NoVersion' }
            $timestamp   = Get-Date -Format 'yyyyMMdd_HHmmss'

            $msiLogPath = Join-Path -Path $LogRoot -ChildPath "$safeName-$safeVersion-$timestamp-msi.log"
            $arguments  = "$arguments /L*v `"$msiLogPath`""
        }
        catch {
            Write-Host "  WARNING: Logging disabled for this MSI run because of log directory issue: $($_.Exception.Message)"
        }
    }

    Write-Host "  MSI uninstall command: msiexec.exe $arguments"

    if ($WhatIf) {
        Write-Host '  WhatIf: msiexec.exe will NOT be executed.'
        return
    }

    try {
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
        Write-Host "  msiexec exit code: $($proc.ExitCode)"

        switch ($proc.ExitCode) {
            0 {
                Write-Host '  Result: Success.'
            }
            1605 {
                Write-Host '  Result: Product not installed / already removed (1605). Treating as success.'
            }
            3010 {
                Write-Host '  Result: Success, reboot required (3010).'
                if ($global:OverallExitCode -eq 0) {
                    $global:OverallExitCode = 3010
                }
            }
            default {
                Write-Host "  Result: Failure. MSI exit code: $($proc.ExitCode)"
                $global:OverallExitCode = 1
            }
        }
    }
    catch {
        Write-Host "  ERROR: Failed to start msiexec.exe: $($_.Exception.Message)"
        $global:OverallExitCode = 1
    }
}

function Invoke-NonMsiUninstall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UninstallString,

        [Parameter(Mandatory = $true)]
        [string]$DisplayName,

        [string]$DisplayVersion
    )

    Write-Host "  Non-MSI uninstall string detected for '$DisplayName' (Version: $DisplayVersion):"
    Write-Host "    $UninstallString"

    if ($NonMsiExtraArgs) {
        Write-Host "  Appending extra args for non-MSI uninstall: $NonMsiExtraArgs"
        $UninstallString = "$UninstallString $NonMsiExtraArgs"
    }

    if ($WhatIf) {
        Write-Host '  WhatIf: non-MSI uninstall command will NOT be executed.'
        return
    }

    try {
        # Use cmd /c so complex EXE uninstall strings (with quotes, switches) work as in ARP.
        Write-Host '  Executing non-MSI uninstall via cmd.exe /c ...'
        $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$UninstallString`"" -WindowStyle Hidden -Wait -PassThru
        Write-Host "  Non-MSI uninstall exit code: $($proc.ExitCode)"

        if ($proc.ExitCode -eq 0) {
            Write-Host '  Result: Success (non-MSI).'
        }
        else {
            Write-Host '  Result: Failure (non-MSI).'
            $global:OverallExitCode = 1
        }
    }
    catch {
        Write-Host "  ERROR: Failed to execute non-MSI uninstall: $($_.Exception.Message)"
        $global:OverallExitCode = 1
    }
}

# =====================================================================
# MAIN
# =====================================================================

Write-Host "=== Dynamic app uninstall script ==="
Write-Host "Target application name (from CONFIG): '$AppName'"

if ($AllowPartialMatch) {
    Write-Host 'Matching mode: Partial literal contains'
}
else {
    Write-Host 'Matching mode: Exact'
}

if ($AllowNonMsiUninstall) {
    Write-Host 'Non-MSI uninstall: ENABLED for this app.'
}
else {
    Write-Host 'Non-MSI uninstall: DISABLED (MSI-only).'
}

if ($WhatIf) {
    Write-Host 'Mode: WhatIf. No changes will be made.'
}

Start-DetailedLogging -TargetAppName $AppName

try {
    Write-Host 'Searching uninstall registry for matches...'

    $apps = Get-MatchedApps -NamePattern $AppName -UsePartialMatch ([bool]$AllowPartialMatch)

    if (-not $apps -or $apps.Count -eq 0) {
        Write-Host "No installed applications found with DisplayName matching '$AppName'. Treating as success."
        $global:OverallExitCode = 0
    }
    else {
        Write-Host "Found $($apps.Count) matching installation(s):"

        foreach ($app in $apps) {
            Write-Host " - $($app.DisplayName) | Version: $($app.DisplayVersion) | Key: $($app.PSChildName)"
            Write-Host "   Registry path: $($app.RegistryPath)"
        }

        foreach ($app in $apps) {
            Write-Host ''
            Write-Host "Processing '$($app.DisplayName)' version '$($app.DisplayVersion)'..."

            $uninstallString = if ($app.QuietUninstallString) {
                $app.QuietUninstallString
            }
            else {
                $app.UninstallString
            }

            # Try MSI first: detect ProductCode from uninstall string or registry key name.
            $productCode = Get-MSIProductCode -UninstallString $uninstallString -RegistryKeyName $app.PSChildName

            if ($productCode) {
                Write-Host "  Detected MSI ProductCode: $productCode"
                Invoke-MSIUninstall `
                    -ProductCode $productCode `
                    -DisplayName $app.DisplayName `
                    -DisplayVersion $app.DisplayVersion
                continue
            }

            # No ProductCode found -> decide what to do based on config
            if ($AllowNonMsiUninstall) {
                if (-not $uninstallString) {
                    Write-Host '  Failure: no UninstallString or QuietUninstallString present, cannot perform non-MSI uninstall.'
                    $global:OverallExitCode = 1
                    continue
                }

                # At this point we allow non-MSI uninstall for this target
                Invoke-NonMsiUninstall `
                    -UninstallString $uninstallString `
                    -DisplayName $app.DisplayName `
                    -DisplayVersion $app.DisplayVersion
            }
            else {
                if (-not $uninstallString) {
                    Write-Host '  Failure: no UninstallString or QuietUninstallString present, and registry key is not an MSI ProductCode.'
                }
                elseif ($uninstallString -notmatch '(?i)\bmsiexec(?:\.exe)?\b') {
                    Write-Host '  Failure: matched app is not MSI-based. Non-MSI uninstalls are not allowed by configuration.'
                }
                else {
                    Write-Host '  Failure: MSI-like uninstall string detected, but no ProductCode GUID was found.'
                }

                $global:OverallExitCode = 1
                continue
            }
        }
    }
}
catch {
    Write-Host "FATAL ERROR: $($_.Exception.Message)"
    $global:OverallExitCode = 1
}
finally {
    Stop-DetailedLogging
    Write-Host 'Script finished.'

    if ($WhatIf) {
        exit 0
    }

    if ($global:OverallExitCode -eq 3010) {
        exit 3010
    }
    elseif ($global:OverallExitCode -eq 0) {
        exit 0
    }
    else {
        exit 1
    }
}