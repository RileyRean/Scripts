# ============================================
# Enterprise Security Check Script
# Credential Guard / HVCI / Device Guard / Secure Boot
# ============================================

$result = [PSCustomObject]@{
    ComputerName       = $env:COMPUTERNAME
    SecureBoot         = "Unknown"
    VBS                = "Unknown"
    CredentialGuard    = "Unknown"
    HVCI               = "Unknown"
}

# --------------------------------------------
# Secure Boot Check
# --------------------------------------------
try {
    $secureBoot = Confirm-SecureBootUEFI
    $result.SecureBoot = if ($secureBoot) { "Enabled" } else { "Disabled" }
}
catch {
    $result.SecureBoot = "Not Supported / Legacy"
}

# --------------------------------------------
# Device Guard / VBS Status
# --------------------------------------------
try {
    $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard

    # VBS
    if ($dg.VirtualizationBasedSecurityStatus -eq 2) {
        $result.VBS = "Running"
    } else {
        $result.VBS = "Not Running"
    }

    # Credential Guard
    if ($dg.SecurityServicesRunning -contains 1) {
        $result.CredentialGuard = "Running"
    } else {
        $result.CredentialGuard = "Not Running"
    }

    # HVCI (Memory Integrity)
    if ($dg.SecurityServicesRunning -contains 2) {
        $result.HVCI = "Running"
    } else {
        $result.HVCI = "Not Running"
    }
}
catch {
    $result.VBS             = "Error"
    $result.CredentialGuard = "Error"
    $result.HVCI            = "Error"
}

# --------------------------------------------
# Output
# --------------------------------------------
$result

# --------------------------------------------
# Exit logic (optional for compliance)
# --------------------------------------------

# Non-compliant if:
# - Secure Boot OFF
# - OR any core feature NOT running

if (
    $result.SecureBoot -ne "Enabled" -or
    $result.VBS -ne "Running" -or
    $result.CredentialGuard -ne "Running" -or
    $result.HVCI -ne "Running"
) {
    exit 2
}
else {
    exit 0
}